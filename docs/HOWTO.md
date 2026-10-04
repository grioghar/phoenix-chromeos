# Phoenix HOWTO

Step-by-step instructions for running Phoenix. Commands go in the ChromeOS console unless noted.
To open it, press **Ctrl+Alt+F2** and log in as `chronos` (no password). **Ctrl+Alt+F1** returns
to the desktop.

> **Browser terminal:** Ctrl+Alt+T, then `shell`, also gives a Linux shell. But ChromeOS starts it
> with the "no new privileges" flag, so `sudo` fails there (*"The no new privileges flag is set"*).
> Run `phoenix rootshell on` once from the console (Ctrl+Alt+F2). After that, every `phoenix`
> command also works in the browser terminal: it uses a private, key-only SSH login on
> 127.0.0.1:2222. `phoenix rootshell off` removes it.

> Phoenix is early. Today a Phoenix USB image is built on the Phoenix build server; a
> download-and-flash image for any PC is on the roadmap. Steps marked *(build server)* need it.

---

## 1. Check your computer

- 64-bit Intel Core (2008 or newer) or AMD (2011 or newer). Core 2 Duo and older won't work.
- At least 4 GB of RAM. 8 GB is better for Android apps.
- **Turn on virtualization** in the BIOS/UEFI setup (Intel VT-x / AMD-V, often called
  "Virtualization Technology"). Many business laptops, ThinkPads especially, ship with it off.
  Without it ChromeOS runs, but the Play Store doesn't.
- To check for a profile, look for your maker and model under [profiles/](../profiles/). For
  example, `profiles/dell/latitude-e6420.conf`.

## 2. Make the USB stick *(build server)*

The build server produces an image for a Brunch base plus a ChromeOS recovery version, for example
`vostro_rammus150_fix.img.zst` today. To flash it from a Mac (replace `diskN`; check it with `diskutil list`):

```bash
sudo -v
```

```bash
diskutil unmountDisk /dev/diskN
```

```bash
zstd -dc phoenix.img.zst | pv -s <image size in bytes> | sudo dd of=/dev/rdiskN bs=4m
```

From Linux use `/dev/sdX` and `bs=4M status=progress`.

## 3. Boot from USB

1. Plug in the stick, power on, and open the boot menu. That's F12 on Dell/Lenovo, F9 on HP,
   Esc/F8 on ASUS, or hold Option on a Mac.
2. Pick the USB stick. GRUB shows **ChromeOS**, and the Phoenix boot screen appears.
3. **The first boot takes several minutes**, because Brunch prepares the system once.
4. Set up ChromeOS as usual: network, Google account.

## 4. Apply Phoenix and get the Play Store

Open the console (Ctrl+Alt+F2), log in as `chronos`, then:

```bash
curl -s 192.168.1.128:8099/v | sudo sh
```

```bash
phoenix fix
```

The first command installs the `phoenix` command. It uses the Phoenix server's address, which is
dockervm on the home network today. The second command does the following:
1. Installs this machine's fixes: Android VM fixes, Android image patches and the boot menu fix.
2. Sets up the platform layer, meaning the modules, CPU profile and fan for your model.
3. Saves everything so it survives ChromeOS updates.

Reboot when it says so, then open the Play Store from the launcher.

- **Error 8 / error 7:** Android didn't start. Run `phoenix diag` and see section 9.
- **Error 2 (check-in timeout):** on a first boot this is usually just slowness. Wait 5–10
  minutes and click Retry.
- **"Starting Play Store…" forever:** run `phoenix diag`.

## 5. Install to the internal drive

**This erases the internal drive**, Windows and all your files included.

```bash
phoenix install
```

The installer walks you through it:
1. **This computer:** the detected machine, CPU, graphics and firmware.
2. **Disks:** it picks the internal drive. Type `ERASE sda` (or whatever the drive is called) to confirm.
3. **Hostname:** the name your router shows. Press Enter to accept the suggested name.
4. **Platform modules:** the drivers recommended for your model. Press Enter to accept, or type
   `+module` / `-module` to add or remove one; `?` lists all of them.
5. **Performance mode** (optional, off unless you choose it): turns off the CPU security
   workarounds that slow down older processors. Faster, especially web pages and Android apps, but
   less protected against malicious sites or apps exploiting CPU flaws (Spectre, Meltdown and
   others). The installer explains the trade-off before asking. Change it later with
   `phoenix platform perf on|off`.
6. **Throttle override** (on by default, pointed out): some firmware slows the processor down
   drastically when the battery has failed or the charger isn't recognised (a Dell with a dead
   battery drops to about 400 MHz). Phoenix undoes that and guards the temperature itself, slowing
   down above 90 °C. Turn it off if the computer uses a weaker charger than it came with. Change it
   later with `phoenix platform throttle on|off`.
7. Installation. Brunch copies the system, which takes several minutes.
8. **BIOS boot** (BIOS-only computers), then the fixes are copied onto the drive.

When it says Done, run `sudo poweroff`, **remove the USB stick**, and power on. If the computer
doesn't start from the drive by itself, open the boot menu and pick the internal drive. On the
first boot from the drive, the Play Store may need one Retry (see above).

## 6. Settings: `phoenix platform`

```bash
phoenix platform
```

This shows the machine, its platform modules (loaded or not, with what each one does),
temperatures, fans, and the speed settings. For an interactive menu:

```bash
phoenix platform menu
```

Common changes:

| Command | Effect |
|---|---|
| `phoenix platform enable dell-smm-hwmon` | Load a platform module now and at every boot |
| `phoenix platform cpu performance` | CPU profile: `balanced` (default), `performance`, `quiet` |
| `phoenix platform fan auto` | Fan curve (`bios` = firmware decides; only where software control is allowed) |
| `phoenix platform anim 0.5` | Android animations twice as fast (`0` = off) |
| `phoenix platform throttle on\|off` | Undo firmware throttling (dead battery, unrecognised charger); on by default |
| `phoenix platform thermal on\|off` | Temperature-based speed control (thermal guard); on by default |
| `phoenix platform thermal limit 90` | Target maximum temperature, 60–100 °C (above it the speed steps down) |
| `phoenix platform thermal hysteresis 5` | Speed steps back up this many °C below the limit |
| `phoenix platform thermal step 100` / `poll 3` | MHz per step / seconds between checks |
| `phoenix platform perf on` | **Performance mode**, after a reboot: turns off CPU vulnerability workarounds and some memory hardening. Much faster on old CPUs, but less protected against malicious websites and apps. It asks before turning on. |

## 6b. Optimized kernel

`phoenix kernel install` installs a Phoenix build of Brunch's kernel compiled for your CPU family
(e.g. `sandybridge`), if the build server has one. `phoenix kernel status` shows what is running;
`phoenix kernel stock` goes back to Brunch's kernel. The first boot after a switch rebuilds the
system once (a few minutes). Phoenix saves your fixes first and restores them during the rebuild.
The boot menu always keeps **ChromeOS (stock kernel)** as a fallback.

Expect a modest gain from the optimized kernel (a few percent). Performance mode makes the larger
difference on older CPUs.

## 6c. Phoenix Health on the desktop

Phoenix checks the computer every minute: failed battery, firmware throttling, cooling, disk space,
virtualization, held updates. A **Phoenix Health** icon in Chrome's toolbar shows the result:
**green** (all good), **yellow** (warning) or **red** (problem). Pin it with the puzzle-piece menu.
New problems also appear as ChromeOS notifications, which stay in the tray. Click the icon to see
the details and to change Phoenix settings (performance mode, throttle override, temperature limit,
CPU profile, fan, Android animations, maintenance, check interval). The panel talks only to Phoenix
on this computer (127.0.0.1), and Phoenix accepts requests only from this extension. In the
console: `phoenix health`.

## 7. Touchpad, hostname

```bash
phoenix touchpad alps
```

```bash
phoenix hostname my-laptop
```

Touchpad modes are `alps` (native driver with two-finger scroll; try it first), `alps2` (the same
without the i8042 tweaks) and `exps` (basic mode, always works). Reboot after changing it. If the
touchpad stops working, go to the console and run `phoenix touchpad exps`.

**Pointer jumps when you scroll with two fingers** (ALPS touchpads on many Dell laptops): run
`phoenix touchpad tune`, then log out and back in. It installs ChromeOS touchpad settings for
"semi-multitouch" pads. `phoenix touchpad untune` removes them.

## 8. Updates

ChromeOS updates itself, and Phoenix keeps updates safe:
1. ChromeOS downloads an update in the background.
2. Phoenix's update watcher checks every 10 minutes. When an update is waiting for a reboot, it
   fetches the **hardware-support bundle** for that new version (the fixes this machine needs,
   built for exactly that ChromeOS version) and checks it.
3. If no bundle exists yet, the update is **held**: the computer keeps booting the current, working
   version. The hold is released automatically once the bundle is available.
4. At the next reboot Brunch installs the update, and Phoenix restores the fixes from the bundle.
   The boot screen shows "Restoring hardware support".

`phoenix update-status` shows whether an update is waiting, ready or held. Phoenix machines stay on
ChromeOS's **LTC channel**: only there do the ChromeOS and ChromeOS Flex versions match, and Phoenix
needs both. To update the `phoenix` command itself, run `phoenix update`.

## 8b. Moving an existing install to a new Phoenix release

`phoenix upgrade` installs the current Phoenix boot environment on an existing install: the boot
screen, hardware detection at boot, the Brunch fork's patches and the update-survival hook. It
saves this machine's fixes first, keeps Brunch's originals, and the next boot rebuilds the system
once. `phoenix upgrade --rollback` undoes it. `--verbose-boot` / `--quiet-boot` switch between
Brunch's text log and the boot screen.

## 9. Something doesn't work

| Symptom | Try |
|---|---|
| Anything | `phoenix diag` collects logs for the Phoenix server |
| Missing driver, fan noise, hotkeys, Wi-Fi | `phoenix submit` files a hardware report as a GitHub issue |
| Touchpad dead | Console: `phoenix touchpad exps`, then reboot |
| Boot shows text instead of the boot screen | Brunch verbose mode is on (`verbose=1` in the boot settings) |
| GRUB "bitmap ... unknown format" | Run `phoenix fix` (it adds PNG support to the boot menu) |
| Very slow | `phoenix platform` to check disk and CPU settings; consider `phoenix platform perf on` |

`phoenix submit` asks what's missing, saves a report to Downloads (with serial numbers, MAC/IP
addresses and names removed), and, after you confirm, files it at
[github.com/grioghar/phoenix-chromeos/issues](https://github.com/grioghar/phoenix-chromeos/issues).

## 10. For maintainers

- **Build a Phoenix release** (Brunch release + fork + Phoenix): `build/make-release.sh <brunch_rXXX.tar.gz> <fork checkout> <out>`
- **Patch Android images for a ChromeOS version:** `build/patch-android.sh <system.raw.img> <vendor.raw.img> <out>`
- **Optimized kernel:** `build/build-kernel.sh <fork checkout> <march> <out> [--lean modules.list]`
- **Profiles from research:** `python3 build/gen-profiles.py` (hand-written profiles are never overwritten)
- **Server:** `server/phoenix_server.py` runs as the systemd unit `phoenix-server` on the build
  server. A daily `phoenix-issue-sync` timer pulls hardware reports into `/root/phoenix-intake/`.
- **Image archive:** `build/archive.py` (daily timer `phoenix-archive` on the build server) keeps
  verified copies of the ChromeOS (rammus) and ChromeOS Flex recovery images and the Brunch
  releases in `/root/phoenix-archive`, so installs keep working if Google or GitHub pull a version.
  These are local copies for your own installs. Phoenix images never contain Google's files.
- **GitHub token for automatic issues** (fine-grained, this repo only, Issues read and write) goes
  in `/root/phoenix-secrets/github-token` on the server.
