#!/bin/bash
# Simulate the internal-disk install: Brunch layout on a blank 60 GB disk, then the installer's BIOS step.
set -euo pipefail
cd /work
apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cgpt gdisk e2fsprogs dosfstools pv unzip tar fdisk kmod >/dev/null
rm -f target.img
(cd r150 && yes | bash chromeos-install.sh -l -src /work/chromeos_16700.65.0_rammus_recovery_ltc-channel_RammusMPKeys-v10.bin -dst /work/target.img -s 60 >/tmp/t.log 2>&1) || true
grep -q "you can reboot" /tmp/t.log || { tail /tmp/t.log; exit 1; }
SL=$(losetup -f --show -P vostro_rammus150_fix.img); TL=$(losetup -f --show -P target.img); sleep 1
SRC=$(basename $SL); T=$(basename $TL)
echo "fixed image crosvm: $(mkdir -p /mnt/x; mount -o ro ${SL}p3 /mnt/x; sha256sum /mnt/x/usr/bin/crosvm | cut -c1-16; ls /mnt/x/usr/lib64/dri/crocus_dri.so; umount /mnt/x)"
part(){ case "$1" in *[0-9]) echo "/dev/${1}p$2";; *) echo "/dev/$1$2";; esac; }
le(){ local v=$1 n=$2 i out=""; for ((i=0;i<n;i++)); do out+=$(printf '\\x%02x' $(( (v >> (8*i)) & 255 ))); done; printf "$out"; }
poke(){ le "$3" "$4" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none; }
die(){ echo "ERROR: $*"; exit 1; }
say(){ echo "=== $*"; }
# step 2 verbatim from the installer
sed -n '/^# --- 2\./,/^# --- 3\./p' vostro-install.sh > /tmp/step2.sh
source /tmp/step2.sh
echo "target p11=$T11 p12=$T12+$T12N"; xxd -s 446 -l 66 /dev/$T; xxd -s 0x5c -l 8 /dev/$T
cgpt show -i 11 -t /dev/$T
losetup -d $SL $TL
