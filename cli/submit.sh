#!/bin/sh
# phoenix submit: profile this computer so the Phoenix project can add or fix support for it.
#
# Collects hardware identity and Linux/ChromeOS driver state, plus your description of what is
# missing or not working. Private data is removed before anything is saved: serial numbers, UUIDs,
# MAC and IP addresses, user names, e-mail addresses and the hostname.
# The report is saved to Downloads, shown to you, and only sent after you confirm.
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
H=${PHOENIX_SERVER:-HOST:8099}
REPO_URL=https://github.com/grioghar/phoenix-chromeos
SHARE=/usr/share/phoenix
DL=/home/chronos/user/MyFiles/Downloads
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT

det(){ if [ -r $SHARE/detect/phoenix-detect.sh ]; then PHOENIX_PROFILES=$SHARE/profiles sh $SHARE/detect/phoenix-detect.sh "$@"
       else curl -s -m 20 "http://$H/pd" | sh -s -- "$@"; fi; }
sec(){ echo; echo "## $*"; }
dmi(){ cat "/sys/class/dmi/id/$1" 2>/dev/null || echo "?"; }

echo "Phoenix hardware report"
echo "This collects what Phoenix needs to support this computer (no personal files)."
echo
printf "What is missing or not working? (one line; Enter to skip): "
read -r WHAT || WHAT=""
printf "Anything else (e.g. worked before / only after sleep)? (Enter to skip): "
read -r MORE || MORE=""

R=$TMP/report.txt
set +e   # collect whatever exists; a missing file or tool must not stop the report
{
  echo "# Phoenix hardware report"
  echo "date: $(date -u +%Y-%m-%d)"
  echo "problem: ${WHAT:-not given}"
  echo "details: ${MORE:-none}"

  sec "machine"
  for k in sys_vendor product_name product_version product_family board_vendor board_name board_version bios_vendor bios_version bios_date chassis_type; do
    printf '%s: %s\n' "$k" "$(dmi $k)"; done

  sec "phoenix assessment"
  det --summary 2>&1
  PROFILE=$(det 2>/dev/null)
  [ "$(printf '%s\n' "$PROFILE" | sed -n 's/^machine.profile_kind=//p')" = model ] && echo "model profile: present" || echo "model profile: MISSING (generic profile in use; this machine is not in Phoenix's profile list yet)"
  printf '%s\n' "$PROFILE" | grep -E '^(cpu|gpu|firmware|input|sensors|fan|disk|power|wifi|android|needs)' | sed 's/^/  /'

  sec "software"
  grep -E '^CHROMEOS_RELEASE_(VERSION|BOARD|CHROME_MILESTONE)=' /etc/lsb-release 2>/dev/null
  echo "kernel: $(uname -r)"
  cat /etc/brunch_version 2>/dev/null || true
  echo "cmdline: $(tr ' ' '\n' < /proc/cmdline | grep -vE '^(img_uuid|img_path|root|PARTUUID)=' | tr '\n' ' ')"

  sec "cpu"
  grep -m1 '^model name' /proc/cpuinfo; grep -m1 '^flags' /proc/cpuinfo
  echo "scaling: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null) / $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"

  sec "pci devices (with drivers)"
  lspci -nnk 2>/dev/null || for d in /sys/bus/pci/devices/*; do
    echo "$(basename $d) $(cat $d/class) $(cat $d/vendor):$(cat $d/device) driver=$(basename "$(readlink $d/driver 2>/dev/null)")"; done
  sec "pci devices WITHOUT a driver"
  for d in /sys/bus/pci/devices/*; do [ -L "$d/driver" ] || echo "$(basename $d) class=$(cat $d/class) id=$(cat $d/vendor | sed 's/0x//'):$(cat $d/device | sed 's/0x//')"; done

  sec "usb devices"
  lsusb 2>/dev/null || for d in /sys/bus/usb/devices/*; do [ -r $d/idVendor ] && echo "$(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/product 2>/dev/null)"; done

  sec "input devices"
  grep -E '^(N: Name|P: Phys|H: Handlers)' /proc/bus/input/devices 2>/dev/null

  sec "sensors and fans"
  for h in /sys/class/hwmon/hwmon*; do
    printf '%s:' "$(cat $h/name 2>/dev/null)"
    for f in $h/temp*_input $h/fan*_input $h/pwm[0-9]; do [ -r "$f" ] && printf ' %s=%s' "$(basename $f)" "$(cat $f)"; done; echo
  done

  sec "platform modules"
  [ -r /etc/phoenix/platform.conf ] && grep -v '^#' /etc/phoenix/platform.conf
  echo "loaded: $(cut -d' ' -f1 /proc/modules | sort | tr '\n' ' ')"

  sec "network adapters"
  for n in /sys/class/net/*; do [ -L $n/device ] || continue
    echo "$(basename $n): driver=$(basename "$(readlink $n/device/driver)") $( [ -d $n/wireless ] && echo wireless)"; done

  sec "kernel messages: errors, missing firmware, input/graphics/acpi problems"
  dmesg 2>/dev/null | grep -iE 'firmware|fail|error|i8042|psmouse|alps|synaptics|elan|i915|drm|amdgpu|radeon|nouveau|acpi.*(bios|error|warn)|hwmon|thermal|wmi|backlight|bluetooth|iwlwifi|brcm|ath|rtw|r8169' \
    | grep -viE 'loaded firmware version' | tail -150
} > $R 2>&1
set -e

# remove private data
sed -i -E \
  -e 's/([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/[mac]/g' \
  -e 's/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/[uuid]/g' \
  -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/[ip]/g' \
  -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[email]/g' \
  -e 's/(serial|Serial|SerialNumber|serial_number)[=:][^ ]*/\1=[removed]/g' \
  -e 's#/home/user/[0-9a-f]+#/home/user/[id]#g' $R
HN=$(hostname 2>/dev/null); [ -n "$HN" ] && [ "$HN" != localhost ] && sed -i "s/$HN/[hostname]/g" $R

MODEL=$(dmi product_name | tr -c 'A-Za-z0-9' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//' | cut -c1-40)
OUTF=$DL/phoenix-report-${MODEL:-pc}-$(date +%Y%m%d-%H%M).txt
mkdir -p $DL; cp $R "$OUTF"; chown chronos:chronos "$OUTF" 2>/dev/null || true
echo
echo "Report saved: Downloads/$(basename "$OUTF")  ($(wc -l < $R) lines)"
echo "Open it in the Files app to see exactly what it contains."
echo
printf "Send it to the Phoenix project now? [Y/n]: "
read -r ok || ok=n
case "$ok" in
  n|N|no|No) echo "Not sent. You can attach the saved file to an issue at $REPO_URL/issues/new" ;;
  *)
    ANS=$(curl -s -m 60 -T $R "http://$H/submit" 2>/dev/null || true)
    ISSUE=$(printf '%s\n' "$ANS" | sed -n 's/^issue: //p')
    if [ -n "$ISSUE" ]; then
      echo "Sent. Thank you! Your report is now a GitHub issue (follow it for updates):"
      echo "  $ISSUE"
    elif printf '%s' "$ANS" | grep -q received; then
      echo "Sent to the Phoenix server. Thank you!"
    else
      T=$(printf 'Hardware report: %s %s' "$(dmi sys_vendor)" "$(dmi product_name)" | sed 's/ /%20/g; s/&/%26/g; s/#/%23/g')
      echo "Could not reach the Phoenix server. You can report it yourself: open this link and attach the saved file:"
      echo "  $REPO_URL/issues/new?template=hardware-report.yml&title=$T"
    fi
    ;;
esac
