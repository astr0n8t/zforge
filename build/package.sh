#!/bin/sh
# Assemble the installable package from printer/, installer/ and the build
# outputs in dist/ (see build-rootfs.sh):
#
#   dist/Adventurer5MPro-zforge-<ver>.tgz   (plain tar, like stock updates;
#                                            the stock USB updater installs it)
#   dist/rescue-disable/flashforge_init.sh, dist/rescue-uninstall/flashforge_init.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
. "$HERE/versions.env"
DIST=${1:-$TOP/dist}

for f in zforge-rootfs-armv7.tar.gz dropbearmulti sftp-server; do
    [ -f "$DIST/$f" ] || { echo "missing $DIST/$f (run build/build-rootfs.sh first)" >&2; exit 1; }
done

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
P="$STAGE/pkg"
mkdir -p "$P/zforge/bin" "$P/zforge/lib" "$P/zforge/share"

cp "$TOP/installer/flashforge_init.sh" "$P/"
cp "$TOP/printer/bin/zforge" "$P/zforge/bin/"
cp "$DIST/dropbearmulti" "$DIST/sftp-server" "$P/zforge/bin/"
cp "$TOP/printer/lib/"*.sh "$P/zforge/lib/"
cp "$TOP/printer/hook/S35zforge" "$TOP/printer/share/"* "$P/zforge/share/"
echo "$ZFORGE_VERSION" >"$P/zforge/share/VERSION"
chmod 755 "$P/flashforge_init.sh" "$P/zforge/bin/"* "$P/zforge/share/S35zforge"
cp "$DIST/zforge-rootfs-armv7.tar.gz" "$P/"
( cd "$P" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | xargs sha256sum >SHA256SUMS )

OUT="$DIST/Adventurer5MPro-zforge-$ZFORGE_VERSION.tgz"
tar -C "$P" --owner=0 --group=0 -cf "$OUT" .
for r in disable uninstall firewall-open; do
    mkdir -p "$DIST/rescue-$r"
    cp "$TOP/rescue/$r/flashforge_init.sh" "$DIST/rescue-$r/flashforge_init.sh"
done
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
