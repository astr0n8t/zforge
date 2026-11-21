#!/bin/sh
# zforge rescue: SKIP MCU UPDATE. Copy this file alone to the root of a FAT32
# stick, insert it, power on. Removes the stock "Update" flag in
# /opt/PROGRAM/control/<ver>/, so the boot skips the MCU flash step, then
# reboots. Only for a flash that hangs on every boot while the boards already
# run the firmware being flashed (true for Adventurer5MPro 5.2.0 over 3.2.x:
# control-2.2.3 is identical). If the printer then reports that it can't reach
# its MCU, the boards need the flash after all: ask before going further.
LOG=/mnt/zforge-rescue.log
{
    echo "===== $(date) skip-mcu-update"
    ls -la /opt/PROGRAM/control/*/
    for f in /opt/PROGRAM/control/*/Update; do
        [ -e "$f" ] && rm -f "$f" && echo "removed $f"
    done
} >>"$LOG" 2>&1
rm -f /mnt/flashforge_init.sh   # don't run again on the next boot
sync; sleep 1; reboot
