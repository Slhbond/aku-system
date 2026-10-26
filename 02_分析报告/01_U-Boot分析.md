# U-Boot 分析（aku / GoWild 小小白 xxb 机器人）

## 1. 结论先说

**这次备份里没有 U-Boot 二进制本体。**

备份工具导出的是**具名分区**（boot-res / boot / env / extend / misc / private / rootfs /
rootfs_data / UDISK）。在 Allwinner（全志）平台上，**Boot0(eGON) 与 U-Boot 位于 NAND 的隐藏引导区**，
不以具名分区形式暴露，因此不会被"按分区备份"的工具导出。

本目录提供的是本次备份中**唯一的 U-Boot 数据**：`env` 分区（U-Boot 环境变量）。

## 2. 我们手里的 U-Boot 证据

| 项目 | 值 | 来源 |
|---|---|---|
| U-Boot 版本 | **2011.09** | opkg 包 `uboot-sun5i-R8-Baymin-Board` |
| 目标平台 | **sun5i / R8** | 同上（Architecture: sun5i） |
| 板级 | **Baymin Board** | 同上 |
| 包维护者 | Trace Wong `wangyaliang@allwinnertech.com` | opkg control |
| 说明 | "U-Boot 2011.09 Pre-Built for R8" | opkg control |
| 环境变量 | 18 条，见 `uboot_env_decoded.txt` | env_backup.bin |

opkg 记录（`04_rootfs/extend/lib/opkg/info/uboot-sun5i-R8-Baymin-Board.control`）：

```
Package: uboot-sun5i-R8-Baymin-Board
Version: 2011.09
Source: package/boot/uboot-sun5i
Section: boot
Maintainer: Trace Wong<wangyaliang@allwinnertech.com>
Architecture: sun5i
Installed-Size: 106
Description:  U-Boot 2011.09 Pre-Built for R8
```

注意 `uboot-sun5i-R8-Baymin-Board.list` 大小为 **0 字节** —— 说明该包**不往 rootfs 写任何文件**，
它的产物（`u-boot-sun5i.bin`）是直接烧写到 NAND 引导区的，所以根文件系统里找不到它。

## 3. 启动流程（由 env 还原）

```
Boot0 (eGON, BROM)            ← NAND 引导区，未备份
   ↓
U-Boot 2011.09 (sun5i)        ← NAND 引导区，未备份
   ↓  bootcmd = run setargs_nand boot_normal
   ↓  setargs_nand → setenv bootargs console=ttyS0,115200 root=/dev/nandd rootwait \
   ↓                 init=/etc/preinit ion_cma_512m=32m ion_cma_1g=176m \
   ↓                 ion_carveout_512m=32m ion_carveout_1g=150m \
   ↓                 coherent_pool=4m loglevel=8 partitions=${partitions}
   ↓  boot_normal = fatload sunxi_flash 2 40100000 uImage ; bootm 40100000
   ↓
Linux 3.4.39 (zImage @0x40100000)
   ↓
/etc/preinit → procd → /etc/init.d/rcS S boot → … → /etc/rc.local
       zhc_ipk_install
       xxb_robot_hw_server &
       xxb_robot_sw_server &
       zhc_hardware_test &
```

### 关键点解读

* **`sunxi_flash 2`** —— 全志 U-Boot 的私有命令，`2` 是**分区号**，即 `boot` 分区（就是本次备份的
  `boot_backup.bin`，一个 FAT12 卷，里面只有一个 `uImage`）。
* **`boot_recovery`** 用 `sunxi_flash 5`（recovery 分区），本次备份中**不存在**该分区。
* **`root=/dev/nandd`** —— 从 NAND 上的逻辑卷 `nandd` 挂根文件系统（对应 rootfs 分区）。
* **`partitions=${partitions}`** —— 该变量本身**没有出现在 env 里**，它由 U-Boot 在运行时
  根据 NAND 分区表注入；rootfs 的 `/etc/init.d/boot` 会解析它并建立 `/dev/by-name/*` 符号链接。
  因此我们可以反推出分区名集合（fstab 中也用到）：`boot / boot-res / env / private / misc /
  rootfs / rootfs_data / extend / UDISK`（+ 未备份的 recovery）。
* **`ion_cma_*` / `ion_carveout_*`** —— 全志 ION 显存/多媒体内存预留，说明有显示 + 多媒体播放
  （对应 `gwmplayer`/`mplayer`）。
* **`init=/etc/preinit`** —— 标准 OpenWrt 引导。

## 4. 关于 env 的 CRC

`env_backup.bin` 前 4 字节 = `EA 1F 26 08`，按小端读为 CRC32 = `0x08261FEA`，
紧跟其后（偏移 4）就是 `bootdelay=1\0…`。

也就是说布局是 `[CRC32 4B][数据]`（**不是** U-Boot 原生的 `[CRC32][flags][pad]` 8 字节头）。
对偏移 4 起、各种常见 ENV_SIZE（0x1000~0x200000、以及文件余下全部）计算 CRC32，
**均无法得到 0x08261FEA** —— 说明这份 env 是从运行中的设备 dump 出来的、
或写入过程被打断，**校验值已失效，但内容完整可读**。所以本目录直接给出解码后的明文。

## 5. 想拿到 U-Boot 二进制怎么办

备份集合里没有，需要另取：

1. **从设备 NAND 原始读取**引导区（Boot0 在 NAND 起始若干块，U-Boot 紧随其后）；
   全志方案地址不是固定值，建议用 `sunxi-fel` / `nanddump` 按整片 dump。
2. 或找到 **对应的 Tina/Linux BSP SDK**（本机就是 `tina_baymini` 工程，
   U-Boot 源码在 `package/boot/uboot-sun5i`），重新编译
   `uboot-sun5i-R8-Baymin-Board`，产物即 `u-boot-sun5i.bin`。
3. 也可以在本备份的 `nandi‑data3.img`（3.6 GB，UDISK 全镜像）与 `UDISK_backup.bin` 中搜索，
   但已确认：**全片扫描未发现任何 U-Boot 特征串**（"U-Boot 2"、"sunxi"、"eGON"、"BOOT" 等
   在 UDISK / nandi-data3 / misc / private 中均为 0 命中），故 U-Boot 不在这两块里。
