#!/bin/bash
# Build a Phoenix initramfs from Brunch's: adds the Phoenix boot screen and hardware detection.
#   make-initramfs.sh <brunch initramfs.img> <phoenix-splash binary> <out.img>
# Changes to Brunch's /init (each guarded so Brunch behaves exactly as before without a framebuffer):
#   - start phoenix-splash on /dev/fb0 when the boot is not verbose (or phoenix_splash=1), feed it
#     the detection summary, and skip Brunch's static fbv bootsplash
#   - rootfs rebuild: `pv -n` progress goes to the boot screen's progress bar
#   - stop the boot screen before any interactive shell / brunch-setup, and before switch_root
set -euo pipefail
IN=$1 SPLASH=$2 OUT=$3
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cd "$W"
zcat "$IN" | cpio -idm --quiet
grep -q 'exec switch_root /roota /sbin/init' init || { echo "unexpected Brunch init"; exit 1; }
grep -q 'Phoenix boot screen' init && { echo "already a Phoenix initramfs"; exit 1; }

install -m 755 "$SPLASH" bin/phoenix-splash
mkdir -p phoenix && install -m 755 "$HERE/detect/phoenix-detect.sh" phoenix/phoenix-detect.sh
cp -r "$HERE/profiles" phoenix/profiles

python3 - init <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
def rep(a, b, count=1):
    global s
    assert s.count(a) >= 1, a
    s = s.replace(a, b) if count == 0 else s.replace(a, b, count)

rep('ln -s /proc/mounts /etc/mtab\n', r'''ln -s /proc/mounts /etc/mtab

# --- Phoenix boot screen (non-verbose boots, or phoenix_splash=1; phoenix_splash=0 disables it)
phoenix_splash_on=0
psplash(){ [ "$phoenix_splash_on" = 1 ] && pidof phoenix-splash >/dev/null 2>&1 && PMSG="$*" timeout 1 sh -c 'echo "$PMSG" > /run/phoenix-splash' 2>/dev/null; return 0; }
if [ "$phoenix_splash" = 1 ] || { [ "$phoenix_splash" != 0 ] && grep -qE '(^| )console=( |$)' /proc/cmdline; }; then
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -e /dev/fb0 ] && break; sleep 0.2; done
	if [ -e /dev/fb0 ]; then
		mkdir -p /run
		phoenix-splash /dev/fb0 /run/phoenix-splash > /dev/null 2>&1 &
		for i in 1 2 3 4 5 6 7 8 9 10; do [ -p /run/phoenix-splash ] && break; sleep 0.1; done
		phoenix_splash_on=1
		brunch_bootsplash=""
		PHOENIX_PROFILES=/phoenix/profiles sh /phoenix/phoenix-detect.sh --summary 2>/dev/null | sed -n '1,4p' | while read -r l; do psplash "detail $l"; done
		psplash "status Starting"
	fi
fi
''')
# rootfs rebuild progress -> progress bar
rep('\tpv "$partpath"5 > "$partpath"3\n',
    '\tif [ "$phoenix_splash_on" = 1 ]; then : > /run/phoenix-pv; psplash "pvfile /run/phoenix-pv"; pv -n "$partpath"5 2>/run/phoenix-pv > "$partpath"3; psplash "progress -1"; else pv "$partpath"5 > "$partpath"3; fi\n')
# never hide a shell or the config editor behind the boot screen
rep('exec sh', 'pkill -9 phoenix-splash; exec sh', 0)
rep('\tbrunch-setup\n', '\tpkill -9 phoenix-splash; brunch-setup\n')
# hand over to ChromeOS
rep('pkill -9 fbv\n', 'pkill -9 fbv\npsplash "status Starting ChromeOS"; sleep 0.3; pkill -9 phoenix-splash\n')
open(p, "w").write(s)
PY
sh -n init 2>/dev/null || bash -n init
find . | cpio -o -H newc --quiet | gzip -9 > "$OUT"
echo "built $OUT ($(stat -c %s "$OUT") bytes)"
