#!/bin/sh
# zforge installer.
#
# USB:  put Adventurer5MPro-zforge-<ver>.tgz (and optionally authorized_keys,
#       moonraker.cert + moonraker.key, moonraker.user.conf) on a FAT32 stick,
#       power on. Stock /opt/auto_run.sh unpacks the package into /data/update/
#       and runs this script as: flashforge_init.sh Adventurer5MPro 0024
# SSH:  tools/install/run-install.sh root@PRINTER dist/Adventurer5MPro-zforge-<ver>.tgz
#       (runs this script with --ssh)
#
# Upgrades keep /data/.zforge/etc (config, SSH keys) and var (Moonraker data,
# certificate, swap). Exit status != 0 leaves the printer booting normally.

set -u
WORK_DIR=$(cd "$(dirname "$0")" && pwd)
ZF=/data/.zforge
MODE=usb
[ "${1:-}" = "--ssh" ] && MODE=ssh

# Log next to the package on the USB stick if we can, else on /data.
LOGF=/data/zforge-install.log
if [ "$MODE" = usb ] && grep -q " /mnt " /proc/mounts; then LOGF=/mnt/zforge-install.log; fi
log() { echo "$(date '+%F %T' 2>/dev/null) $*" | tee -a "$LOGF" >&2; }
STOPPED=0
fail() {
    log "INSTALL FAILED: $*"
    # Over SSH, don't leave the printer without zforge (and its SSH server):
    # bring back whatever version is in place.
    if [ "$MODE" = ssh ] && [ "$STOPPED" = 1 ] && [ -x "$ZF/bin/zforge" ]; then
        log "restarting the installed zforge"
        "$ZF/bin/zforge" boot >>"$LOGF" 2>&1
    fi
    sync; exit 1
}

log "zforge installer $(cat "$WORK_DIR/zforge/share/VERSION" 2>/dev/null) mode=$MODE"

# ---------------------------------------------------------------- checks
[ "$(uname -m)" = armv7l ] || fail "not an armv7l machine"
if [ "$MODE" = usb ] && [ -n "${1:-}" ]; then
    [ "$1" = Adventurer5MPro ] && [ "${2:-}" = 0024 ] || fail "wrong machine ($1 $2), expected Adventurer5MPro 0024"
fi
grep -q " /data " /proc/mounts || fail "/data is not mounted"
[ -f "$WORK_DIR/zforge-rootfs-armv7.tar.gz" ] && [ -x "$WORK_DIR/zforge/bin/zforge" ] || fail "package incomplete"
if [ -d /opt/config/mod/.shell ] || [ -e /etc/init.d/S99moon ]; then
    fail "zmod is installed. Copy off your certs/keys, remove zmod (REMOVE_ZMOD FULL=1), then install zforge (see docs/install.md)"
fi
free_kb=$(df -k /data | awk 'NR==2 {print $4}')
[ "${free_kb:-0}" -gt 307200 ] || fail "need 300 MB free on /data, have ${free_kb} kB"
if [ -f "$WORK_DIR/SHA256SUMS" ] && command -v sha256sum >/dev/null; then
    ( cd "$WORK_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || fail "package checksum mismatch (corrupted copy?)"
fi

# ---------------------------------------------------------------- stop a running zforge (upgrade)
if [ -x "$ZF/bin/zforge" ]; then
    log "stopping the running zforge"
    "$ZF/bin/zforge" shutdown >>"$LOGF" 2>&1
    STOPPED=1
    grep -q " $ZF/rootfs/" /proc/mounts && fail "chroot still has mounts under $ZF/rootfs; reboot and retry"
fi

# ---------------------------------------------------------------- install
mkdir -p "$ZF/etc/ssh" "$ZF/var/log" && chmod 700 "$ZF/etc/ssh"

log "unpacking rootfs"
rm -rf "$ZF/rootfs.new"
mkdir -p "$ZF/rootfs.new"
# The stock BusyBox tar has no -z: decompress with gzip and pipe. Check both
# halves (BusyBox 1.29 ash may lack pipefail) and log the real error.
rm -f "$ZF/.gunzip-failed"
{ gzip -dc "$WORK_DIR/zforge-rootfs-armv7.tar.gz" 2>>"$LOGF" || : >"$ZF/.gunzip-failed"; } |
    tar -xf - -C "$ZF/rootfs.new" 2>>"$LOGF"
tar_rc=$?
if [ -e "$ZF/.gunzip-failed" ] || [ "$tar_rc" != 0 ]; then
    rm -f "$ZF/.gunzip-failed"; rm -rf "$ZF/rootfs.new"
    fail "rootfs unpack failed (tar rc=$tar_rc; see the errors above; free on /data: $(df -k /data | awk 'NR==2 {print $4}') kB)"
fi

log "installing scripts and binaries"
rm -rf "$ZF/code.new" && mkdir -p "$ZF/code.new"
cp -a "$WORK_DIR/zforge/." "$ZF/code.new/" || fail "copy failed"
for l in dropbear dropbearkey scp; do ln -sf dropbearmulti "$ZF/code.new/bin/$l"; done

# swap in the new tree (only now does anything existing change)
for d in bin lib share; do
    rm -rf "$ZF/$d.old"; [ -e "$ZF/$d" ] && mv "$ZF/$d" "$ZF/$d.old"
    mv "$ZF/code.new/$d" "$ZF/$d" || fail "could not install $d"
done
rm -rf "$ZF/rootfs.old"; [ -e "$ZF/rootfs" ] && mv "$ZF/rootfs" "$ZF/rootfs.old"
mv "$ZF/rootfs.new" "$ZF/rootfs" || fail "could not install rootfs"
rm -rf "$ZF/code.new" "$ZF/bin.old" "$ZF/lib.old" "$ZF/share.old" "$ZF/rootfs.old"

[ -f "$ZF/etc/zforge.conf" ] || cp "$ZF/share/zforge.conf.default" "$ZF/etc/zforge.conf"

# ---------------------------------------------------------------- imports from the USB stick
if [ "$MODE" = usb ] && grep -q " /mnt " /proc/mounts; then
    if [ -s /mnt/authorized_keys ]; then
        touch "$ZF/etc/ssh/authorized_keys"
        # append keys not already present
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            grep -qxF "$line" "$ZF/etc/ssh/authorized_keys" || echo "$line" >>"$ZF/etc/ssh/authorized_keys"
        done </mnt/authorized_keys
        chmod 600 "$ZF/etc/ssh/authorized_keys"
        log "imported SSH keys from the stick ($(grep -c . "$ZF/etc/ssh/authorized_keys") total)"
    fi
    if [ -s /mnt/moonraker.user.conf ]; then
        cp /mnt/moonraker.user.conf "$ZF/etc/moonraker.user.conf" && log "imported moonraker.user.conf"
    fi
fi
[ -s "$ZF/etc/ssh/authorized_keys" ] || log "WARNING: no SSH keys installed; put authorized_keys on the stick and re-run to get SSH access"

# ---------------------------------------------------------------- the two files on the stock system
cp "$ZF/share/S35zforge" /etc/init.d/S35zforge.new && chmod 755 /etc/init.d/S35zforge.new &&
    mv /etc/init.d/S35zforge.new /etc/init.d/S35zforge || fail "could not install /etc/init.d/S35zforge"
mkdir -p /etc/profile.d && cp "$ZF/share/zforge-profile.sh" /etc/profile.d/zforge.sh && chmod 644 /etc/profile.d/zforge.sh ||
    log "WARNING: could not install /etc/profile.d/zforge.sh (zforge is then at /data/.zforge/bin/zforge)"
rm -f "$ZF/disabled"

# Certificate import needs the chroot (openssl), so it runs after the rootfs is in place.
if [ "$MODE" = usb ] && [ -s /mnt/moonraker.cert ] && [ -s /mnt/moonraker.key ]; then
    if "$ZF/bin/zforge" tls import /mnt/moonraker.cert /mnt/moonraker.key >>"$LOGF" 2>&1; then
        log "imported Moonraker certificate from the stick"
    else
        log "WARNING: certificate import failed (see above); a new one will be generated"
    fi
fi

sync
log "zforge $(cat "$ZF/share/VERSION") installed"
if [ "$MODE" = usb ]; then
    # Rename the package on the stick, or the stock updater would install it
    # again on every boot while the stick stays in.
    for f in /mnt/Adventurer5MPro-zforge-*.tgz; do
        [ -f "$f" ] && mv "$f" "$f.installed" && log "renamed $(basename "$f") to $(basename "$f").installed on the stick"
    done
    sync
    log "rebooting (remove the USB stick)"
    sync; sleep 2; reboot
    sleep 30
fi
exit 0
