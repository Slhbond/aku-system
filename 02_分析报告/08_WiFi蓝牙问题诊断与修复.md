# WiFi / 蓝牙 问题诊断与修复指南

> 面向：大佬的 Ubuntu 22.04（`aku_ubuntu_2204_251017`）与你的 Alpine 3.19.9（`aku_alpine_3.19.9_slhbond`）
> **所有结论都经过镜像内实证核对**，包括一条推翻了我自己初始猜测的发现（见"更正"）

---

## ⚠️ 先更正一条

我最初怀疑"**蓝牙被内核和用户态双重占用**"（DTB 里有 `bluetooth` 节点，同时 `btstart.service` 又跑 `brcm_patchram_plus`）。

**查证后这个假设是错的。** 用 `modules.builtin` 核对内核编译配置：

```
bluetooth    builtin=1     ← 有
hci_uart     builtin=1     ← 有（brcm_patchram_plus 需要它）
btbcm        builtin=0  module=0   ← ❌ 根本没有！
hci_bcm      builtin=0  module=0   ← ❌ 根本没有！
```

内核里**压根没有 Broadcom 的蓝牙驱动**，所以 DTB 里那个 `bluetooth { }` 节点
**没有任何驱动会去绑定它，是死配置**，不存在抢串口的问题。

蓝牙路径是**纯用户态**：`brcm_patchram_plus`（下载补丁）→ `hci_uart` H4 线路规程 → `hci0`。
所以下面的 **D 项已作废**，真正的问题在 **F 项**。

---

## 结论速览（修正版）

| # | 问题 | 影响对象 | 确诊程度 | 修复难度 |
|---|---|---|---|---|
| **A** | NetworkManager 默认开 WiFi 省电 | 🔴 Ubuntu | ✅ 已确诊 | ★☆☆☆☆ |
| **B** | 没有管制域库 + bootargs 未设 regdom | 🔴 Ubuntu | ✅ 已确诊 | ★★☆☆☆ |
| **C** | DTB 缺 SDIO 时钟与电源时序（5 个属性） | 🔴 Ubuntu | ✅ 已确诊 | ★★☆☆☆ |
| **D** | ~~蓝牙被双重占用~~ | — | ❌ **已推翻** | — |
| **E** | BSA 协议栈 vs BlueZ | 🟡 两者 | ⚠️ 固有限制 | ★★★★★ |
| **F** | **Alpine 没有加载蓝牙固件补丁** | 🔴 **Alpine** | ✅ 已确诊 | ★★☆☆☆ |
| **G** | 原厂 BT 走 `/dev/ttyS1`，新系统走 `/dev/ttyS3` | 🟡 两者 | ⚠️ 需实测 | ★★★☆☆ |

**一句话：Ubuntu 的 WiFi 配置有问题，Alpine 的蓝牙配置有问题 —— 两边各对一半。**

---

## 两套系统的逐项对照（核心表）

| 项目 | 原厂 (3.4.39) | 大佬 Ubuntu 22.04 | 你的 Alpine 3.19.9 |
|---|---|---|---|
| WiFi 驱动 | 闭源 `bcmdhd` | 主线 `brcmfmac` | 主线 `brcmfmac` |
| NVRAM | 原厂 `nvram_ap6212.txt` | ✅ 原样复用 | ✅ 原样复用 |
| **管制域库 `regulatory.db`** | 不适用 | ❌ **没有** | ✅ **有**（`wireless-regdb`） |
| **WiFi 省电** | 无强制 | ❌ NM `wifi.powersave=3` | ✅ 无 NetworkManager |
| **DTB WiFi 修复（5 项）** | fex 里 | ❌ 缺 | ✅ 有 |
| **蓝牙固件补丁加载** | `bsa_server -p <hcd>` | ✅ `brcm_patchram_plus` | ❌ **没有任何程序加载** |
| 蓝牙协议栈 | Broadcom **BSA** | BlueZ 5 | BlueZ 5 |
| 蓝牙串口 | `/dev/ttyS1`（vendor 编号） | `/dev/ttyS3` | 无配置 |

> **Alpine 的 WiFi 理论上已经比 Ubuntu 好**（省电/管制域/DTB 三项里占了两项）
> **但 Alpine 的蓝牙可能更糟**，因为 HCD 补丁文件虽然放进了 `/lib/firmware/brcm/`，却**没有任何东西去加载它**。

---

## 修复 A：关掉 WiFi 省电（Ubuntu）✅

**证据**：`ubuntu-rootfs/etc/NetworkManager/conf.d/default-wifi-powersave-on.conf`

```ini
[connection]
wifi.powersave = 3
```

这是 Ubuntu 出厂默认值 = **开启省电**。省电模式下 brcmfmac 频繁休眠，
表现为**延迟高、吞吐低、信号看起来"虚"**。

```bash
sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf >/dev/null <<'EOF'
[connection]
wifi.powersave = 2
EOF
sudo systemctl restart NetworkManager

# 验证
iw dev wlan0 get power_save     # 期望: Power save: off
```

> 取值：`0`=默认 `1`=忽略 `2`=**关闭** `3`=开启
> **Alpine 不需要做这一步** —— 它用 `wpa_supplicant` + `ifupdown-ng`，没有 NetworkManager。

---

## 修复 B：管制域（Ubuntu）✅

**证据（三连）**：
1. Ubuntu rootfs 里**没有** `/lib/firmware/regulatory.db`（Alpine 反而有）
2. DTB bootargs = `"console=ttyS0,115200 ubi.mtd=0 root=ubi0:rootfs rootfstype=ubifs rw"`，没有 `cfg80211.ieee80211_regdom=`
3. 原厂 NVRAM 写的是 `ccode=ALL` —— **等于不做任何限制**

→ 原厂全功率全信道，新系统被砍一大截。**这是"信号变差"最典型的原因。**

```bash
sudo apt install -y wireless-regdb
sudo iw reg set CN
iw reg get
```

### 持久化（推荐方式 1）

```bash
sudo tee /etc/systemd/system/regdom.service >/dev/null <<'EOF'
[Unit]
Description=Set WiFi regulatory domain
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iw reg set CN
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now regdom.service
```

> Alpine 已经有 `wireless-regdb` 了，只需要在 `/etc/local.d/regdom.start` 里加一句
> `iw reg set CN`（如果还没加的话）。

---

## 修复 C：DTB 的 5 个 WiFi 属性（Ubuntu）✅

**两个 DTB 反编译后 diff，只有 5 处差异，全在 WiFi 上：**

| 属性 | 位置 | Ubuntu | Alpine | 作用 |
|---|---|---|---|---|
| `max-frequency = <10000000>` | `mmc@1c11000`（WiFi SDIO） | ❌ | ✅ | SDIO 时钟限 10 MHz，避免 CRC 重传 |
| `output-high` | PD18 引脚 pinctrl | ❌ | ✅ | WL_REG_ON 上电默认拉高 |
| `post-power-on-delay-ms = <500>` | `wifi_reg_en` | ❌ | ✅ | 上电后等 500ms 再枚举 |
| `power-off-delay-us = <10000>` | `wifi_reg_en` | ❌ | ✅ | 下电延时 |
| `clocks = <&clk_32k>` + `clock-names = "ext_clock"` | `wifi_reg_en` | ❌ | ✅ | 给模组 32.768 kHz LPO 时钟 |

**Alpine DTB 是 Ubuntu DTB 的严格超集**（diff 只有 `+` 没有 `-`）。

### 修复：直接把 Alpine 的 DTB 用到 Ubuntu 上

```bash
cd images10
cp ../aimages/sun5i_r8_akubox_linux.dtb ./sun5i_r8_akubox_linux.dtb

# 零风险验证（只从 RAM 启动，不写任何存储）
./debug_kernel.sh

# 确认没问题再落盘（只写 DTB + 内核，不动 rootfs）
./flash_kernel.sh
```

> ⚠️ **千万别用 `flash_all.sh`** —— 它会 `nand scrub.chip` 把整片 NAND 清空。
> 大佬已经把安全路径铺好了：`debug_kernel.sh` → `flash_kernel.sh`。

---

## 修复 F：Alpine 没有加载蓝牙固件补丁 🔴

**证据（全盘搜索）**：

```bash
# Alpine rootfs 里搜 bcm43438 / patchram / brcm_patchram
grep -rl 'bcm43438\|patchram\|brcm_patchram' ./alpine-rootfs/
# → 无任何结果

find ./alpine-rootfs -name '*patchram*'
# → 无（只有 bluez-deprecated 提供的 hciattach）
```

Alpine 装了 70 个包，其中蓝牙相关的是 `bluez` + `bluez-deprecated`，
**没有 `brcm_patchram_plus`**。而 `/lib/firmware/brcm/bcm43438a0.hcd` 明明已经放进去了 ——
**文件在，但没人用它。**

对比 Ubuntu：`cp/brcm_patchram_plus` 被拷进 `/usr/bin/`，且 `btstart.service` 负责调用。

**后果**：BCM43438 跑在出厂 ROM 固件上，没有加载 RAM patch，
→ 蓝牙**距离短、易断、与 WiFi 共存差**。

### 修复（二选一）

**方案 1：把 Ubuntu 那份 `brcm_patchram_plus` 借过来（最快）**

```bash
# 从 Ubuntu 系统或 Ubuntu 的 rootfs 里取出
scp root@<ubuntu板子>:/usr/bin/brcm_patchram_plus /usr/bin/
chmod +x /usr/bin/brcm_patchram_plus

# 做成 OpenRC 服务
cat > /etc/init.d/btstart <<'EOF'
#!/sbin/openrc-run
name="Broadcom Bluetooth Firmware Patch"
command="/usr/bin/brcm_patchram_plus"
command_args="-d --patchram /lib/firmware/brcm/bcm43438a0.hcd --enable_hci \
              --no2bytes --tosleep 1000 --baudrate 1500000 /dev/ttyS3"
command_background=true
pidfile="/run/btstart.pid"
depend() { after bluetooth; }
EOF
chmod +x /etc/init.d/btstart
rc-update add btstart default
rc-service btstart start
```

**方案 2：用 BlueZ 自带的 `hciattach`（Alpine 已有）**

```bash
# BlueZ 的 bcm43xx 类型自己会下载固件
hciattach /dev/ttyS3 bcm43xx 1500000 flow
```

### 怎么确认修好了

```bash
hciconfig -a
# 看 BD Address 是不是真实地址（不是 00:00:00:00:00:00）
# 看 "Manufacturer: Broadcom Corporation" 和版本号

dmesg | grep -iE 'bluetooth|hci'
```

---

## 修复 G：蓝牙串口编号疑点 ⚠️ 需实测

### 背景：原厂和新系统用的不是同一个 UART

原厂 rootfs 里的 `/etc/bluetooth/btenable.sh`：

```sh
bt_on()
{
  echo 0 > /sys/class/rfkill/rfkill0/state     # ← rfkill 控制 BT 上电
  sleep 1
  echo 1 > /sys/class/rfkill/rfkill0/state
  sleep 1

  $BSA_SERVER -all=0 -d /dev/ttyS1 -p /lib/firmware/ap6212/bcm43438a0.hcd -r 12 &
  sleep 2
}
```

→ 原厂用 **`/dev/ttyS1`** + **`bsa_server`**（BSA 自己下载固件）+ **`rfkill0/state`** 做上电时序。

新系统用 **`/dev/ttyS3`** + `brcm_patchram_plus`。

### ⚠️ 陷阱：mainline 的 `/dev/ttyS<N>` 编号来自 DTS 别名，不等于硬件 UART 号

新 DTB 里：

```dts
aliases {
    serial0 = "/soc/serial@1c28400";   /* 硬件 UART1，却叫 ttyS0 */
    serial3 = "/soc/serial@1c28c00";   /* 硬件 UART3，叫 ttyS3 */
};
```

而 **vendor 内核**是按硬件顺序编号的：`ttyS0`=UART0(0x1c28000)，`ttyS1`=UART1(0x1c28400)。

**所以原厂脚本里的 `ttyS1` 和新系统里的 `ttyS0` 指向的是同一个物理串口（0x1c28400）。**

### 怎么核实

1. 看新 DTB 的 pinmux：`serial@1c28400` 用的是 **PG3/PG4**，`serial@1c28c00` 用的是另一组
2. 在板子上量这两组引脚，看哪一组接到了 WiFi 模组的 BT UART
3. 或者干脆两边都试：把 `brcm_patchram_plus` 的 `/dev/ttyS3` 换成 `/dev/ttyS0` 试试
   （注意 `ttyS0` 现在是 console，会冲突 —— 如果 `ttyS0` 才是 BT，那 console 就配错了）

> 既然现在蓝牙**能用**（只是差），说明 `ttyS3` 至少不是完全错的。
> 但值得花 10 分钟量一下，因为这决定了修 F 的时候该填哪个设备名。

---

## 修复 E：协议栈差异（大概率无解）

原厂蓝牙用的是 **Broadcom 私有 BSA 协议栈**：

```
04_rootfs/extend/bin/bsa_server      1,689,397 B    ← BSA 服务端
04_rootfs/extend/lib/libbsa.so         185,681 B
04_rootfs/extend/lib/libbtapp.so       136,975 B
04_rootfs/rootfs/bin/zhc_bluetooth_service
```

新系统用 BlueZ 5.x。两者在 **A2DP 音质、HFP 通话、多点连接、功耗**上行为本就不同。

**这属于"换了实现"，不是"配置错了"。除非移植 BSA（闭源 + 老工具链，几乎不可能），
否则无法完全追平原厂。**

---

## 修完怎么验证？别凭感觉

"效果没那么好"没法量化，修完也不知道修没修好。**同一位置、同一台 AP，三套对比**：

```bash
# WiFi
iw dev wlan0 link          # 看 signal / bitrate
iw reg get                 # 看国家码与允许功率
iw dev wlan0 get power_save
iperf3 -c <PC的IP> -t 30   # PC 上先跑 iperf3 -s
dmesg | grep -iE 'brcmfmac|sdio|mmc'

# 蓝牙
hciconfig -a
dmesg | grep -iE 'bluetooth|hci|bcm|patchram'
```

**记录表**（原厂 / Ubuntu / Alpine 各一行）：

| 系统 | signal | bitrate | iperf3 吞吐 | power_save | regdom | BT 距离 |
|---|---|---|---|---|---|---|
| 原厂 | | | | | | |
| Ubuntu | | | | | | |
| Alpine | | | | | | |

---

## 附：一页速查

| 步骤 | 对象 | 命令 | 风险 |
|---|---|---|---|
| 1. 关省电 | Ubuntu | `wifi.powersave = 2` + 重启 NM | 无 |
| 2. 装 regdb | Ubuntu | `apt install wireless-regdb` | 无 |
| 3. 设 regdom | 两者 | `iw reg set CN` | 无 |
| 4. 换 DTB（验证） | Ubuntu | `./debug_kernel.sh` | 无（不写盘） |
| 5. 换 DTB（落盘） | Ubuntu | `./flash_kernel.sh` | 低 |
| 6. 加蓝牙补丁加载 | **Alpine** | 装 `brcm_patchram_plus` + OpenRC 服务 | 低 |
| 7. 核实 BT 串口 | 两者 | 量 PG3/PG4 vs UART3 引脚 | 无 |
| ❌ 禁用 | — | `./flash_all.sh` | **高（擦全片）** |
