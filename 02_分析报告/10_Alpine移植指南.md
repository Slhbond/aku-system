# Alpine Linux 移植评估与实施指南
### 目标硬件：GoWild 小小白（xxb）机器人 / AKU 版 — Allwinner R8 (sun5i) / Baymin 板

> 本文基于 `aku1/` 中已提取的真实固件内容写成，不是通用模板。
> 关键结论都标注了证据来源，方便你复核。
> 文档日期：基于 2017-03-23 出厂固件（Tina Linux V1 / Linux 3.4.39）

---

## 0. 先看红绿灯（可行性速查）

| 子系统 | 原厂怎么做的 | 主线 Linux 支持情况 | 难度 | 判定 |
|---|---|---|---|---|
| **SoC / CPU** | sun5i BSP 3.4.39 | ✅ `mach-sunxi` 支持 sun5i/a13/r8 | ★ | **白送** |
| **串口 ttyS0** | `console=ttyS0,115200` | ✅ `sun5i.dtsi` 自带 | ★ | **白送** |
| **SD / MMC** | `sunxi-mmc`（内核有 SDMMC0/1/2 门控） | ✅ `sun4i-mmc` / `sunxi-mmc` | ★★ | **关键通道** |
| **PMU AXP20x** | `zhc_power.ko` + 内核 `axp20` | ✅ `axp20x` MFD + regulator + battery | ★★ | 可用 |
| **GPIO / LED / 按键** | `zhc_gpio`/`zhc_led` 读 fex `[gpio_para]`/`[led_para]` | ✅ `gpio-leds` / `gpio-keys` | ★★ | 重写 DT 即可 |
| **WiFi / BT (AP6212)** | 闭源 `bcmdhd.ko` | ✅ `brcmfmac`(SDIO) + `hci_bcm`(UART) | ★★★ | 可用，需 DT + 固件 |
| **NAND** | 厂商 `sw_nand` + 私有 `/dev/nandd` 逻辑卷 | ⚠️ `sunxi_nand` 存在，但原厂分区表主线不认 | ★★★★ | **能读，要重分区** |
| **显示 (LCD)** | Allwinner DISP/TCON + `[disp_init]` + `/dev/fb0` + DirectFB | ⚠️ `sun4i-drm` 支持 DE/TCON，**但面板型号未知** | ★★★★ | **取决于面板** |
| **音频** | **ASoC + FPGA**（`zhc_function.ko` = "ASoC FPGA driver"） | ❌ 主线无 | ★★★★★ | **最大拦路虎** |
| **FPGA iCE40** | 厂商 SPI + 自定义 DMA + mmap ioctl | ⚠️ 主线有 `ice40-spi` FPGA manager，自定义部分无 | ★★★★ | 部分可行 |
| **电量计 NAU8540** | `zhc_adc_nau8540.ko` | ❌ 主线无（`nau7802` 是另一颗芯片） | ★★★ | 需自写 IIO 驱动 |
| **原厂 App（GoWild）** | uClibc 0.9.33.2 + 闭源 `.so` | — | ★★★★★ | **基本无法复用** |

**一句话结论：**
Alpine **能跑起来**，而且"点亮 + 串口 + 网络 + 存储"是**现实目标**；
"**屏幕 + 声音**"要啃硬骨头，其中**音频走 FPGA，没有原厂资料基本做不了**；
至于"让原厂那套机器人程序继续工作"——**基本不可能**（musl/uClibc 不兼容 + 闭源库）。

---

## 1. 先想清楚：移植的本质是什么

| | 原机 | Alpine |
|---|---|---|
| 内核 | 厂商 **3.4.39 BSP** | **主线** (6.x) |
| 板级描述 | `sys_config.fex` → `script.bin` | **设备树 DTB** |
| libc | uClibc 0.9.33.2 | **musl** |
| init | procd (OpenWrt) | **OpenRC / busybox init** |
| 包管理 | opkg (.ipk) | **apk** |

所以"移植 Alpine"**不是换发行版那么简单**，真正的工作量在于：
**把整块板级支持从厂商 BSP 换成主线设备树 + 主线驱动。**

**好消息**：R8 就是 sun5i，而 **NextThing C.H.I.P. 用的正是这颗 R8** —— 主线内核和 U-Boot
对 sun5i 的支持相当成熟，SoC 级外设（串口/MMC/USB/NAND/PMU/显示控制器）基本白送。

**坏消息**：这块 **"Baymin" 是定制板**，FPGA 音频、外置 ADC、自定义电源 GPIO 树，
主线一个都没有 —— 这些要么自己写驱动，要么放弃。

---

## 2. 三条路线，先选路

### 🟢 路线 A：SD 卡起步 + 主线内核（**强烈推荐**）
- 不碰 NAND，**失败零风险**（拔卡即恢复原系统）
- 全志 BROM 的启动顺序是 **SD/MMC0 → NAND → USB FEL**，插一张带 eGON 头的卡就会从卡启动
- 唯一前提：**这台机器得有 microSD 卡槽**

### 🟡 路线 B：保留原厂 U-Boot/Boot0，只换内核 + rootfs（**保底方案**）
- 不刷引导区，用 **追加 DTB 到 zImage** 的技巧让主线内核拿到设备树（见 §6.4）
- 风险低，但受制于原厂 U-Boot 和老分区表

### 🔴 路线 C：整片重刷 NAND（**不推荐**，除非 A/B 都走不通）
- 需要 `sunxi-nand-image-builder` 造 BROM 兼容镜像，砖了要用 FEL 救
- 建议**至少先把 A 走通了再考虑**

> 本文按 **A → 验证外设 → 再决定要不要落 NAND** 的顺序写。

---

## 3. 阶段 0：保命（动任何东西之前必须做完）

### 3.1 完整备份 NAND

**在机器还能正常开机的时候做**，从串口/ADB 登录原系统：

```sh
# 1) 先看清分区与设备名（不同 BSP 设备名不一样，务必先确认）
cat /proc/mtd
cat /proc/partitions
cat /proc/cmdline
mount
dmesg > /mnt/UDISK/dmesg-full.txt        # 这一份极其重要，见 §3.3

# 2) 整片备份（Allwinner 通常把整片 NAND 暴露成 /dev/nand）
#    确认设备名后再执行！至少 1GB 空间，写到 UDISK 或通过 adb pull 拉走
dd if=/dev/nand of=/mnt/UDISK/nand-full-backup.bin bs=1M
sync
md5sum /mnt/UDISK/nand-full-backup.bin
```

> 本目录 `00_raw/` 里已经有一份**分区级备份**（10 个分区，4 GB），
> 但它**不含 Boot0 和 U-Boot**（那两块在 NAND 隐藏引导区）。
> 所以**整片 dd 备份仍然必须做**——那是你唯一的"后悔药"。

### 3.2 确认 FEL 救砖通道

全志 BROM 里的 **FEL 模式是烧不死的**（在 ROM 里）。方式是：
上电瞬间按住 FEL/UBOOT 按键（或短接 NAND 的某根线），让 SoC 进 FEL，通过 USB OTG 连接 PC：

```bash
git clone https://github.com/linux-sunxi/sunxi-tools && cd sunxi-tools && make
./sunxi-fel ver
# 期望输出: AWUSBFEX soc=00162500(A13) ... 之类
```

**如果 `sunxi-fel ver` 有反应，你就永远不会变砖。** 先确认这一步，再往下走。

### 3.3 从原系统"榨干"必要信息（错过就没机会了）

原厂 fex 不在本次备份里，但**很多参数能在运行时读出来**：

```sh
# 屏幕时序 —— 移植显示全靠它
cat /sys/class/graphics/fb0/modes
cat /sys/class/graphics/fb0/virtual_size
cat /sys/class/graphics/fb0/bits_per_pixel
fbset -i 2>/dev/null || true
cat /sys/class/graphics/fb0/name

# NAND 几何参数（页大小 / OOB / ECC），移植 NAND 必需
dmesg | grep -i -E 'nand|nfc|ecc|page|block'
cat /proc/mtd

# PMU / 稳压器现状
cat /sys/class/regulator/regulator:*/name 2>/dev/null
ls /sys/class/power_supply/

# GPIO 使用情况
cat /sys/kernel/debug/gpio 2>/dev/null

# 模块参数
cat /proc/modules
for m in zhc_gpio zhc_led zhc_power zhc_fpga_iCE40; do dmesg | grep -i $m; done
```

**全部拉回 PC 存档。** 尤其是 `fbset` / `dmesg` 两份。

### 3.4 别乱动这几个分区

| 分区 | 为什么不能动 |
|---|---|
| `env` | U-Boot 环境变量，改坏了可能无法启动 |
| `misc` | recovery/升级标志位，原厂恢复逻辑依赖它 |
| `private` | 工厂 MAC / SN / 授权令牌 |
| `boot-res` | 开机 logo + 电池图标 |

---

## 4. 阶段 1：确认能不能从 SD 启动 ← **决定成败的一步**

全志 BROM 上电后先找 **MMC0（通常是 SD 槽）**，检查 **第 16 扇区（偏移 8 KiB）**
是否有 `eGON.BT0` 魔数；有就从卡启动，**完全不动 NAND**。

### 4.1 先物理确认有没有卡槽
拆机看有没有 microSD 座。**没有卡槽的话，直接跳到 §8 的路线 B。**

### 4.2 造一张"探针卡"验证
```bash
# 随便拿张卡（会被清空！）
sudo dd if=/dev/zero of=/dev/sdX bs=1M count=8

# 造一个最小可启动体：把主线 U-Boot 的 SPL+U-Boot 写到偏移 8KiB
# （U-Boot 编译见 §5）
sudo dd if=u-boot-sunxi-with-spl.bin of=/dev/sdX bs=1024 seek=8 conv=fsync
```

插卡上电，**接串口**（`ttyS0, 115200`）。若看到 U-Boot 的 `DRAM:` 打印 ——
**大功告成，整条路走通了**。

---

## 5. 阶段 2：编译主线 U-Boot

```bash
git clone https://source.denx.de/u-boot/u-boot.git && cd u-boot

# 先看当前版本还有哪些 sun5i 参考板（不同版本的 defconfig 会变）
ls configs/ | grep -i -E 'sun5i|A13|CHIP'

# 常见候选：
#   A13-OLinuXino_defconfig      (sun5i-A13 公版)
#   CHIP_defconfig               (NextThing C.H.I.P. = R8，最接近本机)
make CROSS_COMPILE=arm-linux-gnueabihf- CHIP_defconfig
make CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc)

# 产物
ls -l u-boot-sunxi-with-spl.bin
```

**DRAM 参数**：U-Boot 的 `CONFIG_DRAM_*`（时钟、ZQ、IO 电压）必须和这块板子匹配。
参考板是公版，**很可能要按本机实际情况调**。如果 DRAM 参数不对，表现是
**上电无任何串口输出 / 反复重启**——这时换参数重试，或用 FEL 直接在 RAM 里试：

```bash
./sunxi-fel uboot u-boot-sunxi-with-spl.bin      # 直接灌进 RAM 跑，不写任何存储
```

**调试期请一律用 `sunxi-fel uboot`**，不要写卡不要写 NAND。

---

## 6. 阶段 3：写设备树（DTB）—— 工作量最大的一块

### 6.1 起点

```bash
git clone --depth=1 https://github.com/torvalds/linux && cd linux
ls arch/arm/boot/dts/allwinner/ | grep -i sun5i
#   sun5i.dtsi                ← SoC 公共部分（不用改）
#   sun5i-a13.dtsi
#   sun5i-r8-chip.dts         ← ★ R8 最接近的参考，从这里抄
#   sun5i-a13-olinuxino.dts   ← 另一份参考
```

**做法：把 `sun5i-r8-chip.dts` 复制成 `sun5i-r8-baymin.dts`，然后按下面逐项改。**

### 6.2 需要自己填的节点

| 节点 | 内容 | 依据 |
|---|---|---|
| `&mmc0` | SD 卡：`cd-gpios`、`vmmc-supply`、`bus-width` | 抄参考板 + 实测 |
| `&mmc1` / `&mmc2` | AP6212 走 SDIO，需 `non-removable`、`cap-power-off-card`、`mmc-pwrseq`（`WL_REG_ON` GPIO） | `kmod-net-ap6212` |
| `&i2c0/1` | `axp209@34`（PMU）、`nau8540@??`（电量 ADC，需自己写驱动） | `zhc_power.ko` 的 `axp20_*` 串 |
| `&nfc` | NAND 控制器 + 分区表 | 需要 §3.3 抓到的几何参数 |
| `&spi0` | iCE40 FPGA，`lattice,ice40-*` | `zhc_fpga_iCE40.ko` |
| `&lcd0` + `panel` | **面板时序**（hactive/vactive/porch/clock） | **必须靠 §3.3 抓到，或查屏的型号丝印** |
| `&pwm` + `backlight` | 背光 | — |
| `&i2s0` / `&codec` | 音频 | ⚠️ 见 §6.3 |
| `gpio-keys` | 按键（原厂用 evdev） | `kmod-input-evdev` |
| `gpio-leds` | `led_red` / `led_green` / `led_blue` | `zhc_led.ko` 字符串 |
| `&usb_otg` / `&usbphy` | USB | 内核有 `musb`/`ehci`/`ohci` |

### 6.3 ⚠️ 音频：先说清楚这个坑

原厂音频驱动 `zhc_function.ko` 的 modinfo 是：

```
description: ASoC FPGA zhc_function driver
author:      lovemengx <zhangfuliang@team-co-operation.com>
```

也就是说**音频链路里插了一颗 FPGA**（很可能是 I2S 桥 / DAC / 音效）。
主线**没有任何驱动**能对应它。你有三个选择：

1. **放弃音频**（推荐先这样，让系统先跑起来）
2. **逆向 FPGA 位流 + 逻辑分析仪抓 I2S 时序**，自己写 ASoC 驱动 —— 按周计的工作量
3. 若 FPGA 只是"旁路/音效"，尝试 `simple-audio-card` 直连 codec —— **先确认硬件走线**

> 位流文件我们有：`09_app_resources` 与 `rootfs/bin/baymin_bitmap4.bin`（Lattice iCE40UL1K，iCEcube2 2015.08 生成）。
> 但位流是**比特流不是源码**，反推寄存器语义极难。

### 6.4 路线 B 的关键技巧：把 DTB 追加到 zImage

原厂 U-Boot 2011.09 是 **fex 时代**的，**不会传 DTB 给内核**。
但主线内核支持 **`CONFIG_ARM_APPENDED_DTB`** —— 把 DTB 直接拼在 zImage 后面，
内核自己去找，**不依赖 bootloader**：

```bash
# 内核配置里打开 CONFIG_ARM_APPENDED_DTB=y
cat arch/arm/boot/zImage arch/arm/boot/dts/allwinner/sun5i-r8-baymin.dtb > zImage-dtb

# 打成原厂 U-Boot 认识的 uImage（参数照抄原厂 uImage 头！）
mkimage -A arm -O linux -T kernel -C none \
        -a 0x40008000 -e 0x40008000 \
        -n "Alpine" -d zImage-dtb uImage

# 把 uImage 塞进 boot 分区（FAT12），替换原文件
```

参数 `0x40008000` 是从原厂 uImage 头里读出来的（见 `02_kernel_dts/README_dts.md`）。

**这个技巧是整条路线 B 的核心**：不用碰 U-Boot、不用碰引导区，就能让主线内核跑起来。

---

## 7. 阶段 4：构建 Alpine rootfs

### 7.1 目标架构选 `armv7`

Cortex-A8 有 NEON + VFPv3 → 用 Alpine 的 **`armv7`**（硬浮点）。
注意 **Cortex-A8 没有 LPAE**，是纯 32 位 —— 选内核时要留意。

### 7.2 造 rootfs（在 x86_64 上就能做）

```bash
VER=3.20
mkdir -p rootfs && cd rootfs
wget https://dl-cdn.alpinelinux.org/alpine/v$VER/releases/armv7/\
alpine-minirootfs-${VER}.0-armv7.tar.gz
tar xzf alpine-minirootfs-*.tar.gz

# 或者干脆用 apk 直接装（更干净）
apk add --root "$PWD" --initdb --arch armv7 \
  --repository https://dl-cdn.alpinelinux.org/alpine/v$VER/main \
  --repository https://dl-cdn.alpinelinux.org/alpine/v$VER/community \
  alpine-base openrc \
  e2fsprogs e2fsprogs-extra \
  wpa_supplicant wireless-tools iw \
  bluez \
  util-linux mount \
  linux-firmware-brcm        # AP6212 固件
```

### 7.3 用 qemu 进去做后续配置

```bash
sudo cp /usr/bin/qemu-arm-static rootfs/usr/bin/
sudo mount --bind /dev  rootfs/dev
sudo mount -t proc proc rootfs/proc
sudo mount -t sysfs sys rootfs/sys
sudo chroot rootfs /bin/sh

# 里面：
apk update
rc-update add networking default
rc-update add wpa_supplicant default
passwd root
```

### 7.4 内核

Alpine 官方 armv7 的 `linux-lts` **未必开启 sun5i**。两条路：

- **省事**：直接把你 §6 自己编的 `zImage` + `.dtb` 放进 boot 分区（不装 Alpine 内核包）
- **规范**：基于 Alpine 的 `linux-lts` APKBUILD 改一份 `linux-sunxi` 包

自编内核（推荐先这样）：
```bash
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- sunxi_defconfig
# 打开：CONFIG_ARM_APPENDED_DTB（走路线 B 时）、CONFIG_DEVTMPFS、CONFIG_BLK_DEV_INITRD
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- zImage dtbs -j$(nproc)
```

### 7.5 分区与引导文件（SD 方案）

```
SD 卡布局：
  p1  64 MiB   FAT32    /boot   ← zImage + dtb + extlinux.conf
  p2  余下     ext4     /       ← Alpine rootfs
```

`/boot/extlinux.conf`（U-Boot 的 distro-boot 会读它）：
```
DEFAULT alpine
LABEL alpine
    LINUX /zImage
    FDT   /sun5i-r8-baymin.dtb
    APPEND console=ttyS0,115200 root=/dev/mmcblk0p2 rootwait rw
```

---

## 8. 路线 B 细则（没有 SD 槽 / 不想拆机时的走法）

保留原厂 U-Boot + Boot0 + fex 分区表，只替换**内核和 rootfs**：

1. **内核**：用 §6.4 的"追加 DTB"技巧做成 uImage，塞进 `boot` 分区
2. **bootargs**：原厂 env 里是 `root=/dev/nandd`（厂商私有逻辑卷，主线不认）。
   需要进 U-Boot 串口控制台改 env：
   ```
   setenv bootargs console=ttyS0,115200 root=/dev/mmcblk0p2 rootwait rw
   saveenv
   ```
   （改 env 有风险，**先备份 `env` 分区**——我们已经有 `00_raw/env_backup.bin`）
3. **rootfs 放哪**：
   - 有 SD 就放 SD（`/dev/mmcblk0p2`）
   - 只能用 NAND 的话，主线把 NAND 看成 MTD/UBI，需要
     `root=ubi0:rootfs ubi.mtd=<n> rootfstype=ubifs`
4. **别覆盖** `boot-res` / `env` / `misc` / `private`

> 路线 B 的代价：**引导流程永远受制于原厂 U-Boot**，而且 NAND 上的
> 私有 `/dev/nandd` 逻辑卷结构主线不认，只能**重建成标准 MTD + UBI**。

---

## 9. 阶段 6：如果要落到 NAND（可选，高风险）

### 9.1 你需要先拿到 NAND 几何参数
页大小 / OOB 大小 / ECC 强度 —— 来自 §3.3 的 `dmesg`。
**没有这些参数不要动 NAND。**

### 9.2 工具
```bash
# sunxi-tools 里的 NAND 镜像工具，负责生成 BROM 兼容的引导块
make -C sunxi-tools sunxi-nand-image-builder
```

### 9.3 分区规划（UBI 方案）
```
mtd0  spl+u-boot   （BROM 专用布局，用 sunxi-nand-image-builder 生成）
mtd1  env
mtd2  boot         （内核 + DTB）
mtd3  rootfs       （UBIFS，Alpine）
mtd4  data         （UBIFS，可写）
```
```bash
mkfs.ubifs -r rootfs/ -m <min_io> -e <leb_size> -c <max_leb> -o rootfs.ubifs
ubinize -o rootfs.ubi -m <min_io> -p <peb_size> ubinize.cfg
```

### 9.4 ⚠️ 强烈建议
**先走通路线 A/B，确认所有外设都 OK，再考虑刷 NAND。**
NAND 一刷，原厂 `/dev/nandd` 逻辑卷就没了，只能靠 §3.1 的整片备份 + FEL 恢复。

---

## 10. Alpine 特有的坑（别踩）

| 坑 | 说明 | 对策 |
|---|---|---|
| **musl ≠ uClibc ≠ glibc** | 原厂 `libcae.so`/`libmsc.so`/`xxb_robot_*.so` **一个都跑不了** | 全部源码重编，或放弃原厂 App |
| **没有 `procd`** | 原厂 init 脚本全是 `/etc/rc.common` + `procd` | 改写成 OpenRC service |
| **没有 `opkg`** | 原厂应用是 `.ipk` | 用 `apk` 重打包，或直接放文件 |
| **`/usr` 是独立分区** | 原厂 `extend` 分区挂在 `/usr` | Alpine 里建议合并到 rootfs，别照搬 |
| **`/overlay` 机制** | OpenWrt 的可写层 | Alpine 用普通 `rw` rootfs 即可 |
| **固件路径不同** | 原厂 `/lib/firmware/ap6212/` | 主线 `brcmfmac` 要 `/lib/firmware/brcm/brcmfmac43430-sdio.bin` + `.txt` |
| **时区/证书** | Alpine 默认精简 | 记得 `apk add ca-certificates tzdata` |

**有用的现成物**：原厂 `/lib/firmware/ap6212/nvram_ap6212.txt` 可以直接改名为
`brcmfmac43430-sdio.txt` 给主线用 —— 这省不少事（已在 `04_rootfs/rootfs/lib/firmware/ap6212/`）。

---

## 11. 原厂程序 → Alpine 替代对照

| 原厂 | 作用 | Alpine 替代 |
|---|---|---|
| `xxb_robot_sw_server` | 语音交互主状态机（讯飞） | **需重写**；或调讯飞 WebAPI（`bj.voicecloud.cn/msp.do`） |
| `xxb_robot_hw_server` | 硬件服务聚合 | 拆成 OpenRC 服务 + 标准 sysfs |
| `gwmplayer` / `mplayer` | 媒体播放 | `mpv` / `ffmpeg` / `mpg123` |
| `smartlinkd` | SmartLink 配网 | `wpa_supplicant` + `iw` |
| `zhc_bluetooth_service` | 蓝牙服务 | `bluez` |
| `qrencode_test` | 二维码配网 | `qrencode` |
| `libgowild_battery_server.so` | 电量 | `axp20x_battery` + `upower` 或自写脚本 |
| `libgowild_led.so` | RGB 灯 | `/sys/class/leds/*` |
| `zhc_hardware_test` | 产测 | 自写脚本 |
| `aw_upgrade_*.sh` | OTA | 自建（`fw_setenv` + A/B 分区 或 `swupdate`） |

界面部分：原厂用 **DirectFB + `.cut` 稀疏像素帧**（我们已逆向，见
`05_report/固件分析报告.md` §9.5）。Alpine 上可用：
- 最简单：写个小程序直接 `mmap` `/dev/fb0` 画
- 或 `SDL2`（framebuffer backend）/ `LVGL`（嵌入式 GUI，很合适）

---

## 12. 工作量粗估

| 阶段 | 前提 | 估计 |
|---|---|---|
| 备份 + FEL + 串口打通 | 有串口焊盘/UART | 1 天 |
| SD 启动验证 | **有卡槽** | 1 天 |
| 主线 U-Boot + DRAM 参数调通 | — | 1–3 天 |
| 设备树基础版（串口 + SD + 启动到 shell） | — | 2–5 天 |
| WiFi / BT 可用 | 有 `WL_REG_ON` 引脚资料 | 2–5 天 |
| 显示点亮 | 面板型号明确 | 3 天 ～ 2 周 |
| 显示点亮 | 面板型号未知（要试时序） | 2 ～ 6 周 |
| **音频（FPGA）** | 有 FPGA 文档 | 1–2 周 |
| **音频（FPGA）** | 无文档，纯逆向 | **数周～数月，可能失败** |
| 电量计 NAU8540 | — | 1 周（写 IIO 驱动） |
| 落 NAND（UBI 启动） | — | 1–2 周 |
| 应用层重写 | — | 取决于你想保留多少功能 |

**如果目标只是"跑个 Alpine 玩"**：**1 周内**能到"串口 + 网络 + shell"。
**如果要"替代原系统"**：这是一条**以月计**的路，而且**音频很可能做不成**。

---

## 13. 我的建议（直接可执行）

1. **今天**：拆机，确认 ①有没有 microSD 卡槽 ②有没有 UART 测试点/焊盘 ③FEL 按键位置
2. **然后**：接串口开机，跑 §3.3 的命令，把 `dmesg`/`fbset` 全存下来
3. **接着**：做整片 NAND 备份，验证 `sunxi-fel ver` 能通
4. **再然后**：用 `sunxi-fel uboot` 在 **RAM 里**跑主线 U-Boot（**不写任何存储**），看串口有没有输出
   - 有输出 → 主攻设备树，按 §6.2 一项项填
   - 无输出 → 调 DRAM 参数，或考虑路线 B
5. **最后**：先让"串口 + SD + 网络"跑通，**显示和音频放到最后再啃**

> **最重要的心态**：先让它"能启动、能进 shell、能联网"，这三件事做到了，
> 剩下的都是逐个外设的体力活。**不要一上来就纠结屏幕和声音。**

---

## 14. 参考资源

- **linux-sunxi 社区 wiki**（R8/sun5i 的权威资料）: https://linux-sunxi.org/
- **sunxi-tools**（FEL / NAND 镜像工具）: https://github.com/linux-sunxi/sunxi-tools
- **xfel**（新一代 FEL 工具，全志官方）: https://github.com/xboot/xfel
- **主线内核 sun5i 参考 DTS**: `arch/arm/boot/dts/allwinner/sun5i-r8-chip.dts`
- **主线 U-Boot sunxi 文档**: `doc/board/allwinner/sunxi.rst`
- **Alpine Linux 交叉/异架构安装**: https://wiki.alpinelinux.org/wiki/Alpine_Linux_on_ARM
- **Alpine mkimage**: `aports/scripts/mkimage.sh`
- **起点资料（本次分析产物）**：
  - `01_uboot/README_uboot.md` —— 启动流程、bootargs、分区号
  - `02_kernel_dts/README_dts.md` —— 硬件清单、主线对应关系
  - `02_kernel_dts/baymin_sun5i_reconstructed.dts` —— 可当写 DTS 的草稿
  - `05_report/固件分析报告.md` —— 全量硬件/软件事实

---

## 附：一句话备忘

> **BROM 顺序：SD → NAND → FEL。所以只要有一张 SD 卡和一个 FEL 入口，这块板子就永远救得回来。**
