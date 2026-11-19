# zforge stock firmware updates (Phase 3).
#
# A stock update package is a plain tar (named .tgz) with flashforge_init.sh
# and component tars (software-, library-, kernel-, control-<ver>.tar.xz, also
# plain tar despite the name), each with an md5sum.list. Stock /opt/auto_run.sh
# installs one from USB by unpacking it into /data/update and running
# /data/update/flashforge_init.sh Adventurer5MPro 0024. `zforge fw install`
# does the same, with checks first and the user's Wi-Fi config preserved.
# See docs/stock/update-package.md.

FWU_STAGE=$ZF_SYSROOT/data/update          # same place stock uses
FWU_MACHINE=Adventurer5MPro
FWU_PID=0024
FWU_HISTORY=$ZF_VAR/fw-history.log
FWU_P_TEMP=198                             # temporary allow: a download host
FWU_P_OTA=199                              # temporary allow: all outbound (OTA window)
PROGRAM_DIR=$ZF_SYSROOT/opt/PROGRAM

# ver_lt A B: is dotted version A lower than B? (numeric parts only)
ver_lt() {
    a=$1 b=$2
    case "$a$b" in *[!0-9.]*) return 1 ;; esac
    while [ -n "$a$b" ]; do
        x=${a%%.*}; y=${b%%.*}
        if [ "$a" = "$x" ]; then a=""; else a=${a#*.}; fi
        if [ "$b" = "$y" ]; then b=""; else b=${b#*.}; fi
        x=${x:-0}; y=${y:-0}
        [ "$x" -lt "$y" ] && return 0
        [ "$x" -gt "$y" ] && return 1
    done
    return 1
}

fwu_installed() {  # fwu_installed COMPONENT -> version dir name under /opt/PROGRAM
    # newest first, as stock picks it (names are plain version numbers)
    # shellcheck disable=SC2010
    ls -1t "$PROGRAM_DIR/$1" 2>/dev/null | grep -v '^temp$' | head -n 1
}

fwu_versions() {
    for c in software library kernel control; do printf '%s=%s ' "$c" "$(fwu_installed "$c")"; done
    echo
}

# Is a print running? Moonraker (loopback, API key) first; if it can't say,
# fall back to "is Klipper running at all".
fwu_printing() {
    db="$MR_DATA_REL/database/moonraker-sql.db"
    if [ -f "$ZF_SYSROOT$db" ] && [ -x "$ZF_ROOTFS/usr/bin/python3" ]; then
        st=$(zf_chroot /opt/moonraker-env/bin/python - "$db" "$MOONRAKER_HTTP_PORT" 2>/dev/null <<'EOF'
import json, sqlite3, sys, urllib.request
key = sqlite3.connect(sys.argv[1]).execute(
    "SELECT password FROM authorized_users WHERE username='_API_KEY_USER_'").fetchone()[0]
req = urllib.request.Request(
    "http://127.0.0.1:%s/printer/objects/query?print_stats" % sys.argv[2], headers={"X-Api-Key": key})
print(json.load(urllib.request.urlopen(req, timeout=5))["result"]["status"]["print_stats"]["state"])
EOF
)
        case "$st" in
            printing|paused) return 0 ;;
            ?*) return 1 ;;      # standby, complete, cancelled, error
        esac
    fi
    # Moonraker couldn't tell (not running, or Klipper not ready)
    if grep -q -s '[k]lippy.py' /proc/[0-9]*/cmdline 2>/dev/null; then
        zf_log "fw: can't ask Moonraker for the print state, and Klipper is running"
        return 2
    fi
    return 1
}

# ---------------------------------------------------------------- download

# Temporarily allow outbound to a host's addresses (pref 198), run "$@", remove.
fwu_with_host_allowed() {
    host=$1; shift
    ips=$(fw_resolve "$host")
    [ -n "$ips" ] || { zf_log "fw: cannot resolve $host"; return 1; }
    fw_lock || return 1
    for ip in $ips; do zf_ip rule add pref "$FWU_P_TEMP" to "$ip" lookup main 2>/dev/null; done
    fw_unlock
    "$@"; rc=$?
    fw_lock && { while zf_ip rule del pref "$FWU_P_TEMP" 2>/dev/null; do :; done; fw_unlock; }
    return $rc
}

fwu_download() {  # fwu_download URL DEST (DEST: path on the printer)
    case "$1" in http://*|https://*) ;; *) zf_die "not a URL: $1" ;; esac
    host=$(echo "$1" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
    zf_log "fw: downloading $1"
    fwu_with_host_allowed "$host" zf_chroot /usr/bin/python3 -c '
import shutil, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=60) as r, open(sys.argv[2], "wb") as f:
    shutil.copyfileobj(r, f)
' "$1" "$2"
}

# ---------------------------------------------------------------- install

fw_cmd_install() {
    export ZF_COMPONENT=fw
    force=0; reboot_after=1; src=""
    for a in "$@"; do
        case "$a" in
            --force) force=1 ;;
            --no-reboot) reboot_after=0 ;;
            -*) zf_die "unknown option $a" ;;
            *) src=$a ;;
        esac
    done
    [ -n "$src" ] || zf_die "usage: zforge fw install <package.tgz|URL> [--force] [--no-reboot]"
    zf_mount_chroot

    # --- get the package
    case "$src" in
        http://*|https://*)
            pkg="$ZF_VAR/fw-download.tgz"; rm -f "$pkg"
            fwu_download "$src" "$ZF_HOME/var/fw-download.tgz" || zf_die "download failed"
            name=$(basename "${src%%\?*}") ;;
        *)
            pkg=$src; name=$(basename "$src")
            [ -f "$pkg" ] || zf_die "no such file: $pkg" ;;
    esac
    case "$name" in
        "$FWU_MACHINE"-zforge-*) zf_die "$name is a zforge package; use the zforge installer instead" ;;
        "$FWU_MACHINE"-*) ;;
        *) [ $force = 1 ] || zf_die "$name doesn't look like an $FWU_MACHINE update package (use --force to try anyway)" ;;
    esac
    sha=$(sha256sum "$pkg" | awk '{print $1}')

    # --- room to work
    need_kb=$(( $(wc -c <"$pkg") / 1024 * 2 + 20480 ))
    free_data=$(df -k "$ZF_SYSROOT/data" | awk 'NR==2 {print $4}')
    free_root=$(df -k "$ZF_SYSROOT/" | awk 'NR==2 {print $4}')
    [ "$free_data" -gt "$need_kb" ] || zf_die "not enough space on /data (${free_data} kB free, need ${need_kb} kB)"
    [ "$free_root" -gt 102400 ] || zf_die "not enough space on / (${free_root} kB free, need 100 MB)"

    # --- unpack like stock does
    zf_log "fw: unpacking $name (sha256 $sha)"
    rm -rf "$FWU_STAGE" && mkdir -p "$FWU_STAGE" || zf_die "cannot create $FWU_STAGE"
    if [ "$(dd if="$pkg" bs=2 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 1f8b ]; then
        gzip -dc "$pkg" | tar -xf - -C "$FWU_STAGE"
    else
        tar -xf "$pkg" -C "$FWU_STAGE"
    fi || { rm -rf "$FWU_STAGE"; zf_die "cannot unpack $name"; }
    [ -f "$FWU_STAGE/flashforge_init.sh" ] || { rm -rf "$FWU_STAGE"; zf_die "$name has no flashforge_init.sh"; }

    # --- checks
    fail() { rm -rf "$FWU_STAGE"; zf_die "$*"; }
    grep -q "^MACHINE=$FWU_MACHINE\$" "$FWU_STAGE/flashforge_init.sh" &&
        grep -q "^PID=$FWU_PID\$" "$FWU_STAGE/flashforge_init.sh" ||
        fail "package is not for $FWU_MACHINE (PID $FWU_PID)"
    if [ -e "$FWU_STAGE/screwflag" ] && [ $force = 0 ]; then
        fail "this is a Factory package: it skips the model check and overwrites Wi-Fi and printer configs. Use a regular package, or --force"
    fi
    comps=""
    for f in "$FWU_STAGE"/*-*.tar.xz; do
        [ -f "$f" ] || continue
        b=$(basename "$f" .tar.xz); c=${b%%-*}; v=${b#*-}
        tmp="$ZF_RUN/fwcheck.$$"; rm -rf "$tmp"; mkdir -p "$tmp"
        if ! tar -xf "$f" -C "$tmp" 2>/dev/null || ! ( cd "$tmp" && md5sum -c md5sum.list >/dev/null 2>&1 ); then
            rm -rf "$tmp"; fail "$b fails its md5sum.list check (corrupted package?)"
        fi
        rm -rf "$tmp"
        cur=$(fwu_installed "$c")
        if [ -n "$cur" ] && ver_lt "$v" "$cur" && [ $force = 0 ]; then
            fail "$c $v is older than the installed $cur (downgrade; use --force)"
        fi
        comps="$comps $c:${cur:-none}->$v"
    done
    [ -n "$comps" ] || fail "no components in the package"
    fwu_printing; p=$?
    if [ $p = 0 ]; then fail "a print is running; try again when it's done"; fi
    if [ $p = 2 ] && [ $force = 0 ]; then fail "can't tell whether a print is running (see the log); use --force if you're sure"; fi

    # --- save what the update may overwrite
    bk="$ZF_VAR/fw-backup/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bk"
    for f in /etc/wpa_supplicant.conf /etc/rtl_hostapd_2G.conf /opt/config/printer.cfg /opt/config/printer.base.cfg; do
        [ -f "$ZF_SYSROOT$f" ] && cp -p "$ZF_SYSROOT$f" "$bk/"
    done
    before=$(fwu_versions)
    echo "$before" >"$bk/versions-before.txt"
    zf_log "fw: installing:$comps (backup in ${bk#"$ZF_SYSROOT"})"

    # --- run the vendor installer exactly like stock auto_run.sh: absolute path
    # (its WORK_DIR=$(dirname $0) must be absolute), with machine and PID.
    chmod +x "$FWU_STAGE/flashforge_init.sh"
    "$FWU_STAGE/flashforge_init.sh" "$FWU_MACHINE" "$FWU_PID" >"$ZF_LOG/fw-install.log" 2>&1
    rc=$?

    # --- afterwards: the user's Wi-Fi, zforge's stock files, history
    for f in wpa_supplicant.conf rtl_hostapd_2G.conf; do
        if [ -f "$bk/$f" ] && ! cmp -s "$bk/$f" "$ZF_SYSROOT/etc/$f"; then
            cp -p "$bk/$f" "$ZF_SYSROOT/etc/$f" && zf_log "fw: restored /etc/$f (the update had replaced it)"
        fi
    done
    for f in printer.cfg printer.base.cfg; do
        if [ -f "$bk/$f" ] && ! cmp -s "$bk/$f" "$ZF_SYSROOT/opt/config/$f"; then
            zf_log "fw: the update changed /opt/config/$f (your previous copy: ${bk#"$ZF_SYSROOT"}/$f)"
        fi
    done
    hook_check
    after=$(fwu_versions)
    echo "$(date '+%F %T') rc=$rc $name sha256=$sha before: $before after: $after" >>"$FWU_HISTORY"
    rm -rf "$FWU_STAGE"
    if [ $rc != 0 ]; then
        zf_die "the vendor installer failed (rc=$rc); see $ZF_HOME/var/log/fw-install.log. Not rebooting."
    fi
    zf_log "fw: installed. Now: $after"
    if [ $reboot_after = 1 ]; then
        zf_log "fw: rebooting"
        sync; sleep 2; reboot
    else
        echo "installed; reboot to run the new firmware"
    fi
}

# ---------------------------------------------------------------- OTA window

fwu_parse_duration() {  # 30 / 30m -> seconds; 90s -> 90
    echo "$1" | grep -q -E '^([0-9]+[ms]?)?$' || return 1
    case "$1" in
        '') echo 1800 ;;
        *s) echo "${1%s}" ;;
        *m) echo $(( ${1%m} * 60 )) ;;
        *) echo $(( $1 * 60 )) ;;
    esac
}

fw_cmd_allow_ota() {
    secs=$(fwu_parse_duration "${1:-}") || zf_die "usage: zforge fw allow-ota [MINUTES|Nm|Ns]"
    fw_lock || exit 1
    zf_ip rule show | grep -q "^$FWU_P_OTA:" || zf_ip rule add pref "$FWU_P_OTA" lookup main
    fw_unlock
    [ -f "$ZF_RUN/ota-close.pid" ] && kill "$(cat "$ZF_RUN/ota-close.pid")" 2>/dev/null
    setsid "$ZF_SELF" __ota_close "$secs" </dev/null >/dev/null 2>&1 &
    echo "$!" >"$ZF_RUN/ota-close.pid"
    echo $(( $(date +%s) + secs )) >"$ZF_RUN/ota-until"
    zf_log "fw: outbound internet open for ${secs}s (OTA window)"
    echo "Outbound internet is open for $((secs / 60)) min ($secs s): the touchscreen can check for and"
    echo "download updates. It closes by itself (and at reboot); 'zforge fw close-ota' closes it now."
}

fw_cmd_close_ota() {
    fw_lock || exit 1
    while zf_ip rule del pref "$FWU_P_OTA" 2>/dev/null; do :; done
    fw_unlock
    rm -f "$ZF_RUN/ota-until"
    [ "${1:-}" = timer ] || { [ -f "$ZF_RUN/ota-close.pid" ] && kill "$(cat "$ZF_RUN/ota-close.pid")" 2>/dev/null; }
    rm -f "$ZF_RUN/ota-close.pid"
    zf_log "fw: OTA window closed"
}

fw_cmd_ota_timer() { sleep "$1"; fw_cmd_close_ota timer; }

fw_cmd_status() {
    echo "installed: $(fwu_versions)"
    if [ -f "$ZF_RUN/ota-until" ]; then
        echo "OTA window: open for $(( $(cat "$ZF_RUN/ota-until") - $(date +%s) ))s more"
    else
        echo "OTA window: closed"
    fi
    echo "history:"
    tail -n 5 "$FWU_HISTORY" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
}
