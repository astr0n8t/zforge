#!/bin/sh
# zforge-backup: printer-side helper for raw block-device backups.
#
# Read-only. Two modes:
#   sh -s list            print "NAME SIZE_KB KIND" for each block device worth saving
#   sh -s dump NAME [KB]  stream /dev/NAME to stdout (first KB kilobytes if given)
#   sh -s sum NAME [KB]   print md5 of the same byte range (for verification)
#
# Driven from the PC by tools/probe/run-backup.sh. Never writes to the printer.

set -u
PATH="$PATH:/sbin:/usr/sbin:/bin:/usr/bin"

die() { echo "[backup] $*" >&2; exit 1; }

# Output: NAME SIZE_KB KIND LABEL
# KIND: disk = whole device (we only save its head: partition table +
# bootloader area), part = partition, hwboot = eMMC hardware boot partition,
# mtd = raw NAND. LABEL is the GPT partition name (e.g. rootfs), or "-".
label_of() {
    _l=$(sed -n 's/^PARTNAME=//p' "/sys/class/block/$1/uevent" 2>/dev/null)
    echo "${_l:--}"
}

list() {
    awk 'NR>2 {print $4, $3}' /proc/partitions | while read -r name kb; do
        case "$name" in
            loop*|ram*|zram*|sr*|dm-*|nbd*|mmcblk*rpmb) continue ;;
            mmcblk*boot[0-9]) kind=hwboot ;;
            mtdblock*)
                # same flash as /dev/mtdN, which is listed below when present
                [ -r /proc/mtd ] && continue
                kind=part ;;
            mmcblk[0-9]|sd[a-z]|vd[a-z]) kind=disk ;;
            *) kind=part ;;
        esac
        echo "$name $kb $kind $(label_of "$name")"
    done
    # raw NAND (no block layer): offer /dev/mtdN char devices
    if [ -r /proc/mtd ]; then
        tail -n +2 /proc/mtd | while read -r dev size _erase label; do
            echo "${dev%:} $(( 0x$size / 1024 )) mtd $(echo "$label" | tr -d '"')"
        done
    fi
}

DEV_DIR=${ZFORGE_DEV_DIR:-/dev}   # overridable for testing only

devpath() {
    case "$1" in */*|*..*) die "bad name $1" ;; esac
    [ -e "$DEV_DIR/$1" ] || die "no such device $DEV_DIR/$1"
    [ -r "$DEV_DIR/$1" ] || die "cannot read $DEV_DIR/$1"
    echo "$DEV_DIR/$1"
}

stream() {
    dev=$(devpath "$1") || exit 1
    # dd prints its record counts on stderr; keep only real errors visible
    if [ -n "${2:-}" ]; then
        dd if="$dev" bs=1024 count="$2" 2>&1 >&3 3>&- | grep -v -E 'records (in|out)|bytes .* copied' >&2
    else
        dd if="$dev" bs=65536 2>&1 >&3 3>&- | grep -v -E 'records (in|out)|bytes .* copied' >&2
    fi
    return 0
}

exec 3>&1
case "${1:-}" in
    list) list ;;
    dump) [ -n "${2:-}" ] || die "dump NAME [KB]"; stream "$2" "${3:-}" ;;
    sum)  [ -n "${2:-}" ] || die "sum NAME [KB]"; stream "$2" "${3:-}" 3>&1 | md5sum | awk '{print $1}' ;;
    *) die "usage: list | dump NAME [KB] | sum NAME [KB]" ;;
esac
