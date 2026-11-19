#!/bin/sh
# zforge rescue: FIREWALL OPEN. Copy this file alone to the root of a FAT32
# USB stick, insert it, power on. Sets FIREWALL_PROFILE=open (stock
# behaviour) and drops any pending change, then reboots. Use it if a firewall
# setting locked you out; fix zforge.conf over SSH afterwards.
LOG=/mnt/zforge-rescue.log
echo "$(date) opening the zforge firewall" >>"$LOG"
grep -q " /data " /proc/mounts || mount /dev/mmcblk0p7 /data
for f in /data/.zforge/etc/zforge.conf /data/.zforge/var/firewall.confirmed.conf; do
    [ -f "$f" ] || continue
    if grep -q '^FIREWALL_PROFILE=' "$f"; then
        sed -i 's/^FIREWALL_PROFILE=.*/FIREWALL_PROFILE=open/' "$f"
    else
        echo 'FIREWALL_PROFILE=open' >>"$f"
    fi
done
rm -f /data/.zforge/var/firewall.pending
echo "ok: FIREWALL_PROFILE=open" >>"$LOG"
rm -f /mnt/flashforge_init.sh   # don't run again on the next boot
sync; sleep 1; reboot
