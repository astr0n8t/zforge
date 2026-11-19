#!/bin/sh
# End-to-end test of a zforge package on a simulated printer.
#
#   [STOCK_ROOT=DIR] unshare -m -n -p -f --mount-proc sh tests/e2e/printer-sim.sh dist/Adventurer5MPro-zforge-<ver>.tgz
#
# Runs the real package (armv7 binaries via qemu-user binfmt on x86) inside
# private mount + network + PID namespaces (all processes die with it).
#
# STOCK_ROOT (recommended): a directory holding the printer's stock root
# filesystem, e.g. the rootfs partition from tools/probe/run-backup.sh
# loop-mounted read-only. The printer side (installer, hook, zforge CLI, SSH
# sessions) then runs *inside* it, on a writable overlay, with the printer's
# own BusyBox/bash userland, which catches tool incompatibilities (like the
# stock tar having no -z). The stock image may still contain zmod; the test
# first checks the installer refuses, then removes zmod's hooks.
# Without STOCK_ROOT the printer side runs with the host's tools.
#
# Network: "wlan0" (10.9.0.1) <-veth-> netns "lan" (10.9.0.2) plays the PC.
# qemu-user can't emulate netlink, so the armv7 `ip` can't run here: the
# printer side's `ip` calls are relayed to the host's `ip` (same netns).
set -u
[ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 2; }
PKG=$(readlink -f "$1")
TOP=$(cd "$(dirname "$0")/../.." && pwd)
W=$TOP/work/e2e
LAN="ip netns exec lan"
FAILS=0

pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

rm -rf "$W"; mkdir -p "$W/pc" "$W/shim"
mount -t tmpfs tmpfs /run      # private /run (ip netns state) in both modes

# ------------------------------------------------------------------ simulated printer
if [ -n "${STOCK_ROOT:-}" ]; then
    MODE=stock
    R=$W/root
    mkdir -p "$W/ovl/u" "$W/ovl/w" "$R"
    mount -t overlay overlay -o "lowerdir=$(readlink -f "$STOCK_ROOT"),upperdir=$W/ovl/u,workdir=$W/ovl/w" "$R"
    mount -t proc proc "$R/proc"
    mount -t sysfs sysfs "$R/sys"
    mount --rbind /dev "$R/dev"
    for d in tmp run mnt; do mount -t tmpfs tmpfs "$R/$d"; done
    mkdir -p "$R/data"; mount -t tmpfs -o size=1500m tmpfs "$R/data"
    SHIM=$R/zf-shim
    # run a command on the "printer": stock userland, printer-like PATH
    P() { chroot "$R" /usr/bin/env -i PATH=/zf-shim:/bin:/sbin:/usr/bin:/usr/sbin HOME=/root "$@"; }
else
    MODE=host
    R=""
    mkdir -p "$W/initd" "$W/optconfig" /data /opt/config
    mount -t tmpfs -o size=1500m tmpfs /data
    mount --bind "$W/initd" /etc/init.d
    mount --bind "$W/optconfig" /opt/config
    for d in /mnt /tmp; do mount -t tmpfs tmpfs "$d"; done
    printf '[virtual_sdcard]\npath: /data/\n' >/opt/config/printer.cfg
    SHIM=$W/shim
    printf '#!/bin/sh\n[ "${1:-}" = -m ] && { echo armv7l; exit 0; }\nexec /bin/uname "$@"\n' >"$SHIM/uname"
    P() { env PATH="$SHIM:$PATH" "$@"; }
fi
echo "mode: $MODE"
mkdir -p "$SHIM"
# reboot must not reboot anything
printf '#!/bin/sh\necho "[shim] reboot requested"\n' >"$SHIM/reboot"
# `ip` relay: printer side writes a request, the host executes it
cat >"$SHIM/ip" <<'EOF'
#!/bin/sh
d=/run/iprelay; mkdir -p "$d"; id=$$
echo "$*" >"$d/$id.tmp" && mv "$d/$id.tmp" "$d/$id.req"
while [ ! -f "$d/$id.rc" ]; do sleep 0.05; done
cat "$d/$id.out"; cat "$d/$id.err" >&2; rc=$(cat "$d/$id.rc"); rm -f "$d/$id.out" "$d/$id.err" "$d/$id.rc"; exit "$rc"
EOF
chmod +x "$SHIM/"*
mkdir -p "$R/run/iprelay"
(
    while :; do
        for f in "$R"/run/iprelay/*.req; do
            [ -f "$f" ] || continue
            b=${f%.req}
            # shellcheck disable=SC2046
            ip $(cat "$f") >"$b.out" 2>"$b.err"; echo $? >"$b.rc.tmp"; rm -f "$f"; mv "$b.rc.tmp" "$b.rc"
        done
        sleep 0.05
    done
) &
RELAY=$!

ip link set lo up
ip netns add lan
ip link add wlan0 type veth peer name pc0
ip link set pc0 netns lan
ip addr add 10.9.0.1/24 dev wlan0; ip link set wlan0 up
$LAN ip link set lo up; $LAN ip addr add 10.9.0.2/24 dev pc0; $LAN ip link set pc0 up

ssh-keygen -q -t ed25519 -N '' -f "$W/pc/id"
SSHC="ssh -i $W/pc/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
ZFH=/data/.zforge              # path on the printer
ZFX=$R/data/.zforge            # same, seen from the host

# ------------------------------------------------------------------ install
echo "== install (USB mode)"
cp "$W/pc/id.pub" "$R/mnt/authorized_keys"
# a user file that tries to undo the policy (like the current zmod config); zforge must win
printf '[server]\n# user include from the stick\nport: 0\n\n[authorization]\ntrusted_clients:\n  0.0.0.0/0\ncors_domains:\n  *\n' >"$R/mnt/moonraker.user.conf"
# the zmod migration path: an existing certificate on the stick must be kept
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj /CN=zmod-cert \
    -addext "subjectAltName=IP:10.9.0.1" -keyout "$R/mnt/moonraker.key" -out "$R/mnt/moonraker.cert" >/dev/null 2>&1
cp "$R/mnt/moonraker.cert" "$W/pc/zmod.cert"
# like stock auto_run.sh: copy the package to /data/update and unpack it there
mkdir -p "$R/data/update" && tar -xf "$PKG" -C "$R/data/update"

if [ "$MODE" = stock ] && { [ -d "$R/opt/config/mod/.shell" ] || [ -e "$R/etc/init.d/S99moon" ]; }; then
    P sh /data/update/flashforge_init.sh Adventurer5MPro 0024 >"$W/install-zmod.out" 2>&1
    check "refuses to install over zmod"       grep -q "zmod is installed" "$R/mnt/zforge-install.log"
    # what REMOVE_ZMOD FULL=1 leaves: no hooks, no mod dir
    rm -f "$R"/etc/init.d/S00fix "$R"/etc/init.d/S60dropbear "$R"/etc/init.d/S98zssh \
        "$R"/etc/init.d/S99camera "$R"/etc/init.d/S99moon "$R"/etc/init.d/K99moon "$R"/etc/init.d/prepare.sh
    rm -rf "$R/opt/config/mod" "$R/mnt/zforge-install.log"
    rm -f "$R"/bin/dropbear "$R"/bin/dropbearkey "$R"/bin/dropbearmulti "$R"/bin/scp "$R"/etc/init.d/S50sshd
fi
P sh /data/update/flashforge_init.sh Adventurer5MPro 0024 >"$W/install.out" 2>&1
check "installer succeeded"                    grep -q "installed" "$R/mnt/zforge-install.log"
check "installer asked for reboot"             grep -q "reboot requested" "$W/install.out"
check "boot hook installed"                    cmp "$R/etc/init.d/S35zforge" "$ZFX/share/S35zforge"
check "PATH snippet installed"                 cmp "$R/etc/profile.d/zforge.sh" "$ZFX/share/zforge-profile.sh"
check "SSH key imported from stick"            grep -qF "$(cat "$W/pc/id.pub")" "$ZFX/etc/ssh/authorized_keys"
check "moonraker.user.conf imported"           grep -q "user include from the stick" "$ZFX/etc/moonraker.user.conf"
check "existing certificate imported"          cmp "$R/mnt/moonraker.cert" "$ZFX/var/moonraker/certs/moonraker.cert"
{ echo 'SWAP_MB=16'; echo 'NTP_SERVERS=""'; echo 'ZF_IP=/zf-shim/ip'; } >>"$ZFX/etc/zforge.conf"
[ "$MODE" = host ] && echo "ZF_IP=$SHIM/ip" >>"$ZFX/etc/zforge.conf"

# ------------------------------------------------------------------ boot
echo "== boot (S35zforge start)"
P /etc/init.d/S35zforge start
check "firewall: local table moved to pref 100" sh -c "ip rule | grep -q '^100:.*lookup local'"
check "firewall: no pref-0 local rule"          sh -c "! ip rule | grep -q '^0:.*lookup local'"
check "firewall: 7125 blackholed on wlan0"      sh -c "ip rule | grep -q 'iif wlan0 .*dport 7125 blackhole'"

printf "  waiting for Moonraker HTTPS (qemu is slow)"
i=0; while [ $i -lt 120 ]; do
    $LAN curl -sk -o /dev/null --max-time 3 https://10.9.0.1:7130/server/info && break
    printf "."; sleep 3; i=$((i + 1))
done; echo
CERT=$ZFX/var/moonraker/certs/moonraker.cert
KEY=$(P $ZFH/bin/zforge apikey show 2>/dev/null)
code() { $LAN curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }

echo "== SSH (from the LAN)"
i=0; while [ $i -lt 40 ]; do $LAN $SSHC root@10.9.0.1 true 2>/dev/null && break; sleep 3; i=$((i + 1)); done
out=$($LAN $SSHC root@10.9.0.1 echo hello 2>&1)
[ "$out" = hello ] || echo "        diag: ssh output: $(echo "$out" | tr '\n' ' ')"
check "/data made non-world-writable for dropbear" sh -c "[ -z \"\$(find $R/data -maxdepth 0 -perm -o+w)\" ]"
check "ssh root with key works"                sh -c "$LAN $SSHC root@10.9.0.1 echo hello | grep -qx hello"
check "only publickey auth offered"            sh -c "$LAN $SSHC -o PreferredAuthentications=password -o BatchMode=yes root@10.9.0.1 true 2>&1 | grep -q 'Permission denied (publickey)'"
echo "G1 X10" >"$W/pc/t1.gcode"
check "sftp upload"                            sh -c "echo 'put $W/pc/t1.gcode /data/sftp.gcode' | $LAN sftp -q -i $W/pc/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -b - root@10.9.0.1 && [ -f $R/data/sftp.gcode ]"
check "scp (legacy protocol) upload"           sh -c "$LAN scp -q -O -i $W/pc/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $W/pc/t1.gcode root@10.9.0.1:/data/scp.gcode && [ -f $R/data/scp.gcode ]"
if [ ! -f "$R/data/scp.gcode" ]; then
    echo "        diag: $($LAN $SSHC root@10.9.0.1 'echo PATH=$PATH; command -v scp; ls -la $(command -v scp)' 2>&1 | tr '\n' ' ')"
    echo "        diag: $($LAN scp -O -i "$W/pc/id" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$W/pc/t1.gcode" root@10.9.0.1:/data/scp.gcode 2>&1 | tr '\n' ' ')"
fi
check "zforge on PATH in a login shell"        sh -c "$LAN $SSHC root@10.9.0.1 'sh -l -c \"command -v zforge\"' | grep -q /data/.zforge/bin/zforge"
check "zforge status over ssh (no login shell)" sh -c "$LAN $SSHC root@10.9.0.1 zforge status | grep -q 'moonraker *running'"

echo "== Moonraker over TLS (from the LAN)"
check "API key readable (zforge apikey show)"  [ -n "$KEY" ]
check "HTTPS without key -> 401"               [ "$(code -k https://10.9.0.1:7130/server/info)" = 401 ]
check "HTTPS with key -> 200"                  [ "$(code -k -H "X-Api-Key: $KEY" https://10.9.0.1:7130/server/info)" = 200 ]
check "served cert is the imported one"        [ "$(code --cacert "$W/pc/zmod.cert" -H "X-Api-Key: $KEY" https://10.9.0.1:7130/server/info)" = 200 ]
check "cert verifies for the IP (no -k)"       [ "$(code --cacert "$CERT" -H "X-Api-Key: $KEY" https://10.9.0.1:7130/server/info)" = 200 ]
check "CORS off: no ACAO header"               sh -c "! $LAN curl -sk -D - -o /dev/null -H 'Origin: http://evil.example' -H 'X-Api-Key: $KEY' https://10.9.0.1:7130/server/info | grep -qi access-control-allow-origin"
check "plain HTTP 7125 from LAN: no answer"    [ "$(code http://10.9.0.1:7125/server/info)" = 000 ]
check "plain HTTP 7125 on loopback answers"    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:7125/server/info | grep -q 401"
check "nothing else listening on the LAN IP"   sh -c "! netstat -tln | awk 'NR>2{print \$4}' | grep -v -E ':(22|7125|7130)\$' | grep -q ."

echo "== OrcaSlicer path (OctoPrint API)"
check "GET /api/version with key"              [ "$(code -k -H "X-Api-Key: $KEY" https://10.9.0.1:7130/api/version)" = 200 ]
echo "G28" >"$W/pc/orca.gcode"
check "upload via /api/files/local"            sh -c "$LAN curl -sk -f --max-time 60 -H 'X-Api-Key: $KEY' -F file=@$W/pc/orca.gcode https://10.9.0.1:7130/api/files/local >/dev/null && [ -f $R/data/orca.gcode ]"
check "file list shows uploads, hides .zforge" sh -c "$LAN curl -sk -H 'X-Api-Key: $KEY' https://10.9.0.1:7130/server/files/list | grep -q orca.gcode && ! $LAN curl -sk -H 'X-Api-Key: $KEY' https://10.9.0.1:7130/server/files/list | grep -q '.zforge'"

echo "== key rotation and certificate tools"
P $ZFH/bin/zforge apikey rotate >"$W/newkey" 2>/dev/null
NEW=$(tail -n 1 "$W/newkey")
i=0; while [ $i -lt 60 ]; do [ "$(code -k -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ] && break; sleep 3; i=$((i + 1)); done
check "rotated key works"                      [ "$(code -k -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ]
check "old key rejected"                       [ "$(code -k -H "X-Api-Key: $KEY" https://10.9.0.1:7130/server/info)" = 401 ]
check "tls show prints a SHA-256 fingerprint"  sh -c "chroot ${R:-/} /usr/bin/env -i PATH=/bin:/usr/bin $ZFH/bin/zforge tls show | grep -qi 'sha256 fingerprint'"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$R/tmp/other.key" -out "$R/tmp/other.crt" -subj /CN=x -days 1 >/dev/null 2>&1
check "tls import rejects a mismatched key"    sh -c "! chroot ${R:-/} /usr/bin/env -i PATH=/bin:/usr/bin $ZFH/bin/zforge tls import $ZFH/var/moonraker/certs/moonraker.cert /tmp/other.key"
P $ZFH/bin/zforge tls regen >/dev/null 2>&1
i=0; while [ $i -lt 60 ]; do [ "$(code --cacert "$CERT" -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ] && break; sleep 3; i=$((i + 1)); done
check "tls regen: new cert served, verifies"   [ "$(code --cacert "$CERT" -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ]
check "tls regen: old cert no longer served"   [ "$(code --cacert "$W/pc/zmod.cert" -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 000 ]
cp "$CERT" "$W/pc/before-upgrade.cert"

echo "== upgrade over SSH (same package again)"
$LAN $SSHC root@10.9.0.1 "rm -rf /data/.zforge-update && mkdir -p /data/.zforge-update && tar -xf - -C /data/.zforge-update" <"$PKG"
$LAN $SSHC root@10.9.0.1 "PATH=$( [ "$MODE" = stock ] && echo /zf-shim || echo "$SHIM"):\$PATH sh /data/.zforge-update/flashforge_init.sh --ssh" >"$W/upgrade.out" 2>&1
check "upgrade installer succeeded"            grep -q "installed" "$W/upgrade.out"
check "upgrade kept SSH keys"                  grep -qF "$(cat "$W/pc/id.pub")" "$ZFX/etc/ssh/authorized_keys"
check "upgrade kept the certificate"           cmp "$W/pc/before-upgrade.cert" "$CERT"
check "upgrade kept config"                    grep -q '^SWAP_MB=16' "$ZFX/etc/zforge.conf"
P /etc/init.d/S35zforge start
i=0; while [ $i -lt 60 ]; do [ "$(code --cacert "$CERT" -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ] && break; sleep 3; i=$((i + 1)); done
check "after upgrade: same API key works"      [ "$(code --cacert "$CERT" -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ]
check "after upgrade: ssh works"               sh -c "$LAN $SSHC root@10.9.0.1 echo hello | grep -qx hello"

echo "== shutdown and disable"
P /etc/init.d/S35zforge stop
pgrep -a -f '[m]oonraker.py|[d]ropbear' | sed 's/^/        still running: /'
check "services stopped"                       sh -c "! pgrep -f '[m]oonraker.py|[d]ropbear' >/dev/null"
check "chroot mounts gone"                     sh -c "! grep -q '/data/.zforge/rootfs/' /proc/mounts"
: >"$ZFX/disabled"
P /etc/init.d/S35zforge start >/dev/null
sleep 3
check "disabled: nothing starts"               sh -c "! pgrep -f '[m]oonraker.py|[d]ropbear' >/dev/null"

kill "$RELAY" 2>/dev/null
echo
if [ "$FAILS" = 0 ]; then echo "ALL PASSED ($MODE mode)"; else
    echo "$FAILS FAILED ($MODE mode). Logs copied to $W/zforge-logs; installer output in $W/*.out"
    cp -r "$ZFX/var/log" "$W/zforge-logs" 2>/dev/null
    cp "$ZFX/var/moonraker/logs/moonraker.log" "$W/zforge-logs/" 2>/dev/null
    cp "$R/mnt/zforge-install.log" "$W/zforge-logs/" 2>/dev/null
fi
exit "$FAILS"
