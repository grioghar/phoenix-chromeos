#!/bin/bash
# Build a platform-optimized Brunch kernel for one CPU family.
#
#   build-kernel.sh <brunch fork checkout> <march> <out dir> [--lean modules.list] [--jobs N]
#
#   march   gcc -march value: sandybridge ivybridge haswell broadwell skylake nehalem westmere
#           btver2 (AMD Jaguar) bdver2..4 (Bulldozer family) znver1..3, or x86-64-v2/v3
#   --lean  build only the modules listed (lsmod names from the target machine, e.g. from a
#           `phoenix submit` report) plus a safety set (USB storage/HID, common network, filesystems)
#
# Same sources, patches and config as Brunch's generic kernel (via the fork's prepare_kernels.sh),
# then:
#   - compiled for <march> (KCFLAGS), so the kernel uses the CPU's instructions and scheduling model
#   - CONFIG_LOCALVERSION=-phoenix-<march>: own modules directory; the stock kernel stays a fallback
#   - performance defaults that can be switched back at boot: init_on_alloc off
#     (re-enable with init_on_alloc=1)
# Output: <out>/kernel-<kver>-phoenix-<march> (bzImage) and kernel-<uname>.tar.gz (modules + headers),
# the same layout as Brunch's ROOT-C kernels/packages.
# Runs in an ubuntu:24.04 container (gcc 12, as Brunch's kernels are built).
set -euo pipefail
FORK=$(cd "$1" && pwd) MARCH=$2 OUT=$(mkdir -p "$3" && cd "$3" && pwd); shift 3
LEAN="" JOBS=$(( $(free -m | awk '/^Mem/{print $2}') / 1500 ))   # ~1.5 GB of RAM per gcc job on this tree
[ $JOBS -gt $(nproc) ] && JOBS=$(nproc); [ $JOBS -lt 1 ] && JOBS=1
while [ $# -gt 0 ]; do case $1 in --lean) LEAN=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2;; --jobs) JOBS=$2; shift 2;; *) shift;; esac; done
KV=6.12
W=${PHOENIX_KBUILD:-/root/phoenix-kbuild}
mkdir -p "$W"
log(){ echo "[$(date +%H:%M:%S)] $*"; }

if [ ! -d "$W/src/kernels/$KV" ]; then
  log "Preparing Brunch $KV sources (download + Brunch patches + config)"
  rm -rf "$W/src"; mkdir -p "$W/src"
  cp -r "$FORK/kernel-patches" "$FORK/prepare_kernels.sh" "$W/src/"
  sed -i "s/^kernels=.*/kernels=\"$KV\"/" "$W/src/prepare_kernels.sh"
  docker run --rm -v "$W/src:/k" -w /k ubuntu:24.04 bash -c "
    apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcc-12 make bc bison flex libelf-dev libssl-dev git curl patch cpio kmod python3 rsync >/dev/null 2>&1
    ln -sf /usr/bin/gcc-12 /usr/bin/gcc; bash prepare_kernels.sh" | grep -E 'kernel_version|failed|Creating' || true
  [ -f "$W/src/kernels/$KV/arch/x86/configs/chromeos_defconfig" ] || { echo "kernel preparation failed"; exit 1; }
fi

T="$W/build-$MARCH${LEAN:+-lean}"
log "Copying sources to $T"
rm -rf "$T"; cp -a "$W/src/kernels/$KV" "$T"
CFG="$T/arch/x86/configs/chromeos_defconfig"
sed -i '/^CONFIG_LOCALVERSION=/d; /CONFIG_INIT_ON_ALLOC_DEFAULT_ON/d' "$CFG"
cat >> "$CFG" <<EOF
CONFIG_LOCALVERSION="-phoenix-$MARCH"
# CONFIG_INIT_ON_ALLOC_DEFAULT_ON is not set
EOF
[ -n "$LEAN" ] && cp "$LEAN" "$T/lean-modules.list"

log "Building for -march=$MARCH with $JOBS jobs (this takes hours on small machines)"
docker run --rm -v "$T:/k" -v "$OUT:/out" -w /k ubuntu:24.04 bash -c "
  set -e
  apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcc-12 make bc bison flex libelf-dev libssl-dev cpio kmod python3 >/dev/null 2>&1
  ln -sf /usr/bin/gcc-12 /usr/bin/gcc
  make O=out chromeos_defconfig >/dev/null
  if [ -f lean-modules.list ]; then
    # keep the target's modules + a safety set, then let localmodconfig drop the rest
    { cat lean-modules.list; printf '%s\n' usb_storage uas usbhid hid_generic hid_multitouch xhci_pci ehci_pci r8169 e1000e cdc_ether rndis_host ax88179_178a exfat vfat ntfs3 fuse loop zram; } \
      | awk '{print \$1\" 0 0\"}' > /tmp/lsmod
    make O=out LSMOD=/tmp/lsmod localmodconfig </dev/null >/dev/null
  fi
  KCONFIG_NOTIMESTAMP=1 KBUILD_BUILD_TIMESTAMP='' KBUILD_BUILD_USER=chronos KBUILD_BUILD_HOST=localhost \
    make O=out -j$JOBS KCFLAGS='-march=$MARCH -mtune=$MARCH' 2>&1 | grep -E '^(  LD +vmlinux|Kernel: |.*error:)' || true
  test -f out/arch/x86/boot/bzImage
  REL=\$(cat out/include/config/kernel.release)
  rm -rf /tmp/pkg; make O=out INSTALL_MOD_PATH=/tmp/pkg INSTALL_MOD_STRIP=1 modules_install >/dev/null
  rm -f /tmp/pkg/lib/modules/\$REL/build /tmp/pkg/lib/modules/\$REL/source
  cp out/arch/x86/boot/bzImage /out/kernel-$KV-phoenix-$MARCH
  tar -C /tmp/pkg -czf /out/kernel-\$REL.tar.gz lib
  echo built \$REL
"
ls -la "$OUT"
log "done"
