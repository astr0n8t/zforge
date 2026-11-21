#!/bin/sh
# Run the read-only zforge probe on the printer and unpack the report locally.
#
#   tools/probe/run-probe.sh root@192.168.1.50 [OUTDIR]
#
# Needs only an ssh client on the PC and `sh` on the printer (nothing is
# copied to or installed on the printer). Extra ssh options can be passed
# via SSH_OPTS, e.g. SSH_OPTS="-o HostKeyAlgorithms=+ssh-rsa" for old dropbear.
#
# The printer-side progress/errors are saved to OUTDIR/probe.log; if anything
# goes wrong, that file is what to look at (or send along).

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SSH=${SSH:-ssh}

[ $# -ge 1 ] || { echo "usage: $0 root@PRINTER [OUTDIR]" >&2; exit 2; }
TARGET=$1
OUTDIR=${2:-probe-$(date +%Y%m%d-%H%M%S)}

mkdir -p "$OUTDIR" || exit 1
LOG="$OUTDIR/probe.log"
ARCHIVE="$OUTDIR/probe.archive"
echo "probing $TARGET -> $OUTDIR (log: $LOG)" >&2

# stdout is the archive; printer-side progress and errors go to the log.
: >"$LOG"
# shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split
$SSH ${SSH_OPTS:-} "$TARGET" 'sh -s' <"$HERE/zforge-probe.sh" >"$ARCHIVE" 2>"$LOG" &
pid=$!
# echo new log lines while it runs
shown=0
while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    n=$(wc -l <"$LOG")
    [ "$n" -gt "$shown" ] && { tail -n $((n - shown)) "$LOG" | sed 's/^/  /' >&2; shown=$n; }
done
wait "$pid"
status=$?
n=$(wc -l <"$LOG"); [ "$n" -gt "$shown" ] && tail -n $((n - shown)) "$LOG" | sed 's/^/  /' >&2

fail() {
    echo >&2
    echo "PROBE FAILED: $*" >&2
    echo "ssh exit status: $status" >&2
    echo "--- last lines of $LOG ---" >&2
    tail -n 20 "$LOG" >&2
    echo "--- end ---" >&2
    echo "Please send $LOG (and the error above)." >&2
    exit 1
}

[ -s "$ARCHIVE" ] || fail "no data came back from the printer"

# Detect what the printer could produce: gzip (1f 8b) or plain tar.
magic=$(dd if="$ARCHIVE" bs=2 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
mkdir -p "$OUTDIR/report"
case "$magic" in
    1f8b) mv "$ARCHIVE" "$OUTDIR/probe.tar.gz"; tar -xzf "$OUTDIR/probe.tar.gz" -C "$OUTDIR/report" || fail "could not unpack gzip archive" ;;
    *)    mv "$ARCHIVE" "$OUTDIR/probe.tar";    tar -xf  "$OUTDIR/probe.tar"    -C "$OUTDIR/report" || fail "could not unpack archive (magic $magic)" ;;
esac

[ -f "$OUTDIR/report/SUMMARY.txt" ] || fail "archive unpacked but has no SUMMARY.txt (probe stopped early?)"
echo >&2
cat "$OUTDIR/report/SUMMARY.txt"
echo >&2
echo "full report: $OUTDIR/report" >&2
echo "note: the report includes printer config files; review before sharing publicly." >&2
