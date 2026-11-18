#!/bin/sh
# Run the read-only zforge probe on the printer and unpack the report locally.
#
#   tools/probe/run-probe.sh root@192.168.1.50 [OUTDIR]
#
# Needs only an ssh client on the PC and `sh` on the printer (nothing is
# copied to or installed on the printer). Extra ssh options can be passed
# via SSH_OPTS, e.g. SSH_OPTS="-o HostKeyAlgorithms=+ssh-rsa" for old dropbear.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SSH=${SSH:-ssh}

[ $# -ge 1 ] || { echo "usage: $0 root@PRINTER [OUTDIR]" >&2; exit 2; }
TARGET=$1
OUTDIR=${2:-probe-$(date +%Y%m%d-%H%M%S)}

mkdir -p "$OUTDIR"
echo "probing $TARGET -> $OUTDIR" >&2
# shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split
$SSH ${SSH_OPTS:-} "$TARGET" 'sh -s' <"$HERE/zforge-probe.sh" >"$OUTDIR/probe.tar.gz"

mkdir -p "$OUTDIR/report"
tar -xzf "$OUTDIR/probe.tar.gz" -C "$OUTDIR/report"
echo >&2
cat "$OUTDIR/report/SUMMARY.txt"
echo >&2
echo "full report: $OUTDIR/report  (archive: $OUTDIR/probe.tar.gz)" >&2
echo "note: the report includes printer config files; review before sharing publicly." >&2
