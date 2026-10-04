#!/bin/sh
# Run by the phoenix-health service: status server + health check every minute.
. /usr/share/phoenix/platform/platform-lib.sh
mkdir -p /run/phoenix
/usr/share/phoenix/desktop/phoenix-statusd 8098 "$(cat /usr/share/phoenix/desktop/extension-id.txt)" &
trap 'kill $! 2>/dev/null' EXIT TERM
while :; do
  conf_load
  echo "{\"interval\":${health_interval:-300}}" > /run/phoenix/health-config.json
  sh /usr/share/phoenix/platform/health.sh --json /run/phoenix/health.json
  kill -0 $! 2>/dev/null || { /usr/share/phoenix/desktop/phoenix-statusd 8098 "$(cat /usr/share/phoenix/desktop/extension-id.txt)" & }
  sleep 60
done
