# Machine research format (one JSON file per manufacturer group: research/<group>.json)

A JSON array of objects, one per model (or model family that shares the same hardware and quirks):

{
  "dmi_vendor":   "Dell Inc.",                 // exact /sys/class/dmi/id/sys_vendor string(s); array if it changed over time
  "dmi_model":    "Latitude E6420",            // exact product_name (Lenovo ThinkPads: product_version, e.g. "ThinkPad T420")
  "aliases":      ["Latitude E6420 ATG"],      // other DMI names for the same hardware (optional)
  "years":        "2011-2012",
  "chassis":      "laptop|desktop|convertible|all-in-one",
  "cpus":         "Intel 2nd gen Core (Sandy Bridge) i3/i5/i7",
  "cpu_gen":      "sandybridge",               // nehalem|westmere|sandybridge|ivybridge|haswell|broadwell|skylake|kabylake|...|amd-k10|amd-bulldozer|amd-jaguar|amd-zen...
  "gpu":          "Intel HD 3000; optional NVIDIA NVS 4200M (Optimus)",
  "gpu_gen":      "intel-gen6",                // intel-gen4..12, amd-terascale, amd-gcn1..5, nvidia-<arch>
  "firmware":     "bios|uefi|uefi+csm",
  "vtx":          "yes|no|some-skus",          // VT-x/AMD-V availability (Android needs it)
  "touchpad":     "alps|synaptics|elantech|i2c-hid|cypress|unknown",
  "wifi":         "Intel 6205 / Broadcom BCM4313 options",
  "linux_quirks": ["i8042.nomux=1 needed for touchpad", "..."],   // kernel params or known issues, Linux-wide
  "platform_modules": ["dell-smm-hwmon", "dell-laptop", "dell-wmi"],
  "module_options":   {"dell-smm-hwmon": "ignore_dmi=1"},
  "fan_control":  "bios-only|software-ok|unknown",
  "notes":        "anything relevant: optimus/dGPU switching, known bad wifi, Chromebook-equivalent support",
  "confidence":   "high|medium|low",           // how sure the DMI strings and quirks are
  "sources":      ["https://...", "..."]       // URLs actually consulted (linux-hardware.org, kernel source, Arch wiki, vendor specs)
}

Rules: do not invent DMI strings, quirks or hardware. If unknown, say "unknown" and lower confidence.
Prefer: linux-hardware.org probes (exact DMI names), Linux kernel source (driver DMI tables, e.g.
drivers/hwmon/dell-smm-hwmon.c i8k_dmi_table / i8k_whitelist_fan_control, drivers/input/serio/i8042-acpipnpio.h
quirk tables, drivers/platform/x86/*), ArchWiki laptop pages, vendor spec sheets.
