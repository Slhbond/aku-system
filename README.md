# AKU System

> **GoWild（狗尾草）小小白 / AKU 版陪伴机器人 —— 全量固件逆向分析与系统移植资料库**

本仓库整理了该设备的**原厂固件分析**、**两套移植系统（Ubuntu 22.04 / Alpine 3.19.9）的技术资料**，
以及与移植相关的**问题排查记录**。所有结论都来自对真实固件镜像的解析，附带证据与文件位置。

---

## 硬件规格

| 项目 | 参数 |
|---|---|
| 设备 | GoWild 小小白（xxb）机器人 · **AKU 版** |
| SoC | Allwinner **sun5i (R8)** · ARM Cortex-A8 + NEON · ARMv7 |
| 内存 | 512 MB / 1 GB（依版本） |
| 存储 | **NAND Flash**（不同批次品牌不同） |
| 显示屏 | **ST7735S** 128×160 TFT |
| 音频 | sun4i-codec → PD20 功放 → 喇叭 |
| 无线 | AMPAK **AP6212**（Broadcom BCM43438）WiFi 2.4G + BT 4.1 |
| FPGA | Lattice **iCE40UL1K-CM36A** |
| PMU | AXP20x |
| 原厂系统 | OpenWrt Barrier Breaker 14.07 / Tina Linux V1 · Linux 3.4.39 · uClibc |

---

## 核心结论

### 1. 为什么要移植

设备有两个版本：**小白** 与 **AKU**，硬件差异**仅在 NAND Flash 品牌**。

把小白固件刷到 AKU 上会**无限重启** —— 原因是全志 BROM 按 NAND ID 决定页大小/OOB/ECC，
而刷机用的 `sunxi-spl-with-ecc.bin` 是**按特定 NAND 几何预生成的 ECC 镜像**
（通过 `nand write.raw.noverify` 原样写入）。换 NAND 就对不上，BROM 读不出 SPL。

**→ 这就是必须做 mainline 移植的根本原因**：主线 U-Boot + `sunxi_nand` 用 ONFI/ID 自动探测，自适应。

### 2. 两套移植系统

| | Ubuntu 22.04 | Alpine 3.19.9 |
|---|---|---|
| 内核 | Linux **6.1.9** mainline | 同（**MD5 相同**） |
| U-Boot | **2023.01** | 同（**MD5 相同**） |
| 根文件系统 | UBIFS 136 MiB / glibc / systemd | UBIFS 50 MiB / musl / OpenRC |
| 设备树 | 19,275 B | 19,443 B（**多 5 个 WiFi 属性**） |

### 3. 三个硬骨头怎么解决的

| 难题 | 原厂 | 移植方案 |
|---|---|---|
| **显示** | 全志 DISP/TCON + fex + DirectFB | 面板为 **ST7735S**，自写 `st7735sfb` framebuffer 驱动编进内核 |
| **音频** | ASoC **FPGA** 驱动 | **绕过 FPGA**：主线 `sun4i-a10-codec` + PD20 功放 + `asound.state` |
| **WiFi** | 闭源 `bcmdhd` | 主线 `brcmfmac` + **原厂 NVRAM 逐字节复用** |
| **蓝牙** | Broadcom BSA 私有栈 | BlueZ 5.85 + bluez-alsa（**A2DP 音箱，支持 AAC**），设备上现编 |

### 4. WiFi / 蓝牙现状与预期

| 目标 | WiFi | 蓝牙 |
|---|---|---|
| 能用 | 95% | 85% |
| **体感与原厂无差别** | **80%** | **60%** |
| 全面超越原厂 | 65% | 45% |

> 详细论证见 [11_WiFi蓝牙成功率评估.md](02_分析报告/11_WiFi蓝牙成功率评估.md)

---

## 仓库结构

```
aku-system/
├── README.md                    ← 本文件
├── 00_从这里开始.md              ← 完整索引与项目速览
├── 01_原始资料/                 原始素材说明（大文件见 Release）
├── 02_分析报告/                 14 份技术分析文档
├── 03_问答记录/                 9 份问题排查记录
└── 06_工具脚本/                 资料收集与诊断脚本
```

### 📦 完整资料包（含固件解包结果）

仓库只放**文档**。完整的 4.5 GB 资料（分区镜像、根文件系统解包、图标、
Bluetooth 源码树、DTS 对照、刷机脚本等）请到 **[Releases](../../releases)** 下载：

> `aku-system-v1.0.zip` —— 538 MB / 6,757 个条目 / UTF-8 文件名 / 含符号链接

---

## 文档导航

### 分析报告

| 文档 | 内容 |
|---|---|
| [00_固件分析总报告](02_分析报告/00_固件分析总报告.md) | 设备识别、分区表、启动流程、程序分析、云接口 |
| [01_U-Boot分析](02_分析报告/01_U-Boot分析.md) | 启动流程、env 变量、bootcmd 解读 |
| [02_内核与DTS分析](02_分析报告/02_内核与DTS分析.md) | 为何原厂无设备树（fex 机制）及硬件清单 |
| [03_程序与ELF分析](02_分析报告/03_程序与ELF分析.txt) | 48 个 ELF 的架构/依赖/符号清单 |
| [04_字符串分析](02_分析报告/04_字符串分析.txt) | 云端接口、设备节点、密钥线索 |
| [05_内核模块分析](02_分析报告/05_内核模块分析.txt) | 11 个 `zhc_*` 厂商驱动拆解 |
| [06_移植成果资料整理](02_分析报告/06_移植成果资料整理.md) | 两套镜像的逐项对比 |
| [07_蓝牙方案说明与移植](02_分析报告/07_蓝牙方案说明与移植.md) | BlueZ 5.85 / bluez-alsa / 安装脚本逐段 |
| [08_WiFi蓝牙问题诊断与修复](02_分析报告/08_WiFi蓝牙问题诊断与修复.md) | 具体修复命令 |
| [09_Alpine开机自启配置](02_分析报告/09_Alpine开机自启配置.md) | OpenRC 服务模板与一键脚本 |
| [10_Alpine移植指南](02_分析报告/10_Alpine移植指南.md) | 从头移植的可行性评估与步骤 |
| [11_WiFi蓝牙成功率评估](02_分析报告/11_WiFi蓝牙成功率评估.md) | 概率评估、基线定义、测量方法 |

### 问答记录

[索引](03_问答记录/README.md) · Q1 移植可行性 · Q2 初次评估 · Q3 UDISK 元数据损坏 · Q4 成果资料分析 ·
Q5 NAND 差异 · Q6 成功率 · Q7 基线定义 · Q8 开机加载驱动

---

## 快速上手

### 只想了解这台机器
从 [00_从这里开始.md](00_从这里开始.md) 读起。

### 想在自己的设备上复现
1. 下载 Release 里的完整资料包
2. 阅读 `05_移植系统解包/刷机脚本/` 与 `flash_*.env`
3. **刷机前务必做整片 NAND 备份**（分区级备份不含 Boot0/U-Boot，救不了砖）

### 想改 DTB / 内核
```bash
# 零风险验证：只从 RAM 启动，不写任何存储
./debug_kernel.sh

# 确认没问题再落盘：只写 DTB + 内核，不动 rootfs
./flash_kernel.sh
```

---

## ⚠️ 风险提示

1. **不要用 `flash_all.sh`** —— 它会 `nand scrub.chip` 擦光整片 NAND。
2. **动任何东西之前先整片备份 NAND**。
3. **先确认 `sunxi-fel ver` 能通** —— FEL 在 BROM 里，确认可达就永远救得回来。
4. **mainline 的 `/dev/ttyS<N>` 编号来自 DTS 别名，不等于硬件 UART 号**。
5. 刷机有变砖风险，**自行承担**。

---

## 免责声明

本项目仅用于**技术研究与学习交流**。
所有固件、镜像、厂商代码的版权归**原厂（GoWild / 全志 / Broadcom 等）**所有，
本仓库不包含任何原厂闭源应用的源码，仅包含分析结论与公开可获取的构建资料。
请勿将本项目内容用于商业用途或任何违法用途。

---

## 致谢

- **zheng1** (juping_zheng1@163.com) —— mainline 移植与 Ubuntu 系统构建（`mkrootfs.sh` / `mount.sh`）
- **Ice_BingQi**、**trz0332**、**HM** —— 蓝牙方案（BlueZ 5.85 + bluez-alsa）
- [linux-sunxi](https://linux-sunxi.org/) 社区 —— sunxi 平台资料
- [sunxi-tools](https://github.com/linux-sunxi/sunxi-tools) —— FEL 刷机工具

---

## 相关链接

- **完整资料包**：[Releases](../../releases)
- **问题反馈**：[Issues](../../issues)

---

*本仓库文档由固件逆向分析整理而成，最后更新：2026-10-26*