#!/bin/sh
# zforge rescue: MCU-UPDATE DIAGNOSTICS. Copy this file alone to the root of a
# FAT32 stick, insert it, power on. It starts a background logger and lets the
# boot continue into the stock MCU flash step. Every 10 s for 30 min it writes
# to zforge-mcu-diag.log on the stick: which flasher runs, what it waits on,
# its serial port, the UART byte counters (do bytes still move?) and dmesg.
# When the screen has been stuck long enough, power off and read the log.
# Changes nothing on the printer.
LOG=/mnt/zforge-mcu-diag.log
# stock BusyBox has no pgrep
flasher_pids() {
    for d in /proc/[0-9]*; do
        case "$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)" in
            *NationsCommand*|*IAPCommand*) echo "${d#/proc/}" ;;
        esac
    done
}
(
    cd /mnt || exit 1        # keeps /mnt busy, so stock can't unmount the stick
    i=0
    while [ $i -lt 180 ]; do
        {
            echo "===== $(date) uptime: $(cut -d' ' -f1 /proc/uptime)s"
            ps | grep -E '[N]ationsCommand|[I]APCommand|[r]un\.sh|[a]uto_run|[f]fstartup'
            for p in $(flasher_pids); do
                echo "-- pid $p: $(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null)"
                echo "   state: $(awk '{print $3}' /proc/$p/stat 2>/dev/null)  wchan: $(cat /proc/$p/wchan 2>/dev/null)"
                ls -l /proc/$p/fd 2>/dev/null | awk '{print "   fd " $(NF-2) " -> " $NF}'
            done
            echo "-- load: $(cat /proc/loadavg)"
            echo "-- mem: $(grep -E '^(MemAvailable|SwapFree):' /proc/meminfo | tr -s ' ' | tr '\n' ' ')"
            echo "-- zforge/other busy processes:"
            ps | grep -E '[m]oonraker|[d]ropbear|[m]jpg_streamer|[n]tpd|[m]kswap|[d]d if=' | sed 's/^/   /'
            echo "-- uarts:"; cat /proc/tty/driver/serial 2>/dev/null | grep -v 'uart:unknown'
            echo "-- usb:"; cat /sys/bus/usb/devices/*/product 2>/dev/null | tr '\n' ',' ; echo
            echo "-- dmesg (last 8):"; dmesg | tail -n 8
        } >>"$LOG" 2>&1
        sync
        sleep 10; i=$((i + 1))
    done
) </dev/null >/dev/null 2>&1 &
sleep 1
exit 1    # non-zero: stock auto_run continues the normal boot (into the MCU step)
