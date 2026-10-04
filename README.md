# Phoenix

**ChromeOS with the Google Play Store on older PCs.**

Phoenix is built on [Brunch](https://github.com/sebanc/brunch), which boots official ChromeOS
recovery images on ordinary x86-64 computers. It adds a hardware layer between Brunch and
ChromeOS. That layer recognizes the computer, applies the fixes and drivers that machine needs,
and tunes it for speed. It re-applies all of that after every ChromeOS update.

The goal is to give a 10-year-old laptop a current, fast, Play-Store-capable OS.

> **Status: early, working on the reference machine.** A 2011 Dell Vostro 3550 (Sandy Bridge,
> Intel HD 3000, BIOS-only) runs ChromeOS R150 with the Play Store, installed on its internal drive.
> The general installer, update pipeline and optimized kernels are being built now; see [Roadmap](#roadmap).

## What Phoenix adds on top of Brunch

| Problem on old PCs | What Phoenix does |
|---|---|
| Legacy BIOS only (no UEFI) | Adds BIOS boot: GRUB core in partition 11 plus a hybrid MBR |
| Pre-Haswell CPUs crash ChromeOS's Android VM (MOVBE/BMI) | Swaps in ChromeOS Flex builds of crosvm and the other Rust programs; a CPUID shim lets KVM emulate MOVBE for Android |
| Pre-Ivy Bridge CPUs have no RDRAND (Android won't boot) | Patches Android's BoringSSL to use the kernel's random source |
| Intel Gen4–7 / old AMD GPUs: no Vulkan, no crocus | Transplants Flex's Mesa (crocus); Android draws with OpenGL instead of Vulkan |
| Machine-specific drivers (fans, hotkeys, backlight) | Detects the model and loads its platform modules: `phoenix platform` |
| Slow on old hardware | Disk/CPU/memory tuning, optional performance mode, CPU-optimized kernels |
| Updates undo custom fixes | A Brunch patch hook restores this machine's fixes after every update |
| Text scrolling at boot | A boot screen with status, a progress bar and the detected hardware |
| "Does my laptop work?" | 411 researched machine profiles; `phoenix submit` reports anything missing |

Full details are in [docs/FINDINGS.md](docs/FINDINGS.md), which covers each problem's root
cause and how it was found.

## Quick start

See **[docs/HOWTO.md](docs/HOWTO.md)** for step-by-step instructions: making the USB stick,
installing, first boot, settings, updates and troubleshooting.

On a Phoenix machine, open the console (Ctrl+Alt+F2, log in as `chronos`) and use the `phoenix` command:

```
phoenix fix            bring this machine up to date with Phoenix's fixes
phoenix platform       platform modules, CPU profile, fan, speed settings ("menu" for a menu)
phoenix detect         what Phoenix detects about this computer
phoenix submit         report missing support to the Phoenix project (opens a GitHub issue)
phoenix install        install to the internal drive
phoenix save           keep fixes across ChromeOS updates
phoenix hostname NAME  the name your router sees
phoenix diag           send diagnostics to the Phoenix server
phoenix touchpad tune  stop pointer jumps during two-finger scrolling (ALPS touchpads)
phoenix rootshell on   make phoenix commands work in the browser terminal (run once from the console)
phoenix upgrade        move an existing install to the current Phoenix release
phoenix kernel install use a kernel optimized for this CPU (stock kernel stays in the boot menu)
phoenix update         update the phoenix command
```

Add `-v` to any command to see every step.

## Supported hardware

- **x86-64 CPU with SSE4.2**: Intel Core i3/i5/i7 1st generation (Nehalem, 2008–2010) and newer,
  or AMD Bulldozer/Jaguar (2011) and newer.
- **VT-x / AMD-V** for Android apps. Without it ChromeOS runs, but the Play Store doesn't.
- **Profiles for 411 models**: Dell, Lenovo, HP, Apple, Acer, ASUS, Toshiba, Samsung, Sony, Fujitsu
  and MSI, from about 2009–2017. Listed under [profiles/](profiles/), generated from sourced
  research in [research/](research/).
- Machines without a profile still get generic detection and fixes. Please run `phoenix submit`
  so we can add yours.

## Repository layout

| Path | Contents |
|---|---|
| `detect/` | Hardware detection: machine identity, CPU/GPU/firmware features, needed fixes |
| `profiles/` | Per-model profiles, `<vendor>/<model>.conf` |
| `platform/` | Platform modules catalog, boot-time apply, fan control, speed tuning |
| `cli/` | The `phoenix` command and its subcommands |
| `installer/` | Install to an internal drive (BIOS layer, hostname, platform modules) |
| `hooks/` | Brunch patch hook that restores fixes after updates |
| `boot/` | Boot screen (framebuffer) and initramfs builder |
| `services/` | ChromeOS (upstart) services: hostname, platform, fan |
| `shim/` | crosvm CPUID shim (MOVBE emulation, hides AVX from Android) |
| `build/` | Release builder, Android image patcher, optimized kernel builder, profile generator |
| `server/` | Phoenix server: scripts, components, diagnostics, hardware reports, daily intake |
| `research/` | Sourced hardware research behind the profiles |
| `docs/` | HOWTO, architecture, findings, performance, upstream PR drafts |

The Brunch fork lives at [grioghar/brunch](https://github.com/grioghar/brunch) (branch
`phoenix-r150`). Phoenix releases combine an official Brunch release (kernels, firmware) with
the fork's changes and Phoenix's additions, and are named `phoenix-<brunch base>-<commit>`.

This repository holds scripts and sources only. Google's binaries (ChromeOS recovery and Flex
images, Android images) are downloaded or built on demand, never stored here.

## Roadmap

- [x] Play Store on a Sandy Bridge / HD 3000 / BIOS-only laptop (Dell Vostro 3550)
- [x] Hardware detection, 411 machine profiles, platform modules, `phoenix platform`
- [x] Install to the internal drive with hostname and platform module selection
- [x] Boot screen; update-survival hook; hardware reports to GitHub issues
- [ ] Automatic fix bundles for each new ChromeOS version (in progress)
- [ ] BIOS boot built into the Brunch fork's installer (in progress; upstream PR candidate)
- [x] Upgrade path for existing installs (`phoenix upgrade`; needs a first real-machine run)
- [x] Local, verified archive of Google recovery images and Brunch releases
- [ ] CPU-optimized kernels, chosen at install or boot (first build in progress)
- [ ] Keep-it-fresh maintenance and low-memory tuning (in progress)
- [ ] General installer image for any PC (download, flash, boot)
- [ ] Rewrite MOVBE out of the hottest Android libraries (pre-Haswell performance)

## Contributing

Run `phoenix submit` on your computer, or open a
[hardware report](https://github.com/grioghar/phoenix-chromeos/issues/new?template=hardware-report.yml).
Reports are pulled daily and turned into draft profiles.
