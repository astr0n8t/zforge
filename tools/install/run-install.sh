#!/bin/sh
# Install or upgrade zforge over SSH. Needs a working root SSH login, i.e. an
# earlier zforge install; first installs go via USB (see docs/install.md).
#
#   tools/install/run-install.sh root@PRINTER dist/Adventurer5MPro-zforge-<ver>.tgz
#
# The printer reboots at the end, only if the install succeeded. Keys,
# certificate, API key and zforge.conf are kept.
#
# Env: SSH (default ssh), SSH_OPTS (extra ssh options), REMOTE_REBOOT
# (command run on the printer to reboot; default "reboot"; tests override it).
set -eu
SSH=${SSH:-ssh}
REMOTE_REBOOT=${REMOTE_REBOOT:-reboot}
[ $# -eq 2 ] || { echo "usage: $0 root@PRINTER Adventurer5MPro-zforge-<ver>.tgz" >&2; exit 2; }
TARGET=$1 PKG=$2
[ -f "$PKG" ] || { echo "no such file: $PKG" >&2; exit 1; }

# Only zforge packages: a stock firmware package's own flashforge_init.sh
# would run here without its model check.
case "$(basename "$PKG")" in
    Adventurer5MPro-zforge-*.tgz) ;;
    *) echo "$(basename "$PKG") is not a zforge package (Adventurer5MPro-zforge-<ver>.tgz)." >&2
       echo "For stock firmware updates use: ssh $TARGET zforge fw install <package>" >&2
       exit 1 ;;
esac
tar -tf "$PKG" 2>/dev/null | grep -qx './zforge/bin/zforge' && tar -tf "$PKG" | grep -qx './flashforge_init.sh' ||
    { echo "$PKG doesn't contain a zforge installer (corrupted download?)" >&2; exit 1; }
VER=$(tar -xOf "$PKG" ./zforge/share/VERSION 2>/dev/null || echo "?")

STAGE=/data/.zforge-update
echo "uploading zforge $VER to $TARGET:$STAGE" >&2
# shellcheck disable=SC2086
$SSH ${SSH_OPTS:-} "$TARGET" "rm -rf $STAGE && mkdir -p $STAGE && tar -xf - -C $STAGE" <"$PKG"

echo "running the installer (zforge's services restart only after the reboot)" >&2
# One session for install + reboot: the installer stops zforge's SSH server
# (this session survives), so a second connection wouldn't work. Only the
# reboot is backgrounded, with its output detached, so the session ends
# cleanly and ssh returns the installer's exit status.
# shellcheck disable=SC2086
if $SSH ${SSH_OPTS:-} "$TARGET" "sh $STAGE/flashforge_init.sh --ssh && rm -rf $STAGE && sync &&
        { (sleep 3; $REMOTE_REBOOT) </dev/null >/dev/null 2>&1 & }"; then
    echo "done: zforge $VER installed; the printer is rebooting" >&2
else
    echo >&2
    echo "INSTALL FAILED (see the messages above, or /data/zforge-install.log on the printer)." >&2
    echo "The printer was NOT rebooted. The installer restarts the previous zforge after a" >&2
    echo "failure, so SSH should work again within a minute; if not, power-cycle the printer." >&2
    exit 1
fi
