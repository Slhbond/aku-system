# 04_原固件解包

原厂固件（小白版）的**解包结果**，约 **4.0 GB**，已打包进 Release：

> **Releases** → `aku-system-v1.0.zip`

## 内容

| 子目录 | 内容 |
|---|---|
| `00_raw/` | 10 个原始分区镜像 |
| `01_uboot/` | U-Boot 环境变量（二进制本体在 NAND 隐藏区，未备份） |
| `02_kernel_dts/` | 内核 uImage、解压后 vmlinux、重建板级 DTS |
| `03_logos/` | 18 张开机图/电池图标（BMP + PNG） |
| `04_rootfs/` | rootfs(squashfs) 与 extend(squashfs) 解包 |
| `05_工厂数据/` | MAC / SN / 授权令牌 |
| `06_ipk/` | 厂商应用安装包 |
| `07_overlay/` | /overlay 分区（应用实际安装位置） |
| `09_app_resources/` | 表情动画 358 帧 + 语音 49 个 |