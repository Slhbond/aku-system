#!/bin/sh
# ============================================================
#  collect-info.sh
#  在【移植好的 Alpine / Ubuntu 系统】上运行，一键收集移植资料
#
#  用法:
#      sh collect-info.sh                # 输出到当前目录
#      sh collect-info.sh /tmp/out       # 指定输出目录前缀
#
#  产物: 一个 .tar.gz，把它交给分析方即可
#  兼容 BusyBox ash (Alpine 默认 shell)，不需要 bash
# ============================================================

OUT="${1:-./porting-info}"
OUT="$OUT-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)"
mkdir -p "$OUT" 2>/dev/null || { echo "无法创建 $OUT"; exit 1; }

say() { echo "[*] $*"; }
has() { command -v "$1" >/dev/null 2>&1; }

# 记录某条命令的输出
run() {
  _f="$OUT/$1"; shift
  {
    echo "\$ $*"
    echo "------------------------------------------------------------"
    "$@" 2>&1
    echo "------------------------------------------------------------"
    echo
  } > "$_f" 2>&1
}

# 拼接若干文件的内容
grab() {
  _f="$OUT/$1"; shift
  : > "$_f"
  for _p in "$@"; do
    if [ -e "$_p" ] || [ -L "$_p" ]; then
      echo "===== $_p =====" >> "$_f"
      cat "$_p" >> "$_f" 2>&1
      echo >> "$_f"
    fi
  done
}

KREL="$(uname -r 2>/dev/null)"
say "输出目录: $OUT"
say "内核版本: $KREL"

# ---------------- 1. 基本信息 ----------------
{
  echo "=============== 基本信息 ==============="
  echo "--- uname -a ---";            uname -a 2>&1
  echo; echo "--- /etc/os-release ---"; cat /etc/os-release 2>/dev/null
  echo; echo "--- /etc/issue ---";      cat /etc/issue 2>/dev/null
  echo; echo "--- /proc/cmdline ---";   cat /proc/cmdline 2>&1
  echo; echo "--- 设备树 model ---"
  tr '\0' '\n' < /sys/firmware/devicetree/base/model 2>/dev/null
  echo; echo "--- 设备树 compatible ---"
  tr '\0' '\n' < /sys/firmware/devicetree/base/compatible 2>/dev/null
  echo; echo "--- /proc/cpuinfo ---";   cat /proc/cpuinfo 2>&1
  echo; echo "--- /proc/meminfo ---";   cat /proc/meminfo 2>&1
  echo; echo "--- date / uptime ---";   date 2>&1; uptime 2>&1
} > "$OUT/01-info.txt" 2>&1
say "1/11 基本信息"

# ---------------- 2. 设备树（最关键）----------------
if has dtc; then
  dtc -I fs -O dts /proc/device-tree > "$OUT/02-devicetree-live.dts" 2>&1
  say "2/11 设备树 -> 02-devicetree-live.dts (完整可编译)"
else
  {
    echo "# 未安装 dtc，下面是原始属性值"
    echo "# 建议先执行:  apk add dtc      (Alpine)"
    echo "#         或   apt install device-tree-compiler"
    echo "# 然后重新运行本脚本，即可得到完整 .dts"
    echo
    ( cd /proc/device-tree 2>/dev/null && find . -type f 2>/dev/null | while read -r f; do
        echo "===== $f ====="
        tr '\0' '\n' < "$f" 2>/dev/null
        echo
      done )
  } > "$OUT/02-devicetree-raw.txt" 2>&1
  say "2/11 设备树 -> 02-devicetree-raw.txt (无 dtc，原始属性)"
fi

# ---------------- 3. 引导与分区 ----------------
{
  echo "=============== /boot ==============="
  ls -la /boot 2>&1
  echo; echo "=============== 引导配置 ==============="
  for f in /boot/extlinux/extlinux.conf /boot/extlinux.conf /boot/uEnv.txt \
           /boot/boot.scr /boot/boot.cmd /boot/armbianEnv.txt /boot/config.txt; do
    if [ -f "$f" ]; then echo "----- $f -----"; cat "$f"; echo; fi
  done
  echo "=============== /etc/fstab ==============="; cat /etc/fstab 2>&1
  echo; echo "=============== /proc/partitions ==============="; cat /proc/partitions 2>&1
  echo; echo "=============== /proc/mtd ===============";        cat /proc/mtd 2>&1
  echo; echo "=============== /proc/mounts ===============";     cat /proc/mounts 2>&1
  echo; echo "=============== blkid ===============";            blkid 2>&1
  echo; echo "=============== u-boot env (若有) ==============="
  if [ -r /proc/device-tree/chosen/u-boot,version ]; then
    tr '\0' '\n' < /proc/device-tree/chosen/u-boot,version
  fi
  fw_printenv 2>&1 | head -60
} > "$OUT/03-boot.txt" 2>&1
say "3/11 引导与分区"

# ---------------- 4. 内核与模块 ----------------
{
  echo "=============== 内核 ==============="
  uname -a
  echo; echo "=============== lsmod ==============="; lsmod 2>/dev/null || cat /proc/modules 2>&1
  echo; echo "=============== /proc/modules ==============="; cat /proc/modules 2>&1
  echo; echo "=============== /lib/modules/$KREL 结构 ==============="
  find "/lib/modules/$KREL" -maxdepth 2 2>/dev/null | head -300
  echo; echo "=============== 内核内嵌配置 ==============="
  if [ -r /proc/config.gz ]; then
    zcat /proc/config.gz
  elif [ -r "/boot/config-$KREL" ]; then
    cat "/boot/config-$KREL"
  else
    echo "无 /proc/config.gz 也无 /boot/config-$KREL"
    echo "（若内核开了 CONFIG_IKCONFIG_PROC 就会有）"
  fi
  echo; echo "=============== 内核镜像 / DTB ==============="
  ls -la /boot 2>&1
  find / -maxdepth 4 -name '*.dtb' 2>/dev/null | head -40
} > "$OUT/04-kernel.txt" 2>&1
say "4/11 内核与模块"

# ---------------- 5. 显示 ----------------
{
  echo "=============== 显示 ==============="
  echo "--- /sys/class/graphics ---"; ls -la /sys/class/graphics 2>&1
  for d in /sys/class/graphics/fb*; do
    [ -d "$d" ] || continue
    echo; echo "--- $d ---"
    for p in name modes virtual_size bits_per_pixel stride state; do
      [ -r "$d/$p" ] && { printf '%s = ' "$p"; cat "$d/$p"; }
    done
  done
  echo; echo "--- fbset ---";   fbset -i 2>&1
  echo; echo "--- DRM ---";     ls -la /sys/class/drm 2>&1
  for c in /sys/class/drm/card*/card*-*/modes; do
    [ -r "$c" ] && { echo "--- $c ---"; cat "$c"; }
  done
  echo; echo "--- /dev/fb* /dev/dri ---"; ls -la /dev/fb* /dev/dri 2>&1
  echo; echo "--- dmesg 显示相关 ---"
  dmesg 2>/dev/null | grep -iE 'drm|sun4i|tcon|lcd|panel|backlight|pwm|fb0|disp' | head -80
} > "$OUT/05-display.txt" 2>&1
say "5/11 显示"

# ---------------- 6. WiFi ----------------
{
  echo "=============== WiFi ==============="
  echo "--- dmesg ---"
  dmesg 2>/dev/null | grep -iE 'brcmfmac|brcm|bcmdhd|sdio|mmc[0-9]|wlan|cfg80211' | head -120
  echo; echo "--- 接口 ---";  ip link 2>&1 || ifconfig -a 2>&1
  echo; echo "--- iw dev ---";    iw dev 2>&1
  echo; echo "--- iw reg get ---"; iw reg get 2>&1
  echo; echo "--- power_save ---"
  for w in /sys/class/net/*/; do
    n=$(basename "$w")
    [ "$n" = "lo" ] && continue
    echo "--- $n ---"; iw dev "$n" get power_save 2>&1
    cat "$w/address" 2>/dev/null
  done
  echo; echo "--- brcmfmac 模块参数 ---"
  ls -la /sys/module/brcmfmac/parameters/ 2>&1
  for p in /sys/module/brcmfmac/parameters/*; do
    [ -r "$p" ] && { printf '%s = ' "$(basename "$p")"; cat "$p"; echo; }
  done
  echo; echo "--- 固件 ---"; ls -la /lib/firmware/brcm/ 2>&1
  echo; echo "--- wpa_supplicant 配置 ---"
  cat /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null
  echo; echo "--- 承载模式 ---"
  iw list 2>/dev/null | sed -n '/Supported interface modes/,/^$/p'
} > "$OUT/06-wifi.txt" 2>&1
say "6/11 WiFi"

# ---------------- 7. 蓝牙 ----------------
{
  echo "=============== 蓝牙 ==============="
  echo "--- dmesg ---"
  dmesg 2>/dev/null | grep -iE 'bluetooth|hci|btbcm|bcm|rfkill|uart' | head -120
  echo; echo "--- hciconfig -a ---"; hciconfig -a 2>&1
  echo; echo "--- hcitool dev ---";  hcitool dev 2>&1
  echo; echo "--- bluetoothctl ---"; bluetoothctl list 2>&1
  echo; echo "--- rfkill ---";       rfkill list 2>&1
  echo; echo "--- 固件 ---"
  ls -la /lib/firmware/brcm/ 2>&1 | grep -iE 'hcd|bcm'
  find /lib/firmware -iname '*.hcd' 2>/dev/null
  echo; echo "--- 串口占用 ---"
  ls -la /dev/ttyS* /dev/ttyAMA* 2>&1
  echo; echo "--- 协议栈 ---"
  (dpkg -l 2>/dev/null || apk info 2>/dev/null) | grep -iE 'bluez|bluetooth|bsa' 
  echo; echo "--- BSA (原厂协议栈) 是否存在 ---"
  ls -la /usr/bin/bsa_server /usr/lib/libbsa.so 2>&1
} > "$OUT/07-bluetooth.txt" 2>&1
say "7/11 蓝牙"

# ---------------- 8. 音频 ----------------
{
  echo "=============== 音频 ==============="
  echo "--- /proc/asound ---";  cat /proc/asound/cards 2>&1
  echo; echo "--- aplay -l ---";  aplay -l 2>&1
  echo; echo "--- aplay -L ---";  aplay -L 2>&1
  echo; echo "--- amixer ---";    amixer 2>&1 | head -60
  echo; echo "--- dmesg ---"
  dmesg 2>/dev/null | grep -iE 'asoc|snd|i2s|codec|audio|dai|fpga|dma' | head -120
  echo; echo "--- /sys/class/sound ---"; ls -la /sys/class/sound 2>&1
  echo; echo "--- codec 驱动 ---"; ls /sys/bus/platform/drivers/ 2>/dev/null | grep -iE 'snd|asoc|codec|i2s|audio'
} > "$OUT/08-audio.txt" 2>&1
say "8/11 音频"

# ---------------- 9. 固件与模块实际文件 ----------------
say "9/11 拷贝实际文件 (可能较慢)..."
mkdir -p "$OUT/files" 2>/dev/null
cp -a /boot "$OUT/files/boot" 2>/dev/null
if [ -d "/lib/modules/$KREL" ]; then
  mkdir -p "$OUT/files/lib-modules" 2>/dev/null
  cp -a "/lib/modules/$KREL" "$OUT/files/lib-modules/" 2>/dev/null
fi
mkdir -p "$OUT/files/firmware" 2>/dev/null
for d in /lib/firmware/brcm /lib/firmware/ap6212 /lib/firmware/ap6xxx /lib/firmware/bcmdhd; do
  [ -d "$d" ] && cp -a "$d" "$OUT/files/firmware/" 2>/dev/null
done
mkdir -p "$OUT/files/etc" 2>/dev/null
cp -a /etc/fstab /etc/os-release /etc/wpa_supplicant /etc/network /etc/init.d 2>/dev/null "$OUT/files/etc/"
du -sh "$OUT/files" 2>/dev/null

# ---------------- 10. dmesg 全文 ----------------
dmesg 2>/dev/null > "$OUT/10-dmesg-full.txt"
say "10/11 dmesg 全文"

# ---------------- 11. 打包 ----------------
TAR="${OUT}.tar.gz"
DIR=$(dirname "$OUT"); BASE=$(basename "$OUT")
( cd "$DIR" 2>/dev/null && tar czf "$(pwd)/$BASE.tar.gz" "$BASE" 2>/dev/null )
if [ -f "$DIR/$BASE.tar.gz" ]; then
  TAR="$DIR/$BASE.tar.gz"
fi
say "11/11 打包完成"

echo
echo "============================================================"
echo " 收集完成"
echo "   目录 : $OUT"
echo "   压缩包: $TAR"
echo "   大小 : $(du -sh "$OUT" 2>/dev/null | cut -f1)"
echo
echo " 把这个 .tar.gz 交给分析方即可。"
echo " 如果 tar.gz 太大不方便传，可以只给 files/ 目录 + 02/04/05/06/07/08 这几个 txt。"
echo "============================================================"
