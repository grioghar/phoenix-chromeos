#!/bin/sh
# Phoenix platform library: catalog matching, module/CPU/fan control. Sourced by the boot service,
# the `phoenix platform` tool and the installer. POSIX sh.
#
# Configuration: /etc/phoenix/platform.conf (key=value, sourced):
#   modules="dell-smm-hwmon dell-laptop"   platform modules to load at boot
#   opt_<module_with_underscores>="..."    module options (e.g. opt_dell_smm_hwmon="ignore_dmi=1")
#   cpu_profile=balanced|performance|quiet
#   fan_mode=bios|auto|quiet|max           bios = leave the fan to the firmware
#   io_tuning=auto|off                     disk scheduler/read-ahead by disk type
#   performance_mode=off|on                boot options trading hardening for speed (needs reboot)
#   android_animations=1|0.5|0             Android animation speed (0.5 = twice as fast)
#   maintenance=on|off (+ maintenance_trim/_crashes/_crash_days/_android/_logs)   daily upkeep
#   throttle_override=on|off             undo firmware throttling (dead battery, unrecognised charger)
#   thermal_guard=on|off, thermal_limit=90, thermal_hysteresis=5, thermal_step=100 (MHz), thermal_poll=3 (s)
#                                        temperature-based speed control

PHOENIX_SHARE=${PHOENIX_SHARE:-/usr/share/phoenix}
PLATFORM_CONF=${PLATFORM_CONF:-/etc/phoenix/platform.conf}
CATALOG=${CATALOG:-$PHOENIX_SHARE/platform/catalog.conf}

# ---------------------------------------------------------------- profile + catalog
# profile_get KEY: value from the detection profile (cached in $PHX_PROFILE)
profile_get(){
  [ -n "${PHX_PROFILE:-}" ] || PHX_PROFILE=$(PHOENIX_PROFILES=$PHOENIX_SHARE/profiles sh "$PHOENIX_SHARE/detect/phoenix-detect.sh" 2>/dev/null)
  printf '%s\n' "$PHX_PROFILE" | sed -n "s/^$1=//p" | head -1
}
# catalog_lines: "module|match|description|options" without comments, fields trimmed
catalog_lines(){ grep -v '^[[:space:]]*#' "$CATALOG" | grep '|' | sed 's/[[:space:]]*|[[:space:]]*/|/g; s/[[:space:]]*$//'; }
# rx_any VALUE "re1,re2": 0 if VALUE matches any of the comma-separated regexes (case-insensitive)
rx_any(){ echo "$1" | grep -Eiq "$(echo "$2" | sed 's/,/|/g')"; }
# match_terms "vendor=^Dell chassis=laptop": 0 if this machine matches every term
match_terms(){
  v=$(profile_get machine.vendor); m=$(profile_get machine.model); c=$(profile_get cpu.vendor); ch=$(profile_get machine.chassis)
  for t in $1; do
    case "$t" in
      always) ;;
      vendor=*)  rx_any "$v"  "${t#vendor=}"  || return 1 ;;
      model=*)   rx_any "$m"  "${t#model=}"   || return 1 ;;
      !model=*)  rx_any "$m"  "${t#!model=}"  && return 1 ;;
      chassis=*) rx_any "$ch" "${t#chassis=}" || return 1 ;;
      cpu=Intel) [ "$c" = GenuineIntel ] || return 1 ;;
      cpu=AMD)   [ "$c" = AuthenticAMD ] || return 1 ;;
      *) return 1 ;;
    esac
  done; return 0
}
# recommended_modules: catalog modules matching this machine (plus the model profile's list)
recommended_modules(){
  { catalog_lines | while IFS='|' read -r mod match desc opts; do match_terms "$match" && echo "$mod"; done
    pm=$(profile_get profile.modules); for x in $pm; do echo "$x"; done; } | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//'
}
catalog_field(){ catalog_lines | awk -F'|' -v m="$1" -v f="$2" '$1 == m {print $f; exit}'; }
module_available(){ modprobe -n "$1" >/dev/null 2>&1 || [ -d "/sys/module/$(echo "$1" | tr - _)" ]; }
module_loaded(){ [ -d "/sys/module/$(echo "$1" | tr - _)" ]; }

# ---------------------------------------------------------------- config
conf_load(){
  modules=""; cpu_profile=balanced; fan_mode=bios; io_tuning=auto; performance_mode=off; android_animations=1
  # daily maintenance (platform/maintain.sh); ChromeOS already TRIMs SSDs and rotates logs
  throttle_override=on; thermal_guard=on; thermal_limit=""; thermal_hysteresis=5; thermal_step=100; thermal_poll=3   # platform/throttle.sh
  health_interval=300   # Phoenix Health extension refresh (s)
  maintenance=on; maintenance_trim=off; maintenance_crashes=on; maintenance_crash_days=7; maintenance_android=on; maintenance_logs=off
  [ -r "$PLATFORM_CONF" ] && . "$PLATFORM_CONF"
  [ -n "$thermal_limit" ] || thermal_limit=${PHX_THERMAL_DEFAULT:=$(thermal_default)}   # this CPU's default
}
# thermal_default: the guard's default limit for THIS CPU (°C), in order of trust:
#   1. platform/cpu-thermal.conf (researched per family: "regex|limit|tjmax|family")
#   2. TjMax the CPU reports via coretemp (temp*_crit) - 5
#   3. TjMax from MSR 0x1A2 (IA32_TEMPERATURE_TARGET bits 23:16) - 5
#   4. 90
thermal_default(){
  model=$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | sed 's/^[^:]*: //')
  T=$PHOENIX_SHARE/platform/cpu-thermal.conf
  if [ -r "$T" ] && [ -n "$model" ]; then
    l=$(grep -v '^#' "$T" | while IFS='|' read -r rx lim tj fam; do
          [ -n "$lim" ] && echo "$model" | grep -Eiq "$rx" && { echo "$lim"; break; }; done)
    [ -n "$l" ] && { echo "$l"; return; }
  fi
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat $h/name 2>/dev/null)" = coretemp ] || continue
    c=$(cat $h/temp1_crit 2>/dev/null) && [ -n "$c" ] && { echo $(( c / 1000 - 5 )); return; }
  done
  if modprobe msr 2>/dev/null; [ -r /dev/cpu/0/msr ]; then
    v=$(dd if=/dev/cpu/0/msr bs=8 count=1 skip=$((0x1A2)) iflag=skip_bytes 2>/dev/null | od -An -tu8 | tr -d ' ')
    tj=$(( (${v:-0} >> 16) & 255 )); [ $tj -ge 60 ] && [ $tj -le 110 ] && { echo $(( tj - 5 )); return; }
  fi
  echo 90
}
thermal_source(){   # where the default came from (for status)
  [ -n "$(grep -s '^thermal_limit=' "$PLATFORM_CONF")" ] && { echo "set by you"; return; }
  echo "this CPU's default"; }
# conf_default: a new config for this machine (recommended modules + catalog/profile options)
conf_default(){
  echo "# Phoenix platform configuration (see: phoenix platform)"
  echo "modules=\"$(recommended_modules)\""
  for mod in $(recommended_modules); do
    o=$(profile_get "profile.opt_$(echo "$mod" | tr - _)"); [ -n "$o" ] || o=$(catalog_field "$mod" 4)
    [ -n "$o" ] && echo "opt_$(echo "$mod" | tr - _)=\"$o\""
  done
  echo "cpu_profile=$(profile_get profile.cpu_profile | grep . || echo balanced)"
  echo "fan_mode=$(profile_get profile.fan_mode | grep . || echo bios)"
}
# conf_set KEY VALUE (rewrites the line, or appends it)
conf_set(){
  mkdir -p "$(dirname "$PLATFORM_CONF")"; touch "$PLATFORM_CONF"
  grep -v "^$1=" "$PLATFORM_CONF" > "$PLATFORM_CONF.new" || true
  echo "$1=\"$2\"" >> "$PLATFORM_CONF.new"; mv -f "$PLATFORM_CONF.new" "$PLATFORM_CONF"
}

# ---------------------------------------------------------------- apply
apply_modules(){
  conf_load
  for mod in $modules; do
    module_loaded "$mod" && continue
    eval "o=\${opt_$(echo "$mod" | tr - _):-}"
    # shellcheck disable=SC2086
    if modprobe "$mod" $o 2>/dev/null; then echo "loaded $mod $o"; else echo "could not load $mod"; fi
  done
}
cpu_policies(){ ls -d /sys/devices/system/cpu/cpufreq/policy* 2>/dev/null; }
apply_cpu(){
  conf_load
  drv=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)
  for p in $(cpu_policies); do
    max=$(cat "$p/cpuinfo_max_freq"); min=$(cat "$p/cpuinfo_min_freq")
    case "$cpu_profile" in
      performance) gov=performance; cap=$max ;;
      quiet)       gov=powersave;   cap=$(( min + (max - min) * 6 / 10 )) ;;   # 60% of the range: cooler, quieter
      *)           gov=; cap=$max ;;                                          # balanced: leave the default governor
    esac
    case "$drv" in intel_pstate|amd-pstate*) [ "$gov" = performance ] || gov=powersave ;; esac
    [ -n "$gov" ] && grep -qw "$gov" "$p/scaling_available_governors" 2>/dev/null && echo "$gov" > "$p/scaling_governor"
    echo "$cap" > "$p/scaling_max_freq" 2>/dev/null
  done
  echo "cpu profile: $cpu_profile ($drv)"
}

# ---------------------------------------------------------------- sensors and fans
hwmon_dirs(){ for h in /sys/class/hwmon/hwmon*; do [ -r "$h/name" ] && echo "$h"; done; return 0; }
max_temp_c(){ t=0; for f in /sys/class/hwmon/hwmon*/temp*_input; do [ -r "$f" ] || continue; v=$(( $(cat "$f") / 1000 )); [ $v -gt $t ] && t=$v; done; echo $t; }
fan_pwm(){ for f in /sys/class/hwmon/hwmon*/pwm1; do [ -w "$f" ] && { echo "$f"; return 0; }; done; return 0; }
sensors_report(){
  for h in $(hwmon_dirs); do
    n=$(cat "$h/name"); line=""
    for f in "$h"/temp*_input; do [ -r "$f" ] || continue
      l=$(cat "${f%_input}_label" 2>/dev/null || basename "${f%_input}"); line="$line $l $(( $(cat "$f") / 1000 ))C,"; done
    for f in "$h"/fan*_input; do [ -r "$f" ] || continue; line="$line $(basename "${f%_input}") $(cat "$f") rpm,"; done
    [ -n "$line" ] && echo "  $n:${line%,}"
  done
}
# fan_step: one control step for the fan service (called every few seconds)
fan_step(){
  conf_load; pwm=$(fan_pwm); [ -n "$pwm" ] || return 0
  en="${pwm}_enable"
  if [ "$fan_mode" = bios ]; then [ -w "$en" ] && echo 2 > "$en" 2>/dev/null; return 0; fi
  [ -w "$en" ] && echo 1 > "$en" 2>/dev/null
  t=$(max_temp_c)
  case "$fan_mode" in
    max)   v=255 ;;
    quiet) if [ $t -ge 80 ]; then v=255; elif [ $t -ge 65 ]; then v=128; else v=0; fi ;;
    *)     if [ $t -ge 72 ]; then v=255; elif [ $t -ge 55 ]; then v=128; else v=0; fi ;;   # auto
  esac
  echo $v > "$pwm" 2>/dev/null
}

# ---------------------------------------------------------------- speed tuning
# Disks: BFQ keeps the desktop responsive on spinning disks under load; SSDs use mq-deadline.
apply_io(){
  conf_load; [ "$io_tuning" = off ] && return 0
  for q in /sys/block/sd*/queue /sys/block/nvme*/queue /sys/block/mmcblk*/queue; do
    [ -w "$q/scheduler" ] || continue
    if [ "$(cat $q/rotational)" = 1 ]; then s=bfq; ra=1024; else s=mq-deadline; ra=256; fi
    grep -qw "$s" "$q/scheduler" && echo "$s" > "$q/scheduler" 2>/dev/null
    echo "$ra" > "$q/read_ahead_kb" 2>/dev/null
    echo "$(basename "$(dirname "$q")"): $s, read-ahead ${ra} KB"
  done
  # write back dirty pages sooner on slow disks: shorter stalls when memory fills
  sysctl -q -w vm.dirty_background_ratio=5 vm.dirty_ratio=15 2>/dev/null || true
}
# Performance mode: kernel options in Brunch's settings.cfg (EFI partition), applied at next boot.
#   mitigations=off   no CPU-vulnerability workarounds (big win on pre-2018 Intel, esp. for the Android VM)
#   init_on_alloc=0   don't zero every memory allocation
#   nowatchdog        no lockup-detector timers
PERF_PARAMS="mitigations=off init_on_alloc=0 nowatchdog"
settings_cfg(){   # mount the EFI partition of the boot disk and run "$@" on settings.cfg
  d=$(rootdev -d -s 2>/dev/null); case "$d" in *[0-9]) e=${d}p12;; *) e=${d}12;; esac
  mkdir -p /tmp/phoenix-efi; mount "$e" /tmp/phoenix-efi || return 1
  "$@" /tmp/phoenix-efi/efi/boot/settings.cfg; r=$?; sync; umount /tmp/phoenix-efi; return $r
}
_perf_edit(){   # $1=on|off  $2=settings.cfg
  cur=$(sed -n 's/^cmdline_params="\(.*\)"$/\1/p' "$2"); new=""
  for w in $cur; do case " $PERF_PARAMS " in *" $w "*) ;; *) new="$new $w";; esac; done
  [ "$1" = on ] && new="$new $PERF_PARAMS"
  new=$(echo $new); sed -i "s|^cmdline_params=.*|cmdline_params=\"$new\"|" "$2"; echo "boot options: $new"
}
apply_perf_mode(){ conf_load; settings_cfg _perf_edit "$performance_mode"; }
perf_mode_active(){ for p in $PERF_PARAMS; do grep -qw "$p" /proc/cmdline || return 1; done; }
# Android: animation speed through the Android VM's settings (kept by Android across reboots)
apply_android(){
  conf_load; command -v android-sh >/dev/null || return 0
  for k in window_animation_scale transition_animation_scale animator_duration_scale; do
    timeout 20 android-sh -c "settings put global $k $android_animations" >/dev/null 2>&1 || return 0
  done; echo "android animations: $android_animations"
}

# daily maintenance service (platform/maintain.sh via phoenix-maintain)
apply_maintain(){
  conf_load
  if [ "$maintenance" = on ]; then start phoenix-maintain 2>/dev/null || true; echo "maintenance: on"
  else stop phoenix-maintain 2>/dev/null || true; echo "maintenance: off"; fi
}

# firmware throttle override + thermal guard (platform/throttle.sh via phoenix-throttle)
apply_throttle(){
  conf_load
  if [ "$throttle_override" = on ] || [ "$thermal_guard" = on ]; then start phoenix-throttle 2>/dev/null || true
  else stop phoenix-throttle 2>/dev/null || true
       for p in /sys/devices/system/cpu/cpufreq/policy*; do cat $p/cpuinfo_max_freq > $p/scaling_max_freq 2>/dev/null; done; fi
  echo "throttle override: $throttle_override   thermal guard: $thermal_guard (limit ${thermal_limit} C, hysteresis ${thermal_hysteresis} C, step ${thermal_step} MHz, every ${thermal_poll} s)"
}
