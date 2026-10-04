#!/bin/sh
# phoenix fix: bring this machine up to date with Phoenix.
# Android VM (Play Store) on pre-Haswell CPUs / pre-Vulkan GPUs:
#  1. crosvm + libkvm_movbe.so: the VM is told it has MOVBE, and KVM emulates it
#  2. Android system image with BoringSSL's RDRAND calls disabled (Sandy Bridge has no RDRAND)
#  3. Android draws with OpenGL instead of Vulkan (Intel HD 3000 has no Vulkan)
#  4. Phoenix platform layer: platform modules, CPU profile, fan (see: phoenix platform)
#  5. Saves the fixes so they survive ChromeOS updates and Brunch rebuilds (see: phoenix save)
# Safe to run again: parts already installed are skipped.
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
n=0; step(){ n=$((n+1)); echo; echo "[$n] $*"; }
H=HOST:8099
CROSVM_SHA=1c1032c5febe62c6a8b6ecf12c8c756ce950c735b878ba3521bd837c12cfce0f
LIB_SHA=901eb4460ffe152b035be3784cbb2735e3b2bccb4a45dada01475f347a068aec
IMG_SHA=4c8d4b5e79b5947fb16ffa6eb08333d7e5c5c53a6f949ea7f51cd0337bec1ce1
VIMG_SHA=691e3530fd0d9782150fc51a96201dcff7419754c1d9b1f24931ec2a837716d8
IMG=/opt/google/vms/android/system.raw.img
VIMG=/opt/google/vms/android/vendor.raw.img
W=/mnt/stateful_partition/vostro-fix; mkdir -p $W; cd $W
sha(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# Boot menu: load GRUB's PNG module so Brunch's background image works ("bitmap ... unknown format")
step "Boot menu PNG support"
D=$(rootdev -d -s); case "$D" in *[0-9]) E=${D}p12;; *) E=${D}12;; esac
mkdir -p /tmp/vostro-efi
if mount "$E" /tmp/vostro-efi 2>/dev/null; then
  G=/tmp/vostro-efi/efi/grub/grub.cfg
  if [ ! -f $G ]; then echo "  no BIOS boot menu on $E, skipping"
  elif grep -q 'insmod png' $G; then echo "  already done"
  else sed -i 's/^insmod gfxterm$/insmod gfxterm\ninsmod png/' $G; sync; echo "  added (takes effect next boot)"; fi
  umount /tmp/vostro-efi
else echo "  could not mount $E, skipping"; fi

NEED=""
[ "$(sha /usr/bin/crosvm)" = $CROSVM_SHA ] || NEED="$NEED crosvm"
[ "$(sha /usr/lib64/libkvm_movbe.so)" = $LIB_SHA ] || NEED="$NEED lib"
step "Checking what is already installed"
echo "  crosvm: $( [ "$(sha /usr/bin/crosvm)" = $CROSVM_SHA ] && echo ok || echo needs update)"
echo "  MOVBE library: $( [ "$(sha /usr/lib64/libkvm_movbe.so)" = $LIB_SHA ] && echo ok || echo needs update)"
echo "  Android image: checking (a few seconds)..."
[ "$(sha $IMG)" = $IMG_SHA ] || NEED="$NEED img"
[ "$(sha $VIMG)" = $VIMG_SHA ] || NEED="$NEED vimg"
echo "  To do:${NEED:- nothing}"
if [ -n "$NEED" ]; then

step "Downloading"
for p in $NEED; do
  case $p in crosvm) f=crosvm.new; s=$CROSVM_SHA;; lib) f=libkvm_movbe.so; s=$LIB_SHA;; img) f=system.raw.img; s=$IMG_SHA;; vimg) f=vendor.raw.img; s=$VIMG_SHA;; esac
  [ "$(sha $f)" = $s ] && { echo "  $f already downloaded"; continue; }
  echo "Downloading $f..."
  curl -# -o $f http://$H/m/$p
  [ "$(sha $f)" = $s ] && echo "  $f checksum OK" || { echo "Download of $f is damaged; run phoenix fix again."; exit 1; }
done

step "Making the system writable and stopping the VM service"
mount -o remount,rw / || { echo "Could not make the system writable"; exit 1; }
stop vm_concierge 2>/dev/null || true
step "Installing"
for p in $NEED; do
  echo "  installing $p"
  case $p in
    crosvm) [ -e /usr/bin/crosvm.flex ] || cp -a /usr/bin/crosvm /usr/bin/crosvm.flex
            cat crosvm.new > /usr/bin/crosvm ;;        # keeps owner and SELinux label
    lib)    cp libkvm_movbe.so /usr/lib64/libkvm_movbe.so; chmod 755 /usr/lib64/libkvm_movbe.so
            chcon --reference=/usr/lib64/libc.so.6 /usr/lib64/libkvm_movbe.so 2>/dev/null || true ;;
    img)    pv system.raw.img 2>/dev/null > $IMG || cat system.raw.img > $IMG ;;
    vimg)   cat vendor.raw.img > $VIMG ;;
  esac
done
sync
step "Checking crosvm starts"
if ! /usr/bin/crosvm version >/dev/null 2>&1; then
  echo "crosvm failed to start, restoring the previous one"; cat /usr/bin/crosvm.flex > /usr/bin/crosvm
fi
step "Cleaning up"
mount -o remount,ro / 2>/dev/null || true
start vm_concierge 2>/dev/null || true
else
  echo "  Android fixes already up to date."
fi
rm -rf $W

step "Phoenix platform layer (modules, CPU profile, fan)"
curl -s http://$H/p | sh -s apply | sed 's/^/  /' || echo "  (platform layer could not be applied; try: phoenix platform)"

if [ "${VOSTRO_INSTALL:-0}" = 1 ]; then echo; echo "Fixes done. Continuing with the hard-drive install..."; exit 0; fi

VER=$(sed -n 's/^CHROMEOS_RELEASE_VERSION=//p' /etc/lsb-release)
if [ -n "$NEED" ] || [ ! -f /mnt/stateful_partition/unencrypted/phoenix/bundles/$VER.tar ]; then
  step "Saving fixes so they survive updates"
  curl -s http://$H/s | sh | sed 's/^/  /'
fi
echo
[ -n "$NEED" ] && echo "Done. Reboot (sudo reboot), log in, and open the Play Store again." || echo "Done."
