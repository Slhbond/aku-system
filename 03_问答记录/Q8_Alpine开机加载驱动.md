# Q8：让 Alpine 开机加载 WiFi/蓝牙驱动

## 你的问题

> alpine 再让他开机加载驱动比如 WiFi 蓝牙这些

## ⚠️ 先纠正一个说法

**这句话对 WiFi 对，对蓝牙不对。**

这套系统里**绝大多数驱动是编进内核的（=y）**，开机就在，根本不需要「加载」。
核对 `modules.builtin` 的结果：

| 驱动 | 状态 |
|---|---|
| `bluetooth`、`hci_uart`、`rfkill` | **builtin** |
| `cfg80211`、`mac80211` | **builtin** |
| `sunxi_nand`、`mtd`、`ubi`、`ubifs` | **builtin** |
| `st7735sfb`、`sun4i-codec`、`pwm-sun4i`、`backlight` | **builtin** |
| `axp20x_battery` | **builtin** |
| **`brcmfmac`、`brcmutil`** | **module（只有这 2 个是模块）** |

**→ 整个系统只有 `brcmfmac` 一个模块需要「开机加载」。**

## 三层模型

### WiFi（需要加载模块）

| 层 | 内容 | 机制 | 现状 |
|---|---|---|---|
| ① 内核模块 | `brcmfmac` + `brcmutil` | `modprobe` | ✅ `/etc/modules` 里有（但**重复写了两次**） |
| ② 固件 | `brcmfmac43430a0-sdio.bin` | 驱动自动从 `/lib/firmware/brcm/` 读 | ✅ |
| ③ NVRAM | `brcmfmac43430a0-sdio.txt` | 同上 | ✅（与原厂逐字节相同） |
| ④ 用户态 | `wpa_supplicant` + `udhcpc` | `networking` 服务 → `ifup wlan0` | ✅ 已在 boot runlevel |

### 蓝牙（**不需要加载驱动**）

| 层 | 内容 | 机制 | 现状 |
|---|---|---|---|
| ① 内核驱动 | `bluetooth`、`hci_uart` | **编进内核，开机即在** | ✅ **不用管** |
| ② 固件补丁 | `bcm43438a0.hcd` | **用户态程序**下载 + 挂 HCI | ❌ **没有任何程序做这件事** |
| ③ 用户态 | `bluetoothd` | OpenRC `bluetooth` 服务 | ⚠️ 需确认是否启用 |

> **关键**：蓝牙的「开机加载」不是加载模块，而是**启动一个用户态服务，去下载固件补丁并把 HCI 挂到串口上**。

## 好消息：不用 glibc 兼容层

查了 Alpine 自带的 `hciattach`（来自 `bluez-deprecated` 包）：
```
$ strings /usr/bin/hciattach | grep -i bcm
bcm43xx_init
bcm2035
bcm43xx
/lib/firmware
.hcd
```
**它支持 `bcm43xx` 类型，会从 `/lib/firmware` 读 `.hcd` 补丁 —— 而且是 musl 原生二进制。**
所以不需要把 Ubuntu 那份 glibc 的 `brcm_patchram_plus` 搬过来。

## 要补的东西（就一样）

| 项 | 状态 |
|---|---|
| `brcmfmac` 模块加载 | ✅ 已配（去掉重复行即可） |
| WiFi 固件 / NVRAM | ✅ 齐 |
| `wpa_supplicant` 自启 | ✅ 已配 |
| **蓝牙固件补丁加载** | ❌ **全盘搜 `bcm43438`/`patchram` 零命中** |
| `bluetoothd` 自启 | ⚠️ 未确认 |
| `bluealsa`（音箱功能） | ❌ 没有 |

## 蓝牙服务模板

```sh
# 先把 HCD 铺到 hciattach 能找到的位置（几个候选名都放一份）
cd /lib/firmware
for n in BCM43430A0.hcd BCM43430A1.hcd BCM43438A0.hcd; do
    cp -n brcm/bcm43438a0.hcd "$n"
done

cat > /etc/init.d/btattach <<'EOF'
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
stop() { killall hciattach 2>/dev/null; }
EOF
chmod +x /etc/init.d/btattach

rc-update add dbus default
rc-update add btattach default
rc-update add bluetooth default
```

## 两个提醒

**① runlevel 状态请在设备上确认**
解包结果里 runlevel 只有 `devfs networking procfs sysfs`(boot) 和 `adbd sshd`(default)，
但 OpenRC 的 runlevel 是**符号链接**，在 Windows 上解包可能丢失 → **上设备跑 `rc-update show` 看真实状态**。

**② 蓝牙串口编号陷阱**
如果 `hciattach /dev/ttyS3` 一直挂不上，**试试换成 `/dev/ttyS0`**：
- 原厂脚本用 `ttyS1` → 硬件 UART1
- 新系统用 `ttyS3` → 硬件 UART3
- 而 mainline 的 `serial0` 别名指向的其实是**硬件 UART1**

## 完整配置
见 [`../02_分析报告/09_Alpine开机自启配置.md`]（含一键脚本、排错速查表）