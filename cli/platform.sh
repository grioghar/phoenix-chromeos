#!/bin/sh
# phoenix platform: view and configure this machine's platform modules, CPU profile and fan.
#   phoenix platform               status (what was detected, what is loaded, temperatures, fans)
#   phoenix platform menu          interactive menu
#   phoenix platform enable MOD    load MOD now and at every boot     (disable MOD: stop doing so)
#   phoenix platform cpu  balanced|performance|quiet
#   phoenix platform fan  bios|auto|quiet|max
#   phoenix platform reset         back to the recommended settings for this machine
set -e
[ "${VERBOSE:-0}" = 1 ] && set -x
H=${PHOENIX_SERVER:-HOST:8099}
SHARE=/usr/share/phoenix

# ---------------------------------------------------------------- install/update Phoenix's shared files
rw(){ mount -o remount,rw / 2>/dev/null || true; }
ro(){ sync; mount -o remount,ro / 2>/dev/null || true; }
ensure_share(){
  T=/tmp/phoenix-share.tgz
  curl -s -m 30 "http://$H/share.tgz" -o $T 2>/dev/null && tar -tzf $T >/dev/null 2>&1 || { [ -r $SHARE/platform/platform-lib.sh ] && return 0; echo "Cannot reach the Phoenix server and Phoenix is not installed."; exit 1; }
  NEW=$(sha256sum < $T); [ "$NEW" = "$(cat $SHARE/.share.sha 2>/dev/null)" ] && return 0
  rw; mkdir -p $SHARE /etc/phoenix
  tar -xzf $T -C $SHARE
  for s in $SHARE/services/phoenix-*.conf; do
    cp "$s" /etc/init/; chcon --reference=/etc/init/shill.conf "/etc/init/$(basename "$s")" 2>/dev/null || true
  done
  echo "$NEW" > $SHARE/.share.sha; ro
}
# keep the settings across Brunch rebuilds/updates (phoenix save's version-independent archive)
persist(){
  S=/mnt/stateful_partition/unencrypted/phoenix; mkdir -p $S
  C=$(cd / && for f in usr/lib64/libkvm_movbe.so etc/phoenix usr/share/phoenix usr/bin/vostro usr/bin/phoenix etc/init/phoenix-*.conf; do [ -e "$f" ] && echo "$f"; done)
  (cd / && tar --xattrs --xattrs-include='*' -cf $S/common.tar.new $C) && mv -f $S/common.tar.new $S/common.tar
}
ensure_share
. $SHARE/platform/platform-lib.sh
save_conf(){ rw; mkdir -p /etc/phoenix; "$@"; ro; persist; }
[ -r "$PLATFORM_CONF" ] || save_conf sh -c ". $SHARE/platform/platform-lib.sh; conf_default > $PLATFORM_CONF"

# ---------------------------------------------------------------- views
status(){
  conf_load
  echo "Machine:      $(profile_get machine.vendor) $(profile_get machine.model)$( [ -n "$(profile_get machine.profile)" ] && echo '  (known model)')"
  echo "CPU:          $(profile_get cpu.name)   scaling: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)/$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  echo "CPU profile:  $cpu_profile        Fan mode: $fan_mode$( [ -z "$(fan_pwm)" ] && echo '  (no software fan control on this machine)')"
  echo
  echo "Platform modules (* = recommended for this machine):"
  rec=" $(recommended_modules) "
  all=$( { catalog_lines | cut -d'|' -f1; for m in $modules; do echo "$m"; done; } | awk '!s[$0]++')
  i=0
  for mod in $all; do
    i=$((i+1))
    case " $modules " in *" $mod "*) on="[on] ";; *) on="[off]";; esac
    case "$rec" in *" $mod "*) r="*";; *) r=" ";; esac
    if module_loaded "$mod"; then st="loaded"; elif module_available "$mod"; then st="available"; else st="not in kernel"; fi
    # only list what is relevant here: enabled, recommended, or loaded
    case "$on$r$st" in "[off] "*available|"[off] not in kernel") continue;; esac
    printf "  %-2s %s%s %-16s %-13s %s\n" "$i" "$on" "$r" "$mod" "$st" "$(catalog_field "$mod" 3)"
  done
  echo
  echo "Sensors:"; sensors_report | grep . || echo "  (none reported yet)"
}

menu(){
  while :; do
    clear 2>/dev/null || true
    echo "=== Phoenix platform settings ==="; echo; status; echo
    echo "  e) enable a module    d) disable a module    a) show all catalog modules"
    echo "  c) CPU profile        f) fan mode            r) reset to recommended"
    echo "  q) quit"
    printf "> "; read -r k || exit 0
    case "$k" in
      e) printf "Module to enable: "; read -r m; [ -n "$m" ] && enable "$m"; pause ;;
      d) printf "Module to disable: "; read -r m; [ -n "$m" ] && disable "$m"; pause ;;
      a) catalog_lines | awk -F'|' '{printf "  %-16s %s\n", $1, $3}'; pause ;;
      c) printf "CPU profile (balanced / performance / quiet): "; read -r p; cpu "$p"; pause ;;
      f) printf "Fan mode (bios / auto / quiet / max): "; read -r p; fan "$p"; pause ;;
      r) reset; pause ;;
      q|"") exit 0 ;;
    esac
  done
}
pause(){ printf "(press Enter)"; read -r _ || true; }

# ---------------------------------------------------------------- actions
enable(){
  conf_load; case " $modules " in *" $1 "*) ;; *) save_conf conf_set modules "$(echo "$modules $1" | sed 's/^ //')";; esac
  o=$(catalog_field "$1" 4); v=opt_$(echo "$1" | tr - _)
  [ -n "$o" ] && ! grep -q "^$v=" "$PLATFORM_CONF" && save_conf conf_set "$v" "$o"
  apply_modules; echo "$1 enabled (loads at every boot)"
}
disable(){
  conf_load; save_conf conf_set modules "$(echo " $modules " | sed "s/ $1 / /; s/^ //; s/ $//")"
  modprobe -r "$1" 2>/dev/null && echo "$1 unloaded" || true; echo "$1 disabled"
}
cpu(){ case "$1" in balanced|performance|quiet) save_conf conf_set cpu_profile "$1"; apply_cpu;; *) echo "use: balanced, performance or quiet";; esac; }
fan(){
  case "$1" in bios|auto|quiet|max) ;; *) echo "use: bios, auto, quiet or max"; return;; esac
  [ "$1" != bios ] && [ -z "$(fan_pwm)" ] && { echo "This machine does not allow software fan control (the firmware keeps it)."; return; }
  save_conf conf_set fan_mode "$1"
  if [ "$1" = bios ]; then stop phoenix-fan 2>/dev/null || true; else restart phoenix-fan 2>/dev/null || start phoenix-fan 2>/dev/null || true; fi
  echo "fan mode: $1"
}
reset(){ save_conf sh -c ". $SHARE/platform/platform-lib.sh; conf_default > $PLATFORM_CONF"; apply_modules; apply_cpu; echo "Recommended settings restored."; }

case "${1:-status}" in
  status)  status ;;
  menu)    menu ;;
  enable)  enable "$2" ;;
  disable) disable "$2" ;;
  cpu)     cpu "${2:-}" ;;
  fan)     fan "${2:-}" ;;
  reset)   reset ;;
  apply)   apply_modules; apply_cpu ;;
  *) echo "usage: phoenix platform [status|menu|enable MOD|disable MOD|cpu PROFILE|fan MODE|reset|apply]" ;;
esac
