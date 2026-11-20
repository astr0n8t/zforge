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
}

zf_load_config() {
    zf_defaults
    # shellcheck disable=SC1090
    if [ -f "$ZF_CONF" ]; then . "$ZF_CONF"; fi
}

zf_is_mounted() {  # zf_is_mounted MOUNTPOINT
    grep -q " $1 " "$ZF_SYSROOT/proc/mounts" 2>/dev/null
}

# Run a command inside the zforge chroot with a clean environment.
zf_chroot() {
    chroot "$ZF_ROOTFS" /usr/bin/env -i \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 TZ="${TZ:-UTC}" "$@"
}

# The iproute2 we ship (in the chroot): known version, supports ipproto/dport rules.
zf_ip() {
    if [ -n "${ZF_IP:-}" ]; then "$ZF_IP" "$@"; else zf_chroot /sbin/ip "$@"; fi
}

# Bind-mount what the chroot needs. Idempotent.
zf_mount_chroot() {
    r=$ZF_ROOTFS
    zf_is_mounted "$ZF_HOME/rootfs/proc" || mount -t proc proc "$r/proc"
    zf_is_mounted "$ZF_HOME/rootfs/sys"  || mount -t sysfs sysfs "$r/sys"
    zf_is_mounted "$ZF_HOME/rootfs/dev"  || mount -o bind /dev "$r/dev"
    zf_is_mounted "$ZF_HOME/rootfs/tmp"  || mount -o bind /tmp "$r/tmp"   # /tmp/uds (Klipper API socket)
    mkdir -p "$r/data"
    zf_is_mounted "$ZF_HOME/rootfs/data" || mount -o bind /data "$r/data"
    mkdir -p "$r/opt/config"
    zf_is_mounted "$ZF_HOME/rootfs/opt/config" || mount -o bind /opt/config "$r/opt/config"
    # name resolution and time zone follow the printer
    [ -f /etc/resolv.conf ] && { zf_is_mounted "$ZF_HOME/rootfs/etc/resolv.conf" ||
        mount -o bind /etc/resolv.conf "$r/etc/resolv.conf"; }
    return 0
}

zf_umount_chroot() {
    for m in etc/resolv.conf opt/config data tmp dev sys proc; do
        zf_is_mounted "$ZF_HOME/rootfs/$m" && umount "$ZF_ROOTFS/$m" 2>/dev/null
    done
    return 0
}

# Is the clock plausible? (The printer may boot at 1970 until NTP syncs.)
zf_clock_ok() {
    [ "$(date +%Y)" -ge 2025 ]
}
