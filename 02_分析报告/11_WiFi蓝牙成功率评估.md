# WiFi / 蓝牙 成功率评估与方法论

> 回答的问题：「移植 Alpine 的 WiFi 和蓝牙做到原厂效果，概率多大？」
> 以及「基线到底怎么定？」

---

## 一、结论速览

| 目标 | WiFi | 蓝牙 |
|---|---|---|
| **能用** | 95% | 85% |
| **体感与原厂无差别** | **80%** | **60%** |
| **全面超越原厂** | 65% | 45% |
| **两个同时达到原厂水平** | | **约 50%** |

**一句话**：
> **WiFi 我很有信心（80%）** —— 决定 WiFi 好坏的东西（NVRAM、天线、管制域）都已经对了，剩下是调参。
>
> **蓝牙我给 60%** —— 换的是整套协议栈，而且缺了 GPIO 共存管理。
> **它不会「调不好」，但可能「调不回一模一样」**。

---

## 二、支撑判断的硬数据

### 2.1 蓝牙 HCD 固件 —— 三份完全相同 ✅

```
原厂        e83ba393b7550d56addd04b05860c8be  bcm43438a0.hcd
Ubuntu 镜像  e83ba393b7550d56addd04b05860c8be
BT 安装包    e83ba393b7550d56addd04b05860c8be
Alpine 镜像  e83ba393b7550d56addd04b05860c8be
```
→ 蓝牙**射频层的固件是同一份**，差异只能来自协议栈和主机侧集成。

### 2.2 WiFi 固件 —— 不同构建 ⚠️

```
原厂      fw_bcm43438a0.bin          378,595 B   (bcmdhd 用)
新系统    brcmfmac43430a0-sdio.bin   382,455 B   (brcmfmac 用)
```
→ 同芯片的**不同 Broadcom 发布版本**。影响的是特性而非射频功率。

### 2.3 NVRAM —— 逐字节相同 ✅

```
原厂  /lib/firmware/ap6212/nvram_ap6212.txt
新系统 /lib/firmware/brcm/brcmfmac43430a0-sdio.txt
diff → 完全相同
```

**关键观察**：原厂 NVRAM 文件里写着：
```
# The following parameter values are just placeholders, need to be updated.
macaddr=00:90:4c:c5:12:38      ← Broadcom 默认占位 MAC
ccode=ALL                      ← 不做任何管制域限制
```
→ **原厂根本没做板级射频调校。所以主线只要配置对，本来就该打平。**

---

## 三、WiFi 分析（80%）

### 3.1 结构性优势

| 决定因素 | 状况 |
|---|---|
| **射频功率 / 灵敏度** | 由 NVRAM 决定 —— **逐字节相同** ✅ |
| **天线 / 射频走线** | 同一块板 ✅ |
| **管制域** | 原厂 `ccode=ALL` 无限制；Alpine 已装 `wireless-regdb`，补一条 `iw reg set CN` 即可 ✅ |
| **省电模式** | Alpine 用 `wpa_supplicant` + `ifupdown-ng`，**无 NetworkManager 强制省电** ✅ |
| **驱动成熟度** | `brcmfmac` 是主线驱动，BCM43438 是**树莓派 3 同款**，社区坑早踩平 ✅ |

### 3.2 风险点

| # | 风险 | 严重度 | 对策 |
|---|---|---|---|
| 1 | **`max-frequency = <10000000>`（10 MHz）可能是自设的吞吐上限** | 🟠 中高 | **试 25 MHz**（见 3.3） |
| 2 | WiFi 固件是不同构建 | 🟡 低 | 观察，一般不需要动 |
| 3 | brcmfmac 的速率自适应/漫游策略与 bcmdhd 不同 | 🟡 低-中 | 属驱动固有差异，接受 |

### 3.3 关于 `max-frequency` 的取舍

```
SDIO 4-bit 带宽 = 时钟 × 4
  10 MHz → 40 Mbps   （你现在的设置）
  25 MHz → 100 Mbps
  50 MHz → 200 Mbps  （原厂 bcmdhd 大概率跑这个）
```

802.11n 1×1 20MHz 的实测 TCP 吞吐上限约 **35 Mbps**。
**10 MHz 的 SDIO 只有 40 Mbps 理论带宽，扣掉协议开销后很可能正好卡在脖子上。**

| 设置 | 稳定性 | 吞吐 |
|---|---|---|
| 10 MHz | 最稳 | 可能受限 |
| **25 MHz** | **大概率够稳** | **应该够用** |
| 50 MHz | 可能 CRC 重传 | 最高 |

**建议：从 10 MHz 开始往上试，找到「稳定前提下的最高值」。**
改法：编辑 DTB → `debug_kernel.sh` 验证（零写入）→ `flash_kernel.sh` 落盘。

---

## 四、蓝牙分析（60%）

### 4.1 射频层没问题

HCD 固件逐字节相同 ✅，天线共用同一套 ✅。

### 4.2 三个结构性劣势

#### ① 协议栈整个换了 —— 这不是配置问题

| | 原厂 | 新系统 |
|---|---|---|
| 协议栈 | Broadcom **BSA**（私有） | **BlueZ 5.85** |
| 组件 | `bsa_server` 1.69 MB + `libbsa.so` + `libbtapp.so` | `bluetoothd` + `bluealsa` |
| A2DP 实现 | BSA 内部 | bluez-alsa |
| profile 支持 | BSA 决定的集合 | BlueZ 决定的集合 |

**profile 支持、A2DP 实现、功耗策略都不同 —— 属于「换了实现」，不是「配置错了」。**

#### ② 内核缺 `hci_bcm` / `btbcm` —— 最值得担心的一条

核对 `modules.builtin`：
```
bluetooth    builtin=1      ← 有
hci_uart     builtin=1      ← 有（brcm_patchram_plus 需要它）
btbcm        builtin=0  module=0     ← ❌ 没有
hci_bcm      builtin=0  module=0     ← ❌ 没有
```

后果：DTB 里这三个 GPIO **没有任何驱动去管**
```dts
bluetooth {
    compatible = "brcm,bcm43438-bt";
    shutdown-gpios      = <&pio 4 10 1>;   // PE10  BT 电源
    device-wakeup-gpios = <&pio 1 3 1>;    // PB3
    host-wakeup-gpios   = <&pio 6 1 1>;    // PG1
};
```

**WiFi 和蓝牙共用同一根天线，共存靠这些信号握手。** 没人管它们，共存只能靠硬件默认状态。
**这很可能就是「蓝牙不如原厂」的真正原因。**

原厂还有 `rfkill0/state` 做 BT 上电时序（见原厂 `/etc/bluetooth/btenable.sh`），新系统也没这个驱动。

#### ③ 用户态固件补丁加载（Alpine 侧缺失）

- Ubuntu 侧：✅ `brcm_patchram_plus` 已配
- Alpine 侧：❌ **全盘搜 `bcm43438`/`patchram` 零命中** —— 补丁文件在但没人加载

**Alpine 的蓝牙大概率比 Ubuntu 还差，必须先补这一环。**

### 4.3 一个正向因素：音质可能更好 ✅

bluez-alsa 编译时开了 `--enable-aac`（从 `build/config.log` 确认 `ENABLE_AAC_TRUE=''`）：

| 编解码器 | 状态 |
|---|---|
| SBC | ✅ 启用 |
| **AAC** | ✅ **启用** |
| aptX / aptX-HD | ❌ 未启用 |
| LC3plus | ❌ 未启用 |

原厂 BSA 那套大概率只有 SBC。**如果音源支持 AAC，新系统音质应该比原厂好。**

---

## 五、基线怎么定（重要）

### 5.1 硬约束

**小白的原固件在 AKU 上跑不起来**（NAND 品牌不同，一直重启）。
所以「在 AKU 上跑原厂固件测基线」这条路是堵死的。

### 5.2 三层基线

| 层级 | 怎么测 | 前提 | 可行性 |
|---|---|---|---|
| **A. 真·原厂基线** | 小白设备 + 小白原厂固件 | 小白还在手上 | ✅ 最理想 |
| **B. 绝对基线** | 用芯片理论上限当标尺 | 无 | ✅ **推荐** |
| **C. 相对基线** | AKU+Ubuntu vs AKU+Alpine | 现在就有 | ✅ 现在就能做 |

**关于 A**：小白和 AKU 只差 NAND 品牌，射频部分完全相同，所以小白的数据可以当 AKU 的参照。

**关于 B**：BCM43438 是 802.11n 1×1 20MHz，理论 PHY 72.2 Mbps，实测 TCP 天花板约 35 Mbps。
```bash
iw dev wlan0 link
# 近距离能协商到 72.2 Mbit/s → PHY 已拉满，射频层面没得可捞了
```
**这比「跟原厂比」更有意义，因为原厂也超不过芯片上限。**

### 5.3 测量方法与工具

**原厂系统没有 `iw` / `iperf3`**，但有 `wget` / `nc` / `telnetd` / `adbd`。
信号强度可以用 `cat /proc/net/wireless` 读（不需要 iw）。

```sh
# ── 原厂上（telnet 或 adb） ──
cat /proc/net/wireless
wget -O /dev/null http://<PC_IP>:8000/test.bin

# ── Ubuntu / Alpine 上（先补工具） ──
apt install iperf3 iw     # Ubuntu
apk add iperf3 iw         # Alpine

iw dev wlan0 link
iw reg get
iw dev wlan0 get power_save
iperf3 -c <PC_IP> -t 30
dmesg | grep -iE 'brcmfmac|sdio|mmc'
```

PC 侧：
```bash
python -m http.server 8000      # 放个 100MB 的 test.bin
iperf3 -s
```

### 5.4 记录表（建议照抄）

| 系统 | signal(dBm) | bitrate | iperf3(Mbps) | power_save | regdom | BT 掉音距离 |
|---|---|---|---|---|---|---|
| 小白+原厂 | | | | 不适用 | 不适用 | |
| AKU+Ubuntu | | | | | | |
| AKU+Alpine | | | | | | |

### 5.5 三条纪律

1. **同一时间、同一位置、同一 AP** —— 2.4GHz 很挤，不同时段数据没法比
2. **每点测 3 次取中位** —— 单次读数波动很大
3. **蓝牙也要量距离** —— 从 1m 走远，记下「开始断续」的位置。蓝牙音箱的「效果」主要就是这个

---

## 六、提升概率的动作清单

按性价比排序：

| # | 动作 | 影响对象 | 预期收益 | 难度 |
|---|---|---|---|---|
| 1 | **测出基线数字** | 两者 | 没有基线，一切无从判断 | ★ |
| 2 | Ubuntu 侧：装 `wireless-regdb` + 关省电 + 换 Alpine 的 DTB | WiFi | 🔥🔥🔥 | ★ |
| 3 | **Alpine 侧：补 `btattach` 服务加载 HCD** | 蓝牙 | 🔥🔥🔥 | ★★ |
| 4 | 试把 SDIO `max-frequency` 从 10 MHz 提到 25 MHz | WiFi | 🔥🔥 | ★ |
| 5 | Alpine 侧：重编 BlueZ 5.85 + bluez-alsa | 蓝牙 | 🔥🔥（恢复 A2DP 音箱 + AAC） | ★★★ |
| 6 | **把 `hci_bcm`/`btbcm` 编进内核** | 蓝牙 | 🔥🔥🔥（恢复共存 GPIO 管理） | ★★★★ |
| 7 | Alpine 侧：设 `iw reg set CN` 开机项 | WiFi | 🔥 | ★ |

---

## 七、风险登记表

| ID | 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|---|
| R1 | 蓝牙共存 GPIO 无人管理导致距离/稳定性不如原厂 | 中高 | 高 | 把 `hci_bcm` 编进内核，或手工用 `gpioset` 设定引脚状态 |
| R2 | SDIO 10 MHz 限制吞吐 | 中 | 中 | 提到 25 MHz 试 |
| R3 | BSA 特有 profile 无法在 BlueZ 复现 | 中 | 中 | 接受；先确认原厂实际用了哪些 profile |
| R4 | `aku_auto_pair`/`aku_volum` 无源码，Alpine 上不能用 | 高 | 低 | 用 glibc 兼容层，或自己重写（逻辑简单） |
| R5 | 蓝牙串口编号（ttyS1 vs ttyS3）不确定 | 低 | 中 | 实测两个端口 |
| R6 | 换 NAND 品牌需重新生成 SPL-ECC 镜像 | 低（当前设备已可用） | 高 | 用 `sunxi-nand-image-builder` 重新生成 |

---

## 八、最终判断

```
WiFi   ████████████████░░░░  80%   主要靠配置，可修
蓝牙   ████████████░░░░░░░░  60%   协议栈差异 + 共存 GPIO 缺失
两者   ██████████░░░░░░░░░░  50%
```

**WiFi 是可以「调到打平甚至更好」的**；
**蓝牙更现实的目标是「能用且够用」，完全一致要看共存那条线能不能补上。**

---

## 相关文档

- [`08_WiFi蓝牙问题诊断与修复.md`](08_WiFi蓝牙问题诊断与修复.md) —— 具体修复步骤
- [`07_蓝牙方案说明与移植.md`](07_蓝牙方案说明与移植.md) —— 蓝牙整套架构
- [`09_Alpine开机自启配置.md`](09_Alpine开机自启配置.md) —— Alpine 侧落地配置