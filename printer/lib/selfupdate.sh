# zforge self-update, run on the printer:  zforge update PKG|URL [--force] [--no-reboot]
#
# Same installer and guarantees as tools/install/run-install.sh, started from
# the printer: the installer runs detached (it stops zforge's SSH server and
# replaces /data/.zforge, so it must not depend on this shell or the SSH
# session), and this command follows its log until it finishes.
#   success -> reboot (unless --no-reboot)
#   failure -> no reboot; the installer restarts the installed zforge

SU_STAGE=$ZF_SYSROOT/data/.zforge-update
SU_RUN=$ZF_SYSROOT/data/.zforge-update.run     # status of the detached run (outside the stage)

zf_cmd_update() {
    export ZF_COMPONENT=update
    force=0; reboot_after=1; src=""; downloaded=0
    for a in "$@"; do
        case "$a" in
            --force) force=1 ;;
            --no-reboot) reboot_after=0 ;;
            -*) zf_die "unknown option $a" ;;
            *) src=$a ;;
        esac
    done
    [ -n "$src" ] || zf_die "usage: zforge update <Adventurer5MPro-zforge-VER.tgz|URL> [--force] [--no-reboot]"
    zf_mount_chroot

    case "$src" in
        http://*|https://*)
            pkg="$ZF_VAR/zforge-download.tgz"; rm -f "$pkg"
            fwu_download "$src" "$ZF_HOME/var/zforge-download.tgz" || zf_die "download failed"
            downloaded=1
            name=$(basename "${src%%\?*}") ;;
        *)  pkg=$src; name=$(basename "$src")
            [ -f "$pkg" ] || zf_die "no such file: $pkg" ;;
    esac
    case "$name" in
        Adventurer5MPro-zforge-*.tgz) ;;
        *) zf_die "$name is not a zforge package (Adventurer5MPro-zforge-VER.tgz). Stock firmware: zforge fw install" ;;
    esac

    # unpack and check before touching anything
    rm -rf "$SU_STAGE" "$SU_RUN" && mkdir -p "$SU_STAGE" "$SU_RUN" || zf_die "cannot create $SU_STAGE"
    tar -xf "$pkg" -C "$SU_STAGE" 2>/dev/null || { rm -rf "$SU_STAGE"; zf_die "cannot unpack $name"; }
    [ -x "$SU_STAGE/zforge/bin/zforge" ] && [ -f "$SU_STAGE/flashforge_init.sh" ] ||
        { rm -rf "$SU_STAGE"; zf_die "$name doesn't contain a zforge installer"; }
    [ $downloaded = 1 ] && rm -f "$pkg"
    new=$(cat "$SU_STAGE/zforge/share/VERSION" 2>/dev/null)
    cur=$(cat "$ZF_SHARE/VERSION" 2>/dev/null)
    if [ -n "$cur" ] && [ -n "$new" ] && ver_lt "$new" "$cur" && [ $force = 0 ]; then
        rm -rf "$SU_STAGE"; zf_die "$new is older than the installed $cur (use --force to downgrade)"
    fi
    zf_log "update: zforge ${cur:-?} -> ${new:-?}"

    # Detached run: survives this shell, the SSH server stopping, and a
    # dropped SSH session. The script is inline (not a file in /data/.zforge,
    # which the installer replaces).
    # shellcheck disable=SC2016  # expanded by the detached shell
    setsid sh -c '
        st=$1; run=$2; reboot_cmd=$3; do_reboot=$4
        sh "$st/flashforge_init.sh" --ssh >"$run/log" 2>&1
        rc=$?
        if [ $rc = 0 ]; then rm -rf "$st"; fi
        sync
        echo "$rc" >"$run/rc"
        if [ $rc = 0 ] && [ "$do_reboot" = 1 ]; then sleep 3; $reboot_cmd; fi
    ' sh "$SU_STAGE" "$SU_RUN" "$ZF_REBOOT" "$reboot_after" </dev/null >/dev/null 2>&1 &

    # follow the installer's log until it's done
    shown=0
    while [ ! -f "$SU_RUN/rc" ]; do
        sleep 1
        if [ -f "$SU_RUN/log" ]; then
            n=$(wc -l <"$SU_RUN/log")
            # by line number: lines written meanwhile wait for the next round
            [ "$n" -gt "$shown" ] && { sed -n "$((shown + 1)),${n}p" "$SU_RUN/log"; shown=$n; }
        fi
    done
    sed -n "$((shown + 1)),\$p" "$SU_RUN/log"
    rc=$(cat "$SU_RUN/rc")
    if [ "$rc" = 0 ]; then
        if [ $reboot_after = 1 ]; then
            echo "zforge ${new:-?} installed; the printer reboots now"
        else
            echo "zforge ${new:-?} installed; reboot to start it"
        fi
        return 0
    fi
    echo "UPDATE FAILED (rc=$rc); not rebooting. The installed zforge was restarted." >&2
    return 1
}
