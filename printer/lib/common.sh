# shellcheck shell=sh disable=SC2034  # variables are used by the files that source this
# zforge common definitions. Sourced by bin/zforge and the hook.
# Runs on the stock printer's BusyBox ash, so: POSIX sh only.
#
# ZF_SYSROOT prefixes every host path so tests can run against a fake
# root directory. On the printer it is empty.

ZF_SYSROOT=${ZF_SYSROOT:-}

# Paths as seen on the printer. The chroot sees the same /data/... paths
# because /data is bind-mounted into it.
ZF_HOME=/data/.zforge
ZF=$ZF_SYSROOT$ZF_HOME
ZF_ROOTFS=$ZF/rootfs
ZF_BIN=$ZF/bin
ZF_LIB=$ZF/lib
ZF_SHARE=$ZF/share
ZF_ETC=$ZF/etc
ZF_VAR=$ZF/var
ZF_LOG=$ZF_VAR/log
ZF_RUN=$ZF_SYSROOT/var/run/zforge
ZF_CONF=$ZF_ETC/zforge.conf
ZF_HOOK=$ZF_SYSROOT/etc/init.d/S35zforge
ZF_PROFILE=$ZF_SYSROOT/etc/profile.d/zforge.sh
ZF_DISABLED=$ZF/disabled

MR_DATA_REL=$ZF_HOME/var/moonraker      # path inside the chroot
MR_DATA=$ZF_SYSROOT$MR_DATA_REL         # same directory, host side

zf_log() {
    _msg="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) [${ZF_COMPONENT:-zforge}] $*"
    echo "$_msg" >&2
    if [ -d "$ZF_LOG" ]; then echo "$_msg" >>"$ZF_LOG/zforge.log" 2>/dev/null || true; fi
}
zf_die() { zf_log "ERROR: $*"; exit 1; }

# Defaults; etc/zforge.conf overrides them.
zf_defaults() {
    NET_IFACES="wlan0 eth0"
    SSH_PORT=22
    MOONRAKER=on
    MOONRAKER_HTTP_PORT=7125      # loopback-only; blocked from the network in every profile
    MOONRAKER_HTTPS_PORT=7130
    SWAP_MB=128
    NTP_SERVERS="pool.ntp.org"
    TLS_DAYS=825
    TLS_EXTRA_NAMES=""
    ZF_REBOOT=reboot              # command zforge uses to reboot (tests override it)
    # firewall (Phase 2)
    FIREWALL_PROFILE=lan
    LAN_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
    ALLOW_OUT=""
    SSH_ALLOW=""
    MOONRAKER_ALLOW=""
    STOCK_LAN_API=off
    FW_CONFIRM_SECONDS=120
    # camera (Phase 2)
    CAMERA=on
    CAMERA_DEVICE=/dev/video0
    CAMERA_RES=1280x720
    CAMERA_FPS=15
    CAMERA_PORT=8080
    CAMERA_ALLOW=""
    # Moonraker prints start through the touchscreen app, so the screen shows them
    SCREEN_PRINT=on
}

zf_load_config() {
    zf_defaults
    # shellcheck disable=SC1090
    if [ -f "$ZF_CONF" ]; then . "$ZF_CONF"; fi
}

zf_is_mounted() {  # zf_is_mounted MOUNTPOINT
    grep -q " $1 " "$ZF_SYSROOT/proc/mounts" 2>/dev/null
}

# The chroot. Klipper's SDCARD_PRINT_FILE walks the whole virtual_sdcard root
# (/data) with os.walk(followlinks=True), so nothing under /data may loop or
# be huge:
#   - the chroot runs at /run/zforge/root, a bind of /data/.zforge/rootfs, and
#     all its mounts (proc, sys, dev, tmp, data, ...) are made under that bind,
#     where they're invisible at the /data/... path;
#   - /data/.zforge/rootfs itself is covered by an empty read-only tmpfs, so
#     the walk sees an empty folder instead of thousands of files;
#   - Moonraker's gcodes and config/stock folders are bind mounts inside the
#     chroot only (a gcodes -> /data symlink would loop the walk).
ZF_CROOT_REL=/run/zforge/root
ZF_CROOT=$ZF_SYSROOT$ZF_CROOT_REL

# Run a command inside the zforge chroot with a clean environment.
zf_chroot() {
    zf_root_ready || return 1
    chroot "$ZF_CROOT" /usr/bin/env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 TZ="${TZ:-UTC}" "$@"
}

# The iproute2 we ship (in the chroot): known version, supports ipproto/dport rules.
zf_ip() {
    if [ -n "${ZF_IP:-}" ]; then "$ZF_IP" "$@"; else zf_chroot /sbin/ip "$@"; fi
}

# Bind the rootfs at /run/zforge/root, then hide its /data path. Idempotent.
zf_root_ready() {
    if ! zf_is_mounted "$ZF_CROOT_REL"; then
        # never bind the hiding tmpfs by mistake
        zf_is_mounted "$ZF_HOME/rootfs" && umount "$ZF_ROOTFS"
        mkdir -p "$ZF_CROOT" && mount -o bind "$ZF_ROOTFS" "$ZF_CROOT" || return 1
        mount --make-private "$ZF_CROOT" 2>/dev/null   # mounts under it must not propagate back
    fi
    zf_is_mounted "$ZF_HOME/rootfs" ||
        mount -t tmpfs -o ro,size=16k,mode=755 zforge-hidden "$ZF_ROOTFS"
    return 0
}

# Everything the chroot needs. Idempotent.
zf_mount_chroot() {
    zf_root_ready || return 1
    r=$ZF_CROOT
    zf_is_mounted "$ZF_CROOT_REL/proc" || mount -t proc proc "$r/proc"
    zf_is_mounted "$ZF_CROOT_REL/sys"  || mount -t sysfs sysfs "$r/sys"
    zf_is_mounted "$ZF_CROOT_REL/dev"  || mount -o bind /dev "$r/dev"
    zf_is_mounted "$ZF_CROOT_REL/tmp"  || mount -o bind /tmp "$r/tmp"   # /tmp/uds (Klipper API socket)
    mkdir -p "$r/data" "$r/opt/config"
    zf_is_mounted "$ZF_CROOT_REL/data" || mount -o bind /data "$r/data"
    zf_is_mounted "$ZF_CROOT_REL/opt/config" || mount -o bind /opt/config "$r/opt/config"
    # name resolution and time zone follow the printer
    [ -f /etc/resolv.conf ] && { zf_is_mounted "$ZF_CROOT_REL/etc/resolv.conf" ||
        mount -o bind /etc/resolv.conf "$r/etc/resolv.conf"; }
    # Moonraker's folders that point elsewhere: real (empty) dirs on disk,
    # bind mounts in the chroot only. (Before 0.4.1 these were symlinks.)
    for d in gcodes config/stock; do
        [ -L "$MR_DATA/$d" ] && rm -f "$MR_DATA/$d"
        mkdir -p "$MR_DATA/$d"
    done
    zf_is_mounted "$ZF_CROOT_REL$MR_DATA_REL/gcodes" ||
        mount -o bind /data "$r$MR_DATA_REL/gcodes"
    zf_is_mounted "$ZF_CROOT_REL$MR_DATA_REL/config/stock" ||
        mount -o bind /opt/config "$r$MR_DATA_REL/config/stock"
    return 0
}

zf_umount_chroot() {
    for m in "$MR_DATA_REL/config/stock" "$MR_DATA_REL/gcodes" \
             etc/resolv.conf opt/config data tmp dev sys proc; do
        m=${m#/}
        zf_is_mounted "$ZF_CROOT_REL/$m" && umount "$ZF_CROOT/$m" 2>/dev/null
    done
    zf_is_mounted "$ZF_CROOT_REL" && umount "$ZF_CROOT" 2>/dev/null
    zf_is_mounted "$ZF_HOME/rootfs" && umount "$ZF_ROOTFS" 2>/dev/null
    return 0
}

# Is the clock plausible? (The printer may boot at 1970 until NTP syncs.)
zf_clock_ok() {
    [ "$(date +%Y)" -ge 2025 ]
}
