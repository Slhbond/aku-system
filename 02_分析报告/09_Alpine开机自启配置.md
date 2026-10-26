# Alpine 开机自动加载 WiFi / 蓝牙 配置指南

> 针对：AKU 设备上的 Alpine 3.19.9 + Linux 6.1.9（大佬的 mainline 移植）
> 本文所有结论都基于**解包出来的实际 rootfs**，不是通用模板

---

## 0. ⚠️ 先纠正一个说法

**"让 Alpine 开机加载 WiFi/蓝牙驱动"这句话，对 WiFi 对，对蓝牙不对。**

这套系统里，绝大多数驱动是**编进内核的（=y）**，开机就在，根本不需要"加载"。
我核对过 `modules.builtin`：

| 驱动 | 状态 |
|---|---|
| `bluetooth`、`hci_uart`、`rfkill` | **builtin**（编进内核） |
| `cfg80211`、`mac80211` | **builtin** |
| `sunxi_nand`、`mtd`、`ubi`、`ubifs` | **builtin** |
| `st7735sfb`（显示）、`sun4i-codec`（音频）、`pwm-sun4i`、`backlight` | **builtin** |
| `axp20x_battery` | **builtin** |
| **`brcmfmac`、`brcmutil`** | **module（只有这 2 个是模块）** |

**所以整个系统只有 `brcmfmac` 一个模块需要"开机加载"。**

### 三层模型（WiFi 和蓝牙完全不同）

**WiFi：**
| 层 | 内容 | 机制 | 你的现状 |
|---|---|---|---|
| ① 内核模块 | `brcmfmac` + `brcmutil` | `modprobe` | ✅ `/etc/modules` 里有（但重复写了两次） |
| ② 固件 | `brcmfmac43430a0-sdio.bin` | 驱动自动从 `/lib/firmware/brcm/` 读 | ✅ |
| ③ NVRAM | `brcmfmac43430a0-sdio.txt` | 同上 | ✅（与原厂逐字节相同） |
| ④ 用户态 | `wpa_supplicant` + `udhcpc` | `networking` 服务 → `ifup wlan0` | ✅ `networking` 已在 boot runlevel |

**蓝牙：**
| 层 | 内容 | 机制 | 你的现状 |
|---|---|---|---|
| ① 内核驱动 | `bluetooth`、`hci_uart` | **编进内核，开机即在** | ✅ **不用管** |
| ② 固件补丁 | `bcm43438a0.hcd` | **用户态程序**下载 + 挂 HCI | ❌ **没有任何程序做这件事** |
| ③ 用户态 | `bluetoothd` | OpenRC `bluetooth` 服务 | ⚠️ 需确认是否启用 |

> **关键**：蓝牙的"开机加载"不是加载模块，而是**启动一个用户态服务，去下载固件补丁并把 HCI 挂到串口上**。
> 内核那部分开机就在，缺的是这一环。

---

## 1. WiFi 开机自启

### 1.1 检查现状

```sh
cat /etc/modules                    # 应该有 brcmfmac
lsmod | grep -E 'brcmfmac|brcmutil' # 看是否已加载
rc-update show                      # 看服务在哪个 runlevel
```

### 1.2 修正 `/etc/modules`（去掉重复）

你现在的内容是：
```
af_packet
ipv6
brcmfmac
brcmfmac      ← 重复了
```

改成：
```sh
cat > /etc/modules <<'EOF'
af_packet
ipv6
brcmfmac
EOF
```

### 1.3 确保服务在正确的 runlevel

Alpine 的 `/etc/init.d/modules` **确实会读 `/etc/modules`**（我读过源码，里面有 `if [ -f /etc/modules ]` 分支）。

```sh
rc-update add modules boot
rc-update add hwdrivers boot     # 按 /sys 的 modalias 自动加载，双保险
rc-update add networking boot    # ifup wlan0（wpa_supplicant + dhcp）

# 立刻生效
rc-service modules start
rc-service networking restart
```

> **`hwdrivers` 是个好保险** —— 它扫描 `/sys/**/modalias` 然后 `modprobe -b -a`，
> SDIO 设备的 modalias 会自动匹配到 `brcmfmac`，所以即使 `/etc/modules` 写错了也能加载上。

### 1.4 验证

```sh
dmesg | grep -iE 'brcmfmac|brcm|sdio'
ip link show wlan0
iw dev wlan0 link
cat /proc/net/wireless
```

**期望看到**：`brcmfmac: ... firmware: brcm/brcmfmac43430a0-sdio.bin`，然后 `wlan0` 出现。

---

## 2. 蓝牙开机自启（这是要补的核心一环）

Alpine 目前**没有任何东西加载 `bcm43438a0.hcd`**（我全盘搜过 `bcm43438`/`patchram`，零命中）。

### 2.1 好消息：不用 glibc 兼容层

我查了 Alpine 自带的 `hciattach`（来自 `bluez-deprecated` 包）：

```
$ strings /usr/bin/hciattach | grep -i bcm
bcm43xx_init
bcm2035
bcm43xx
bcm43xx-3wire
/lib/firmware
.hcd
```

**它支持 `bcm43xx` 类型，并且会从 `/lib/firmware` 读 `.hcd` 补丁文件 —— 而且是 musl 原生二进制。**
所以不需要把 Ubuntu 那份 glibc 的 `brcm_patchram_plus` 搬过来。

### 2.2 先把 HCD 放到 hciattach 能找到的位置

`hciattach` 找的是 **`/lib/firmware/`**（不是 `/lib/firmware/brcm/`），
而文件名是按芯片 ID 拼出来的，需要试。

**做法：几个候选名字都放一份**（成本极低，一劳永逸）：

```sh
cd /lib/firmware
for n in BCM43430A0.hcd BCM43430A1.hcd BCM43438A0.hcd bcm43438a0.hcd; do
    cp -n brcm/bcm43438a0.hcd "$n"
done
ls -la /lib/firmware/*.hcd
```

### 2.3 先手动试通，再做成服务

```sh
# 确保 bluetoothd 没在跑（避免抢串口）
rc-service bluetooth stop 2>/dev/null
killall bluetoothd 2>/dev/null; sleep 1

# 手动挂
hciattach /dev/ttyS3 bcm43xx 1500000 flow

# 另开一个终端（或后台跑）验证
hciconfig -a
```

**成功的样子**：`hciconfig` 显示 `hci0`，`BD Address` 是真实地址（不是 `00:00:00:00:00:00`），
Manufacturer 显示 `Broadcom Corporation`。

**如果报错**，看提示：
- `Can't open firmware file` → 文件名不对，按提示的名字再 cp 一份
- `Can't open serial port` → 串口不对（见下面第 4 节）
- `unknown chip id` → 通信没建立，检查波特率/接线

### 2.4 做成 OpenRC 服务

```sh
cat > /etc/init.d/btattach <<'EOF'
#!/sbin/openrc-run
name="BCM43438 Bluetooth Attach"
description="Download BCM43438 firmware patch and attach HCI on UART3"

depend() {
    need localmount
    after modules hwdrivers
    before bluetooth
    provide btattach
}

start() {
    ebegin "Attaching BCM43438 on /dev/ttyS3"
    # hciattach 会自己 fork 到后台
    /usr/bin/hciattach /dev/ttyS3 bcm43xx 1500000 flow
    eend $?
}

stop() {
    ebegin "Detaching Bluetooth"
    killall hciattach 2>/dev/null
    eend 0
}
EOF

chmod +x /etc/init.d/btattach
rc-update add btattach default
```

### 2.5 启用 bluetoothd

```sh
rc-update add dbus default          # bluetooth 服务依赖 dbus
rc-update add bluetooth default
rc-service dbus start
rc-service btattach start
rc-service bluetooth start
```

### 2.6 验证

```sh
rc-status                          # 看服务状态
hciconfig -a
bluetoothctl show
dmesg | grep -iE 'bluetooth|hci'
```

---

## 3. 一条命令搞定（配置脚本）

把下面存成 `/root/setup-radio.sh` 在设备上跑：

```sh
#!/bin/sh
# AKU Alpine —— WiFi/蓝牙开机自启配置
set -e

echo "=== 1. 修正 /etc/modules ==="
printf 'af_packet\nipv6\nbrcmfmac\n' > /etc/modules
cat /etc/modules

echo "=== 2. WiFi 服务入 runlevel ==="
rc-update add modules boot     2>/dev/null || true
rc-update add hwdrivers boot   2>/dev/null || true
rc-update add networking boot  2>/dev/null || true

echo "=== 3. 铺 HCD 候选文件名 ==="
cd /lib/firmware
for n in BCM43430A0.hcd BCM43430A1.hcd BCM43438A0.hcd; do
    [ -f "$n" ] || cp brcm/bcm43438a0.hcd "$n"
done
ls -la /lib/firmware/*.hcd

echo "=== 4. 装 btattach 服务 ==="
cat > /etc/init.d/btattach <<'EOS'
#!/sbin/openrc-run
name="BCM43438 Bluetooth Attach"
depend() {
    need localmount
    after modules hwdrivers
    before bluetooth
    provide btattach
}
start() {
    ebegin "Attaching BCM43438 on /dev/ttyS3"
    /usr/bin/hciattach /dev/ttyS3 bcm43xx 1500000 flow
    eend $?
}
stop() {
    ebegin "Detaching Bluetooth"
    killall hciattach 2>/dev/null
    eend 0
}
EOS
chmod +x /etc/init.d/btattach

echo "=== 5. 蓝牙服务入 runlevel ==="
rc-update add dbus default      2>/dev/null || true
rc-update add btattach default  2>/dev/null || true
rc-update add bluetooth default 2>/dev/null || true

echo "=== 6. 当前 runlevel 状态 ==="
rc-update show

echo
echo "配置完成，重启后生效：  reboot"
```

---

## 4. ⚠️ 还要先确认蓝牙串口（第 4 节很关键）

前面分析原厂固件时发现一个**编号陷阱**：

- **原厂（vendor 内核）**：`btenable.sh` 用 `/dev/ttyS1` → 硬件 **UART1**（0x1c28400）
- **新系统（mainline）**：用 `/dev/ttyS3` → 硬件 **UART3**（0x1c28c00）

**mainline 的 `/dev/ttyS<N>` 编号来自 DTS 别名，不等于硬件 UART 号：**

```dts
aliases {
    serial0 = "/soc/serial@1c28400";   /* 硬件 UART1，却暴露成 ttyS0 */
    serial3 = "/soc/serial@1c28c00";   /* 硬件 UART3，暴露成 ttyS3 */
};
```

既然 Ubuntu 那套用 `ttyS3` 确实能用，说明 `ttyS3` 是对的。
**但如果你 `hciattach` 一直挂不上，不妨试试换成 `/dev/ttyS0`** —— 成本很低：

```sh
hciattach /dev/ttyS0 bcm43xx 1500000 flow
```

> 注意：`ttyS0` 现在是 console，如果 BT 真在 `ttyS0` 上，那 console 就配错了，
> 这时候要改 DTB 的 bootargs。先试再说。

---

## 5. 排错速查

| 现象 | 检查 |
|---|---|
| WiFi 没起来 | `lsmod | grep brcmfmac`；`dmesg | grep -i brcmfmac` 看有没有固件加载失败 |
| wlan0 不存在 | `ip link`；`dmesg | grep -i mmc` 看 SDIO 有没有枚举到 |
| 能连上但很慢 | `iw dev wlan0 get power_save`；`iw reg get` |
| 蓝牙 hci0 不存在 | `rc-service btattach status`；手动跑 `hciattach` 看报错 |
| hci0 在但地址是全 0 | HCD 补丁没加载成功 → 检查文件名 |
| 蓝牙能连但音质差/易断 | `bluealsa` 没装/没起；见 `蓝牙方案说明与移植.md` |
| 服务没自动起 | `rc-update show` 看 runlevel；`rc-status` 看运行状态 |

### 一个通用原则

**Alpine 里"开机自动做某事"= 写一个 `/etc/init.d/xxx` + `rc-update add xxx <runlevel>`。**

runlevel 的含义：
- `sysinit` → 最早，文件系统还没挂全
- `boot` → 基本系统就绪（网络、模块、挂载都在这）
- `default` → 正常的用户态服务（adbd、sshd、bluetooth 在这）
- `shutdown` → 关机时执行

---

## 6. 总结：你现在缺什么

| 项 | 状态 | 要做什么 |
|---|---|---|
| `brcmfmac` 模块加载 | ✅ 已配 | 去掉 `/etc/modules` 里的重复行 |
| WiFi 固件/NVRAM | ✅ 齐 | 无 |
| `wpa_supplicant` 自启 | ✅ 已配（`networking` + `interfaces`） | 确认 `networking` 在 boot runlevel |
| **蓝牙固件补丁加载** | ❌ **完全没做** | **按第 2 节建 `btattach` 服务** |
| `bluetoothd` 自启 | ⚠️ 未确认 | `rc-update add dbus/bluetooth default` |
| `bluealsa`（蓝牙音箱） | ❌ 没有 | 见 `蓝牙方案说明与移植.md` |
| 管制域 | ✅ 有 `wireless-regdb` | 加 `iw reg set CN` 的开机项 |

**工作量：WiFi 侧半小时，蓝牙侧 1-2 小时（如果要 A2DP 音箱功能则要 1-2 天，因为要重编 bluez-alsa）。**
