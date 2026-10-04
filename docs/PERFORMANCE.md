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
