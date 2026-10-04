#!/bin/sh
# Phoenix micro-benchmark: the costs that performance mode (mitigations=off init_on_alloc=0
# nowatchdog) changes. Each test runs 3 times; the best (fastest) run is reported, which keeps
# background activity from skewing the result. POSIX sh + coreutils only (runs on ChromeOS as root).
#   bench.sh [label]   -> prints key=value lines (append to a file to compare runs)
LABEL=${1:-run}
now(){ date +%s%N; }
best(){ # best of 3: prints the smallest elapsed ms of "$@"
  b=0; for i in 1 2 3; do t0=$(now); "$@" >/dev/null 2>&1; t=$(( ($(now) - t0) / 1000000 )); { [ $b = 0 ] || [ $t -lt $b ]; } && b=$t; done; echo $b; }
syscalls(){ dd if=/dev/zero of=/dev/null bs=1 count=1000000; }          # ~2M read/write syscalls
forks(){ i=0; while [ $i -lt 400 ]; do /bin/true; i=$((i+1)); done; }      # 400 process start-ups
pipes(){ yes | head -c 200000000 | cat > /dev/null; }                    # 200 MB through 2 pipes
memtouch(){ head -c 1073741824 /dev/zero | tail -c 1 >/dev/null; }      # 1 GB through new buffers
vmexits(){ T=/sys/kernel/debug/tracing; [ -d $T ] || T=/sys/kernel/tracing
  K=/sys/kernel/debug/kvm; a=$(cat $K/exits 2>/dev/null || echo 0); sleep 5; b=$(cat $K/exits 2>/dev/null || echo 0); echo $(( (b - a) / 5 )); }
vmcpu(){ # the crosvm process that owns the vCPU threads
  p=""; for t in /proc/[0-9]*/task/*/comm; do [ "$(cat $t 2>/dev/null)" = crosvm_vcpu0 ] && { p=${t#/proc/}; p=${p%%/*}; break; }; done
  [ -n "$p" ] || { echo -; return; }
  a=$(awk '{print $14+$15}' /proc/$p/stat); sleep 5; b=$(awk '{print $14+$15}' /proc/$p/stat); echo $(( (b - a) / 5 )); }

echo "label=$LABEL"
echo "time=$(date '+%F %T')"
echo "kernel=$(uname -r)"
echo "cmdline_perf=$(tr ' ' '\n' < /proc/cmdline | grep -E '^(mitigations|init_on_alloc|nowatchdog)' | tr '\n' ' ')"
echo "spectre_v2=$(cat /sys/devices/system/cpu/vulnerabilities/spectre_v2 2>/dev/null | cut -c1-60)"
echo "load_before=$(cut -d' ' -f1 /proc/loadavg)"
echo "syscalls_2M_ms=$(best syscalls)"
echo "forks_400_ms=$(best forks)"
echo "pipes_200MB_ms=$(best pipes)"
echo "memtouch_1GB_ms=$(best memtouch)"
echo "vm_exits_per_s=$(vmexits)"
echo "vm_cpu_pct=$(vmcpu)"
echo "cpu_pressure=$(head -1 /proc/pressure/cpu | sed 's/ total=.*//')"
