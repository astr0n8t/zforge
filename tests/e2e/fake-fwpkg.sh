#!/bin/sh
# Make a synthetic stock-style update package for the e2e tests (no vendor
# files). Mimics the real format (docs/stock/update-package.md): a plain tar
# with flashforge_init.sh and software-<ver>.tar.xz (plain tar + md5sum.list).
#
#   fake-fwpkg.sh OUT.tgz VERSION [factory|corrupt|wrongmachine]
set -eu
OUT=$1 VER=$2 VARIANT=${3:-}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/pkg" "$T/sw"
echo "fake firmwareExe $VER" >"$T/sw/firmwareExe"
( cd "$T/sw" && md5sum firmwareExe >md5sum.list )
[ "$VARIANT" = corrupt ] && echo "tampered" >>"$T/sw/firmwareExe"
tar -C "$T/sw" -cf "$T/pkg/software-$VER.tar.xz" .
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
cd \$WORK_DIR
f=\`ls -1t software-*.tar.xz | head -n 1\`
v=\${f#software-}; v=\${v%.tar.xz}
mkdir -p \$RUN_DIR/software && rm -rf \$RUN_DIR/software/temp && mkdir \$RUN_DIR/software/temp
tar -xf \$f -C \$RUN_DIR/software/temp
cd \$RUN_DIR/software/temp
md5sum -c md5sum.list >/dev/null 2>&1 || { cd ..; rm -rf temp; exit 0; }
cd ..; ls | grep -v temp | xargs rm -rf; mv temp \$v
echo "installed software \$v"
exit 0
EOS
chmod +x "$T/pkg/flashforge_init.sh"
tar -C "$T/pkg" -cf "$OUT" .
