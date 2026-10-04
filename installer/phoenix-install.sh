#!/bin/bash
# Phoenix installer: install the running Brunch ChromeOS (booted from a USB stick) onto an internal
# drive, with what Brunch itself does not do:
#   - hardware detection summary (detect/phoenix-detect.sh)
#   - hostname chosen at install time (applied at every boot by the phoenix-hostname service)
#   - legacy-BIOS boot on BIOS-only machines: GRUB core.img in partition 11 (typed BIOS-boot),
#     boot code in the MBR, hybrid MBR (active FAT entry -> EFI partition 12 + GPT protective entry)
#   - the running system's hardware fixes copied onto both root partitions
# Run from the VT2 console (Ctrl+Alt+F2, user chronos):  sudo bash phoenix-install.sh
set -euo pipefail

FORCE=0; [ "${1:-}" = "--anyway" ] && FORCE=1
die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo; echo "=== $*"; }
# Prompt with line editing (VT2's Backspace otherwise arrives as a literal ^H/^?), then apply any
# leftover backspaces, drop other control characters and squeeze spaces.
ask(){ local __v __o="" __i __c
  read -e -rp "$1" __v || true
  for ((__i=0; __i<${#__v}; __i++)); do __c=${__v:__i:1}
    case "$__c" in $'\b'|$'\177') __o=${__o%?} ;; [[:cntrl:]]) ;; *) __o+=$__c ;; esac
  done
  __o=$(echo "$__o" | tr -s ' ' | sed 's/^ //; s/ $//'); printf -v "$2" '%s' "$__o"; }
[ "$(id -u)" = 0 ] || die "run with sudo"

# Partition device name: sda -> sda3, nvme0n1 -> nvme0n1p3
part(){ case "$1" in *[0-9]) echo "/dev/${1}p$2";; *) echo "/dev/$1$2";; esac; }

# Little-endian byte strings for printf
le(){ local v=$1 n=$2 i out=""; for ((i=0;i<n;i++)); do out+=$(printf '\\x%02x' $(( (v >> (8*i)) & 255 ))); done; printf "$out"; }
poke(){ le "$3" "$4" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none; }   # dev offset value bytes

SRC=$(basename "$(rootdev -d -s)")
say "Booted from: /dev/$SRC"

# --- what is this machine? (detection script: bundled, else from the Phoenix server)
SERVER=${PHOENIX_SERVER:-HOST:8099}
DET=/usr/share/phoenix/detect/phoenix-detect.sh
[ -r $DET ] || { curl -s -m 10 "http://$SERVER/pd" -o /tmp/phoenix-detect.sh && DET=/tmp/phoenix-detect.sh; }
PROFILE=""
if [ -s "$DET" ]; then
  say "This computer"; sh "$DET" --summary | sed 's/^/  /'
  PROFILE=$(sh "$DET")
fi
pget(){ printf '%s\n' "$PROFILE" | sed -n "s/^$1=//p" | head -1; }
FIRMWARE=$(pget firmware); FIRMWARE=${FIRMWARE:-bios}

# --- the running system must already have the Sandy Bridge fixes, or the install inherits the crash
FIXED=1
[ -e /usr/lib64/dri/crocus_dri.so ] || FIXED=0
# Flex crosvm, or Flex crosvm patched to load libkvm_movbe.so (MOVBE for the Android VM)
case "$(sha256sum /usr/bin/crosvm | cut -d' ' -f1)" in
  711b2f0f5c1e226462f97cb6be315859b103af00813319df5fb961137c271cd6) ;;
  1c1032c5febe62c6a8b6ecf12c8c756ce950c735b878ba3521bd837c12cfce0f) ;;
  *) FIXED=0 ;;
esac
if [ $FIXED = 0 ]; then
  echo "This stick does not have the crosvm/Mesa fixes for Sandy Bridge, so Google Play would still fail."
  echo "Flash vostro_rammus150_fix.img to the stick first, boot it, then run this again."
  [ $FORCE = 1 ] || die "stopping (re-run with --anyway to install regardless)"
fi

# --- pick the internal disk: not the boot disk, not removable, not USB
say "Disks"
lsblk -d -o NAME,SIZE,RM,TRAN,MODEL
CANDS=()
while read -r line; do
  eval "$line"   # NAME= RM= TRAN= TYPE=
  [ "$NAME" != "$SRC" ] && [ "$RM" = 0 ] && [ "$TRAN" != usb ] && [ "$TYPE" = disk ] && CANDS+=("$NAME")
done < <(lsblk -dn -P -o NAME,RM,TRAN,TYPE | grep -v 'NAME="zram\|NAME="loop')
[ ${#CANDS[@]} -ge 1 ] || die "no internal disk found"
T=${CANDS[0]}
[ ${#CANDS[@]} -gt 1 ] && { echo "Several internal disks: ${CANDS[*]}"; ask "Which one? " T; }
[ -b "/dev/$T" ] && [ "$T" != "$SRC" ] || die "bad target $T"
echo
echo "Target: /dev/$T  ($(lsblk -dn -o SIZE,MODEL /dev/$T))"
echo "EVERYTHING on /dev/$T will be erased (Windows, files, all partitions)."
for try in 1 2 3; do
  ask "Type ERASE $T to continue (or just press Enter to cancel): " ans
  [ -z "$ans" ] && die "cancelled"
  [ "${ans^^}" = "ERASE ${T^^}" ] && break
  echo "That didn't match \"ERASE $T\" (you typed \"$ans\"). Try again."
  [ $try = 3 ] && die "cancelled"
done

# --- hostname: the name your router shows for this computer
DEFHOST=$(pget machine.model | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' | cut -c1-63)
DEFHOST=${DEFHOST:-phoenix}
while :; do
  ask "Hostname for this computer [$DEFHOST]: " HN
  HN=${HN:-$DEFHOST}
  echo "$HN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' && break
  echo "Use only letters, digits and hyphens (not at the start or end), up to 63 characters."
done
echo "Hostname: $HN"

# --- platform modules (fans, sensors, hotkeys, keyboard backlight...) for this machine
SHR=/tmp/phoenix-share PLCONF=/tmp/phoenix-platform.conf; rm -rf $SHR; mkdir -p $SHR
if curl -s -m 20 "http://$SERVER/share.tgz" -o /tmp/phoenix-share.tgz && tar -xzf /tmp/phoenix-share.tgz -C $SHR 2>/dev/null; then
  plib(){ PHOENIX_SHARE=$SHR CATALOG=$SHR/platform/catalog.conf PLATFORM_CONF=$PLCONF PHX_PROFILE="$PROFILE" \
          sh -c ". $SHR/platform/platform-lib.sh; $1"; }
  plib conf_default > $PLCONF
  while :; do
    say "Platform modules for this computer"
    MODS=$(sed -n 's/^modules="\(.*\)"$/\1/p' $PLCONF)
    for m in $MODS; do printf '  %-16s %s\n' "$m" "$(plib "catalog_field $m 3")"; done
    [ -n "$MODS" ] || echo "  (none needed)"
    echo "  CPU profile: $(sed -n 's/^cpu_profile=//p' $PLCONF)    Fan: $(sed -n 's/^fan_mode=//p' $PLCONF)  (change any time: phoenix platform)"
    ask "Press Enter to use these, or +module / -module to add or remove (? lists all): " PM
    [ -z "$PM" ] && break
    if [ "$PM" = "?" ]; then plib catalog_lines | awk -F'|' '{printf "  %-16s %s\n", $1, $3}'; continue; fi
    for t in $PM; do
      case "$t" in
        +*) MODS="$MODS ${t#+}" ;;
        -*) MODS=$(echo " $MODS " | sed "s/ ${t#-} / /") ;;
      esac
    done
    MODS=$(echo $MODS); sed -i "s/^modules=.*/modules=\"$MODS\"/" $PLCONF
  done
else
  echo "(Phoenix server not reachable: platform modules can be set up later with: phoenix platform)"
  rm -f $PLCONF
fi

# --- performance mode (optional, explained, off unless chosen)
PERF=off
say "Performance mode (optional)"
cat <<'TXT'
  Older processors (roughly 2008-2018) slow down a lot because of the security workarounds that
  protect them against CPU design flaws (Spectre, Meltdown, L1TF, MDS...). Performance mode turns
  those workarounds off, plus some memory hardening and the lockup watchdog
  (boot options: mitigations=off init_on_alloc=0 nowatchdog).

  You gain: a noticeably faster machine, especially web pages and Android apps.
  You give up: protection against those CPU flaws. A malicious web page or app could, in theory,
  read memory belonging to other programs (passwords, keys, other tabs). The risk is real but needs
  a targeted attack; it matters most if you visit untrusted sites or install unknown apps.

  Recommended for machines used with trusted software. You can change it any time:
  phoenix platform perf on|off (applies after a reboot).
TXT
ask "Turn on performance mode? [y/N]: " PA
case "$PA" in y|Y|yes|Yes) PERF=on; echo "Performance mode: ON";; *) echo "Performance mode: off";; esac
[ -f "$PLCONF" ] && { grep -v '^performance_mode=' $PLCONF > $PLCONF.n; echo "performance_mode=\"$PERF\"" >> $PLCONF.n; mv $PLCONF.n $PLCONF; }
# --- throttle override (on by default, pointed out)
THR=on
say "Throttle override (on by default)"
cat <<'TXT'
  Some computers' firmware slows the processor down drastically when the battery has failed or the
  charger is not recognised. A Dell with a dead battery, for example, drops to about 400 MHz (a
  tenth of normal speed). Phoenix undoes that throttling and instead watches the temperature itself:
  if the processor gets hotter than 90 C it lowers the speed step by step, and raises it again as it
  cools. The processor's own overheating protection always stays active. Computers whose firmware
  does not throttle are not affected.

  Turn it OFF if this computer is used with a weaker charger than it came with: the firmware may be
  throttling to avoid overloading that charger, and without it a heavy load could make the computer
  switch off. Change it any time: phoenix platform throttle on|off
TXT
ask "Keep the throttle override on? [Y/n]: " TA
case "$TA" in n|N|no|No) THR=off; echo "Throttle override: off";; *) echo "Throttle override: on";; esac
[ -f "$PLCONF" ] && { grep -v '^throttle_override=' $PLCONF > $PLCONF.n; echo "throttle_override=\"$THR\"" >> $PLCONF.n; mv $PLCONF.n $PLCONF; }

# add/remove the boot options in a Brunch settings.cfg
perf_settings(){ cur=$(sed -n 's/^cmdline_params="\(.*\)"$/\1/p' "$1"); new=""
  for w in $cur; do case "$w" in mitigations=off|init_on_alloc=0|nowatchdog) ;; *) new="$new $w";; esac; done
  [ "$PERF" = on ] && new="$new mitigations=off init_on_alloc=0 nowatchdog"
  new=$(echo $new); sed -i "s|^cmdline_params=.*|cmdline_params=\"$new\"|" "$1"; }

# --- 1. Brunch's own installer copies the running system
say "Installing ChromeOS with Brunch (several minutes)"
chromeos-install -dst "/dev/$T"
sync; partprobe "/dev/$T" 2>/dev/null || true; sleep 2

# --- 2. BIOS boot layer (BIOS-only machines; UEFI machines boot Brunch's EFI loader directly)
if [ "$FIRMWARE" = bios ]; then
say "Adding legacy BIOS boot"
S11=$(cgpt show -i 11 -b "/dev/$SRC"); T11=$(cgpt show -i 11 -b "/dev/$T")
S11N=$(cgpt show -i 11 -s "/dev/$SRC"); T11N=$(cgpt show -i 11 -s "/dev/$T")
T12=$(cgpt show -i 12 -b "/dev/$T"); T12N=$(cgpt show -i 12 -s "/dev/$T")
[ "$T11N" -ge "$S11N" ] || die "target partition 11 smaller than the stick's"
# core.img lives at the start of partition 11 on the stick; copy it (with a progress bar)
dd if="$(part $SRC 11)" of="$(part $T 11)" bs=1M status=progress conv=fsync
# core.img's first sector lists where the rest of it is: re-point it at the target's partition 11
poke "$(part $T 11)" $((0x1f4)) $((T11 + 1)) 8
cgpt add -i 11 -t 21686148-6449-6E6F-744E-656564454649 "/dev/$T"
# MBR boot code from the stick, pointed at the target's core.img, plus hybrid partition table
dd if="/dev/$SRC" of="/dev/$T" bs=440 count=1 conv=notrunc status=none
poke "/dev/$T" $((0x5c)) "$T11" 8
{ printf '\x80\xfe\xff\xff\x0c\xfe\xff\xff'; le "$T12" 4; le "$T12N" 4
  printf '\x00\xfe\xff\xff\xee\xfe\xff\xff'; le 1 4; le $((T12 - 1)) 4
  head -c 32 /dev/zero; printf '\x55\xaa'; } | dd of="/dev/$T" bs=1 seek=446 conv=notrunc status=none

# GRUB files + touchpad/boot settings in the EFI partition
mkdir -p /tmp/vi/se /tmp/vi/te
mount -o ro "$(part $SRC 12)" /tmp/vi/se; mount "$(part $T 12)" /tmp/vi/te
cp -a /tmp/vi/se/efi/grub /tmp/vi/te/efi/
# PNG support for Brunch's boot background (fixes "bitmap ... unknown format")
grep -q 'insmod png' /tmp/vi/te/efi/grub/grub.cfg || sed -i 's/^insmod gfxterm$/insmod gfxterm\ninsmod png/' /tmp/vi/te/efi/grub/grub.cfg
cp /tmp/vi/se/efi/boot/settings.cfg /tmp/vi/te/efi/boot/settings.cfg; perf_settings /tmp/vi/te/efi/boot/settings.cfg
sync; umount /tmp/vi/se /tmp/vi/te
else
  echo "UEFI firmware: using Brunch's EFI boot (no BIOS layer needed)"
  mkdir -p /tmp/vi/se /tmp/vi/te
  mount -o ro "$(part $SRC 12)" /tmp/vi/se; mount "$(part $T 12)" /tmp/vi/te
  cp /tmp/vi/se/efi/boot/settings.cfg /tmp/vi/te/efi/boot/settings.cfg; perf_settings /tmp/vi/te/efi/boot/settings.cfg
  sync; umount /tmp/vi/se /tmp/vi/te
fi

# --- 3. make sure both root partitions carry the Sandy Bridge fixes
say "Checking root partitions"
FILES="usr/lib64/dri usr/share/glvnd usr/share/drirc.d
       usr/bin/crosvm usr/bin/crosh usr/bin/btmanagerd usr/bin/btadapterd usr/bin/btclient usr/bin/resourced
       usr/bin/vhost_user_starter usr/bin/chunneld usr/bin/9s usr/sbin/pdata_tools usr/bin/ippusb_bridge
       opt/google/vms/android/system.raw.img opt/google/vms/android/vendor.raw.img"
FILES="$FILES $(cd / && ls -d usr/lib64/libEGL*.so* usr/lib64/libGLESv2.so* usr/lib64/libGLdispatch.so* usr/lib64/libOpenGL.so* \
                 usr/lib64/libglapi.so* usr/lib64/libdrm*.so* usr/lib64/libminigbm.so* usr/lib64/libgbm.so* usr/lib64/libkvm_movbe.so 2>/dev/null | tr '\n' ' ')"
mkdir -p /tmp/vi/r
for p in 3 5; do
  dev=$(part $T $p)
  mount -o ro "$dev" /tmp/vi/r
  # compare by checksum (ChromeOS has no cmp)
  ok=1; for f in usr/bin/crosvm usr/lib64/dri/crocus_dri.so opt/google/vms/android/system.raw.img opt/google/vms/android/vendor.raw.img; do [ "$(sha256sum < "/$f")" = "$(sha256sum < "/tmp/vi/r/$f" 2>/dev/null)" ] || ok=0; done
  umount /tmp/vi/r
  printf '\000' | dd of="$dev" bs=1 seek=$((0x464 + 3)) conv=notrunc status=none   # allow rw mount
  mount -o rw "$dev" /tmp/vi/r
  if [ $ok = 1 ]; then echo "partition $p: fixes already present"
  else
    echo "partition $p: copying fixes"
    rm -f /tmp/vi/r/usr/lib64/libEGL.so* /tmp/vi/r/usr/lib64/libGLESv2.so* /tmp/vi/r/usr/lib64/libglapi.so*
    tar --xattrs --xattrs-include='*' -C / -cf - $FILES | tar --xattrs --xattrs-include='*' -C /tmp/vi/r -xpf -
  fi
  # Phoenix layer: hostname, detection, platform modules, services, the phoenix command
  mkdir -p /tmp/vi/r/etc/phoenix /tmp/vi/r/usr/share/phoenix/detect
  echo "$HN" > /tmp/vi/r/etc/phoenix/hostname
  printf '%s\n' "$PROFILE" > /tmp/vi/r/etc/phoenix/profile.install
  [ -f "$PLCONF" ] && cp "$PLCONF" /tmp/vi/r/etc/phoenix/platform.conf
  if [ -d $SHR/platform ]; then cp -r $SHR/. /tmp/vi/r/usr/share/phoenix/
  elif [ -s "$DET" ]; then cp "$DET" /tmp/vi/r/usr/share/phoenix/detect/phoenix-detect.sh; fi
  LBL=$(getfattr --only-values -n security.selinux /tmp/vi/r/etc/init/shill.conf 2>/dev/null)
  for svc in /tmp/vi/r/usr/share/phoenix/services/phoenix-*.conf; do
    [ -f "$svc" ] || continue
    cp "$svc" /tmp/vi/r/etc/init/; setfattr -n security.selinux -v "$LBL" "/tmp/vi/r/etc/init/$(basename "$svc")" 2>/dev/null || true
  done
  [ -f /tmp/vi/r/etc/init/phoenix-hostname.conf ] || echo "  (hostname service missing; set it later with: phoenix hostname $HN)"
  if [ -x /usr/bin/phoenix ]; then cp /usr/bin/phoenix /tmp/vi/r/usr/bin/phoenix; ln -sfn phoenix /tmp/vi/r/usr/bin/vostro
  elif [ -x /usr/bin/vostro ]; then cp /usr/bin/vostro /tmp/vi/r/usr/bin/vostro; fi
  sync; umount /tmp/vi/r
done

say "Result"
cgpt show "/dev/$T" | grep -E 'Label|EFI|RWFW|STATE|ROOT' | head -20
echo
echo "Hostname: $HN    Performance mode: $PERF    Throttle override: $THR"
echo "Done. Shut down (sudo poweroff), REMOVE the USB stick, then power on."
echo "If the BIOS asks, choose the internal hard drive in the boot menu (F12)."
