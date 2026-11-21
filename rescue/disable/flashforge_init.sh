#!/bin/sh
# zforge rescue: DISABLE. Copy this file alone to the root of a FAT32 USB
# stick, insert it, power on. zforge (including its SSH server) is skipped
# from the next boot on; the stock firmware runs untouched. To re-enable,
# run the zforge installer stick again (it keeps your config and keys).
LOG=/mnt/zforge-rescue.log
echo "$(date) disabling zforge" >>"$LOG"
grep -q " /data " /proc/mounts || mount /dev/mmcblk0p7 /data
: >/data/.zforge/disabled && echo "ok: /data/.zforge/disabled created" >>"$LOG"
rm -f /mnt/flashforge_init.sh   # don't run again on the next boot
sync; sleep 1; reboot
