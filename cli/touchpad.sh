#!/bin/sh
# vostro touchpad <mode>: choose how Linux drives the ALPS touchpad (takes effect after a reboot)
#   alps   native ALPS driver: two-finger scroll, tap settings   (i8042.nomux=1 i8042.reset=1)
#   alps2  native ALPS driver without the i8042 tweaks            (no extra parameters)
#   exps   basic mouse mode: always works, no two-finger scroll  (the previous setting)
#   tune   install Phoenix's touchpad tuning (stops pointer jumps on ALPS semi-multitouch pads)
#   untune remove it
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
MODE=${1:-}
H=${PHOENIX_SERVER:-HOST:8099}
G=/etc/gesture/50-phoenix-alps-semimt.conf
relogin(){
  echo "ChromeOS reads touchpad settings when the desktop starts. Log out and back in to apply"
  printf "(or type 'now' to restart the desktop immediately: open windows close): "
  read -r a || a=""; [ "$a" = now ] && restart ui; return 0; }
case "$MODE" in
  tune)
    mount -o remount,rw / 2>/dev/null || true
    curl -s -m 20 "http://$H/gesture/50-phoenix-alps-semimt.conf" -o $G.new && grep -q '^Section' $G.new && mv -f $G.new $G \
      || { rm -f $G.new; echo "Could not download the tuning file."; exit 1; }
    chcon --reference=/etc/gesture/40-touchpad-cmt.conf $G 2>/dev/null || true
    sync; mount -o remount,ro / 2>/dev/null || true
    echo "Touchpad tuning installed ($G)."; relogin; exit 0 ;;
  untune)
    mount -o remount,rw / 2>/dev/null || true; rm -f $G; sync; mount -o remount,ro / 2>/dev/null || true
    echo "Touchpad tuning removed."; relogin; exit 0 ;;
  alps)  P="i8042.nomux=1 i8042.reset=1" ;;
  alps2) P="" ;;
  exps)  P="i8042.nomux=1 i8042.reset=1 psmouse.proto=exps" ;;
  *) echo "usage: phoenix touchpad alps|alps2|exps|tune|untune"
     echo "  alps   two-finger scroll (try this first)"
     echo "  alps2  two-finger scroll, without the i8042 tweaks (if alps does not work)"
     echo "  exps   basic mode that is known to work (no two-finger scroll)"
     echo "  tune   stop pointer jumps when scrolling with two fingers (ALPS touchpads)"
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
