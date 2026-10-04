#!/bin/sh
# Boot-time apply (run by the phoenix-platform service): modules, CPU profile, fan, and maintenance.
. /usr/share/phoenix/platform/platform-lib.sh
[ -r "$PLATFORM_CONF" ] || conf_default > "$PLATFORM_CONF" 2>/dev/null || true
apply_modules 2>&1 | logger -t phoenix-platform
sleep 1
apply_cpu 2>&1 | logger -t phoenix-platform
apply_io 2>&1 | logger -t phoenix-platform
apply_maintain 2>&1 | logger -t phoenix-platform
apply_throttle 2>&1 | logger -t phoenix-platform
conf_load
[ "$fan_mode" != bios ] && [ -n "$(fan_pwm)" ] && start phoenix-fan 2>/dev/null
exit 0
