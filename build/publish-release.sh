#!/bin/bash
# Publish a Phoenix release for `phoenix upgrade`: extract the upgrade pieces from a release tarball
# (built by make-release.sh) into the server's release directory.
#
#   publish-release.sh <phoenix-rXXX-<commit>.tar.gz> <original brunch_rXXX.tar.gz> [dir]
#
# dir (default /root/phoenix-release/current) gets: initramfs.img, patches.tar, manifest
# manifest: tag, base_initramfs (sha of the ORIGINAL Brunch initramfs the release is built on,
# so upgrade refuses other Brunch versions), base_kernel, initramfs_sha, patches_sha.
set -euo pipefail
REL=$1 BASE=$2 DIR=${3:-/root/phoenix-release/current}
W=$(mktemp -d); trap 'umount "$W/m" 2>/dev/null || true; rm -rf "$W"' EXIT
mkdir -p "$W/m" "$W/b" "$DIR"
sha(){ sha256sum "$1" | cut -d' ' -f1; }

tar -xzf "$BASE" -C "$W/b" --wildcards '*rootc.img'
mount -o ro,loop "$W/b/rootc.img" "$W/m"
BASE_INIT=$(sha "$W/m/initramfs.img"); BASE_K=$(readlink "$W/m/kernel" | sed 's/^kernel-//')
BASE_KV=$(ls "$W/m/packages" | sed -n "s/^kernel-\(${BASE_K//./\\.}[^-]*\)-generic.*/\1/p" | head -1)
umount "$W/m"

tar -xzf "$REL" -C "$W" --wildcards '*rootc.img'
mount -o ro,loop "$W/rootc.img" "$W/m"
cp "$W/m/initramfs.img" "$DIR/initramfs.img"
tar -cf "$DIR/patches.tar" -C "$W/m" patches
umount "$W/m"

TAG=$(basename "$REL" .tar.gz)
cat > "$DIR/manifest" <<EOF
tag=$TAG
base_initramfs=$BASE_INIT
base_kernel=${BASE_KV:-$BASE_K}
initramfs_sha=$(sha "$DIR/initramfs.img")
patches_sha=$(sha "$DIR/patches.tar")
EOF
cat "$DIR/manifest"
