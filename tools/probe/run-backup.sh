#!/bin/sh
# Back up the printer's block devices to the PC, with md5 verification.
#
#   tools/probe/run-backup.sh [-m MAX_MB] [-a] [-n] root@PRINTER [OUTDIR]
#
#   -m MAX_MB  skip partitions larger than this (default 1024); they are
#              listed in the manifest so you can fetch them later with -a
#   -a         back up everything regardless of size
#   -n         dry run: only show what would be saved
#
# For whole disks only the first 16 MiB is saved (partition table and
# bootloader area); the partitions themselves are saved individually.
# Images are gzipped on the PC side to keep load off the printer's CPU.
# Run it while the printer is idle: mounted filesystems are imaged live.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SSH=${SSH:-ssh}
MAX_MB=1024
ALL=0
DRY=0
DISK_HEAD_KB=16384

while getopts m:an opt; do
    case $opt in
        m) MAX_MB=$OPTARG ;;
        a) ALL=1 ;;
        n) DRY=1 ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || { echo "usage: $0 [-m MAX_MB] [-a] [-n] root@PRINTER [OUTDIR]" >&2; exit 2; }
TARGET=$1
OUTDIR=${2:-backup-$(date +%Y%m%d-%H%M%S)}

# Reuse one ssh connection for the many calls below (one password prompt).
CTL_DIR=$(mktemp -d)
trap 'rm -rf "$CTL_DIR"' EXIT
case "$SSH" in
    ssh|*/ssh) SSH_MUX="-o ControlMaster=auto -o ControlPath=$CTL_DIR/c -o ControlPersist=60" ;;
    *) SSH_MUX="" ;;
esac

remote() {  # remote ARGS... : run zforge-backup.sh on the printer with ARGS
    # shellcheck disable=SC2086
    $SSH $SSH_MUX ${SSH_OPTS:-} "$TARGET" "sh -s $*" <"$HERE/zforge-backup.sh"
}

md5_local() {
    if command -v md5sum >/dev/null 2>&1; then md5sum | awk '{print $1}'; else md5 -q; fi
}

LIST=$(remote list)
[ -n "$LIST" ] || { echo "no block devices reported" >&2; exit 1; }

mkdir -p "$OUTDIR"
MANIFEST="$OUTDIR/manifest.txt"
{
    echo "# zforge backup of $TARGET on $(date)"
    echo "# name size_kb kind action md5"
} >"$MANIFEST"

echo "$LIST" | while read -r name kb kind; do
    count=""
    case "$kind" in
        disk) count=$DISK_HEAD_KB; [ "$kb" != "?" ] && [ "$kb" -lt "$count" ] && count=$kb ;;
    esac
    if [ -z "$count" ] && [ "$ALL" = 0 ] && [ "$kb" != "?" ] && [ "$kb" -gt $((MAX_MB * 1024)) ]; then
        echo "skip  $name ($((kb / 1024)) MiB > $MAX_MB MiB, use -a)" >&2
        echo "$name $kb $kind skipped -" >>"$MANIFEST"
        continue
    fi
    label=$name; [ -n "$count" ] && label="$name (first $((count / 1024)) MiB)"
    if [ "$DRY" = 1 ]; then
        echo "would save $label" >&2
        continue
    fi
    echo "save  $label ..." >&2
    out="$OUTDIR/$name.img.gz"
    remote dump "$name" $count | gzip -c >"$out"
    bytes=$(gzip -dc "$out" | wc -c | tr -d ' ')
    expect=""
    if [ -n "$count" ]; then expect=$((count * 1024)); elif [ "$kb" != "?" ]; then expect=$((kb * 1024)); fi
    if [ "$bytes" = 0 ] || { [ -n "$expect" ] && [ "$bytes" != "$expect" ]; }; then
        echo "      FAILED: got $bytes bytes, expected ${expect:-?} (see error above)" >&2
        echo "$name $kb $kind FAILED $bytes-bytes" >>"$MANIFEST"
        rm -f "$out"
        continue
    fi
    want=$(remote sum "$name" $count)
    got=$(gzip -dc "$out" | md5_local)
    if [ "$want" = "$got" ]; then
        echo "      ok $got" >&2
        echo "$name $kb $kind saved $got" >>"$MANIFEST"
    else
        # Live, mounted filesystems can change between the two reads.
        echo "      MISMATCH printer=$want local=$got (live fs changed? re-run when idle)" >&2
        echo "$name $kb $kind MISMATCH $got/$want" >>"$MANIFEST"
    fi
done

echo "done: $OUTDIR (see manifest.txt)" >&2
