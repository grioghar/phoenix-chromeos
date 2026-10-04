# Making old machines fast

Phoenix speeds machines up in three layers. Each layer is optional and reversible.

## 1. Runtime tuning (every machine, no rebuild): `phoenix platform`
| Setting | What it does | Default |
|---|---|---|
| Disk tuning | BFQ scheduler + 1 MB read-ahead on spinning disks, mq-deadline on SSDs; earlier dirty-page writeback | on |
| CPU profile | balanced / performance / quiet (governor and frequency cap) | balanced |
| Fan mode | firmware / auto / quiet / max where the hardware allows software control | firmware |
| Android animations | 1 / 0.5 / 0 | 1 |
| Performance mode | boot options `mitigations=off init_on_alloc=0 nowatchdog` | off; asks for confirmation |

Performance mode is the biggest single win on pre-2018 Intel CPUs. The Android VM exits to the
hypervisor constantly, and on those CPUs every exit pays for the Spectre/Meltdown workarounds. It
is a security trade-off, so Phoenix explains it and only turns it on when the user confirms.

## 2. Platform-optimized kernels: `build/build-kernel.sh`
This builds Brunch's own kernel (same sources, patches and config) compiled for one CPU family
(`-march=sandybridge`, `haswell`, `znver1`, ...). Hardening defaults that can be switched back at
boot are relaxed. The kernel gets its own version suffix (`-phoenix-<march>`), so the stock kernel
stays installed as a fallback in the GRUB menu. `--lean <modules.list>` also drops every module
the machine doesn't use (localmodconfig from a `phoenix submit` report, plus a safety set for USB
storage, input, networking and filesystems). That build is much smaller and faster.

Plan for choosing it:
- The installer and `phoenix kernel` offer "optimized kernel for <CPU>". If the build server has
  one for that CPU family, it is installed right away. Otherwise a build is queued on the server
  (hours) and `phoenix fix` installs it when it is ready.
- The boot menu shows both kernels; the stock kernel is always one keypress away.
- Later: an on-device build option for machines that can't reach a build server. It is slow (a
  day or more on a dual-core) but needs no other computer.

## 3. Apps and Android
- Animations faster or off. Disk and CPU tuning also help Android, because it runs on the same
  host.
- Lighter app choices for old machines (documented recommendations, not forced).
- Later: rewrite MOVBE out of the hottest Android libraries. That removes the remaining
  hypervisor-emulation cost on pre-Haswell CPUs.

## 4. Keeping it fresh: Daily maintenance (`phoenix platform maintain`)

Phoenix runs optional daily maintenance tasks to keep old machines responsive. ChromeOS already
handles most cleanup automatically, so these are **supplements** for user control and visibility.

| Task | What it does | Default | Safe to enable |
|---|---|---|---|
| **TRIM** | Runs `fstrim` on SSDs (reduces garbage-collection pauses). ChromeOS already does this every 6 hours automatically; this runs on schedule if enabled. | on | Yes. TRIM only marks blocks as reusable; it doesn't touch data. Only runs on SSDs (rotational=0). |
| **Crash cleanup** | Removes crash dump files older than N days (default: 7). Keeps recent crashes for debugging. ChromeOS auto-limits to 32 crashes per directory. | on | Yes. Only removes old `.dmp` and `.log` files; doesn't affect future crash collection. |
| **Android cache trim** | Runs `pm trim-caches` in ARCVM when it's running. ARCVM already has WorkingSetTrim for automatic cache reclamation on memory pressure. | on | Yes. Only clears app caches (not data); apps rebuild on next use. Don't enable frequent runs; once per day is enough. |
| **Log cleanup** | Removes log files older than 14 days (ChromeOS already rotates daily at 7 days). Only touches archived log files, not active logs. | off | Yes, but usually not needed. ChromeOS already runs `chromeos-cleanup-logs` daily. Enable only if you need extra cleanup. |

**Configure maintenance:**
- `phoenix platform maintain on` / `off` — enable/disable daily maintenance
- `phoenix platform maintain-menu` — interactive menu to toggle individual tasks
- `phoenix platform maintain-now` — run maintenance tasks immediately (for testing)

**Why these defaults:**
- TRIM, crash cleanup, and Android cache trim are on by default because they're safe and benefit old hardware with limited storage/memory.
- Log cleanup is off because ChromeOS already does it; enable only if you want more aggressive cleanup.
- All tasks are fully reversible: disabling simply stops the daily runs.

**How it works:**
- The `phoenix-maintain` upstart service runs daily (background loop, low priority via `nice`).
- Each task is optional and can be toggled independently.
- Health reporting (memory, swap, disk usage) runs with every maintenance cycle and logs warnings if concerning.
- All tasks are idempotent (safe to run multiple times) and never delete user files.

**References:**
- TRIM: [ChromeOS fstrim.conf](https://cos.googlesource.com/third_party/platform2/+/refs/heads/release-R113/trim/init/trim.conf)
- Crash dumps: [ChromeOS crash-reporting FAQ](https://new.chromium.org/chromium-os/packages/crash-reporting/faq)
- Android cache: [Android ComponentCallbacks2](https://developer.android.com/reference/android/content/ComponentCallbacks2), [ARCVM memory management](https://chromium.googlesource.com/chromium/src/+/f9ef487d3e8736e259e1cb11b45e47fee17d48d3)
- Log rotation: [ChromeOS log-rotate.conf](https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/init/upstart/log-rotate.conf)

## Throttle override and thermal guard (`phoenix-throttle` service)

- **Throttle override** (`throttle_override`, default on): some firmware slows the CPU drastically
  when the battery has failed or the charger is not recognised. On a Dell Vostro 3550 with a dead
  battery that meant 800 MHz plus 1/8 duty cycling, about 418 MHz effective. Phoenix clears the
  clock modulation (MSR 0x19A) and BD PROCHOT (MSR 0x1FC bit 0) whenever the firmware sets them.
- **Thermal guard** (`thermal_guard`, default on): steps the maximum CPU frequency down by
  `thermal_step` MHz while the package is at or above `thermal_limit` °C, and back up once it is
  `thermal_hysteresis` °C below. It checks every `thermal_poll` seconds. The CPU's own protection at
  TjMax always stays active.
- The installer points out the override (on by default) and the case where it should be off: a
  weaker replacement charger, where the firmware throttles to protect the charger.
