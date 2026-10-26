# 05_移植系统解包

两套移植系统（Ubuntu 22.04 / Alpine 3.19.9）的**解包结果**，约 **300 MB**，已打包进 Release：

> **Releases** → `aku-system-v1.0.zip`

## 内容

| 子目录 | 内容 |
|---|---|
| `Ubuntu_镜像/` | 大佬的 Ubuntu 刷机镜像包（uImage / SPL / U-Boot / DTB / rootfs.ubi + 刷机脚本） |
| `Alpine_镜像/` | 你的 Alpine 刷机镜像包（同上） |
| `Ubuntu_rootfs工程/` | rootfs 构建工程（`mkrootfs.sh` / `mount.sh` / `ubinize.cfg`） |
| `Alpine_rootfs解包/` | Alpine UBIFS 解包结果（976 个文件 / 70 个包） |
| `补充文件_cp/` | 需拷入 rootfs 的 firmware / modules / adbd / asound.state |
| `蓝牙方案/` | BlueZ 5.85 + bluez-alsa 完整源码树 + 安装脚本 + 自定义服务 |
| `DTS对照/` | 两套 DTB 的反编译 `.dts` 与差异 `.diff` |
| `刷机脚本/` | `flash_all.sh` / `flash_kernel.sh` / `debug_kernel.sh` 与 `.env` |

## ⚠️ 刷机前必读

1. **不要用 `flash_all.sh`** —— 会 `nand scrub.chip` 擦光整片 NAND
2. 改 DTB/内核用 `debug_kernel.sh`（零写入验证）→ `flash_kernel.sh`（只写 DTB+内核）
3. 刷机前**务必整片备份 NAND**