#!/bin/bash
# Build a Phoenix Brunch release without recompiling kernels:
#   official Brunch release (kernels, firmware, EFI images)
#   + our Brunch fork (brunch-init, brunch-patches, chromeos-install.sh)
#   + Phoenix (boot screen, hardware detection, machine profiles)
#
#   make-release.sh <brunch_rXXX_*.tar.gz> <brunch fork checkout> <out_dir>
#
# Output: <out_dir>/phoenix-brunch-<tag>.tar.gz with the same layout as a Brunch release, so
# Brunch's chromeos-install.sh builds images/installs from it exactly as from the original.
# Runs as root on Linux (loop-mounts rootc.img). Needs: cpio, gzip, docker (to build the
# static boot screen) or a prebuilt boot/splash/phoenix-splash.
set -euo pipefail
REL=$1 FORK=$2 OUT=$3
PHX=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/phoenix-release.XXXX")
cleanup(){ umount "$W/rc" 2>/dev/null || true; rm -rf "$W"; }
trap cleanup EXIT
step(){ echo; echo "### $*"; }

step "Boot screen binary"
SPL=$PHX/boot/splash/phoenix-splash
if [ ! -x "$SPL" ] || [ "$PHX/boot/splash/phoenix-splash.c" -nt "$SPL" ]; then
  docker run --rm -v "$PHX/boot/splash:/s" -w /s alpine:3.20 sh -c \
    "apk add -q build-base linux-headers >/dev/null && gcc -O2 -Wall -static -o phoenix-splash phoenix-splash.c && strip phoenix-splash"
fi
file "$SPL" | grep -q 'statically linked' || { echo "boot screen binary is not static"; exit 1; }

step "Unpacking $(basename "$REL")"
mkdir -p "$W/rel" "$W/rc" "$W/irf" "$OUT"
tar -xzf "$REL" -C "$W/rel"
[ -f "$W/rel/rootc.img" ] || { echo "not a Brunch release (no rootc.img)"; exit 1; }
mount -o loop "$W/rel/rootc.img" "$W/rc"

step "Initramfs: fork's brunch-init + boot screen + detection"
( cd "$W/irf" && zcat "$W/rc/initramfs.img" | cpio -idm --quiet )
install -m 755 "$FORK/scripts/brunch-init" "$W/irf/init"
install -m 755 "$SPL" "$W/irf/bin/phoenix-splash"
mkdir -p "$W/irf/phoenix"
install -m 755 "$PHX/detect/phoenix-detect.sh" "$W/irf/phoenix/phoenix-detect.sh"
cp -r "$PHX/profiles" "$W/irf/phoenix/profiles"
( cd "$W/irf" && find . | cpio -o -H newc --quiet | gzip -9 ) > "$W/rc/initramfs.img"

step "Patches: fork's brunch-patches"
rm -f "$W/rc/patches/"*.sh
install -m 755 "$FORK"/brunch-patches/*.sh "$W/rc/patches/"
ls "$W/rc/patches" | wc -l | sed 's/^/  patches: /'
df -h "$W/rc" | tail -1 | awk '{print "  ROOT-C free: " $4}'
sync; umount "$W/rc"

step "Installer: fork's chromeos-install.sh"
install -m 755 "$FORK/scripts/chromeos-install.sh" "$W/rel/chromeos-install.sh"

TAG=${PHOENIX_TAG:-$(cd "$FORK" && git -c safe.directory="*" describe --always --dirty 2>/dev/null || echo local)}
# phoenix-<brunch base>-<fork commit>, e.g. phoenix-r150-0937d31 (fork branches are named phoenix-rXXX)
BASE=${PHOENIX_BASE:-$(cd "$FORK" && git -c safe.directory="*" rev-parse --abbrev-ref HEAD)}; BASE=${BASE#phoenix-}
NAME=phoenix-$BASE-$TAG
tar -czf "$OUT/$NAME.tar.gz" -C "$W/rel" .
( cd "$OUT" && sha256sum "$NAME.tar.gz" | tee "$NAME.tar.gz.sha256" )
