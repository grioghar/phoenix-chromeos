#!/bin/bash
# Build a Brunch ChromeOS image for a legacy-BIOS Sandy Bridge PC (Dell Vostro 3550):
#   1. Brunch install of an official recovery image (e.g. rammus) with Play Store
#   2. Transplant ChromeOS Flex (reven) Mesa stack of the SAME version -> crocus for Gen6 GPUs
#   3. BIOS GRUB layer (core.img in RWFW partition, boot.img in MBR) chaining Brunch's grub.cfg
#   4. Hybrid MBR with an active FAT entry so old Dell/Phoenix BIOSes accept the disk
# Runs inside a privileged Ubuntu 22.04 container:
#   docker run --rm --privileged -v /dev:/dev -v $PWD:/work -w /work ubuntu:22.04 \
#     bash make_vostro_image.sh <brunch_dir> <recovery.bin> <flex_recovery.bin> <out.img>
set -euo pipefail
BRUNCH=$1 RECOVERY=$2 FLEX=$3 OUT=$4

step(){ echo; echo "### $*"; }

step "Installing tools"
apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cgpt pv unzip tar fdisk gdisk e2fsprogs kmod \
  grub-pc-bin grub2-common python3 >/dev/null

step "Brunch install ($RECOVERY)"
rm -f "$OUT"
# The installer's exit status is unreliable; judge success by its final message and the image.
(cd "$BRUNCH" && yes | bash chromeos-install.sh -l -s 24 -src "$RECOVERY" -dst "$OUT" >/tmp/brunch.log 2>&1) || true
grep -q "you can reboot your computer and start ChromeOS" /tmp/brunch.log && [ -s "$OUT" ] \
  || { tail -30 /tmp/brunch.log; exit 1; }

LOOP=$(losetup -f --show -P "$OUT")
FLOOP=$(losetup -f --show -P -r "$FLEX")
cleanup(){ umount /mnt/a /mnt/f /mnt/e 2>/dev/null || true; losetup -d "$LOOP" "$FLOOP" 2>/dev/null || true; }
trap cleanup EXIT
sleep 1
mkdir -p /mnt/a /mnt/f /mnt/e
mount -o ro "${FLOOP}p3" /mnt/f

FILES="usr/lib64/dri usr/share/glvnd usr/share/drirc.d"
for g in 'libEGL.so*' 'libEGL_mesa.so*' 'libGLESv2.so*' 'libGLdispatch.so*' 'libOpenGL.so*' \
         'libglapi.so*' 'libdrm*.so*' 'libminigbm.so*' 'libgbm.so*'; do
  for f in /mnt/f/usr/lib64/$g; do [ -e "$f" ] || [ -L "$f" ] && FILES="$FILES usr/lib64/$(basename "$f")"; done
done

BINS="usr/bin/crosvm usr/bin/crosh usr/bin/btmanagerd usr/bin/btadapterd usr/bin/btclient usr/bin/resourced
      usr/bin/vhost_user_starter usr/bin/chunneld usr/bin/9s usr/sbin/pdata_tools usr/bin/ippusb_bridge"

for part in 3 5; do   # ROOT-A and ROOT-B
  dev="${LOOP}p$part"
  blkid "$dev" | grep -q ext2 || { echo "p$part: no filesystem, skipping"; continue; }
  step "Transplanting Flex graphics stack into p$part"
  # ChromeOS marks its rootfs with unknown ro_compat bits to block rw mounts; clear them.
  printf '\000' | dd of="$dev" bs=1 seek=$((0x464 + 3)) conv=notrunc status=none
  mount -o rw "$dev" /mnt/a
  rm -f /mnt/a/usr/lib64/libEGL.so* /mnt/a/usr/lib64/libGLESv2.so* /mnt/a/usr/lib64/libglapi.so*
  # libgallium_dri.so was only used by the old libEGL; drop it if nothing else needs it (frees 22 MB).
  if ! grep -rl libgallium_dri.so /mnt/a/usr/lib64 /mnt/a/usr/bin /mnt/a/usr/sbin 2>/dev/null | grep -qv '/libgallium_dri.so$'; then
    rm -f /mnt/a/usr/lib64/libgallium_dri.so
  fi
  tar --xattrs --xattrs-include='*' -C /mnt/f -cf - $FILES | tar --xattrs --xattrs-include='*' -C /mnt/a -xpf -
  # rammus builds these Rust programs for Amber Lake (MOVBE etc.); they SIGILL on Sandy Bridge.
  # Flex builds of the same release target older CPUs. crosvm is the Android VM host.
  tar --xattrs --xattrs-include='*' -C /mnt/f -cf - $BINS | tar --xattrs --xattrs-include='*' -C /mnt/a -xpf -
  ls -l /mnt/a/usr/lib64/dri | head -3; df -h /mnt/a | tail -1
  umount /mnt/a
done

step "BIOS GRUB layer"
EFI_START=$(sgdisk -i 12 "$LOOP" | awk '/First sector/ {print $3}')
EFI_LAST=$(sgdisk -i 12 "$LOOP" | awk '/Last sector/ {print $3}')
CORE_LBA=$(sgdisk -i 11 "$LOOP" | awk '/First sector/ {print $3}')
sgdisk -t 11:EF02 "$LOOP" >/dev/null
mount "${LOOP}p12" /mnt/e
mkdir -p /mnt/e/efi/grub/i386-pc
cp /usr/lib/grub/i386-pc/*.mod /usr/lib/grub/i386-pc/*.lst /mnt/e/efi/grub/i386-pc/
cat > /mnt/e/efi/grub/grub.cfg <<'EOF'
search --no-floppy --set=root --file /efi/boot/grub.cfg
insmod all_video
insmod gfxterm
configfile /efi/boot/grub.cfg
EOF
cat > /tmp/early.cfg <<'EOF'
search --no-floppy --set=root --file /efi/grub/grub.cfg
set prefix=($root)/efi/grub
EOF
grub-mkimage -O i386-pc -o /tmp/core.img -c /tmp/early.cfg -p /efi/grub \
  biosdisk part_gpt part_msdos fat ext2 search search_fs_file configfile normal linux echo test regexp
# Vostro 3550 touchpad needs ExplorerPS/2 mode; verbose boot log while we are still testing.
# (cmdline_params, unlike options=, does not trigger a Brunch rootfs rebuild.)
sed -i 's/^cmdline_params=.*/cmdline_params="i8042.nomux=1 i8042.reset=1 psmouse.proto=exps"/; s/^verbose=0/verbose=1/' \
  /mnt/e/efi/boot/settings.cfg
umount /mnt/e

step "Writing boot code and hybrid MBR"
python3 - "$OUT" "$CORE_LBA" "$EFI_START" "$EFI_LAST" <<'PY'
import struct, sys
img, core_lba, efi_start, efi_last = sys.argv[1], *map(int, sys.argv[2:])
core = bytearray(open("/tmp/core.img", "rb").read())
n = (len(core) + 511) // 512
core += b"\0" * (n * 512 - len(core))
assert n * 512 <= 8 * 1024 * 1024
struct.pack_into("<QHH", core, 0x1f4, core_lba + 1, n - 1, 0x820)   # diskboot blocklist
boot = bytearray(open("/usr/lib/grub/i386-pc/boot.img", "rb").read())
struct.pack_into("<Q", boot, 0x5c, core_lba)                         # where core.img lives
def ent(flag, typ, start, count):
    chs = b"\xfe\xff\xff"
    return bytes([flag]) + chs + bytes([typ]) + chs + struct.pack("<II", start, count)
with open(img, "r+b") as f:
    mbr = bytearray(f.read(512))
    mbr[0:440] = boot[0:440]
    mbr[446:510] = (ent(0x80, 0x0C, efi_start, efi_last - efi_start + 1)   # active FAT entry -> EFI partition
                    + ent(0x00, 0xEE, 1, efi_start - 1) + b"\0" * 32)        # GPT protective entry
    mbr[510:512] = b"\x55\xaa"
    f.seek(0); f.write(mbr)
    f.seek(core_lba * 512); f.write(core)
print(f"core.img: {n} sectors at LBA {core_lba}; EFI partition {efi_start}-{efi_last}")
PY
sgdisk -v "$LOOP" | tail -2
for part in 3 5; do e2fsck -fn "${LOOP}p$part" >/dev/null 2>&1 && echo "p$part fsck clean" || echo "p$part fsck: check output"; done
step "Done: $OUT"
