#!/bin/bash
# Phoenix patch hook for Brunch (installed as /rootc/patches/95-phoenix.sh).
#
# Brunch rebuilds ROOT-A from ROOT-B after a ChromeOS update and after kernel/option/framework
# changes, then runs every /rootc/patches/*.sh with ROOT-A mounted at /roota. This hook puts
# back this machine's Phoenix fixes, which `phoenix save` stored on the STATE partition:
#   unencrypted/phoenix/common.tar            version-independent (shim, hostname, services, CLI)
#   unencrypted/phoenix/bundles/<ver>.tar     for ChromeOS <ver> only (Flex binaries, Mesa, Android images)
# Files are extracted by ROOT-A's own GNU tar (in a chroot) so SELinux labels are kept.
# Exit status: 0 ok, 1 common failed, 2 bundle failed, 4 no bundle for this ChromeOS version.

ret=0
# messages go to the kernel log and, if the Phoenix boot screen is running, to its status line
# (a FIFO write blocks when nobody reads it, hence the pidof check and the timeout)
log(){ echo "phoenix: $*" > /dev/kmsg
  pidof phoenix-splash >/dev/null 2>&1 && PMSG="status $*" timeout 1 sh -c 'echo "$PMSG" > /run/phoenix-splash' 2>/dev/null; }

dev=$(awk '$2 == "/roota" {print $1}' /proc/mounts)
case "$dev" in *[0-9]p3) state=${dev%3}1;; *3) state=${dev%3}1;; *) log "cannot find the system disk"; exit 0;; esac
M=/roota/tmp/phoenix-store
mkdir -p $M
mount -o ro "$state" $M || { log "cannot mount $state"; exit 0; }
S=/tmp/phoenix-store/unencrypted/phoenix            # path as seen inside the chroot
VER=$(sed -n 's/^CHROMEOS_RELEASE_VERSION=//p' /roota/etc/lsb-release)

if [ -f /roota$S/common.tar ]; then
  log "Restoring Phoenix settings"
  chroot /roota /bin/tar --xattrs --xattrs-include='*' -xpf $S/common.tar -C / || ret=$((ret | 1))
fi
if [ -f /roota$S/bundles/$VER.tar ]; then
  log "Restoring hardware support for ChromeOS $VER"
  # the Flex Mesa stack ships different sonames; remove the stock ones so they cannot win
  rm -f /roota/usr/lib64/libEGL.so* /roota/usr/lib64/libGLESv2.so* /roota/usr/lib64/libglapi.so*
  chroot /roota /bin/tar --xattrs --xattrs-include='*' -xpf $S/bundles/$VER.tar -C / || ret=$((ret | 2))
  rm -f /roota/etc/phoenix/needs-fix
else
  log "No hardware support saved for ChromeOS $VER yet; run 'phoenix fix' after login"
  mkdir -p /roota/etc/phoenix && echo "$VER" > /roota/etc/phoenix/needs-fix
  ret=$((ret | 4))
fi
sync
umount $M; rmdir $M 2>/dev/null
exit $ret
