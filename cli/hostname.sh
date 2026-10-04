#!/bin/sh
# phoenix hostname [NAME]: the name this computer gives your router (DHCP) and itself.
# Saved in /etc/phoenix/hostname and applied at every boot by the phoenix-hostname service.
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
H=${PHOENIX_SERVER:-HOST:8099}
N=${1:-}
SH="dbus-send --system --print-reply --dest=org.chromium.flimflam /"
cur(){ $SH org.chromium.flimflam.Manager.GetProperties | grep -A1 '"DHCPProperty.Hostname"' | tail -1 | sed 's/.*string //; s/"//g'; }
if [ -z "$N" ]; then
  echo "Network (DHCP) hostname: $(cur)"
  echo "Saved hostname:          $(cat /etc/phoenix/hostname 2>/dev/null || echo none)"
  echo "Boot service installed:  $([ -f /etc/init/phoenix-hostname.conf ] && echo yes || echo no)"
  echo "usage: hostname NAME   (letters, digits and hyphens, up to 63 characters)"; exit 0
fi
echo "$N" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' || { echo "Use only letters, digits and hyphens (not at the start or end), up to 63 characters."; exit 1; }
$SH org.chromium.flimflam.Manager.SetProperty string:DHCPProperty.Hostname variant:string:"$N" >/dev/null
hostname "$N" 2>/dev/null || true
# make it permanent: saved name + boot service on the system partition
mount -o remount,rw / 2>/dev/null || true
mkdir -p /etc/phoenix && echo "$N" > /etc/phoenix/hostname
curl -s http://$H/svc/phoenix-hostname.conf -o /etc/init/phoenix-hostname.conf.new && mv -f /etc/init/phoenix-hostname.conf.new /etc/init/phoenix-hostname.conf
chcon --reference=/etc/init/shill.conf /etc/init/phoenix-hostname.conf 2>/dev/null || true
sync; mount -o remount,ro / 2>/dev/null || true
echo "Hostname set to: $(cur)  (saved; re-applied at every boot)"
echo "Your router sees the new name the next time this computer connects: turn Wi-Fi off and on (or replug Ethernet)."
