# Findings: ChromeOS R150 with the Play Store on a Dell Vostro 3550

Hardware: i5-2410M (Sandy Bridge), Intel HD 3000 (Gen6), BIOS only, ALPS touchpad, 8 GB RAM.
Base: Brunch r150 + rammus 16700.65.0 (LTC) + ChromeOS Flex (reven) 16700.65.0.

| Symptom | Cause | Fix |
|---|---|---|
| "Operating System Not Found" | The BIOS needs an active MBR partition | Hybrid MBR: an active 0x0C entry for the EFI partition plus a 0xEE entry; GRUB i386-pc core.img in partition 11 |
| No graphics acceleration | rammus Mesa builds no crocus driver | Transplant the Flex Mesa stack (crocus) from the same version |
| Touchpad dead | ALPS protocol detection | `psmouse.proto=exps` to start with; later the native ALPS driver with `i8042.nomux=1 i8042.reset=1` |
| Play: Error 8 (crosvm SIGILL) | rammus Rust binaries are built with MOVBE/BMI | Copy the Flex builds of crosvm, crosh, bt*, resourced, vhost_user_starter, chunneld, 9s, pdata_tools, ippusb_bridge |
| Play: Error 7/8 (guest kernel panic: init SIGILL) | The ARCVM Android userspace targets Goldmont, which has MOVBE | Shim (`shim/kvm_movbe.c`, DT_NEEDED in crosvm) adds MOVBE to the guest CPUID, and KVM emulates MOVBE on #UD |
| Android reboots with "boringssl-self-check-failed" | BoringSSL CRYPTO_rdrand runs RDRAND without a check | Replace RDRAND with `clc`, then fix the FIPS module hash (`build/patch-android.sh`) |
| Apps crash in VulkanManager::setupDevice | No host Vulkan for Gen6 | `ro.hwui.use_vulkan=false`; stop advertising Vulkan |
| Very slow downloads, crosvm at 270% CPU | BoringSSL picks AES-GCM AVX+MOVBE code, so every MOVBE traps (98% of emulations) | Shim also hides AVX/FMA/F16C from the guest |
| First Play check-in timeout (Error 2) | Play Services busy on first boot | Retry |

## Useful diagnostics
- Guest kernel log after a crash: `/home/root/<hash>/crosvm/*.pstore`
- Android logs from the host: `android-sh -c "logcat -d"`
- Emulation hot spots: the `kvm:kvm_emulate_insn` tracepoint, then count by RIP and instruction bytes
- Testing guest binaries: chroot into the Android image with apex bind mounts, then
  `qemu-x86_64-static -cpu SandyBridge,+movbe`
