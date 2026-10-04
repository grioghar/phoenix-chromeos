#!/bin/sh
# vostro hostname <name>: the name the Vostro gives your router (DHCP) and itself.
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
N=${1:-}
SH="dbus-send --system --print-reply --dest=org.chromium.flimflam /"
if [ -z "$N" ]; then
  echo "Current DHCP hostname:"; $SH org.chromium.flimflam.Manager.GetProperties | grep -A1 '"DHCPProperty.Hostname"' | tail -1 | sed 's/.*string //'
  echo "usage: vostro hostname NAME   (letters, digits and hyphens, up to 63 characters)"; exit 0
fi
echo "$N" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' || { echo "Use only letters, digits and hyphens (not at the start or end), up to 63 characters."; exit 1; }
$SH org.chromium.flimflam.Manager.SetProperty string:DHCPProperty.Hostname variant:string:"$N" >/dev/null
hostname "$N" 2>/dev/null || true
echo "DHCP hostname set to: $($SH org.chromium.flimflam.Manager.GetProperties | grep -A1 '"DHCPProperty.Hostname"' | tail -1 | sed 's/.*string //')"
echo "Your router sees the new name the next time the Vostro connects: turn Wi-Fi off and on (or unplug/replug Ethernet)."
