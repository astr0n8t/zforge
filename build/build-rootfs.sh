#!/bin/sh
# Build the zforge armv7 userland.
#
#   build/build-rootfs.sh [OUTDIR]        (default: dist/)
#
# Produces:
#   OUTDIR/zforge-rootfs-armv7.tar.gz   Alpine chroot with Moonraker (unpacked to /data/.zforge/rootfs)
#   OUTDIR/dropbearmulti, OUTDIR/sftp-server   static binaries for the stock system
#
# Runs natively on armv7, or on x86_64 with qemu-user-static registered in
# binfmt_misc with the F (fix-binary) flag, e.g. on Debian/Ubuntu:
#   apt-get install qemu-user-static binfmt-support
# (GitHub Actions: docker/setup-qemu-action does the same.)
#
# If outbound TLS goes through an intercepting proxy, set BUILD_CA_BUNDLE to its
# CA file; it is used during the build only and never ends up in the rootfs.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/versions.env"

OUTDIR=$(mkdir -p "${1:-$HERE/../dist}" && cd "${1:-$HERE/../dist}" && pwd)
WORK=${WORK:-$HERE/../work}
ROOT="$WORK/rootfs"
CACHE="$WORK/cache"
TARBALL="alpine-minirootfs-$ALPINE_VERSION-armv7.tar.gz"
URL="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/armv7/$TARBALL"

log() { echo "[build] $*" >&2; }
[ "$(id -u)" = 0 ] || { echo "needs root (chroot, mounts)" >&2; exit 1; }

case "$(uname -m)" in
    armv7l|armv8l) ;;
    *) [ -e /proc/sys/fs/binfmt_misc/qemu-arm ] ||
        { echo "no qemu-arm binfmt registered; see header of $0" >&2; exit 1; } ;;
esac

mkdir -p "$CACHE"
if [ ! -f "$CACHE/$TARBALL" ]; then
    log "downloading $URL"
    curl -fsSL -o "$CACHE/$TARBALL.part" "$URL"
    mv "$CACHE/$TARBALL.part" "$CACHE/$TARBALL"
fi
echo "$ALPINE_MINIROOTFS_SHA256  $CACHE/$TARBALL" | sha256sum -c - >/dev/null ||
    { echo "sha256 mismatch for $TARBALL" >&2; exit 1; }

log "unpacking minirootfs"
rm -rf "$ROOT" && mkdir -p "$ROOT"
tar -xzf "$CACHE/$TARBALL" -C "$ROOT"
cat >"$ROOT/etc/apk/repositories" <<EOF
https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main
https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/community
EOF
cp /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true
cp "$HERE/rootfs-inside.sh" "$ROOT/rootfs-inside.sh"

CA_ENV=""
if [ -n "${BUILD_CA_BUNDLE:-}" ]; then
    cp "$BUILD_CA_BUNDLE" "$ROOT/build-ca.crt"
    CA_ENV="SSL_CERT_FILE=/build-ca.crt PIP_CERT=/build-ca.crt GIT_SSL_CAINFO=/build-ca.crt REQUESTS_CA_BUNDLE=/build-ca.crt"
fi
mkdir -p "$ROOT/out"

log "running build inside the armv7 chroot (slow under qemu)"
# Private mount namespace: the bind mounts vanish with it, even on failure.
unshare -m sh -eu -c '
    ROOT=$1; OUTDIR=$2; shift 2
    mount -t proc proc "$ROOT/proc"
    mount --rbind /dev "$ROOT/dev"
    mount --bind "$OUTDIR" "$ROOT/out"
    exec chroot "$ROOT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
        http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" \
        "$@" /bin/sh /rootfs-inside.sh
' sh "$ROOT" "$OUTDIR" $CA_ENV \
    MOONRAKER_REPO="$MOONRAKER_REPO" MOONRAKER_REF="$MOONRAKER_REF" \
    DROPBEAR_REPO="$DROPBEAR_REPO" DROPBEAR_REF="$DROPBEAR_REF" \
    OPENSSH_REPO="$OPENSSH_REPO" OPENSSH_REF="$OPENSSH_REF"

log "packing rootfs"
rm -f "$ROOT/rootfs-inside.sh" "$ROOT/build-ca.crt" "$ROOT/etc/resolv.conf"
rmdir "$ROOT/out"
# a fresh, empty resolv.conf: zforge bind-mounts the printer's at runtime
: >"$ROOT/etc/resolv.conf"
tar -C "$ROOT" --numeric-owner -czf "$OUTDIR/zforge-rootfs-armv7.tar.gz" .
( cd "$OUTDIR" && sha256sum zforge-rootfs-armv7.tar.gz dropbearmulti sftp-server >SHA256SUMS )
log "done: $(du -h "$OUTDIR/zforge-rootfs-armv7.tar.gz" | cut -f1) rootfs; outputs in $OUTDIR"
