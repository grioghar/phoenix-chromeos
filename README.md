# Phoenix

ChromeOS with the Google Play Store on older PCs, built on [Brunch](https://github.com/sebanc/brunch).

Phoenix adds a hardware layer between Brunch and ChromeOS. It works out what machine it is
running on, then pulls in the drivers, fixes and tuning that machine needs. Those fixes are
re-applied automatically after ChromeOS updates.

Status: early. It is proven end to end on a Dell Vostro 3550 (Sandy Bridge, Intel HD 3000,
BIOS-only). On that machine Android needed four workarounds: MOVBE emulation, an RDRAND patch,
a Mesa transplant, and OpenGL instead of Vulkan. See [docs/FINDINGS.md](docs/FINDINGS.md).

- [Architecture](docs/ARCHITECTURE.md)
- `installer/`: install to an internal disk, including legacy-BIOS boot
- `cli/`: the `phoenix` command (`fix`, `diag`, `install`, `touchpad`, `hostname`, `update`)
- `server/`: the build/diagnostics server (serves scripts and components, receives diagnostics)
- `shim/`: crosvm CPUID shim (MOVBE emulation, hides AVX from the Android VM)
- `build/`: image build and Android image patching

This repository holds scripts and sources only. Google's binaries (ChromeOS recovery and Flex
images, Android images) are downloaded or built on demand, never stored here.
