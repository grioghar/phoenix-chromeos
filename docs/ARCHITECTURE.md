# Phoenix architecture

Phoenix runs ChromeOS with the Google Play Store on older PCs. It is built on Brunch, which boots
official ChromeOS recovery images on generic hardware. Phoenix adds a hardware layer between
Brunch and ChromeOS. The layer identifies the machine and applies exactly the fixes, drivers and
tuning that machine needs. It also re-applies them after every ChromeOS update.

```
GRUB (BIOS or UEFI) ── Phoenix theme
  └─ Brunch kernel + initramfs
       ├─ Phoenix boot screen (framebuffer): progress, detected hardware
       ├─ Phoenix detect  → /var/lib/phoenix/profile (machine + features)
       ├─ Brunch rootfs rebuild (after updates) → /rootc/patches/phoenix.sh
       │     └─ Phoenix apply: components chosen by the profile
       └─ ChromeOS (Chrome UI, ARCVM Android)
             └─ Phoenix services: hostname, fan curve, tuning, `phoenix` CLI
```

## 1. Detection (`detect/`)

Detection produces one profile file in plain `key=value` form, readable by shell scripts. It has two parts:

**Machine identity.** DMI (`/sys/class/dmi/id`: sys_vendor, product_name, product_version,
board_name, bios_version) and the chassis type (laptop, desktop, convertible). These are matched
against `profiles/<vendor>/<model>.conf`, which hold per-model quirks such as touchpad mode,
fan driver, keyboard backlight and known-bad features. Unknown machines fall back to generic detection.

**Features** (always detected, never assumed from the model):

| Area | Source | Examples of decisions |
|---|---|---|
| CPU | `/proc/cpuinfo` flags, vendor, family/model | MOVBE/BMI/AVX2 → Flex Rust binaries; MOVBE → shim; RDRAND → Android libcrypto patch; vmx/svm → Android possible |
| GPU | PCI IDs (`/sys/bus/pci`) | Intel gen → crocus or iris; AMD → r600, radeonsi or amdgpu; NVIDIA → nouveau; Vulkan availability → Android renderer |
| Firmware | `/sys/firmware/efi` | BIOS → GRUB i386-pc and hybrid MBR; UEFI → Brunch EFI |
| Input | `/proc/bus/input/devices`, PS/2 probe | ALPS, Synaptics or Elan → psmouse mode; i2c-hid |
| Sensors and fans | hwmon, DMI, ACPI | Dell SMM, ThinkPad, ASUS, HP, generic ACPI fan |
| Power | cpufreq drivers, battery | intel_pstate, acpi-cpufreq or amd-pstate; governor; battery thresholds |
| Storage | rotational flag, TRIM support | I/O scheduler, fstrim, zram size |
| Wireless | PCI/USB IDs | Firmware blobs, known-bad drivers |

## 2. Components (`components/`)

A component is a unit that is either needed or not needed. Each one declares:
- `match`: a condition on the profile, e.g. `cpu.movbe=0`.
- `fetch`: how to get it for the running ChromeOS version.
- `apply`: an idempotent script run against a root filesystem.

| Component | Match | Source |
|---|---|---|
| flex-rust | CPU lacks MOVBE or BMI | Flex recovery image, same version |
| mesa-crocus | Intel Gen4–7 | Flex recovery image, same version |
| kvm-movbe-shim | CPU lacks MOVBE | Built from `shim/` |
| android-rdrand | CPU lacks RDRAND | Patched with `build/patch-android.sh` |
| android-gl | Host has no Vulkan | Patched with `build/patch-android.sh` |
| bios-boot | Legacy BIOS | GRUB i386-pc from Brunch or the distro |
| fan-dell-smm | Dell, `dell_smm_hwmon` loads | Kernel module plus the Phoenix fan service |
| fan-thinkpad | ThinkPad | `thinkpad_acpi` with fan_control=1 |
| cpufreq | Always | Governor and EPP tuning per chassis/power |
| touchpad-* | Per input device | Kernel command line in settings.cfg |

**Sources: the build server first, Google as the fallback.**
1. The Phoenix server (for example dockervm) keeps a cache of ready-made components for each
   ChromeOS version and board. They download fast and were already tested.
2. If the server can't be reached, or has nothing for that version, the device builds the
   component itself. It downloads the matching ChromeOS Flex recovery image from Google's
   public recovery list (`dl.google.com`) and extracts the files it needs. For Android, it
   runs the same patch steps on the device. Those need static helper tools shipped in ROOTC:
   mkfs.erofs and objdump, or a small Python-free patcher.

## 3. Update survival

Brunch rebuilds ROOT-A from the updated partition, then runs `/rootc/patches/*.sh`. Phoenix
installs one patch hook into ROOTC. The hook reads the profile, then resolves components for
the new ChromeOS version, fetching or building them as needed. Next it applies them. If a
required component can't be obtained, Phoenix keeps the previous root and tells the user
instead of booting into a broken system.

## 4. Boot screen

- **GRUB:** a gfxmenu theme, with `insmod png` loaded in the BIOS core config.
- **Kernel:** `quiet loglevel=0 vt.global_cursor_default=0` and Brunch verbose off.
- **Initramfs:** a small static framebuffer program draws the Phoenix logo, a status line, a
  progress bar and the detected-hardware lines. Detection and the Brunch rebuild report to it
  through a FIFO. It exits when frecon or Chrome takes over the display.

## 5. Installer

One script that:
1. Detects the hardware and shows the machine summary.
2. Picks the target disk.
3. Asks for a hostname.
4. Runs the Brunch install.
5. Adds the BIOS layer if needed.
6. Applies components to both roots and installs the patch hook and Phoenix services.

## 6. Optimizations

- Choose the best Brunch kernel (5.10, 6.1, 6.6 or 6.12) per hardware generation.
- zram sizing by RAM; swappiness.
- CPU governor/EPP; fan curves.
- I/O scheduler by disk type; periodic TRIM.
- Skip unnecessary rootfs rebuilds.
- Android: hide CPU features whose code paths are emulated (AVX+MOVBE); later, rewrite
  MOVBE in hot Android libraries.

## 7. Update pipeline

An automated server-side pipeline builds Phoenix bundles for new ChromeOS versions. The pipeline runs
on the build server (`/root/phoenix` and `/root/phoenix-bundles` on dockervm):

1. **Bundle builder** (`build/make-bundle.sh <version> <out_dir>`):
   - Fetches Google's recovery image lists and locates the rammus and reven images for the version.
   - Downloads (and caches in `/root/brunch-build/recovery`) the recovery images.
   - Extracts the Mesa graphics stack and Rust binaries from the reven (Flex) image.
   - Patches Android system and vendor images from the rammus image using `build/patch-android.sh`
     (RDRAND → clc; Vulkan disabled; FIPS hash recomputed).
   - Produces `<out_dir>/<version>.tar` with xattrs preserved (same as `cli/save.sh` on a fixed machine),
     plus `.sha256` and `.manifest` files.

2. **Version monitor** (`build/watch-versions.py`):
   - Runs on a daily systemd timer (`phoenix-bundles.{service,timer}`).
   - Reads the recovery JSON lists and finds rammus versions newer than what's in the bundle store
     (`/root/phoenix-bundles`).
   - For each new version with a matching reven, invokes the bundle builder.
   - Limits to 5 builds per run to avoid overloading the build server.
   - Logs to syslog with prefix `phoenix-watch-versions`.

3. **Bundle server** (`server/phoenix_server.py`):
   - New route: `GET /bundle/<version>.tar` and `.sha256`.
   - Streams bundles from `/root/phoenix-bundles` to devices that need them after a ChromeOS update.
   - Device requests are made BEFORE rebooting into the update (the rebuild runs in initramfs with no network;
     the lead is building that pre-update fetch mechanism).

Bundles contain version-specific components (Mesa, Rust binaries, patched Android images) and are
fetched before the system reboots into a new ChromeOS version. If a bundle is not available, the machine
falls back to building components from recovery images at runtime during the Brunch rebuild, but will be
marked to retry after login (`/etc/phoenix/needs-fix`).

## Limits

- **No VT-x/AMD-V:** ChromeOS works, but Android (ARCVM) cannot run. Phoenix says so up front.
- **CPUs without SSE4.2:** older than Core 2 Penryn/Nehalem, or AMD before Bulldozer/Jaguar.
  ChromeOS itself won't run.
- **NVIDIA:** nouveau only, so performance varies by generation.
- **Updates:** Flex and the ARC image must match the ChromeOS version. A brand-new release
  works once its components can be built.
