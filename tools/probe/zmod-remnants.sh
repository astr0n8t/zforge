#!/bin/sh
# List what zmod left on the printer. READ-ONLY: changes nothing.
#
#   ssh root@PRINTER 'sh -s' < tools/probe/zmod-remnants.sh
#
# Based on what zmod 1.7.x installs (its prepare.sh) versus what its own
# uninstaller (REMOVE_ZMOD FULL=1) removes. Lines start with:
#   FOUND   a zmod file/dir/edit that is still there
#   SIZE    disk space it uses
#   ok      checked and not present
set -u
found=0
f() {  # f PATH [why]
    if [ -e "$1" ] || [ -L "$1" ]; then
        found=$((found + 1))
        printf 'FOUND   %-58s %s\n' "$1" "${2:-}"
        [ -d "$1" ] && printf 'SIZE    %s\n' "$(du -sh "$1" 2>/dev/null | cut -f1)"
    else
        printf 'ok      %s\n' "$1"
    fi
}
g() {  # g FILE PATTERN why : a zmod edit inside a stock file
    if [ -f "$1" ] && grep -q -E "$2" "$1" 2>/dev/null; then
        found=$((found + 1))
        printf 'FOUND   %-58s %s\n' "$1" "$3"
        grep -n -E "$2" "$1" | head -n 5 | sed 's/^/          /'
    else
        printf 'ok      %s (%s)\n' "$1" "no zmod edit"
    fi
}

echo "== zmod's own tree"
f /data/.mod                      "zmod chroot (Debian, Moonraker, Fluidd...)"
f /opt/config/mod                 "zmod scripts and configs"
f /opt/config/mod_data            "zmod settings, plugins, Moonraker db"
f /opt/config/base                "zmod web UIs"
f /opt/config/.theme              "zmod theme link"
f /data/logFiles/zmod             "zmod log"

echo "== boot hooks"
for h in S00fix S50sshd S55date S60dropbear S98camera S98zssh S99camera S99moon K99moon prepare.sh; do
    f "/etc/init.d/$h"
done

echo "== stock Klipper (zmod patches it)"
f /opt/klipper/klippy/extras/zmod.py                "zmod Klipper module"
f /opt/klipper/klippy/extras/ens160.py              "zmod air-sensor module"
f /opt/klipper/klippy/extras/gcode_shell_command.py "zmod shell-command module"
g /opt/klipper/klippy/extras/virtual_sdcard.py "zmod" "zmod's patched virtual_sdcard.py"
g /opt/klipper/start.sh "zmod|/opt/config/mod" "zmod lines in Klipper's start script"

echo "== stock config"
g /opt/config/printer.cfg "include .*(mod|mod_data)/" "printer.cfg includes zmod files"
f /opt/config/moonraker.conf       "zmod Moonraker config (link)"
f /opt/config/.moonraker.conf.bkp  "zmod Moonraker backup"
f /opt/config/printer.tmp          "zmod leftover (its scripts write it)"
f /opt/config/printer111.cfg       "Flashforge factory leftover (USB-MCU test config), unused; safe to delete"

echo "== root's home and system files"
f /root/swap                       "zmod's 128 MB swap file (on the small stock root partition)"
f /root/printer_data               "zmod Moonraker data dir"
f /root/.ssh                       "zmod SSH keys"
f /etc/dropbear                    "zmod SSH host keys"
for b in /bin/dropbear /bin/dropbearkey /bin/dropbearmulti /bin/scp /usr/bin/audio /usr/bin/audio.py /usr/bin/audio_midi.sh; do f "$b"; done
f /usr/lib/python3.7/site-packages/audio.py
f /usr/lib/python3.7/site-packages/mido
for d in bin etc home lib libexec root sbin share tmp usr var; do f "/opt/$d" "Entware"; done

echo "== active right now"
grep -E "/root/swap|/data/\.mod" /proc/swaps /proc/mounts 2>/dev/null | sed 's/^/FOUND   active: /'
for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue     # process may have exited
    c=$(tr '\0' ' ' 2>/dev/null <"$d/cmdline")
    case "$c" in *"/opt/config/mod"*|*"/data/.mod"*) echo "FOUND   process ${d#/proc/}: $c" ;; esac
done

echo
echo "$found zmod remnant(s) found. Nothing was changed."
