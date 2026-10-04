#!/bin/sh
# phoenix save: snapshot this (working) system's Phoenix fixes so they survive Brunch rebuilds and
# ChromeOS updates, and install the Brunch patch hook that puts them back.
#   STATE: /mnt/stateful_partition/unencrypted/phoenix/{common.tar,bundles/<version>.tar}
#   ROOT-C: /rootc/patches/95-phoenix.sh
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
H=${PHOENIX_SERVER:-HOST:8099}
S=/mnt/stateful_partition/unencrypted/phoenix
VER=$(sed -n 's/^CHROMEOS_RELEASE_VERSION=//p' /etc/lsb-release)
n=0; step(){ n=$((n+1)); echo; echo "[$n] $*"; }
exists(){ for f in "$@"; do [ -e "/$f" ] || [ -L "/$f" ] && echo "$f"; done; true; }   # (true: a missing last item must not fail under set -e)

step "Checking this system is fixed"
if [ ! -e /usr/lib64/dri/crocus_dri.so ] && [ ! -e /usr/lib64/libkvm_movbe.so ]; then
  echo "  No Phoenix fixes found on this system; nothing to save."; exit 1
fi
echo "  ChromeOS $VER"

# version-specific: rebuilt from Google's images for each ChromeOS release
BUNDLE=$(cd / && exists usr/lib64/dri usr/share/glvnd usr/share/drirc.d \
  usr/bin/crosvm usr/bin/crosh usr/bin/btmanagerd usr/bin/btadapterd usr/bin/btclient usr/bin/resourced \
  usr/bin/vhost_user_starter usr/bin/chunneld usr/bin/9s usr/sbin/pdata_tools usr/bin/ippusb_bridge \
  opt/google/vms/android/system.raw.img opt/google/vms/android/vendor.raw.img \
  $(ls -d usr/lib64/libEGL*.so* usr/lib64/libGLESv2.so* usr/lib64/libGLdispatch.so* usr/lib64/libOpenGL.so* \
        usr/lib64/libglapi.so* usr/lib64/libdrm*.so* usr/lib64/libminigbm.so* usr/lib64/libgbm.so* 2>/dev/null))
# version-independent
COMMON=$(cd / && exists usr/lib64/libkvm_movbe.so etc/phoenix usr/share/phoenix usr/bin/vostro usr/bin/phoenix \
  $(ls -d etc/init/phoenix-*.conf etc/gesture/50-phoenix-*.conf 2>/dev/null))

step "Saving fixes for ChromeOS $VER (about 1 GB, a minute or two)"
mkdir -p $S/bundles
( cd / && tar --xattrs --xattrs-include='*' -cf - $BUNDLE ) | { command -v pv >/dev/null && pv -s "$(cd / && du -sbc $BUNDLE | tail -1 | cut -f1)" || cat; } > $S/bundles/$VER.tar.new
mv -f $S/bundles/$VER.tar.new $S/bundles/$VER.tar
( cd / && tar --xattrs --xattrs-include='*' -cf $S/common.tar.new $COMMON ) && mv -f $S/common.tar.new $S/common.tar
ls -la $S/bundles/$VER.tar $S/common.tar | awk '{print "  " $5 " bytes  " $NF}'

step "Installing the Phoenix patch hook into Brunch"
D=$(rootdev -d -s); case "$D" in *[0-9]) C=${D}p7;; *) C=${D}7;; esac
mkdir -p /tmp/phoenix-rootc
mount "$C" /tmp/phoenix-rootc
curl -s -m 20 http://$H/hook -o /tmp/phoenix-hook.sh && grep -q '^# Phoenix patch hook' /tmp/phoenix-hook.sh \
  || { umount /tmp/phoenix-rootc; echo "  Could not download the hook"; exit 1; }
if [ -f /tmp/phoenix-rootc/patches/95-phoenix.sh ] && [ "$(sha256sum < /tmp/phoenix-hook.sh)" = "$(sha256sum < /tmp/phoenix-rootc/patches/95-phoenix.sh)" ]; then
  echo "  Hook already installed"
else
  cp /tmp/phoenix-hook.sh /tmp/phoenix-rootc/patches/95-phoenix.sh; chmod 755 /tmp/phoenix-rootc/patches/95-phoenix.sh
  echo "  Hook installed. Brunch will rebuild the system once at the next boot (a few minutes);"
  echo "  the hook then restores everything saved above."
fi
sync; umount /tmp/phoenix-rootc
echo
echo "Done. Your fixes now survive ChromeOS updates of version $VER and any Brunch rebuild."
