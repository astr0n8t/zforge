#!/bin/sh
# zforge rescue: UNINSTALL. Copy this file alone to the root of a FAT32 USB
# stick, insert it, power on. Removes the boot hook, /etc/profile.d/zforge.sh
# and /data/.zforge
# (SSH keys, Moonraker data and certificate included), then reboots stock.
LOG=/mnt/zforge-rescue.log
echo "$(date) uninstalling zforge" >>"$LOG"
grep -q " /data " /proc/mounts || mount /dev/mmcblk0p7 /data
[ -x /data/.zforge/bin/zforge ] && /data/.zforge/bin/zforge shutdown >>"$LOG" 2>&1
rm -f /etc/init.d/S35zforge /etc/profile.d/zforge.sh
if grep -q " /data/.zforge/" /proc/mounts; then
    echo "mounts still active under /data/.zforge; hook removed, files kept. Reboot and run again." >>"$LOG"
else
    rm -rf /data/.zforge && echo "ok: zforge removed" >>"$LOG"
fi
rm -f /mnt/flashforge_init.sh
sync; sleep 1; reboot
