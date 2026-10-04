#!/bin/sh
# vostro touchpad <mode>: choose how Linux drives the ALPS touchpad (takes effect after a reboot)
#   alps   native ALPS driver: two-finger scroll, tap settings   (i8042.nomux=1 i8042.reset=1)
#   alps2  native ALPS driver without the i8042 tweaks            (no extra parameters)
#   exps   basic mouse mode: always works, no two-finger scroll  (the previous setting)
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
MODE=${1:-}
case "$MODE" in
  alps)  P="i8042.nomux=1 i8042.reset=1" ;;
  alps2) P="" ;;
  exps)  P="i8042.nomux=1 i8042.reset=1 psmouse.proto=exps" ;;
  *) echo "usage: vostro touchpad alps|alps2|exps"
     echo "  alps   two-finger scroll (try this first)"
     echo "  alps2  two-finger scroll, without the i8042 tweaks (if alps does not work)"
     echo "  exps   basic mode that is known to work (no two-finger scroll)"
     exit 1 ;;
esac
D=$(rootdev -d -s); case "$D" in *[0-9]) E=${D}p12;; *) E=${D}12;; esac
mkdir -p /tmp/vostro-efi
mount "$E" /tmp/vostro-efi
S=/tmp/vostro-efi/efi/boot/settings.cfg
echo "Before: $(grep '^cmdline_params=' $S)"
sed -i "s/^cmdline_params=.*/cmdline_params=\"$P\"/" $S
echo "After:  $(grep '^cmdline_params=' $S)"
sync; umount /tmp/vostro-efi
echo
echo "Reboot to use the new touchpad mode (sudo reboot)."
echo "If the touchpad stops working: press Ctrl+Alt+F2, log in as chronos, and run:  vostro touchpad exps"
