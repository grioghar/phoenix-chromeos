cd /root/brunch-build
R=$(losetup -f --show -P -r chromeos_16700.65.0_rammus_recovery_ltc-channel_RammusMPKeys-v10.bin)
F=$(losetup -f --show -P -r chromeos_16700.65.0_reven_recovery_ltc-channel_RevenMPKeys-v11.bin)
mount -o ro ${R}p3 /mnt/sr; mount -o ro ${F}p3 /mnt/sf
for b in usr/bin/crosvm usr/bin/crosh usr/bin/btmanagerd usr/bin/btadapterd usr/bin/btclient usr/bin/resourced usr/bin/vhost_user_starter usr/bin/chunneld usr/bin/9s usr/sbin/pdata_tools usr/bin/ippusb_bridge; do
  miss=""; for l in $(readelf -d /mnt/sf/$b | awk -F'[][]' '/NEEDED/{print $2}'); do
    [ -e /mnt/sr/usr/lib64/$l ] || [ -e /mnt/sr/lib64/$l ] || miss="$miss $l"; done
  echo "$b  missing:${miss:- none}"
done
umount /mnt/sr /mnt/sf; losetup -d $R $F
echo "--- installer: source handling / rootc / part 11"
grep -nE 'rootdev|src=|-src|ROOT-C|rootc|part.*11|RWFW|EF02|sgdisk|cgpt (add|create)' r150/chromeos-install.sh | head -40
