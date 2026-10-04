#!/bin/sh
# Fan control loop (phoenix-fan service). Returns the fan to the firmware when stopped.
. /usr/share/phoenix/platform/platform-lib.sh
trap 'conf_load; p=$(fan_pwm); [ -n "$p" ] && echo 2 > "${p}_enable" 2>/dev/null; exit 0' TERM INT
while :; do fan_step; conf_load; [ "$fan_mode" = bios ] && exit 0; sleep 3; done
