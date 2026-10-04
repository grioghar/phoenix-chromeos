#!/bin/bash
# Build a Phoenix fix bundle for a given ChromeOS version.
#
# Usage: make-bundle.sh <version> <out_dir>
#
# Downloads (or uses cached) rammus and reven recovery images for the version,
# extracts the Mesa stack and Rust binaries from reven, patches Android images from rammus,
# and produces a tar bundle with xattrs preserved (matching what save.sh creates on a fixed system).
#
# Output: <out_dir>/<version>.tar, <version>.sha256, <version>.manifest
set -euo pipefail
[ "${VERBOSE:-0}" = 1 ] && set -x

VERSION=$1 OUT=$2
CACHE=${CACHE:-/root/brunch-build}
RECOVERY_JSON="https://dl.google.com/dl/edgedl/chromeos/recovery/recovery2.json"
FLEX_JSON="https://dl.google.com/dl/edgedl/chromeos/recovery/cloudready_recovery2.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"

step() { echo; echo "=== $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }
exists() { for f in "$@"; do [ -e "/$f" ] || [ -L "/$f" ] && echo "$f"; done; }

mkdir -p "$OUT" "$CACHE/recovery"

step "Fetching recovery image metadata"
if ! curl -sf "$RECOVERY_JSON" -o "$CACHE/recovery/rammus.json"; then
  err "Failed to download rammus recovery list"
fi
if ! curl -sf "$FLEX_JSON" -o "$CACHE/recovery/reven.json"; then
  err "Failed to download reven recovery list"
fi

step "Looking up images for version $VERSION"
# Try to use cached images first (with standard naming pattern)
RAMMUS_CACHED=$(ls -1 "$CACHE"/chromeos_${VERSION}_rammus_recovery_ltc-channel*.bin 2>/dev/null | head -1)
REVEN_CACHED=$(ls -1 "$CACHE"/chromeos_${VERSION}_reven_recovery_ltc-channel*.bin 2>/dev/null | head -1)

if [ -n "$RAMMUS_CACHED" ] && [ -n "$REVEN_CACHED" ]; then
  # Use cached images
  RAMMUS_URL=""
  REVEN_URL=""
  echo "  Found cached images for $VERSION"
else
  # Try to look up from JSON lists (fallback if not cached)
  RAMMUS_URL=$(python3 - "$VERSION" "$CACHE/recovery/rammus.json" <<'PYEOF' 2>/dev/null
import json, sys
ver = sys.argv[1]
try:
    with open(sys.argv[2]) as f:
        data = json.load(f)
        releases = data if isinstance(data, list) else data.get("releases", [])
        for item in releases:
            if item.get("version") == ver:
                parts = item.get("file", "").split("_")
                if len(parts) >= 3 and parts[2] == "rammus" and item.get("channel", "").upper() == "LTC":
                    print(item.get("url", ""))
                    sys.exit(0)
except: pass
sys.exit(1)
PYEOF
) || true
  REVEN_URL=$(python3 - "$VERSION" "$CACHE/recovery/reven.json" <<'PYEOF' 2>/dev/null
import json, sys
ver = sys.argv[1]
try:
    with open(sys.argv[2]) as f:
        data = json.load(f)
        releases = data if isinstance(data, list) else data.get("releases", [])
        for item in releases:
            if item.get("version") == ver:
                parts = item.get("file", "").split("_")
                if len(parts) >= 3 and parts[2] == "reven" and item.get("channel", "").upper() == "LTC":
                    print(item.get("url", ""))
                    sys.exit(0)
except: pass
sys.exit(1)
PYEOF
) || true

  if [ -z "$RAMMUS_URL" ] || [ -z "$REVEN_URL" ]; then
    err "No matching rammus or reven images found for version $VERSION (not in cache or JSON)"
  fi
fi

step "Locating recovery images"
RAMMUS_FILE="${RAMMUS_CACHED:-$CACHE/recovery/rammus-$VERSION.bin}"
REVEN_FILE="${REVEN_CACHED:-$CACHE/recovery/reven-$VERSION.bin}"

# If we have cached images (from path lookup above), use them directly
if [ -n "$RAMMUS_CACHED" ]; then
  echo "  Using cached rammus: $(basename $RAMMUS_FILE)"
elif [ -f "$RAMMUS_FILE" ]; then
  echo "  Using existing rammus: $(basename $RAMMUS_FILE)"
elif [ -n "$RAMMUS_URL" ]; then
  echo "  Downloading rammus $VERSION..."
  curl -sL "$RAMMUS_URL" -o "$RAMMUS_FILE.tmp" || err "Failed to download rammus"
  mv "$RAMMUS_FILE.tmp" "$RAMMUS_FILE"
else
  err "No rammus image available for version $VERSION"
fi

if [ -n "$REVEN_CACHED" ]; then
  echo "  Using cached reven: $(basename $REVEN_FILE)"
elif [ -f "$REVEN_FILE" ]; then
  echo "  Using existing reven: $(basename $REVEN_FILE)"
elif [ -n "$REVEN_URL" ]; then
  echo "  Downloading reven $VERSION..."
  curl -sL "$REVEN_URL" -o "$REVEN_FILE.tmp" || err "Failed to download reven"
  mv "$REVEN_FILE.tmp" "$REVEN_FILE"
else
  err "No reven image available for version $VERSION"
fi

step "Extracting recovery images"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; for m in /mnt/phoenix-*; do umount -l "$m" 2>/dev/null || true; done' EXIT

# Mount read-only
RAMMUS_LOOP=$(losetup -f --show -P -r "$RAMMUS_FILE")
REVEN_LOOP=$(losetup -f --show -P -r "$REVEN_FILE")
trap "losetup -d '$RAMMUS_LOOP' '$REVEN_LOOP' 2>/dev/null || true; rm -rf '$WORK'; for m in /mnt/phoenix-*; do umount -l \$m 2>/dev/null || true; done" EXIT

mkdir -p /mnt/phoenix-rammus /mnt/phoenix-reven
mount "${RAMMUS_LOOP}p3" /mnt/phoenix-rammus
mount "${REVEN_LOOP}p3" /mnt/phoenix-reven

step "Building bundle tar from reven (Mesa/Rust binaries)"

# List of files from reven (same as in cli/save.sh BUNDLE)
MESA_FILES="usr/lib64/dri usr/share/glvnd usr/share/drirc.d"
for g in 'libEGL.so*' 'libEGL_mesa.so*' 'libGLESv2.so*' 'libGLdispatch.so*' 'libOpenGL.so*' \
         'libglapi.so*' 'libdrm*.so*' 'libminigbm.so*' 'libgbm.so*'; do
  for f in /mnt/phoenix-reven/usr/lib64/$g; do
    [ -e "$f" ] || [ -L "$f" ] && MESA_FILES="$MESA_FILES usr/lib64/$(basename "$f")"
  done
done

BINS="usr/bin/crosvm usr/bin/crosh usr/bin/btmanagerd usr/bin/btadapterd usr/bin/btclient usr/bin/resourced \
      usr/bin/vhost_user_starter usr/bin/chunneld usr/bin/9s usr/sbin/pdata_tools usr/bin/ippusb_bridge"

# Create the bundle: first the Flex binaries, then patch Android images from rammus
(cd /mnt/phoenix-reven && tar --xattrs --xattrs-include='*' -cf - $MESA_FILES $BINS) > "$OUT/$VERSION.tar.tmp"

step "Patching Android images from rammus"
ANDROID_SYSTEM="/mnt/phoenix-rammus/opt/google/vms/android/system.raw.img"
ANDROID_VENDOR="/mnt/phoenix-rammus/opt/google/vms/android/vendor.raw.img"

if [ ! -f "$ANDROID_SYSTEM" ] || [ ! -f "$ANDROID_VENDOR" ]; then
  err "Android images not found in rammus recovery"
fi

# Run patch-android.sh in a container (required for overlayfs and privileged ops)
PATCH_OUT="$WORK/android-patched"
mkdir -p "$PATCH_OUT"

if command -v mkfs.erofs >/dev/null 2>&1 && [ -w /sys/kernel/debug ]; then
  # We're in a privileged container or system with the required tools
  step "Patching Android images directly"
  mkdir -p "$WORK/ptmp"
  TMPDIR="$WORK/ptmp" bash "$REPO/build/patch-android.sh" "$ANDROID_SYSTEM" "$ANDROID_VENDOR" "$PATCH_OUT" \
    || err "Failed to patch Android images"
elif command -v docker >/dev/null 2>&1; then
  # Use docker as fallback
  step "Patching Android images in docker container"
  # scratch must be a host directory: overlayfs cannot use a directory on the container's overlayfs
  mkdir -p "$WORK/ptmp"
  docker run --rm --privileged \
    -v /dev:/dev \
    -v "$REPO:/repo:ro" \
    -v "$(dirname "$ANDROID_SYSTEM"):/images:ro" \
    -v "$PATCH_OUT:/out" \
    -v "$WORK/ptmp:/ptmp" \
    -e TMPDIR=/ptmp \
    ubuntu:24.04 bash -c '
      set -e
      apt-get update -qq >/dev/null
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq erofs-utils attr binutils qemu-user-static python3 >/dev/null 2>&1
      bash /repo/build/patch-android.sh /images/system.raw.img /images/vendor.raw.img /out
    ' || err "Docker patch-android.sh failed"
else
  err "Cannot patch Android images: need mkfs.erofs or docker"
fi

# Append patched images to bundle with correct paths
mkdir -p "$WORK/android-files/opt/google/vms/android"
cp "$PATCH_OUT/system.raw.img" "$WORK/android-files/opt/google/vms/android/"
cp "$PATCH_OUT/vendor.raw.img" "$WORK/android-files/opt/google/vms/android/"
# Preserve SELinux labels from the original images if available
if [ -f "/mnt/phoenix-rammus/opt/google/vms/android/system.raw.img" ]; then
  (getfattr -n security.selinux "/mnt/phoenix-rammus/opt/google/vms/android/system.raw.img" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | \
    xargs -I {} setfattr -n security.selinux -v {} "$WORK/android-files/opt/google/vms/android/system.raw.img") 2>/dev/null || true
fi
if [ -f "/mnt/phoenix-rammus/opt/google/vms/android/vendor.raw.img" ]; then
  (getfattr -n security.selinux "/mnt/phoenix-rammus/opt/google/vms/android/vendor.raw.img" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | \
    xargs -I {} setfattr -n security.selinux -v {} "$WORK/android-files/opt/google/vms/android/vendor.raw.img") 2>/dev/null || true
fi
(cd "$WORK/android-files" && tar --xattrs --xattrs-include='*' -cf - opt) >> "$OUT/$VERSION.tar.tmp"

# One archive, not two concatenated ones: plain `tar -x` (as the Brunch hook uses) stops at the first
# archive's end marker and would silently skip the Android images. Stage everything, then re-tar.
step "Assembling a single archive and linking crosvm to the MOVBE shim"
S="$WORK/stage"; mkdir -p "$S"
tar --xattrs --xattrs-include='*' -ixpf "$OUT/$VERSION.tar.tmp" -C "$S"
L=$(getfattr --only-values -n security.selinux "$S/usr/bin/crosvm" 2>/dev/null || true)
# patchelf 0.14.3 (Ubuntu 22.04) is what produced the crosvm verified on real hardware
docker run --rm -v "$S/usr/bin:/b" ubuntu:22.04 bash -c "apt-get update -qq >/dev/null; \
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq patchelf >/dev/null 2>&1; patchelf --add-needed libkvm_movbe.so /b/crosvm" \
  || err "patchelf failed"
[ -n "$L" ] && setfattr -n security.selinux -v "$L" "$S/usr/bin/crosvm"
readelf -d "$S/usr/bin/crosvm" > "$WORK/needed"; grep -q 'libkvm_movbe.so' "$WORK/needed" || err "crosvm is not linked to libkvm_movbe.so"
(cd "$S" && tar --xattrs --xattrs-include='*' -cf - .) > "$OUT/$VERSION.tar.tmp"
tar -tf "$OUT/$VERSION.tar.tmp" > "$WORK/list"   # (no grep -q in a pipe: with pipefail it fails on SIGPIPE)
grep -q 'opt/google/vms/android/system.raw.img' "$WORK/list" || err "Android images missing from the archive"

# Rename to final output
mv "$OUT/$VERSION.tar.tmp" "$OUT/$VERSION.tar"

step "Computing checksums and manifest"
cd "$OUT"
sha256sum "$VERSION.tar" > "$VERSION.sha256"

# Create manifest (file list with sha256)
{
  tar -tf "$VERSION.tar" | while read f; do
    # Extract individual file and compute its hash
    tar -xOf "$VERSION.tar" "$f" 2>/dev/null | sha256sum | awk -v f="$f" '{print $1 "  " f}' || echo "ERROR  $f"
  done
} > "$VERSION.manifest"

ls -lh "$VERSION.tar" "$VERSION.sha256" "$VERSION.manifest"
echo "Bundle complete: $(tar -tf "$VERSION.tar" | wc -l) files"
