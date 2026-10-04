#!/bin/bash
# Patch a ChromeOS ARCVM Android image pair so it runs on older x86 CPUs/GPUs.
#
#   patch-android.sh <system.raw.img> <vendor.raw.img> <outdir> [--no-rdrand] [--no-vulkan]
#
# - RDRAND: BoringSSL's CRYPTO_rdrand in system/lib64/libcrypto.so executes RDRAND without a
#   CPUID check (the ARC build targets Goldmont). Each RDRAND becomes `clc; nop...` ("no hardware
#   randomness"), so BoringSSL falls back to getrandom(). The FIPS module's text hash is then
#   recomputed by running boringssl_self_test64 under qemu and taking its "Calculated:" value.
# - Vulkan: hosts without a Vulkan driver (e.g. Intel Gen4-7) make every HWUI app abort in
#   VulkanManager::setupDevice. Set ro.hwui.use_vulkan=false and stop advertising Vulkan.
#
# Images are rebuilt with mkfs.erofs from an overlay, keeping owners, modes and SELinux labels;
# the result is verified against the original (only the intended files may differ).
# Needs: root, overlayfs, erofs-utils (mkfs.erofs), binutils (objdump), qemu-user-static, python3.
set -euo pipefail
SYS=$1 VEN=$2 OUT=$3; shift 3
DO_RDRAND=1 DO_VULKAN=1
for a in "$@"; do case $a in --no-rdrand) DO_RDRAND=0;; --no-vulkan) DO_VULKAN=0;; esac; done
COMP=$(sed -n 's/^mkfs.erofs //p' "$(dirname "$SYS")/image_compression_flags" 2>/dev/null || true)
COMP=${COMP:--z lz4hc -C32768}
W=$(mktemp -d "${TMPDIR:-/tmp}/phoenix-android.XXXX")   # must not be on overlayfs
cleanup(){ for m in $W/ns $W/nv $W/s/m $W/v/m $W/as $W/av; do umount -l $m 2>/dev/null || true; done; }
trap cleanup EXIT
step(){ echo; echo "### $*"; }

mkdir -p $W/as $W/av $W/ns $W/nv $W/s/{u,w,m} $W/v/{u,w,m} "$OUT"
mount -o ro,loop "$SYS" $W/as; mount -o ro,loop "$VEN" $W/av

# Overlay whose upper dir root carries the original root's owner/mode/label (else they are lost)
overlay(){ local low=$1 d=$2
  setfattr -n security.selinux -v "$(getfattr --only-values -n security.selinux $low)" $d/u
  chown --reference=$low $d/u; chmod --reference=$low $d/u; touch --reference=$low $d/u
  mount -t overlay overlay -o lowerdir=$low,upperdir=$d/u,workdir=$d/w $d/m; }
overlay $W/as $W/s; overlay $W/av $W/v
# Editing through an overlay replaces files and drops their labels: put them back
relabel(){ setfattr -n security.selinux -v "$(getfattr --only-values -n security.selinux $1/$3)" $2/$3; }

if [ $DO_RDRAND = 1 ]; then
  step "RDRAND -> clc in system/lib64/libcrypto.so"
  L=system/lib64/libcrypto.so
  python3 - $W/s/m/$L <<'EOF'
import re, subprocess, sys
p = sys.argv[1]; d = bytearray(open(p, "rb").read())
# map virtual addresses to file offsets through the program headers
segs = []
for l in subprocess.run(["readelf", "-lW", p], capture_output=True, text=True).stdout.splitlines():
    f = l.split()
    if f and f[0] == "LOAD": segs.append((int(f[1], 16), int(f[2], 16), int(f[4], 16)))
def off(va):
    for o, v, sz in segs:
        if v <= va < v + sz: return va - v + o
    raise SystemExit("address outside LOAD segments: %x" % va)
n = 0
for l in subprocess.run(["objdump", "-d", p], capture_output=True, text=True).stdout.splitlines():
    m = re.match(r"\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} )+)\s*(rdrand|rdseed)\s", l)
    if m:
        o = off(int(m.group(1), 16)); b = bytes.fromhex(m.group(2).replace(" ", ""))
        assert d[o:o+len(b)] == b
        d[o:o+len(b)] = b"\xf8" + b"\x90" * (len(b) - 1); n += 1
open(p, "wb").write(d); print("patched %d instruction(s)" % n)
EOF
  relabel $W/as $W/s/m $L
  step "Recomputing the BoringSSL FIPS module hash"
  Q=$(command -v qemu-x86_64-static || command -v qemu-x86_64)
  R=$W/root; mkdir -p $R; mount -t overlay overlay -o lowerdir=$W/s/m,upperdir=$(mktemp -d -p $W),workdir=$(mktemp -d -p $W) $R
  for a in $W/as/system/apex/*; do n=$(basename $a); n=${n%_arc}; mkdir -p $R/apex/$n; mount --bind $a $R/apex/$n; done
  mount -t proc proc $R/proc; mount --bind /dev $R/dev; cp "$Q" $R/qemu
  # SandyBridge+movbe = the oldest CPU we support with the MOVBE shim (no RDRAND, no AVX2)
  OUTP=$(chroot $R /qemu -cpu SandyBridge,+movbe /system/bin/boringssl_self_test64 2>&1 || true)
  EXP=$(sed -n 's/^Expected: *//p' <<<"$OUTP"); CALC=$(sed -n 's/^Calculated: *//p' <<<"$OUTP")
  if [ -n "$EXP" ] && [ -n "$CALC" ]; then
    python3 - $W/s/m/$L $EXP $CALC <<'EOF'
import sys
p, a, b = sys.argv[1], bytes.fromhex(sys.argv[2]), bytes.fromhex(sys.argv[3]); d = open(p, "rb").read()
assert d.count(a) == 1, "expected hash not found exactly once"; open(p, "wb").write(d.replace(a, b)); print("hash updated")
EOF
    relabel $W/as $W/s/m $L
  fi
  chroot $R /qemu -cpu SandyBridge,+movbe /system/bin/boringssl_self_test64 >/dev/null 2>&1 \
    && echo "boringssl_self_test64 passes on SandyBridge+movbe" || { echo "self-test still fails"; exit 1; }
  for m in $R/apex/* $R/proc $R/dev $R; do umount -l $m 2>/dev/null || true; done
fi

if [ $DO_VULKAN = 1 ]; then
  step "Android renderer: OpenGL instead of Vulkan"
  sed -i 's/^ro.hwui.use_vulkan=true$/ro.hwui.use_vulkan=false/' $W/s/m/system/build.prop; relabel $W/as $W/s/m system/build.prop
  rm -f $W/v/m/etc/permissions/android.hardware.vulkan.*.xml $W/v/m/etc/permissions/android.software.vulkan.deqp.level.xml
  sed -i 's/^    setprop ro.hardware.vulkan/    # disabled by Phoenix (no host Vulkan): setprop ro.hardware.vulkan/' $W/v/m/etc/init/vulkan.rc
  relabel $W/av $W/v/m etc/init/vulkan.rc
fi

step "Building images ($COMP)"
mkfs.erofs --quiet $COMP "$OUT/system.raw.img" $W/s/m
mkfs.erofs --quiet $COMP "$OUT/vendor.raw.img" $W/v/m

step "Verifying"
mount -o ro,loop "$OUT/system.raw.img" $W/ns; mount -o ro,loop "$OUT/vendor.raw.img" $W/nv
meta(){ (cd $1; find . -printf "%p %U %G %m %l\n" | sort; getfattr -R -d -m - --absolute-names . 2>/dev/null); }
for p in "as ns system" "av nv vendor"; do set -- $p
  echo "$3 metadata differences (vulkan permission files are expected):"
  diff <(meta $W/$1) <(meta $W/$2) | grep '^[<>]' | grep -v vulkan || echo "  none"
  echo "$3 changed files:"; diff -rq --no-dereference $W/$1 $W/$2 | sed 's/^/  /' || true
done
sha256sum "$OUT"/*.raw.img
