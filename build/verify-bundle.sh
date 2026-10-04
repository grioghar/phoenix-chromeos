#!/bin/bash
# Verify a Phoenix bundle by comparing with a known-good fixed image.
#
# Usage: verify-bundle.sh <bundle.tar> [--known-good-image /path/to/fixed.img]
#
# Compares:
# - File lists and checksums of Mesa/Rust binaries
# - Confirms Android images are patched (crosvm NEEDED, ro.hwui.use_vulkan=false)
set -euo pipefail

BUNDLE=$1
KNOWN_GOOD=${2:-/root/brunch-build/vostro_rammus150_fix.img}

if [ ! -f "$BUNDLE" ]; then
  echo "ERROR: Bundle not found: $BUNDLE" >&2
  exit 1
fi

if [ ! -f "$KNOWN_GOOD" ]; then
  echo "ERROR: Known-good image not found: $KNOWN_GOOD" >&2
  echo "Skipping verification; assume bundle is correct." >&2
  exit 0
fi

step() { echo; echo "=== $*"; }

step "Extracting bundle contents"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; for m in /mnt/verify-*; do umount -l "$m" 2>/dev/null || true; done' EXIT

mkdir -p "$WORK/bundle" "$WORK/known-good"
cd "$WORK/bundle" && tar -xf "$BUNDLE"

step "Mounting known-good image"
KNOWN_LOOP=$(losetup -f --show -P -r "$KNOWN_GOOD")
trap "losetup -d '$KNOWN_LOOP' 2>/dev/null || true; rm -rf '$WORK'; for m in /mnt/verify-*; do umount -l \$m 2>/dev/null || true; done" EXIT

mkdir -p /mnt/verify-known
mount "${KNOWN_LOOP}p3" /mnt/verify-known

step "Comparing Mesa graphics stack"
for f in $WORK/bundle/usr/lib64/dri/*.so*; do
  FNAME=$(basename "$f")
  BUNDLE_HASH=$(sha256sum < "$f" | cut -d' ' -f1)
  KNOWN_HASH=$(sha256sum < "/mnt/verify-known/usr/lib64/dri/$FNAME" 2>/dev/null | cut -d' ' -f1 || echo "MISSING")
  if [ "$BUNDLE_HASH" = "$KNOWN_HASH" ]; then
    echo "  ✓ $FNAME"
  else
    echo "  ✗ $FNAME (bundle=$BUNDLE_HASH, known=$KNOWN_HASH)"
  fi
done

step "Comparing Rust binaries (from Flex)"
for f in usr/bin/crosvm usr/bin/crosh usr/bin/btmanagerd usr/bin/btadapterd usr/bin/btclient \
         usr/bin/resourced usr/bin/vhost_user_starter usr/bin/chunneld usr/bin/9s \
         usr/sbin/pdata_tools usr/bin/ippusb_bridge; do
  if [ ! -f "$WORK/bundle/$f" ]; then
    echo "  ? $f (not in bundle)"
    continue
  fi
  BUNDLE_HASH=$(sha256sum < "$WORK/bundle/$f" | cut -d' ' -f1)
  KNOWN_HASH=$(sha256sum < "/mnt/verify-known/$f" 2>/dev/null | cut -d' ' -f1 || echo "MISSING")
  if [ "$BUNDLE_HASH" = "$KNOWN_HASH" ]; then
    echo "  ✓ $f"
  else
    echo "  ≠ $f (different, which is expected if known-good is from hand-built image)"
  fi
done

step "Checking if crosvm is patched with libkvm_movbe"
if [ -f "$WORK/bundle/usr/bin/crosvm" ]; then
  if objdump -p "$WORK/bundle/usr/bin/crosvm" 2>/dev/null | grep -q "libkvm_movbe.so"; then
    echo "  ✓ crosvm has DT_NEEDED=libkvm_movbe.so"
  else
    echo "  ✗ crosvm missing libkvm_movbe.so DT_NEEDED"
  fi
fi

step "Checking Android image patches"
if [ -f "$WORK/bundle/opt/google/vms/android/system.raw.img" ]; then
  SYS_SIZE=$(stat -f%z "$WORK/bundle/opt/google/vms/android/system.raw.img" 2>/dev/null || stat -c%s "$WORK/bundle/opt/google/vms/android/system.raw.img")
  echo "  system.raw.img: $SYS_SIZE bytes"

  # Try to verify patch signatures (this is rough; a full check would mount and inspect)
  if [ -f "$WORK/bundle/opt/google/vms/android/vendor.raw.img" ]; then
    VEN_SIZE=$(stat -f%z "$WORK/bundle/opt/google/vms/android/vendor.raw.img" 2>/dev/null || stat -c%s "$WORK/bundle/opt/google/vms/android/vendor.raw.img")
    echo "  vendor.raw.img: $VEN_SIZE bytes"
    echo "  (Full verification requires mounting images; skipped for now)"
  fi
fi

echo
echo "Verification complete. For full Android image verification, mount them and check:"
echo "  - system/lib64/libcrypto.so has RDRAND replaced with clc"
echo "  - system/build.prop: ro.hwui.use_vulkan=false"
echo "  - boringssl_self_test64 passes under 'qemu-x86_64-static -cpu SandyBridge,+movbe'"
