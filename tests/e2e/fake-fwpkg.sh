#!/bin/sh
# Make a synthetic stock-style update package for the e2e tests (no vendor
# files). Mimics the real format (docs/stock/update-package.md): a plain tar
# with flashforge_init.sh and software-<ver>.tar.xz (plain tar + md5sum.list).
#
#   fake-fwpkg.sh OUT.tgz VERSION [factory|corrupt|wrongmachine]
#
# CONTROL_FROM=DIR adds an MCU component (control-$CONTROL_VER, default 2.2.3)
# with DIR's files plus an Update flag, like real packages; CONTROL_TWEAK=1
# changes one byte of its firmware (i.e. new MCU firmware).
set -eu
OUT=$1 VER=$2 VARIANT=${3:-}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/pkg" "$T/sw"
echo "fake firmwareExe $VER" >"$T/sw/firmwareExe"
( cd "$T/sw" && md5sum firmwareExe >md5sum.list )
[ "$VARIANT" = corrupt ] && echo "tampered" >>"$T/sw/firmwareExe"
tar -C "$T/sw" -cf "$T/pkg/software-$VER.tar.xz" .
if [ -n "${CONTROL_FROM:-}" ]; then
    mkdir -p "$T/ctl"
    cp -p "$CONTROL_FROM"/* "$T/ctl/"
    rm -f "$T/ctl/md5sum.list"; : >"$T/ctl/Update"
    if [ "${CONTROL_TWEAK:-0}" = 1 ]; then
        for f in "$T"/ctl/*; do
            case "${f##*/}" in Update|md5sum.list) continue ;; esac
            printf 'x' >>"$f"; break
        done
    fi
    ( cd "$T/ctl" && for f in *; do [ "$f" = md5sum.list ] || md5sum "$f"; done >md5sum.list )
    tar -C "$T/ctl" -cf "$T/pkg/control-${CONTROL_VER:-2.2.3}.tar.xz" .
fi
MACHINE=Adventurer5MPro
[ "$VARIANT" = wrongmachine ] && MACHINE=Adventurer5M
[ "$VARIANT" = factory ] && : >"$T/pkg/screwflag"
printf 'ctrl_interface=DIR=/var/run/wpa_supplicant\nnetwork={\n\tssid="factory_default"\n}\n' >"$T/pkg/wpa_supplicant.conf"
cat >"$T/pkg/flashforge_init.sh" <<EOS
#!/bin/sh
# synthetic vendor installer (behaves like the real one for the parts zforge relies on)
WORK_DIR=\`dirname \$0\`
RUN_DIR="/opt/PROGRAM"
MACHINE=$MACHINE
PID=0024
case "\$WORK_DIR" in /*) ;; *) echo "WORK_DIR not absolute: \$WORK_DIR"; exit 3 ;; esac
if [ "\$1" != "\${MACHINE}" ] || [ "\$2" != "\${PID}" ]; then echo "Firmware does not match machine type."; exit 1; fi
cp \$WORK_DIR/wpa_supplicant.conf /etc/wpa_supplicant.conf
for c in control software; do
    cd \$WORK_DIR
    f=\`ls -1t \$c-*.tar.xz 2>/dev/null | head -n 1\`
    [ -n "\$f" ] || continue
    v=\${f#\$c-}; v=\${v%.tar.xz}
    mkdir -p \$RUN_DIR/\$c && rm -rf \$RUN_DIR/\$c/temp && mkdir \$RUN_DIR/\$c/temp
    tar -xf \$f -C \$RUN_DIR/\$c/temp
    cd \$RUN_DIR/\$c/temp
    md5sum -c md5sum.list >/dev/null 2>&1 || { cd ..; rm -rf temp; continue; }
    cd ..; ls | grep -v temp | xargs rm -rf; mv temp \$v
    echo "installed \$c \$v"
done
exit 0
EOS
chmod +x "$T/pkg/flashforge_init.sh"
tar -C "$T/pkg" -cf "$OUT" .
