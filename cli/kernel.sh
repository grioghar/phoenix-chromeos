#!/bin/sh
# phoenix kernel [status|install [MARCH]|stock]: use a Phoenix kernel built for this CPU family.
#   status          which kernel runs, which are installed
#   install [MARCH] install and select the optimized kernel (MARCH default: detected, e.g. sandybridge)
#   stock           go back to Brunch's standard kernel (the optimized one stays installed)
# A kernel switch makes Brunch rebuild the system once at the next boot (a few minutes). Phoenix
# saves this machine's fixes first and its hook restores them during that rebuild. The boot menu
# always keeps a "ChromeOS (stock kernel)" entry as a fallback.
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
H=${PHOENIX_SERVER:-HOST:8099}
D=$(rootdev -d -s); case "$D" in *[0-9]) P=${D}p;; *) P=$D;; esac
RC=/tmp/phoenix-rootc EF=/tmp/phoenix-efi S=/mnt/stateful_partition/unencrypted/phoenix
mnt(){ mkdir -p $RC $EF; mountpoint -q $RC || mount ${P}7 $RC; mountpoint -q $EF || mount ${P}12 $EF; }
umnt(){ sync; umount $RC 2>/dev/null || true; umount $EF 2>/dev/null || true; }
trap umnt EXIT
sha(){ sha256sum "$1" | cut -d' ' -f1; }
SET=$EF/efi/boot/settings.cfg
detect_march(){ f=$(grep -m1 '^flags' /proc/cpuinfo)
  case "$(grep -m1 '^vendor_id' /proc/cpuinfo)" in *AMD*) echo ""; return;; esac
  case " $f " in *" avx2 "*) echo haswell;; *" f16c "*) echo ivybridge;; *" avx "*) echo sandybridge;;
                 *" aes "*) echo westmere;; *" sse4_2 "*) echo nehalem;; *) echo "";; esac; }
saved(){ V=$(sed -n 's/^CHROMEOS_RELEASE_VERSION=//p' /etc/lsb-release)
  [ -s $S/bundles/$V.tar ] && [ -s $S/common.tar ] && [ -f $RC/patches/95-phoenix.sh ]; }
fallback_entry(){ G=$EF/efi/boot/grub.cfg
  grep -q 'ChromeOS (stock kernel)' $G && return 0
  awk '/^menuentry "ChromeOS" /{f=1} f{buf=buf $0 "\n"} f&&/^}/{f=0; e=buf}
       END{gsub(/menuentry "ChromeOS" /,"menuentry \"ChromeOS (stock kernel)\" ",e); gsub(/\$kernel/,"/kernel",e); printf "\n%s", e}' $G >> $G; }

case "${1:-status}" in
  status)
    mnt
    echo "Running kernel:  $(uname -r)"
    echo "Selected:        $(sed -n 's/^kernel=//p' $SET)"
    echo "Phoenix kernels: $(cd $RC && ls -d kernel-*-phoenix-* 2>/dev/null | tr '\n' ' ')"
    echo "Recommended for this CPU: $(detect_march || true)"
    ;;
  install)
    M=${2:-$(detect_march)}; [ -n "$M" ] || { echo "No optimized kernel for this CPU yet."; exit 1; }
    L=/tmp/phoenix-kernel.list
    curl -fs -m 20 "http://$H/k/$M.sha256" -o $L || { echo "No Phoenix kernel for $M on the server yet."; exit 1; }
    K=$(awk '/kernel-[0-9.]*-phoenix-/ && !/tar.gz/ {print $2}' $L); T=$(awk '/tar.gz/ {print $2}' $L)
    mnt
    echo "[1] Making sure this machine's fixes are saved (the switch rebuilds the system once)"
    if ! saved; then umnt; t=$(curl -fs "http://$H/s") && sh -c "$t" phoenix-save | sed 's/^/    /'; mnt; fi
    saved || { echo "    Could not save the fixes; not switching kernels."; exit 1; }
    echo "[2] Downloading $K and its modules"
    W=/mnt/stateful_partition/phoenix-kernel; mkdir -p $W
    for f in $K $T; do curl -# -fo $W/$f "http://$H/k/$f"; done
    for f in $K $T; do [ "$(sha $W/$f)" = "$(awk -v f=$f '$2==f{print $1}' $L)" ] || { echo "    $f damaged; nothing changed."; exit 1; }; done
    need=$(( $(du -k $W/$K $W/$T | awk '{s+=$1} END{print s}') + 4096 )); free=$(df -k $RC | awk 'NR==2{print $4}')
    [ $free -gt $need ] || { echo "    Not enough room on ROOT-C (${free} KB free, ${need} KB needed)."; exit 1; }
    echo "[3] Installing into Brunch's ROOT-C and selecting it"
    cp $W/$K $RC/$K; cp $W/$T $RC/packages/$T; rm -rf $W
    sed -i "s|^kernel=.*|kernel=\"/$K\"|" $SET
    fallback_entry
    echo "    selected /$K; boot menu keeps \"ChromeOS (stock kernel)\" as a fallback"
    echo
    echo "Done. Reboot: the first boot rebuilds the system once (a few minutes), then restores your fixes."
    echo "If it does not start, choose \"ChromeOS (stock kernel)\" in the boot menu and run: phoenix kernel stock"
    ;;
  stock)
    mnt; sed -i 's|^kernel=.*|kernel="/kernel"|' $SET
    if ! saved; then umnt; t=$(curl -fs "http://$H/s") && sh -c "$t" phoenix-save | sed 's/^/    /'; mnt; fi
    echo "Brunch's standard kernel selected. Reboot to use it (one system rebuild at boot)."
    ;;
  *) echo "usage: phoenix kernel [status|install [MARCH]|stock]" ;;
esac
