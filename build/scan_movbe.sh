cd /root/brunch-build
R=$(losetup -f --show -P -r chromeos_16700.65.0_rammus_recovery_ltc-channel_RammusMPKeys-v10.bin)
F=$(losetup -f --show -P -r chromeos_16700.65.0_reven_recovery_ltc-channel_RevenMPKeys-v11.bin)
mount -o ro ${R}p3 /mnt/sr; mount -o ro ${F}p3 /mnt/sf
printf "%-40s %8s %8s %8s %8s\n" binary r:movbe r:bmi f:movbe f:bmi
for rel in $(awk '{print $2}' /tmp/bad.txt | sed 's#/mnt/sr##'); do
  d1=$(objdump -d /mnt/sr$rel 2>/dev/null); m1=$(grep -cE '\smovbe\s' <<<"$d1"); b1=$(grep -cE '\s(shlx|shrx|sarx|rorx|andn|bzhi|mulx)\s' <<<"$d1")
  if [ -e /mnt/sf$rel ]; then d2=$(objdump -d /mnt/sf$rel 2>/dev/null); m2=$(grep -cE '\smovbe\s' <<<"$d2"); b2=$(grep -cE '\s(shlx|shrx|sarx|rorx|andn|bzhi|mulx)\s' <<<"$d2"); else m2=-; b2=-; fi
  printf "%-40s %8s %8s %8s %8s\n" $rel $m1 $b1 $m2 $b2
done
echo; file /mnt/sr/usr/bin/crosvm | cut -c1-120; ls /mnt/sf/usr/bin/btadapterd /mnt/sf/usr/bin/resourced 2>&1
umount /mnt/sr /mnt/sf; losetup -d $R $F
