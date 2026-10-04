#!/bin/sh
# phoenix upgrade: bring an existing Brunch/Phoenix install up to the current Phoenix release
# (boot screen, hardware detection at boot, the Brunch fork's patches incl. the fix-restoring hook,
# BIOS graphics-mode fix) without reinstalling.
#
#   phoenix upgrade              upgrade (asks before changing anything)
#   phoenix upgrade --rollback   put Brunch's original boot files back
#   phoenix upgrade --verbose-boot / --quiet-boot   show Brunch's text log at boot / the boot screen
#
# What changes: ROOT-C (partition 7): initramfs.img and patches/; EFI (partition 12): theme.cfg,
# settings.cfg verbose. Originals are kept in ROOT-C phoenix-backup/ for --rollback.
# Brunch rebuilds the system once at the next boot (a few minutes); the Phoenix hook then restores
# this machine's saved fixes.
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
H=${PHOENIX_SERVER:-HOST:8099}
n=0; step(){ n=$((n+1)); echo; echo "[$n] $*"; }
D=$(rootdev -d -s); case "$D" in *[0-9]) P=${D}p;; *) P=$D;; esac
RC=/tmp/phoenix-rootc EF=/tmp/phoenix-efi
mnt(){ mkdir -p $RC $EF; mountpoint -q $RC || mount ${P}7 $RC; mountpoint -q $EF || mount ${P}12 $EF; }
umnt(){ sync; umount $RC 2>/dev/null || true; umount $EF 2>/dev/null || true; }
trap umnt EXIT
sha(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
set_verbose(){ sed -i "s/^verbose=.*/verbose=$1/" $EF/efi/boot/settings.cfg; }

case "${1:-}" in
  --verbose-boot) mnt; set_verbose 1; echo "Brunch's text log will show at boot."; exit 0 ;;
  --quiet-boot)   mnt; set_verbose 0; echo "The Phoenix boot screen will show at boot."; exit 0 ;;
  --rollback)
    mnt; B=$RC/phoenix-backup
    [ -f $B/initramfs.img ] || { echo "No backup found: this machine was not upgraded with phoenix upgrade."; exit 1; }
    cp $B/initramfs.img $RC/initramfs.img
    rm -f $RC/patches/*.sh; tar -xf $B/patches.tar -C $RC
    [ -f $B/theme.cfg ] && cp $B/theme.cfg $EF/efi/boot/theme.cfg
    rm -f $RC/phoenix-release
    echo "Brunch's original boot files are back. Reboot to use them (one rebuild happens at boot)."
    exit 0 ;;
esac

step "Checking the Phoenix server for the current release"
M=/tmp/phoenix-release.manifest
curl -s -m 20 "http://$H/rel/manifest" -o $M && grep -q '^tag=' $M || { echo "  Cannot reach the Phoenix server."; exit 1; }
. $M          # tag= base_initramfs= base_kernel= initramfs_sha= patches_sha=
echo "  Phoenix release: $tag (Brunch base kernel $base_kernel)"

step "Checking this installation"
mnt
CUR=$(sha $RC/initramfs.img); KV=$(cat $RC/kernel_version 2>/dev/null)
if [ "$CUR" = "$initramfs_sha" ]; then echo "  Already on $tag."; exit 0; fi
if [ -f $RC/phoenix-release ]; then echo "  Currently: $(cat $RC/phoenix-release)"
elif [ "$CUR" != "$base_initramfs" ]; then
  echo "  This Brunch version is not the one release $tag is built on (initramfs differs)."
  echo "  Upgrading would mix versions; reinstall from a Phoenix image instead (or ask for a release for your Brunch)."
  exit 1
fi
case "$KV" in "$base_kernel"*|*phoenix*) ;; *) echo "  Note: running kernel $KV (release built against $base_kernel)";; esac

step "Making sure this machine's fixes are saved (they are restored after the rebuild)"
VER=$(sed -n 's/^CHROMEOS_RELEASE_VERSION=//p' /etc/lsb-release)
S=/mnt/stateful_partition/unencrypted/phoenix
if [ -f $S/bundles/$VER.tar ] && [ -f $S/common.tar ]; then echo "  Saved fixes for ChromeOS $VER found."
else umnt; curl -s http://$H/s | sh | sed 's/^/  /'; mnt; fi

echo
echo "Ready to upgrade to Phoenix $tag. At the next boot Brunch rebuilds the system once (a few minutes,"
echo "with the Phoenix boot screen), then your fixes are restored. Undo any time: phoenix upgrade --rollback"
printf "Continue? [Y/n]: "; read -r ok || ok=n
case "$ok" in n|N|no|No) echo "Nothing changed."; exit 0;; esac

step "Downloading"
W=/mnt/stateful_partition/phoenix-upgrade; mkdir -p $W
curl -# -o $W/initramfs.img "http://$H/rel/initramfs.img"
curl -s -o $W/patches.tar "http://$H/rel/patches.tar"
[ "$(sha $W/initramfs.img)" = "$initramfs_sha" ] && [ "$(sha $W/patches.tar)" = "$patches_sha" ] \
  || { echo "  Download damaged; nothing changed. Run phoenix upgrade again."; rm -rf $W; exit 1; }
echo "  checksums OK"

step "Backing up Brunch's boot files"
B=$RC/phoenix-backup
if [ ! -f $B/initramfs.img ]; then
  mkdir -p $B; cp $RC/initramfs.img $B/initramfs.img
  tar -cf $B/patches.tar -C $RC patches; cp $EF/efi/boot/theme.cfg $B/theme.cfg 2>/dev/null || true
  echo "  saved to ROOT-C phoenix-backup/"
else echo "  backup from an earlier upgrade kept"; fi

step "Installing Phoenix $tag"
cp $W/initramfs.img $RC/initramfs.img
rm -f $RC/patches/*.sh; tar -xf $W/patches.tar -C $RC; chmod 755 $RC/patches/*.sh
echo "$tag" > $RC/phoenix-release
# BIOS machines: keep GRUB's graphics mode so the boot screen has a framebuffer (UEFI unchanged)
T=$EF/efi/boot/theme.cfg
grep -q 'grub_platform' $T || sed -i 's/^set gfxpayload=text$/if [ "$grub_platform" = pc ]; then set gfxpayload=keep; else set gfxpayload=text; fi/' $T
G=$EF/efi/grub/grub.cfg
[ -f $G ] && { grep -q 'insmod png' $G || sed -i 's/^insmod gfxterm$/insmod gfxterm\ninsmod png/' $G; }
set_verbose 0
rm -rf $W
echo "  installed; boot screen on (phoenix upgrade --verbose-boot shows Brunch's text log instead)"
echo
echo "Done. Reboot (sudo reboot). The first boot rebuilds the system once; let it finish."
