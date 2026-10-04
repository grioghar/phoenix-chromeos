#!/bin/sh
# phoenix-detect: identify the machine and its features, and decide which Phoenix components it needs.
#
#   phoenix-detect.sh            print the profile (key=value, one per line)
#   phoenix-detect.sh --summary  print a short human-readable description
#
# POSIX sh + busybox tools only: it runs in Brunch's initramfs, in ChromeOS and in the installer.
# Optional env: PHOENIX_PROFILES (directory of per-model .conf files), PHOENIX_SYS (sysfs root, for tests).
SYS=${PHOENIX_SYS:-}
PROFILES=${PHOENIX_PROFILES:-$(dirname "$0")/../profiles}

rd(){ [ -r "$SYS$1" ] && tr -d '\n' < "$SYS$1" | sed 's/[[:space:]]*$//' || true; }
kv(){ printf '%s=%s\n' "$1" "$2"; }
has_flag(){ case " $CPUFLAGS " in *" $1 "*) echo 1;; *) echo 0;; esac; }

# ---------------------------------------------------------------- machine identity (DMI)
VENDOR=$(rd /sys/class/dmi/id/sys_vendor); PRODUCT=$(rd /sys/class/dmi/id/product_name)
PVERSION=$(rd /sys/class/dmi/id/product_version); BOARD=$(rd /sys/class/dmi/id/board_name)
BIOS=$(rd /sys/class/dmi/id/bios_version); CHASSIS_N=$(rd /sys/class/dmi/id/chassis_type)
case "$CHASSIS_N" in
  8|9|10|14) CHASSIS=laptop;; 30|31|32) CHASSIS=convertible;; 3|4|5|6|7|13|15|16|35|36) CHASSIS=desktop;; *) CHASSIS=unknown;;
esac
# ThinkPads keep the marketing name in product_version
case "$VENDOR" in LENOVO) [ -n "$PVERSION" ] && MODEL="$PVERSION" || MODEL="$PRODUCT";; *) MODEL="$PRODUCT";; esac
slug(){ echo "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//'; }
VSLUG=$(slug "$(echo "$VENDOR" | awk '{print $1}')"); MSLUG=$(slug "$MODEL")
PROFILE_FILE=""; [ -f "$PROFILES/$VSLUG/$MSLUG.conf" ] && PROFILE_FILE="$PROFILES/$VSLUG/$MSLUG.conf"

# ---------------------------------------------------------------- CPU
CPUFLAGS=$(grep -m1 '^flags' "$SYS/proc/cpuinfo" 2>/dev/null | sed 's/^flags[^:]*: //')
CPUNAME=$(grep -m1 '^model name' "$SYS/proc/cpuinfo" 2>/dev/null | sed 's/^[^:]*: //; s/([^)]*)//g; s/  */ /g; s/ CPU//; s/ @.*//')
CPUVENDOR=$(grep -m1 '^vendor_id' "$SYS/proc/cpuinfo" 2>/dev/null | sed 's/^[^:]*: //')
THREADS=$(grep -c '^processor' "$SYS/proc/cpuinfo" 2>/dev/null)
CF="$SYS/sys/devices/system/cpu/cpu0/cpufreq"
CPUFREQ=$(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)
GOVS=$(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors)
MOVBE=$(has_flag movbe); RDRAND=$(has_flag rdrand); AVX=$(has_flag avx); AVX2=$(has_flag avx2)
BMI2=$(has_flag bmi2); SSE42=$(has_flag sse4_2); AES=$(has_flag aes)
VIRT=0; [ "$(has_flag vmx)" = 1 ] || [ "$(has_flag svm)" = 1 ] && VIRT=1
KVMDEV=0; [ -e "$SYS/dev/kvm" ] && KVMDEV=1
MEM_MB=$(awk '/^MemTotal/{print int($2/1024)}' "$SYS/proc/meminfo" 2>/dev/null)

# ---------------------------------------------------------------- GPU (PCI class 03xx)
GPUS=""; GPU_MAIN=""; GPU_STACK=""; VULKAN=0
intel_gen(){ # PCI device id -> GPU generation (coarse, by known ranges)
  case "$1" in
    29*|2a0*|2a1*|2e*) echo 4;;            # 965 / G35 / G45 / GM45
    0042|0046) echo 5;;                    # Ironlake
    010*|011*|012*) echo 6;;               # Sandy Bridge (HD 2000/3000)
    015*|016[0-9a]) echo 7;;               # Ivy Bridge (HD 2500/4000)
    040*|041*|042*|0a0*|0a1*|0a2*|0d0*|0d1*|0d2*|0c0*|0c1*|0c2*|0f3*) echo 7.5;; # Haswell, Bay Trail
    16*|22b*) echo 8;;                     # Broadwell, Cherry/Braswell
    19*|59*|3e*|9b*|87*|5a*|318*|3ea*|9a4*) echo 9;; # Skylake..Comet Lake, Apollo/Gemini Lake
    8a*|4e*|4c*) echo 11;;                 # Ice Lake, Jasper Lake
    *) echo 12;;                           # Tiger Lake and newer
  esac; }
for d in "$SYS"/sys/bus/pci/devices/*; do
  [ -r "$d/class" ] || continue
  case "$(cat "$d/class")" in 0x03*) ;; *) continue;; esac
  ven=$(sed 's/^0x//' "$d/vendor"); dev=$(sed 's/^0x//' "$d/device")
  drv=""; [ -L "$d/driver" ] && drv=$(basename "$(readlink "$d/driver")")
  case "$ven" in
    8086) g=$(intel_gen "$dev"); desc="intel-gen$g"
          case "$g" in 4|5|6|7|7.5) stack=crocus;; *) stack=iris; VULKAN=1;; esac ;;
    1002) case "$drv" in amdgpu) stack=radeonsi; VULKAN=1;; *) stack=r600-or-radeonsi;; esac; desc="amd"; g="" ;;
    10de) stack=nouveau; desc="nvidia"; g="" ;;
    *)    stack=unknown; desc="other"; g="" ;;
  esac
  GPUS="$GPUS ${desc}:${ven}:${dev}:${drv:-none}"
  [ -z "$GPU_MAIN" ] && { GPU_MAIN=$desc; GPU_STACK=$stack; GPU_GEN=$g; GPU_ID="$ven:$dev"; }
done
GPUS=${GPUS# }

# ---------------------------------------------------------------- firmware, input, sensors, storage, battery, wifi
FIRMWARE=bios; [ -d "$SYS/sys/firmware/efi" ] && FIRMWARE=uefi
TOUCHPAD=none
INPUTS=$(grep '^N: Name=' "$SYS/proc/bus/input/devices" 2>/dev/null | sed 's/^N: Name="//; s/"$//')
case "$INPUTS" in
  *AlpsPS/2*|*ALPS*) TOUCHPAD=alps;; *SynPS/2*|*Synaptics*) TOUCHPAD=synaptics;;
  *Elantech*|*ETPS/2*) TOUCHPAD=elantech;; *[Tt]ouchpad*) TOUCHPAD=i2c-hid;;
  *"PS/2 Generic Mouse"*|*ImExPS/2*|*ImPS/2*) TOUCHPAD=ps2-generic;;
esac
HWMON=""; FANS=0
for h in "$SYS"/sys/class/hwmon/hwmon*; do
  [ -r "$h/name" ] || continue; HWMON="$HWMON $(cat "$h/name")"
  for f in "$h"/fan*_input; do [ -r "$f" ] && FANS=$((FANS + 1)); done
done
HWMON=${HWMON# }
FANCTL=none
case "$VENDOR" in
  Dell*) FANCTL=dell-smm;; LENOVO) case "$MODEL" in ThinkPad*) FANCTL=thinkpad;; esac;;
  ASUS*) FANCTL=asus-wmi;; HP|Hewlett*) FANCTL=hp-wmi;;
esac
ROOTDEV=""; ROT=""; TRIM=0
for b in "$SYS"/sys/block/sd* "$SYS"/sys/block/nvme*n1 "$SYS"/sys/block/mmcblk[0-9]; do
  [ -r "$b/removable" ] || continue; [ "$(cat "$b/removable")" = 0 ] || continue
  ROOTDEV=$(basename "$b"); ROT=$(cat "$b/queue/rotational" 2>/dev/null)
  [ "$(cat "$b/queue/discard_max_bytes" 2>/dev/null || echo 0)" != 0 ] && TRIM=1; break
done
BATTERY=0; for p in "$SYS"/sys/class/power_supply/*; do [ "$(cat "$p/type" 2>/dev/null)" = Battery ] && BATTERY=1; done
WIFI=""; for n in "$SYS"/sys/class/net/*; do [ -d "$n/wireless" ] || [ -d "$n/phy80211" ] || continue
  [ -L "$n/device/driver" ] && WIFI="$WIFI $(basename "$(readlink "$n/device/driver")")"; done
WIFI=${WIFI# }

# ---------------------------------------------------------------- component decisions
NEED=""
need(){ NEED="$NEED $1"; }
[ "$MOVBE" = 0 ] || [ "$BMI2" = 0 ] && need flex-rust
[ "$MOVBE" = 0 ] && need kvm-movbe-shim
[ "$RDRAND" = 0 ] && need android-rdrand
[ "$VULKAN" = 0 ] && need android-gl
[ "$GPU_STACK" = crocus ] && need mesa-crocus
[ "$FIRMWARE" = bios ] && need bios-boot
[ "$FANCTL" != none ] && need "fan-$FANCTL"
need cpufreq-tune
NEED=${NEED# }
ANDROID=yes; [ "$VIRT" = 1 ] || ANDROID="no (CPU has no VT-x/AMD-V)"
[ "$SSE42" = 1 ] || ANDROID="no (CPU lacks SSE4.2; ChromeOS itself will not run)"

if [ "${1:-}" = --summary ]; then
  echo "Machine:   ${VENDOR:-unknown} ${MODEL:-} (${CHASSIS}${PROFILE_FILE:+, known model})"
  echo "CPU:       ${CPUNAME:-unknown}, $THREADS threads$( [ "$MOVBE" = 0 ] && echo ', pre-Haswell')"
  echo "Graphics:  ${GPU_MAIN:-none} (${GPU_STACK:-?})$( [ "$VULKAN" = 0 ] && echo ', no Vulkan')"
  echo "Memory:    ${MEM_MB} MB    Firmware: $FIRMWARE    Touchpad: $TOUCHPAD"
  echo "Disk:      ${ROOTDEV:-?} ($( [ "$ROT" = 1 ] && echo HDD || echo SSD)$( [ "$TRIM" = 1 ] && echo ', TRIM'))    Fan control: $FANCTL"
  echo "Android:   $ANDROID"
  echo "Needs:     $NEED"
  exit 0
fi

kv machine.vendor "$VENDOR"; kv machine.model "$MODEL"; kv machine.product "$PRODUCT"; kv machine.board "$BOARD"
kv machine.bios "$BIOS"; kv machine.chassis "$CHASSIS"; kv machine.id "$VSLUG/$MSLUG"; kv machine.profile "$PROFILE_FILE"
kv cpu.vendor "$CPUVENDOR"; kv cpu.name "$CPUNAME"; kv cpu.threads "$THREADS"
kv cpu.movbe "$MOVBE"; kv cpu.rdrand "$RDRAND"; kv cpu.avx "$AVX"; kv cpu.avx2 "$AVX2"; kv cpu.bmi2 "$BMI2"
kv cpu.sse4_2 "$SSE42"; kv cpu.aes "$AES"; kv cpu.virt "$VIRT"; kv cpu.kvm "$KVMDEV"
kv cpu.freq_driver "$CPUFREQ"; kv cpu.governors "$GOVS"
kv mem.mb "$MEM_MB"
kv gpu.main "$GPU_MAIN"; kv gpu.id "$GPU_ID"; kv gpu.gen "$GPU_GEN"; kv gpu.stack "$GPU_STACK"; kv gpu.vulkan "$VULKAN"; kv gpu.all "$GPUS"
kv firmware "$FIRMWARE"; kv input.touchpad "$TOUCHPAD"
kv sensors.hwmon "$HWMON"; kv sensors.fans "$FANS"; kv fan.control "$FANCTL"
kv disk.dev "$ROOTDEV"; kv disk.rotational "$ROT"; kv disk.trim "$TRIM"
kv power.battery "$BATTERY"; kv wifi.drivers "$WIFI"
kv android "$ANDROID"; kv needs "$NEED"
# per-model profile values override/extend (e.g. touchpad mode, extra kernel params)
[ -n "$PROFILE_FILE" ] && grep -E '^[a-z0-9_.]+=' "$PROFILE_FILE" | sed 's/^/profile./'
exit 0
