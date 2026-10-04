# Phoenix status / handoff (2026-10-04)

Read with: README.md, docs/HOWTO.md, docs/ARCHITECTURE.md, docs/FINDINGS.md, docs/PERFORMANCE.md.

## Reference machine: Dell Vostro 3750 (192.168.1.76; firmware says "Dell System Vostro 3750" — long assumed to be a 3550)
- ChromeOS R150 16700.65.0 **LTC channel** (rammus) on Brunch r150, installed on the internal HDD,
  BIOS boot via Phoenix's GRUB i386-pc layer + hybrid MBR. Play Store works.
- Running: Flex Rust binaries + crocus Mesa, crosvm with `libkvm_movbe.so` (MOVBE in guest CPUID,
  AVX/FMA/F16C hidden → MOVBE emulation went from 40-140k/s to ~32/s), patched Android images
  (RDRAND→clc, OpenGL instead of Vulkan), native ALPS touchpad (`phoenix touchpad alps`).
- `phoenix` CLI installed; **remote access ON**: from the Mac, `ssh vostro` (root, key
  ~/.ssh/phoenix_vostro, only from 192.168.1.119, port 2222). Turn off: `phoenix remote off`.
- **2026-10-04 17:00: verified on real hardware**: performance mode (syscalls 2.4x, forks 39%,
  memory 27% faster: research/bench-vostro.md), `phoenix save` + Brunch hook, and the Sandy Bridge
  kernel `6.12.91-phoenix-sandybridge` via `phoenix kernel install`. The kernel switch triggered a
  full Brunch rebuild and the hook restored all fixes (patched crosvm byte-identical, shim, crocus,
  Android) in ~9 s; Dell platform modules (dell_smm_hwmon, dell_laptop, dell_wmi) load at boot.
- Not yet applied on the Vostro: `phoenix touchpad tune` (pointer jumps on two-finger scroll),
  `phoenix upgrade` (boot screen).
- Slowness root cause found 2026-10-04 15:10: the **Claude Android app** re-rendering a very long
  conversation (constant GC, skipped frames) keeps ARCVM's 4 vCPUs busy; ARCVM re-arms the
  TSC-deadline timer ~10k/s (no APICv on Sandy Bridge → every re-arm is a VM exit). Memory is fine.
  Tried live and reverted (no help): halt_poll_ns=0, arcvm-vcpus shares 256 / quota 1 CPU,
  vmentry_l1d_flush=never. Advice given: use claude.ai in Chrome instead of the Android app.

## Build server: dockervm (VM 101 on pve1; 16 cores / 24 GB; extra 200 GB disk at /root/phoenix-archive)
- Repo copy: /root/phoenix (rsync from ~/phoenix-chromeos). Brunch fork copy: /root/brunch-fork.
- Services: `phoenix-server` (port 8099, serves scripts/blobs, diagnostics, hardware reports),
  timers `phoenix-issue-sync` (daily GitHub hardware-report intake → /root/phoenix-intake),
  `phoenix-archive` (daily, build/archive.py). `phoenix-bundles` timer NOT installed yet.
- Built: Sandy Bridge kernel `6.12.91-phoenix-sandybridge` in /root/brunch-build/kernels-out
  (not yet installed anywhere; needs a `phoenix kernel` command + GRUB fallback entry).
- Release `phoenix-r150-3e129ef` published for `phoenix upgrade` (/root/phoenix-release/current).

## Open problems / next steps
1. ~~Bundle pipeline~~ **DONE 2026-10-04**: build/make-bundle.sh builds 16700.65.0 (1.1 GB); verified
   against the live Vostro: crosvm byte-identical (patched), all Flex files identical, Android
   libcrypto patch identical, Vulkan off. Fixed on the way: Docker scratch on overlay, unpatched
   crosvm, two concatenated archives (plain tar skipped the Android images), pipefail+grep -q.
   Bundles served at /bundle/<version>.tar; daily timer phoenix-bundles installed.
2. ~~Device-side update watcher~~ **DONE**: platform/update-watch.sh + phoenix-update service (every
   10 min): fetches /bundle/<new version> before reboot, or HOLDS the update (KERN-B priority → 0,
   restored when the bundle exists). Simulated hold/release/download on a test disk; on the Vostro
   only the idle path ran (service not yet installed there: comes with `phoenix fix`).
3. ~~Archive~~ **DONE**: Google lists the SHA-1/MD5 of the .zip (not the image inside); fixed.
   /root/phoenix-archive holds verified rammus + Flex recovery zips (LTC, LTR, stable) and Brunch
   r149-r152; daily timer phoenix-archive.
4. **BIOS boot in the Brunch fork** (commits 7b92645..a591a8f, local only, NOT pushed): never
   boot-tested; agent limited it to block devices (must also work for image files). Test in QEMU
   (SeaBIOS + OVMF) before pushing; then upstream PR drafts in docs/upstream/ (ask the user first).
5. **CPU audit** (agent output, uncommitted: build/cpu-audit*.sh, research/cpu-audit/,
   docs/COMPATIBILITY.md): its "RDSEED in libart" and "7,335 BMI" findings were FALSE (substring
   matching, e.g. andnps). Redo with exact mnemonic matching before publishing COMPATIBILITY.md.
6. **Desktop/motherboard research**: an agent was compiling research/desktops.json and
   boards.json; its helpers wrote stray files to ~/grio-co-resume (boards.json, BOARDS_SUMMARY.md)
   and the scratchpad (hp_models.json etc.) — clean up; validate DMI strings (Dell Inc., LENOVO) and
   drop pre-SSE4.2 boards (e.g. P5Q Pro) before gen-profiles.py.
7. **Installer images** (user requirement): an offline USB and a net-install USB built around a
   small standalone installer with a text menu (Ethernet/Wi-Fi, detect, profile, generic build or
   on-device optimized kernel). Phoenix images must NOT contain Google images; the USB-creation
   step downloads them (or takes them from the archive) and adds them to the stick.
8. ARCVM load on pre-APICv CPUs: consider giving ARCVM 2 vCPUs on 2-core machines, and test
   performance mode (`phoenix platform perf on`) on the Vostro.
9. GitHub token for automatic issue creation: user still needs to create it
   (/root/phoenix-secrets/github-token on dockervm).

## Conventions
- Keep README.md and docs/HOWTO.md updated with every change. Commit author: grioghar
  <24253506+grioghar@users.noreply.github.com>. Nothing goes to sebanc/brunch without the user's OK.
- ChromeOS quirks: no `su`; /tmp is noexec for scripts (run downloaded scripts with `sh -c "$t"`);
  crosh shell has no_new_privs (use VT2 or `phoenix rootshell on`); `pkill -f` must use `[p]attern`
  over ssh; overlay scratch dirs must not be on overlayfs.
