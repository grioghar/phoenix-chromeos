#!/bin/sh
# Phoenix health check: hardware/system problems the user should know about.
#   health.sh [--json FILE] [--text]   default: text to stdout
# Each issue: id | severity (critical|warning|info) | title | what it means and what to do.
# Used by: phoenix health, phoenix platform, the installer, and the desktop notifier (via JSON).
OUT_JSON=""; TEXT=1
while [ $# -gt 0 ]; do case $1 in --json) OUT_JSON=$2; TEXT=0; shift 2;; --text) TEXT=1; shift;; *) shift;; esac; done
ISSUES=""
add(){ ISSUES="$ISSUES$1|$2|$3|$4
"; }
rdmsr(){ dd if=/dev/cpu/$2/msr bs=8 count=1 skip=$1 iflag=skip_bytes 2>/dev/null | od -An -tu8 | tr -d ' '; }

# --- battery
for b in /sys/class/power_supply/*; do
  [ "$(cat $b/type 2>/dev/null)" = Battery ] || continue
  cap=$(cat $b/capacity 2>/dev/null); st=$(cat $b/status 2>/dev/null)
  full=$(cat $b/energy_full 2>/dev/null || cat $b/charge_full 2>/dev/null); design=$(cat $b/energy_full_design 2>/dev/null || cat $b/charge_full_design 2>/dev/null)
  ac=0; for a in /sys/class/power_supply/*; do [ "$(cat $a/type 2>/dev/null)" = Mains ] && [ "$(cat $a/online 2>/dev/null)" = 1 ] && ac=1; done
  if [ $ac = 1 ] && [ "${cap:-0}" -le 1 ] && [ "$st" != Charging ]; then
    add battery-failed critical "Battery has failed" "The battery is at ${cap:-0}% and not charging while plugged in. Many laptops (Dell especially) slow the processor drastically without a working battery. Replace the battery; until then Phoenix's throttle override keeps the computer usable (phoenix platform throttle)."
  elif [ -n "$full" ] && [ -n "$design" ] && [ "$design" -gt 0 ] && [ $(( full * 100 / design )) -lt 40 ]; then
    add battery-worn warning "Battery is worn out" "The battery holds only $(( full * 100 / design ))% of its original capacity. Expect short battery life; consider replacing it."
  fi
done

# --- firmware throttling (Intel MSRs; root only)
if [ -r /dev/cpu/0/msr ] || modprobe msr 2>/dev/null; then
  mod=0; for c in /dev/cpu/[0-9]*; do n=${c##*/}; v=$(rdmsr $((0x19A)) $n); [ -n "$v" ] && [ "$v" != 0 ] && mod=1; done
  ps=$(rdmsr $((0x198)) 0); pc=$(rdmsr $((0x199)) 0)
  if [ $mod = 1 ]; then
    add firmware-throttle critical "Firmware is throttling the processor" "The firmware is duty-cycling the CPU (typical with a failed battery or an unrecognised charger), so it runs at a fraction of its speed. Enable the throttle override: phoenix platform throttle on"
  fi
  if [ -n "$ps" ] && [ -n "$pc" ] && [ $(( (ps >> 8) & 255 )) -gt 0 ] && [ $(( (pc >> 8) & 255 )) -gt $(( (ps >> 8) & 255 + 10 )) ]; then
    :   # requested ratio far above delivered: handled by the cooling check below when hot
  fi
fi

# --- heat / cooling: thermal guard holding the CPU far below its rated speed
POL=/sys/devices/system/cpu/cpufreq/policy0
if [ -r $POL/scaling_max_freq ]; then
  cur=$(cat $POL/scaling_max_freq); max=$(cat $POL/cpuinfo_max_freq)
  t=0; for z in /sys/class/thermal/thermal_zone*; do case "$(cat $z/type)" in x86_pkg_temp|acpitz) v=$(( $(cat $z/temp) / 1000 )); [ $v -gt $t ] && t=$v;; esac; done
  if [ -f /run/phoenix-thermal-active ] && [ $(( cur * 100 / max )) -lt 60 ]; then
    add cooling warning "Cooling is limiting speed" "The processor is at ${t} C and Phoenix is holding it at $(( cur / 1000 )) MHz of $(( max / 1000 )) MHz to stay under its temperature limit. Cleaning the fan and heatsink (and renewing the thermal paste) usually fixes this on older laptops."
  elif [ $t -ge 95 ]; then
    add hot warning "Processor is very hot" "The processor is at ${t} C. Check that the vents are clear and the fan works."
  fi
fi

# --- virtualization (Android needs VT-x / AMD-V)
grep -qwE 'vmx|svm' /proc/cpuinfo || add no-vtx warning "Virtualization is off" "Android apps (Play Store) need VT-x / AMD-V. Turn on \"Virtualization Technology\" in the BIOS/UEFI setup."

# --- disk space
fr=$(df -Pm /mnt/stateful_partition 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$fr" ] && [ "$fr" -lt 2048 ] && add disk-low warning "Disk almost full" "Only ${fr} MB free. ChromeOS and Android slow down or fail when the disk is full."

# --- held ChromeOS update
[ -f /var/lib/phoenix/held ] && add update-held info "ChromeOS update on hold" "$(sed 's/prio=[0-9]* tries=[0-9]* //' /var/lib/phoenix/held | sed 's/version=/Version /') is waiting for its Phoenix hardware support. It installs automatically once that is ready."

# --- output
if [ -n "$OUT_JSON" ]; then
  { printf '{"time":"%s","issues":[' "$(date '+%F %T')"; first=1
    printf '%s' "$ISSUES" | while IFS='|' read -r id sev title msg; do
      [ -n "$id" ] || continue
      [ $first = 1 ] || printf ','; first=0
      printf '{"id":"%s","severity":"%s","title":"%s","message":"%s"}' "$id" "$sev" "$(printf '%s' "$title" | sed 's/"/\\"/g')" "$(printf '%s' "$msg" | sed 's/"/\\"/g')"
    done
    printf ']}\n'; } > "$OUT_JSON.new" && mv -f "$OUT_JSON.new" "$OUT_JSON"
fi
if [ $TEXT = 1 ]; then
  if [ -z "$ISSUES" ]; then echo "No problems found."
  else printf '%s' "$ISSUES" | while IFS='|' read -r id sev title msg; do
         [ -n "$id" ] || continue
         case $sev in critical) m="!!";; warning) m="! ";; *) m="i ";; esac
         echo "$m $title"; echo "$msg" | fold -s -w 90 | sed 's/^/     /'; done; fi
fi
