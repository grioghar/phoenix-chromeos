#!/bin/sh
# Phoenix control (called by phoenix-statusd for the Phoenix Health extension).
#   control.sh get              current settings as JSON
#   control.sh set KEY VALUE    change one setting; only the keys and values below are accepted
. /usr/share/phoenix/platform/platform-lib.sh
conf_load
jesc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
get(){
  mhz=$(awk '{s+=$1} END{printf "%d", s/NR/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)
  maxf=$(( $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null || echo 0) / 1000 ))
  t=0; for z in /sys/class/thermal/thermal_zone*; do case "$(cat $z/type)" in x86_pkg_temp|acpitz) v=$(( $(cat $z/temp) / 1000 )); [ $v -gt $t ] && t=$v;; esac; done
  printf '{"machine":"%s","cpu_mhz":%s,"cpu_max_mhz":%s,"temp_c":%s,' \
    "$(jesc "$(profile_get machine.vendor) $(profile_get machine.model)")" "${mhz:-0}" "$maxf" "$t"
  printf '"settings":{"performance_mode":"%s","performance_active":%s,"throttle_override":"%s","thermal_guard":"%s",' \
    "$performance_mode" "$(perf_mode_active && echo true || echo false)" "$throttle_override" "$thermal_guard"
  printf '"thermal_limit":%s,"cpu_profile":"%s","fan_mode":"%s","android_animations":"%s","maintenance":"%s","health_interval":%s}}\n' \
    "$thermal_limit" "$cpu_profile" "$fan_mode" "$android_animations" "$maintenance" "${health_interval:-300}"
}
persist(){   # keep settings across Brunch rebuilds/updates (same archive as phoenix save)
  S=/mnt/stateful_partition/unencrypted/phoenix; mkdir -p $S
  C=$(cd / && for f in usr/lib64/libkvm_movbe.so etc/phoenix usr/share/phoenix usr/bin/vostro usr/bin/phoenix etc/init/phoenix-*.conf etc/gesture/50-phoenix-*.conf; do [ -e "$f" ] && echo "$f"; done; true)
  (cd / && tar --xattrs --xattrs-include='*' -cf $S/common.tar.new $C 2>/dev/null) && mv -f $S/common.tar.new $S/common.tar; }
ok(){ persist; echo "{\"ok\":true,\"key\":\"$1\",\"value\":\"$2\"$3}"; }
set_key(){
  k=$1 v=$2
  rw(){ mount -o remount,rw / 2>/dev/null || true; }; ro(){ sync; mount -o remount,ro / 2>/dev/null || true; }
  case "$k:$v" in
    performance_mode:on|performance_mode:off) rw; conf_set performance_mode "$v"; ro; apply_perf_mode >/dev/null; ok "$k" "$v" ',"reboot":true' ;;
    throttle_override:on|throttle_override:off|thermal_guard:on|thermal_guard:off) rw; conf_set "$k" "$v"; ro; apply_throttle >/dev/null; ok "$k" "$v" ;;
    thermal_limit:*) [ "$v" -ge 60 ] 2>/dev/null && [ "$v" -le 100 ] || { echo '{"error":"thermal_limit: 60-100"}'; exit 1; }
                     rw; conf_set thermal_limit "$v"; ro; ok "$k" "$v" ;;
    cpu_profile:balanced|cpu_profile:performance|cpu_profile:quiet) rw; conf_set cpu_profile "$v"; ro; apply_cpu >/dev/null; ok "$k" "$v" ;;
    fan_mode:bios|fan_mode:auto|fan_mode:quiet|fan_mode:max)
      [ "$v" != bios ] && [ -z "$(fan_pwm)" ] && { echo '{"error":"no software fan control on this computer"}'; exit 1; }
      rw; conf_set fan_mode "$v"; ro; if [ "$v" = bios ]; then stop phoenix-fan 2>/dev/null; else restart phoenix-fan 2>/dev/null || start phoenix-fan 2>/dev/null; fi; ok "$k" "$v" ;;
    android_animations:1|android_animations:0.5|android_animations:0) rw; conf_set android_animations "$v"; ro; apply_android >/dev/null; ok "$k" "$v" ;;
    maintenance:on|maintenance:off) rw; conf_set maintenance "$v"; ro; apply_maintain >/dev/null; ok "$k" "$v" ;;
    health_interval:60|health_interval:300|health_interval:900|health_interval:3600) rw; conf_set health_interval "$v"; ro; ok "$k" "$v" ;;
    *) echo '{"error":"setting or value not allowed"}'; exit 1 ;;
  esac
}
case "${1:-}" in
  get) get ;;
  set) set_key "$2" "$3" ;;
  *) echo '{"error":"usage"}'; exit 1 ;;
esac
