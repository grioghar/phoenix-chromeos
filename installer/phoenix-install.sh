#!/bin/bash
# Install the running Brunch ChromeOS (booted from the USB stick) onto the Vostro's internal drive,
# including the legacy-BIOS boot layer that Brunch itself does not create:
#   - GRUB core.img in partition 11 (RWFW, typed BIOS-boot), boot code in the MBR
#   - hybrid MBR: active FAT entry -> EFI partition 12, plus a GPT protective entry
#   - Sandy Bridge fixes on both root partitions (Flex Mesa/crocus + Flex builds of crosvm etc.)
# Run from the VT2 console (Ctrl+Alt+F2, user chronos):  sudo bash vostro-install.sh
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

# --- 1. Brunch's own installer copies the running system
say "Installing ChromeOS with Brunch (several minutes)"
chromeos-install -dst "/dev/$T"
sync; partprobe "/dev/$T" 2>/dev/null || true; sleep 2

# --- 2. BIOS boot layer
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
cp /tmp/vi/se/efi/boot/settings.cfg /tmp/vi/te/efi/boot/settings.cfg
sync; umount /tmp/vi/se /tmp/vi/te

# --- 3. make sure both root partitions carry the Sandy Bridge fixes
say "Checking root partitions"
FILES="usr/lib64/dri usr/share/glvnd usr/share/drirc.d
       usr/bin/crosvm usr/bin/crosh usr/bin/btmanagerd usr/bin/btadapterd usr/bin/btclient usr/bin/resourced
       usr/bin/vhost_user_starter usr/bin/chunneld usr/bin/9s usr/sbin/pdata_tools usr/bin/ippusb_bridge
       opt/google/vms/android/system.raw.img opt/google/vms/android/vendor.raw.img usr/bin/vostro"
FILES="$FILES $(cd / && ls -d usr/lib64/libEGL*.so* usr/lib64/libGLESv2.so* usr/lib64/libGLdispatch.so* usr/lib64/libOpenGL.so* \
                 usr/lib64/libglapi.so* usr/lib64/libdrm*.so* usr/lib64/libminigbm.so* usr/lib64/libgbm.so* usr/lib64/libkvm_movbe.so 2>/dev/null | tr '\n' ' ')"
mkdir -p /tmp/vi/r
for p in 3 5; do
  dev=$(part $T $p)
  mount -o ro "$dev" /tmp/vi/r
  # compare by checksum (ChromeOS has no cmp)
  ok=1; for f in usr/bin/crosvm usr/lib64/dri/crocus_dri.so opt/google/vms/android/system.raw.img opt/google/vms/android/vendor.raw.img; do [ "$(sha256sum < "/$f")" = "$(sha256sum < "/tmp/vi/r/$f" 2>/dev/null)" ] || ok=0; done
  umount /tmp/vi/r
  if [ $ok = 1 ]; then echo "partition $p: already fixed"; continue; fi
  echo "partition $p: copying fixes"
  printf '\000' | dd of="$dev" bs=1 seek=$((0x464 + 3)) conv=notrunc status=none   # allow rw mount
  mount -o rw "$dev" /tmp/vi/r
  rm -f /tmp/vi/r/usr/lib64/libEGL.so* /tmp/vi/r/usr/lib64/libGLESv2.so* /tmp/vi/r/usr/lib64/libglapi.so*
  tar --xattrs --xattrs-include='*' -C / -cf - $FILES | tar --xattrs --xattrs-include='*' -C /tmp/vi/r -xpf -
  sync; umount /tmp/vi/r
done

say "Result"
cgpt show "/dev/$T" | grep -E 'Label|EFI|RWFW|STATE|ROOT' | head -20
echo
echo "Done. Shut down (sudo poweroff), REMOVE the USB stick, then power on."
echo "If the BIOS asks, choose the internal hard drive in the boot menu (F12)."
