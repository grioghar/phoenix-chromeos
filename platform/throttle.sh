#!/bin/sh
# Phoenix throttle override + thermal guard (phoenix-throttle service). Two independent settings:
#   throttle_override=on|off   undo firmware throttling (below)
#   thermal_guard=on|off       temperature-based speed control: thermal_limit (C), thermal_hysteresis (C),
#                              thermal_step (MHz), thermal_poll (s)
#
# Some firmware (notably Dell with a failed battery or an unrecognised charger) slows the CPU far
# below its normal minimum: it asserts BD PROCHOT and/or sets T-state clock modulation (duty
# cycling), e.g. 1/8 duty at 800 MHz = ~100-400 MHz effective. When throttle_override=on this loop
#   1. clears clock modulation (MSR 0x19A) and the BD PROCHOT enable (MSR 0x1FC bit 0) whenever the
#      firmware sets them (it can re-apply them at any time),
#   2. guards the temperature: steps the CPU's maximum frequency down when the package is above
#      thermal_limit (default 90 C) and back up when it is 5 C below, so badly cooled machines stay
#      safe without a fixed cap. The CPU's own TCC protection at TjMax always remains active.
# Machines whose firmware does not throttle are left untouched (nothing to clear).
. /usr/share/phoenix/platform/platform-lib.sh
TAG=phoenix-throttle
modprobe msr 2>/dev/null
rd(){ dd if=/dev/cpu/$2/msr bs=8 count=1 skip=$1 iflag=skip_bytes 2>/dev/null | od -An -tu8 | tr -d ' '; }
wr(){ v=$2 b=""; for i in 0 1 2 3 4 5 6 7; do b="$b\\$(printf %03o $(( (v >> (8*i)) & 255 )))"; done
      printf "$b" | dd of=/dev/cpu/$3/msr bs=8 count=1 seek=$1 oflag=seek_bytes conv=notrunc 2>/dev/null; }
cpus(){ ls -d /sys/devices/system/cpu/cpu[0-9]* | sed 's#.*/cpu##'; }
pkg_temp(){ t=0; for z in /sys/class/thermal/thermal_zone*; do
  case "$(cat $z/type)" in x86_pkg_temp|acpitz) v=$(( $(cat $z/temp) / 1000 )); [ $v -gt $t ] && t=$v;; esac; done; echo $t; }
POL=/sys/devices/system/cpu/cpufreq
HW_MAX=$(cat $POL/policy0/cpuinfo_max_freq 2>/dev/null); HW_MIN=$(cat $POL/policy0/cpuinfo_min_freq 2>/dev/null)
cleared=0
while :; do
  conf_load
  # 1. undo firmware throttling
  if [ "$throttle_override" = on ]; then
    for c in $(cpus); do
      m=$(rd $((0x19A)) $c); [ -n "$m" ] && [ "$m" != 0 ] && { wr $((0x19A)) 0 $c; cleared=$((cleared + 1)); }
      p=$(rd $((0x1FC)) $c); [ -n "$p" ] && [ $(( p & 1 )) = 1 ] && wr $((0x1FC)) $(( p & ~1 )) $c
    done
    [ $cleared -gt 0 ] && { logger -t $TAG "cleared firmware clock modulation ($cleared)"; cleared=0; }
  fi
  # 2. thermal guard: step the maximum frequency down above the limit, back up below limit - hysteresis
  if [ "$thermal_guard" = on ] && [ -n "$HW_MAX" ]; then
    t=$(pkg_temp); lim=${thermal_limit:-90};   # conf_load fills in this CPU's default hys=${thermal_hysteresis:-5}; step=$(( ${thermal_step:-100} * 1000 ))
    cur=$(cat $POL/policy0/scaling_max_freq)
    if [ $t -ge $lim ] && [ $cur -gt $HW_MIN ]; then new=$(( cur - step ))
    elif [ $t -le $(( lim - hys )) ] && [ $cur -lt $HW_MAX ]; then new=$(( cur + step ))
    else new=$cur; fi
    [ $new -lt $HW_MIN ] && new=$HW_MIN; [ $new -gt $HW_MAX ] && new=$HW_MAX
    [ $new != $cur ] && for p in $POL/policy*; do echo $new > $p/scaling_max_freq; done
  elif [ "$thermal_guard" != on ] && [ -n "$HW_MAX" ] && [ "$(cat $POL/policy0/scaling_max_freq)" != "$HW_MAX" ] && [ -f /run/phoenix-thermal-active ]; then
    for p in $POL/policy*; do echo $HW_MAX > $p/scaling_max_freq; done   # guard switched off: lift its cap
  fi
  [ "$thermal_guard" = on ] && touch /run/phoenix-thermal-active || rm -f /run/phoenix-thermal-active
  [ "$throttle_override" = on ] || [ "$thermal_guard" = on ] || { sleep 30; continue; }
  sleep ${thermal_poll:-3}
done
