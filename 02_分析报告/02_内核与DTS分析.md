# DTS / 设备树分析（aku / GoWild 小小白 xxb 机器人）

## 1. 结论先说

**这块板子不使用 Device Tree，所以固件里没有 .dts / .dtb。**

全志 Linux 3.4 BSP（本项目内核 = **Linux 3.4.39**）用的是 **`sys_config.fex` → `script.bin`**
这套"板级配置二进制"机制，等价于设备树。

**而且，本次备份里连 `script.bin` / `sys_config.fex` 也没有** ——
它和 U-Boot 一起待在未备份的引导区（U-Boot 2011.09 把 fex 配置直接编进自身，
运行时把 `script.bin` 放到固定内存地址交给内核）。

## 2. 判定依据（硬证据）

### 2.1 整个固件里没有任何 FDT 魔数

对**全部**原始镜像（UDISK 249 MB、nandi-data3 3.6 GB、rootfs_data 80 MB、misc、private、
boot、boot-res、env、extend、rootfs）做全片扫描：

```
FDT magic  d0 0d fe ed        →  0 命中
字符串     "d00dfeed"          →  0 命中
```

### 2.2 内核里有全志 fex 机制的符号，且没有 DT 支持

从 `boot_backup.bin → uImage → kernel.bin` 解压出 7,380,548 字节的 vmlinux 后扫描字符串：

```
arch/arm/mach-sun5i/sys_config.c            ← fex 解析核心
Init eGon pin module V2.0                   ← sys_config.c 的打印
sun5i-i2c / sw_nand / timer0 / uart_para
arch/arm/mach-sun5i/clock/clock.c
arch/arm/mach-sun5i/dram/dram.c
CONFIG_ARM_APPENDED_DTB                     → 未找到
CONFIG_ARM_ATAG_DTB_COMPAT                  → 未找到
IKCFG_ST (内核内嵌配置)                      → 未找到
```

### 2.3 驱动明确地按 fex section 名取配置

内核模块里调用的正是全志的 fex 读取接口 `script_parser_fetch()`：

| 模块 | 读取的 fex 段 | 证据串 |
|---|---|---|
| `zhc_gpio.ko` | **`[gpio_para]`** | `gpio_request_ex`, `gpio_para`, `gpio_get_one_pin_status` |
| `zhc_led.ko` | **`[led_para]`** | `led_red`, `led_green`, `led_blue`, `led_para` |
| `zhc_fpga_iCE40.ko` | **`[fpga_para]`** | `fpga_spi_cs0`, `fpga_spi_cs1`, `fpga_crest_b`, `fpga_cdone_data_IRQ` |
| `zhc_power.ko` | **`[zhc_power]`** | `script_parser_fetch`, `fetch power_led from sys_config failed` |

`zhc_power.ko` 里甚至保留了报错原文 **"fetch power_led from sys_config failed"**，
`zhc_gpio.ko` 里是 **"gpio_request [gpio_para] fail!"**。

### 2.4 内核 uImage 尾部没有附加 DTB

`uImage` 尾部（0x32A950 起）是 Allwinner 自有的元数据表：

```
0x32A950  d2 53 6b 9e                              校验/魔数
0x32A954  44 9e 70 00   = 7380548                   解压后内核大小（与实测完全一致）
0x32A96C  b7 3d 00 00   = 15799 = 0x3DB7           gzip 负载偏移（与实测完全一致）
0x32A978  10 08 00 00   = 2064
...       一组指向自身的 32 位指针
```

即：**zImage + 元数据尾**，没有 `d00dfeed`。内核的 gzip 负载解压后同样不含 DTB。

## 3. 这块板的硬件（从驱动/固件中提取的真实信息）

虽然拿不到 fex 文本，但**板级信息可以从内核模块和用户态程序里高置信度还原**：

| 项目 | 结论 | 证据 |
|---|---|---|
| SoC | **Allwinner sun5i（A13/R8 级）** | `linux-sun5i` 构建路径、`mach-sun5i`、`arch/sun5i` |
| CPU | **ARM Cortex-A8 + NEON，ARMv7** | 构建路径 `target-arm_cortex-a8+neon`；`vermagic: ARMv7` |
| 板名 | **Baymin / baymini** | 构建路径 `tina_baymini`；包名 `uboot-sun5i-R8-Baymin-Board` |
| PMU | **AXP20x** | `zhc_power.ko`: `axp20_fpga`, `axp20_led`, `axp20_ldo4`, `axp20_ldo5`, `zhc_axp_read/write` |
| FPGA | **Lattice iCE40UL1K-CM36A** | `baymin_bitmap.bin` 内的 iCEcube2 头；驱动 `zhc_fpga_iCE40.ko` |
| FPGA 配置位流 | `baymin_bitmap.bin` / `baymin_bitmap4.bin`（30942 B，两者相同） | `Lattice\0iCEcube2 2015.08.27744\0Part: iCE40UL1K-CM36A` |
| FPGA 接口 | **SPI + CS0/CS1 + CRESET_B + CDONE 中断** | `fpga_spi_cs0/cs1`, `fpga_crest_b`, `fpga_cdone_data_IRQ`, `IRQ_EINT16` |
| WiFi/BT | **AMPAK AP6212（BCM43438）** | `/lib/firmware/ap6212/fw_bcm43438a0.bin` 等；`kmod-net-ap6212` |
| 电池 | **NAU8540 ADC** + sun5i 内部 ADC | `zhc_adc_nau8540.ko`, `zhc_adc_sun5i.ko`；`/sys/class/power_supply/battery/capacity` |
| LED | **RGB 三色 led_red / led_green / led_blue** | `zhc_led.ko` 字符串 |
| 电源轨 | `power_adc, power_dcin, power_fpga, power_amp, power_lcd, power_led` | `zhc_power.ko` 帮助文本 |
| 显示屏 | **128×160 面板**；应用帧缓冲 stride = 256 | `boot-res` 里 18 张 BMP 全为 128×160；`.cut` 表情帧按 stride 256 解析成立 |
| 控制台 | UART0 @ 115200 | env: `console=ttyS0,115200` |
| 存储 | NAND（`sw_nand`, `root=/dev/nandd`） | 内核 + env |
| 输入 | evdev / `/dev/input` | `kmod-input-evdev`, `libgowild_keyevent.so` |
| 音频 | ALSA + `libzhc_audio.so` + 录音/回放 | `libasound`, `CAEAudioWrite` |

## 4. 目录内容

* `boot_fat/uImage` —— 从 `boot` 分区 FAT 中取出的原始 uImage（3,320,208 B）
* `kernel.bin` —— uImage 负载（zImage，3,320,144 B）
* `kernel_decompressed.bin` —— gzip 解压后的 vmlinux（7,380,548 B，可直接 strings/分析）
* `baymin_sun5i_reconstructed.dts` —— **按证据重建**的板级描述（见下节说明）
* `README_dts.md` —— 本文件

## 5. 关于 `baymin_sun5i_reconstructed.dts`

由于原厂 `sys_config.fex`/`script.bin` 不在本次备份内，本目录提供一份
**重建版板级描述**（DTS 语法），用来把上表的硬件结论固化成可读的结构。

**请注意：**

* 标 `/* [实测] */` 的字段来自固件内的直接证据，可信。
* 标 `/* [推断] */` 的字段（主要是具体 GPIO 编号、I2C 地址、电压值）**无法从本次备份确定**，
  是按 sun5i/R8 + Baymin 常见接法给出的**占位值**，使用前必须用真实 fex 校正。
* 它不是可编译运行的原厂设备树 —— **原厂根本没有设备树**。
