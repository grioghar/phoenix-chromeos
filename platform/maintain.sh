#!/bin/sh
# Phoenix maintenance: keep an old ChromeOS machine fresh and responsive.
# Idempotent, safe, logs what it does, never deletes user files.
# Sourced by the phoenix-maintain service (upstart loop) or run manually.
#
# Most maintenance runs automatically on ChromeOS (TRIM, log rotation, memory reclaim).
# We add optional user-controlled cleanup and health reporting.
#
# Maintenance tasks (all optional, controlled by maintenance_* settings):
#   - TRIM: Run fstrim on SSDs (data-safe, reduces GC pauses; ChromeOS already does this every 6h)
#   - Crash dumps: Remove old crashes, keep recent ones (safe, system already limits to 32)
#   - Android cache: Trim app caches when ARC is running (reversible, apps rebuild on use)
#   - Health reporting: Disk and memory pressure warnings
#
# Reference: ChromeOS automatically handles log rotation, memory pressure reclaim (resourced),
# swap management, and crash dump limiting. We don't duplicate those efforts.

. /usr/share/phoenix/platform/platform-lib.sh

LOG_TAG="phoenix-maintain"

# ---------------------------------------------------------------- TRIM (SSD maintenance)
# ChromeOS already runs fstrim automatically every 6 hours via trim.conf.
# This supplements that: optional on-demand TRIM runs or user-initiated cleanup.
#
# Why it's safe: TRIM only marks blocks as reusable without touching data.
# When to use: Keep enabled; will run periodically to keep SSD responsive.
do_trim(){
  [ "$maintenance_trim" != on ] && return 0
  had_work=0
  for q in /sys/block/sd*/queue /sys/block/nvme*/queue /sys/block/mmcblk*/queue; do
    [ -r "$q/discard_max_hw_bytes" ] || continue
    dev=$(basename "$(dirname "$q")")
    rotational=$(cat "$q/rotational" 2>/dev/null)
    [ "$rotational" = 1 ] && continue  # spinning disks don't support TRIM

    discard_size=$(cat "$q/discard_max_hw_bytes")
    if [ "$discard_size" -gt 0 ] && command -v fstrim >/dev/null 2>&1; then
      fstrim -a 2>&1 | logger -t "$LOG_TAG" -p user.info
      had_work=1
    fi
  done
  [ $had_work = 1 ] && echo "TRIM executed" | logger -t "$LOG_TAG"
}

# ---------------------------------------------------------------- Crash dumps (safe cleanup)
# ChromeOS auto-limits crashes to 32 per directory via the crash_reporter system.
# We supplement with age-based cleanup to prevent disk space from accumulating.
#
# Why it's safe: Only removes old crash files (.dmp, .log); doesn't affect future collection.
# Keep recent crashes for debugging (default: 7 days). Reference: crash-reporting FAQ.
do_clean_crashes(){
  [ "$maintenance_crashes" != on ] && return 0
  max_age=${maintenance_crash_days:-7}
  total_cleaned=0
  for dir in /var/spool/crash /home/chronos/user/crash /home/chronos/crash; do
    [ -d "$dir" ] || continue
    count=$(find "$dir" -maxdepth 1 -type f \( -name "*.dmp" -o -name "*.log" \) -mtime +$max_age 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
      find "$dir" -maxdepth 1 -type f \( -name "*.dmp" -o -name "*.log" \) -mtime +$max_age -delete 2>/dev/null || true
      total_cleaned=$((total_cleaned + count))
    fi
  done
  [ $total_cleaned -gt 0 ] && echo "Cleaned $total_cleaned crash files older than ${max_age} days" | logger -t "$LOG_TAG"
}

# ---------------------------------------------------------------- Android caches (ARC)
# ARCVM WorkingSetTrim already handles automatic app cache reclamation on memory pressure.
# This is optional: manual pm trim-caches for on-demand cache cleanup (safe, reversible).
#
# Why it's safe: Only clears app caches (not app data or user files); apps rebuild on next use.
# When to use: Enable if you want user-initiated cache trimming; don't run continuously.
# Reference: Android ComponentCallbacks2, ARCVM memory management.
do_trim_android(){
  [ "$maintenance_android" != on ] && return 0
  command -v android-sh >/dev/null || return 0

  # Check if ARCVM is running before trimming
  pgrep -f "crosvm.*arc" >/dev/null || return 0

  # Use pm trim-caches to reclaim cache in ARCVM. Safe, reversible, non-destructive.
  # Timeout prevents hangs if Android is unresponsive.
  timeout 30 android-sh -c "pm trim-caches 100M" >/dev/null 2>&1 && \
    echo "Android caches trimmed" | logger -t "$LOG_TAG" || \
    { [ $? -eq 124 ] && echo "Android cache trim timed out" || echo "Android cache trim failed"; } | logger -t "$LOG_TAG"
}

# ---------------------------------------------------------------- Log cleanup (conservative)
# ChromeOS already runs chromeos-cleanup-logs daily via log-rotate.conf.
# That removes logs older than 7 days and manages /var/log size.
#
# This is optional: only runs if maintenance_logs=on (disabled by default because
# ChromeOS already handles it). Use only if additional cleanup is needed.
#
# Why it's safe: Only removes archived log files (not active logs) and Chrome cache.
do_clean_logs(){
  [ "$maintenance_logs" != on ] && return 0

  # Clean old syslog files in /var/log (only those > 14 days old, double the auto-cleanup age).
  # Only touch if file exists; never delete active logs.
  for f in /var/log/messages.? /var/log/syslog.?; do   # rotated copies only, never the live log
    [ -f "$f" ] || continue
    age=$(($(date +%s) - $(stat -c%Y "$f" 2>/dev/null || echo 0)))
    if [ $age -gt 1209600 ]; then  # 14 days in seconds
      rm -f "$f"
      echo "Removed old log: $(basename "$f")" | logger -t "$LOG_TAG"
    fi
  done

  # (Chrome and Google Drive caches are left to ChromeOS: GCache can hold unsynced Drive files.)
}

# ---------------------------------------------------------------- Health reporting
# Report memory, swap and disk health; warn if concerning.
# Helps users spot memory pressure or disk space issues early.
report_health(){
  # Memory and swap status
  if [ -r /proc/meminfo ]; then
    mem_used=$(awk '/MemAvailable/ {available=$2} /MemTotal/ {total=$2} END {printf "%d", (total-available)*100/total}' /proc/meminfo)
    swap_used=$(awk '/SwapTotal/ {total=$2} /SwapFree/ {free=$2} END {used=total-free; printf "%d", used>0 ? used*100/total : 0}' /proc/meminfo 2>/dev/null || echo 0)
    [ $mem_used -gt 85 ] && echo "WARNING: Memory $mem_used% used" | logger -t "$LOG_TAG" -p user.warning
    [ $swap_used -gt 50 ] && echo "WARNING: Swap $swap_used% used (may impact performance)" | logger -t "$LOG_TAG" -p user.warning
    echo "Memory: ${mem_used}% used, Swap: ${swap_used}% used" | logger -t "$LOG_TAG"
  fi

  # Disk health: warn if root or stateful partition low
  for mnt in / /mnt/stateful_partition; do
    [ -d "$mnt" ] || continue
    usage=$(df "$mnt" | tail -1 | awk '{print $5}' | sed 's/%//')
    if [ "$usage" -gt 85 ]; then
      echo "WARNING: Disk $mnt ${usage}% full" | logger -t "$LOG_TAG" -p user.warning
    else
      echo "Disk $mnt: ${usage}% used" | logger -t "$LOG_TAG"
    fi
  done
}

# ---------------------------------------------------------------- Main
# All tasks are optional (controlled by maintenance_* settings in platform.conf).
# Log to syslog for the system journal; report overall health each run.
main(){
  conf_load
  [ "$maintenance" = on ] || { echo "maintenance is off" | logger -t "$LOG_TAG"; return 0; }
  echo "=== Phoenix maintenance started ===" | logger -t "$LOG_TAG"

  do_trim
  do_clean_crashes
  do_trim_android
  do_clean_logs
  report_health

  echo "=== Phoenix maintenance completed ===" | logger -t "$LOG_TAG"
}

[ "$0" != "${0%/*}" ] && [ -z "$1" ] && exit 0  # being sourced, not run
main "$@"
