# Vostro 3550 (i5-2410M Sandy Bridge): performance mode benchmark

`build/bench.sh`, best of 3 per test, run over SSH on the live machine (desktop in use).

| Test | Before (16:53, load 8.6) | After, busy (16:02, load 19) | After, calm (16:56, load 5.5) |
|---|---|---|---|
| 2M system calls (dd bs=1) | 4420 ms | 2423 ms | **1845 ms** (2.4x faster) |
| 400 process start-ups | 2726 ms | 3250 ms | **1667 ms** (39% faster) |
| 200 MB through pipes | 798 ms | 1875 ms | 1007 ms (noise: CPU-throughput test under 70% pressure) |
| 1 GB fresh memory (zero → pipe) | 5146 ms | 4263 ms | **3762 ms** (27% faster) |

Performance mode = `mitigations=off init_on_alloc=0 nowatchdog` (Spectre v2: "Vulnerable").
Kernel-entry-heavy work (syscalls, process creation, page faults) benefits most, which is what
web pages and apps do constantly. VM-exit and ARCVM CPU numbers vary with what Android is doing and
are not comparable between runs. Raw files: bench-vostro-*.txt.
