# 01_原始资料

这里原本存放**所有原始素材**（固件包、移植镜像、构建工程等），
因为体积较大（合计 **259 MB**），已全部打包进 Release：

> **[aku-system-v1.0.zip](../../releases)** —— 532.7 MiB

## 包含内容

| 文件 | 大小 | 说明 |
|---|---|---|
| `原固件_小白_aku原固件.zip` | 50 MB | 小白版原厂固件分区备份（10 个分区） |
| `aku_ubuntu_2204_251017.tar.gz` | 93 MB | Ubuntu 22.04 完整刷机镜像包 |
| `aku_alpine_3.19.9_slhbond.tar.gz` | 24 MB | Alpine 3.19.9 完整刷机镜像包 |
| `ubuntu-22.04.tar.gz` | 72 MB | Ubuntu rootfs 构建工程 |
| `cp.tar.gz` | 0.5 MB | 需拷入 rootfs 的补充文件 |
| `bluetooth-2204-images10-260118.tar.gz` | 18 MB | 蓝牙安装包（BlueZ 5.85 源码树） |
| `制作步骤截图/` | 0.7 MB | 4 张系统制作步骤截图 |

## 注意

- 所有文件**保持原样未改动**（仅原始 JPEG 截图转成了 PNG 以统一格式）
- 解压方法见 [00_从这里开始.md](../00_从这里开始.md)