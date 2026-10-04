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

## Dell dead-battery throttling (found 17:05)
The Vostro's battery has failed. With a dead battery the Dell BIOS caps the CPU at its lowest P-state
(800 MHz, PERF_STATUS ratio 8 while Linux requests 29) **and** sets T-state clock modulation to 1/8
duty on 3 of 4 threads: effective ~418 MHz. All runs above were made in that state.
Override (live, test): clear MSR 0x19A on all CPUs and BD_PROCHOT (MSR 0x1FC bit 0); speed went to
2.7 GHz but the CPU hit 99 °C (degraded heatsink/paste; 82 °C even when throttled). Capped at
1.8 GHz (no turbo): 93-95 °C under load. Charger: 130 W Dell (ample).

| Test | Before | Perf mode | Perf + Sandy Bridge kernel + unthrottled @1.8 GHz (17:08) |
|---|---|---|---|
| 2M system calls | 4420 ms | 1845 ms | **696 ms** |
| 400 process start-ups | 2726 ms | 1667 ms | **568 ms** |
| 200 MB through pipes | 798 ms | 1007 ms | **346 ms** |
| 1 GB fresh memory | 5146 ms | 3762 ms | **1035 ms** |

The last column mixes the kernel change with a 4.3x clock increase, so the kernel's own effect is not
separable here; measure stock vs Sandy Bridge kernel at equal clocks after the battery/cooling repair.
