#!/bin/sh
# Install or upgrade zforge over SSH (needs a working root SSH login, i.e. an
# earlier zforge install). First installs go via USB; see docs/install.md.
#
#   tools/install/run-install.sh root@PRINTER dist/Adventurer5MPro-zforge-<ver>.tgz
#
# The printer reboots at the end.
set -eu
SSH=${SSH:-ssh}
[ $# -eq 2 ] || { echo "usage: $0 root@PRINTER PACKAGE.tgz" >&2; exit 2; }
TARGET=$1 PKG=$2
[ -f "$PKG" ] || { echo "no such file: $PKG" >&2; exit 1; }

STAGE=/data/.zforge-update
echo "uploading $(basename "$PKG") to $TARGET:$STAGE" >&2
# shellcheck disable=SC2086
$SSH ${SSH_OPTS:-} "$TARGET" "rm -rf $STAGE && mkdir -p $STAGE && tar -xf - -C $STAGE" <"$PKG"
echo "running installer" >&2
# shellcheck disable=SC2086
$SSH ${SSH_OPTS:-} "$TARGET" "sh $STAGE/flashforge_init.sh --ssh && rm -rf $STAGE && echo 'rebooting' && (sleep 2; reboot) >/dev/null 2>&1 &"
echo "done; the printer is rebooting" >&2
