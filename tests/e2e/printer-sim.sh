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
    # a private /dev with just the nodes needed: vendor installers write to
    # /dev/fb0 etc., which must not land in the host's /dev
    mount -t tmpfs -o mode=755 tmpfs "$R/dev"
    for n in null zero full random urandom tty; do : >"$R/dev/$n"; mount --bind "/dev/$n" "$R/dev/$n"; done
    mkdir -p "$R/dev/pts" "$R/dev/shm"
    mount -t devpts -o newinstance,ptmxmode=0666 devpts "$R/dev/pts" && ln -sf pts/ptmx "$R/dev/ptmx"
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
printf '#!/bin/sh\necho "[shim] reboot requested"\n: >/tmp/zf-reboot-requested\n' >"$SHIM/reboot"
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
# the package also sits on the stick, as for a real USB install
cp "$PKG" "$R/mnt/$(basename "$PKG")"
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
check "package renamed on the stick (no loop)" sh -c "[ ! -e $R/mnt/$(basename "$PKG") ] && [ -f $R/mnt/$(basename "$PKG").installed ]"
check "boot hook installed"                    cmp "$R/etc/init.d/S35zforge" "$ZFX/share/S35zforge"
check "PATH snippet installed"                 cmp "$R/etc/profile.d/zforge.sh" "$ZFX/share/zforge-profile.sh"
check "SSH key imported from stick"            grep -qF "$(cat "$W/pc/id.pub")" "$ZFX/etc/ssh/authorized_keys"
check "moonraker.user.conf imported"           grep -q "user include from the stick" "$ZFX/etc/moonraker.user.conf"
check "existing certificate imported"          cmp "$R/mnt/moonraker.cert" "$ZFX/var/moonraker/certs/moonraker.cert"
{ echo 'SWAP_MB=16'; echo 'NTP_SERVERS=""'; echo 'ZF_IP=/zf-shim/ip'; echo 'ZF_REBOOT=/zf-shim/reboot'; } >>"$ZFX/etc/zforge.conf"
[ "$MODE" = host ] && { echo "ZF_IP=$SHIM/ip"; echo "ZF_REBOOT=$SHIM/reboot"; } >>"$ZFX/etc/zforge.conf"

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
# forget the printer's MAC, so ARP has to work through the firewall
$LAN ip neigh flush all; ip neigh flush all
check "ARP works through the firewall"         sh -c "$LAN ping -c 1 -W 3 10.9.0.1"
i=0; while [ $i -lt 40 ]; do $LAN $SSHC root@10.9.0.1 true 2>/dev/null && break; sleep 3; i=$((i + 1)); done
out=$($LAN $SSHC root@10.9.0.1 echo hello 2>&1)
[ "$out" = hello ] || echo "        diag: ssh output: $(echo "$out" | tr '\n' ' ')"
if [ "$out" != hello ]; then
    echo "        diag: ip rule:";  ip rule | sed 's/^/          /'
    echo "        diag: ip route:"; ip route | sed 's/^/          /'
    echo "        diag: ip -4 addr:"; ip -4 -o addr | sed 's/^/          /'
    echo "        diag: lan side:"; $LAN ip -4 -o addr | sed 's/^/          /'
fi
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
echo 'TLS_EXTRA_NAMES="printer.lan 10.20.30.40"' >>"$ZFX/etc/zforge.conf"
P $ZFH/bin/zforge tls regen >/dev/null 2>&1
i=0; while [ $i -lt 60 ]; do [ "$(code --cacert "$CERT" -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ] && break; sleep 3; i=$((i + 1)); done
check "tls regen: new cert served, verifies"   [ "$(code --cacert "$CERT" -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ]
check "tls regen: TLS_EXTRA_NAMES in the SAN"  sh -c "openssl x509 -in $CERT -noout -ext subjectAltName | grep -q 'DNS:printer.lan' && openssl x509 -in $CERT -noout -ext subjectAltName | grep -q 'IP Address:10.20.30.40'"
check "tls regen: old cert no longer served"   [ "$(code --cacert "$W/pc/zmod.cert" -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 000 ]
cp "$CERT" "$W/pc/before-upgrade.cert"

echo "== upgrade over SSH (same package again)"
rm -f "$R/tmp/zf-reboot-requested"
# the real PC-side script, with the printer's reboot replaced by the shim
RSHIM=$( [ "$MODE" = stock ] && echo /zf-shim/reboot || echo "$SHIM/reboot")
# host mode: the "printer" is this x86 host, so its SSH sessions need the
# uname shim (stock mode runs the real armv7 userland and needs nothing)
RSSH="$LAN $SSHC"
if [ "$MODE" = host ]; then
    printf '#!/bin/sh\n# ssh wrapper: prefix the remote command with the shim PATH\nt=$1; shift\nexec %s "$t" "PATH=%s:\\$PATH; $*"\n' "$LAN $SSHC" "$SHIM" >"$W/ssh-host"
    chmod +x "$W/ssh-host"; RSSH="$W/ssh-host"
fi
SSH="$RSSH" REMOTE_REBOOT="$RSHIM" sh "$TOP/tools/install/run-install.sh" root@10.9.0.1 "$PKG" >"$W/upgrade.out" 2>&1
upgrade_rc=$?
check "run-install.sh succeeded"               [ "$upgrade_rc" = 0 ]
check "run-install.sh reported success"        grep -q "^done: zforge .* installed" "$W/upgrade.out"
check "upgrade installer succeeded"            grep -q "installed" "$R/data/zforge-install.log"
check "staging dir removed"                    [ ! -e "$R/data/.zforge-update" ]
check "reboot triggered after the install"     sh -c "i=0; while [ \$i -lt 10 ]; do [ -e '$R/tmp/zf-reboot-requested' ] && exit 0; sleep 1; i=\$((i+1)); done; exit 1"
check "run-install.sh refuses a stock package" sh -c "cp '$PKG' '$W/Adventurer5MPro-5.2.0.tgz'; ! SSH=false sh '$TOP/tools/install/run-install.sh' root@x '$W/Adventurer5MPro-5.2.0.tgz'"
check "upgrade kept SSH keys"                  grep -qF "$(cat "$W/pc/id.pub")" "$ZFX/etc/ssh/authorized_keys"
check "upgrade kept the certificate"           cmp "$W/pc/before-upgrade.cert" "$CERT"
check "upgrade kept config"                    grep -q '^SWAP_MB=16' "$ZFX/etc/zforge.conf"
P /etc/init.d/S35zforge start
i=0; while [ $i -lt 60 ]; do [ "$(code --cacert "$CERT" -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ] && break; sleep 3; i=$((i + 1)); done
check "after upgrade: same API key works"      [ "$(code --cacert "$CERT" -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ]
check "after upgrade: ssh works"               sh -c "$LAN $SSHC root@10.9.0.1 echo hello | grep -qx hello"

echo "== failed upgrade over SSH (truncated rootfs, valid checksums)"
B=$W/broken; rm -rf "$B"; mkdir -p "$B/p"
tar -xf "$PKG" -C "$B/p"
echo 9.9.9-broken >"$B/p/zforge/share/VERSION"
head -c 2000000 "$B/p/zforge-rootfs-armv7.tar.gz" >"$B/r" && mv "$B/r" "$B/p/zforge-rootfs-armv7.tar.gz"
( cd "$B/p" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | xargs sha256sum >SHA256SUMS )
tar -C "$B/p" -cf "$B/Adventurer5MPro-zforge-9.9.9.tgz" .
ver_before=$(cat "$ZFX/share/VERSION")
rm -f "$R/tmp/zf-reboot-requested"
SSH="$RSSH" REMOTE_REBOOT="$RSHIM" sh "$TOP/tools/install/run-install.sh" root@10.9.0.1 "$B/Adventurer5MPro-zforge-9.9.9.tgz" >"$W/upgrade-broken.out" 2>&1
broken_rc=$?
check "broken upgrade: run-install.sh fails"   [ "$broken_rc" != 0 ]
check "broken upgrade: says INSTALL FAILED"    grep -q "INSTALL FAILED" "$W/upgrade-broken.out"
sleep 6
check "broken upgrade: no reboot triggered"    [ ! -e "$R/tmp/zf-reboot-requested" ]
check "broken upgrade: old version in place"   [ "$(cat "$ZFX/share/VERSION")" = "$ver_before" ]
i=0; while [ $i -lt 40 ]; do $LAN $SSHC root@10.9.0.1 true 2>/dev/null && break; sleep 3; i=$((i + 1)); done
check "broken upgrade: SSH back (restarted)"   sh -c "$LAN $SSHC root@10.9.0.1 echo hello | grep -qx hello"

echo "== firewall (Phase 2; default profile: lan)"
notc() { ! "$@"; }
reach() { out=$(timeout 5 "$@" </dev/null 2>/dev/null); [ -n "$out" ]; }
lan_to() { $LAN ip neigh flush all; reach $LAN nc -w2 10.9.0.1 "$1"; }   # PC -> printer port (fresh ARP each time)
out_to() { reach nc -w2 "$1" 80; }                     # printer -> host:80
set_conf() { sed -i "/^$1=/d" "$ZFX/etc/zforge.conf"; echo "$1=\"$2\"" >>"$ZFX/etc/zforge.conf"; }
apply_confirm() { P $ZFH/bin/zforge firewall apply 600 >/dev/null && P $ZFH/bin/zforge firewall confirm >/dev/null; }
wait_for() { i=0; while [ $i -lt 40 ]; do "$@" && return 0; sleep 2; i=$((i + 1)); done; return 1; }
# dummy services on the printer: stock LAN API (8899), something else (5000), camera port
for port in 8899 5000 8080; do sh -c "while true; do echo hi-$port | nc -l -N 10.9.0.1 $port >/dev/null 2>&1; done" & done
# the "internet" behind the PC, and a web server on the PC itself
$LAN ip addr add 203.0.113.5/32 dev pc0; $LAN ip addr add 203.0.113.6/32 dev pc0
$LAN sh -c 'while true; do echo web | nc -l -N 0.0.0.0 80 >/dev/null 2>&1; done' &
ip route add default via 10.9.0.2
sleep 1
check "lan: LAN -> ssh"                        lan_to 22
check "lan: LAN -> camera port (CAMERA=on)"    lan_to 8080
check "lan: stock API 8899 blocked (default)"  notc lan_to 8899
check "lan: any other port blocked"            notc lan_to 5000
check "lan: printer -> LAN allowed"            reach nc -w2 10.9.0.2 80
check "lan: printer -> internet refused"       notc out_to 203.0.113.5
if [ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
check "lan: IPv6 turned off"                   [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 1 ]
else echo "  SKIP  lan: IPv6 turned off (no IPv6 sysctls in this environment)"; fi
check "lan: fwrefresh service running"         pgrep -f '[_]_run fwrefresh'

set_conf FIREWALL_PROFILE strict; set_conf ALLOW_OUT 203.0.113.6; set_conf STOCK_LAN_API on
apply_confirm
check "strict: ALLOW_OUT host reachable"       out_to 203.0.113.6
check "strict: other internet refused"         notc out_to 203.0.113.5
check "STOCK_LAN_API=on: 8899 reachable"       lan_to 8899

set_conf SSH_ALLOW 10.9.0.99/32                # locks this PC out of SSH
P $ZFH/bin/zforge firewall refresh >/dev/null 2>&1 &   # concurrent refresh (the lock must serialize)
P $ZFH/bin/zforge firewall apply 15 >/dev/null
wait $!
check "no rule errors under concurrent apply"  sh -c "! grep -q 'FAILED' $ZFX/var/log/zforge.log"
check "apply: lockout takes effect"            notc lan_to 22
check "status shows the pending change"        sh -c "chroot ${R:-/} /usr/bin/env -i PATH=/bin:/usr/bin:/sbin:/usr/sbin $ZFH/bin/zforge firewall status | grep -q PENDING"
check "not confirmed: reverted, SSH back"      wait_for lan_to 22
P $ZFH/bin/zforge firewall apply 900 >/dev/null
check "lockout applied again (no confirm)"     notc lan_to 22
P /etc/init.d/S35zforge stop >/dev/null 2>&1; P /etc/init.d/S35zforge start >/dev/null 2>&1
check "pending change dropped at reboot"       wait_for lan_to 22
set_conf SSH_ALLOW ""

set_conf FIREWALL_PROFILE open; apply_confirm
check "open: other ports reachable"            lan_to 5000
check "open: internet reachable"               out_to 203.0.113.5
check "open: 7125 still blocked"               [ "$(code http://10.9.0.1:7125/server/info)" = 000 ]
if [ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
check "open: IPv6 back on"                     [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 0 ]
else echo "  SKIP  open: IPv6 back on (no IPv6 sysctls in this environment)"; fi
set_conf CAMERA off; apply_confirm
check "CAMERA=off: camera port blocked"        notc lan_to 8080
set_conf CAMERA on; set_conf FIREWALL_PROFILE lan; apply_confirm

echo "== camera"
check "camera service waits for a device"      grep -q "waiting for /dev/video0" "$ZFX/var/log/camera.log"

if [ "$MODE" = stock ]; then
echo "== stock firmware updates (Phase 3; synthetic packages)"
FAKE="$TOP/tests/e2e/fake-fwpkg.sh"
mkdir -p "$R/data/pkgs"
"$FAKE" "$R/data/pkgs/Adventurer5MPro-9.9.9.tgz" 9.9.9
"$FAKE" "$R/data/pkgs/Adventurer5MPro-1.0.0.tgz" 1.0.0
"$FAKE" "$R/data/pkgs/Adventurer5MPro-9.9.8-Factory.tgz" 9.9.8 factory
"$FAKE" "$R/data/pkgs/Adventurer5MPro-9.9.7.tgz" 9.9.7 corrupt
"$FAKE" "$R/data/pkgs/Adventurer5MPro-9.9.6.tgz" 9.9.6 wrongmachine
fwi() { P $ZFH/bin/zforge fw install "$@" --no-reboot >"$W/fw.out" 2>&1; }
if [ -n "${FW_PKG_REAL:-}" ]; then
    # a real Flashforge package (not in the repo), e.g. FW_PKG_REAL=Adventurer5MPro-5.2.0-....tgz
    cp "$FW_PKG_REAL" "$R/data/pkgs/Adventurer5MPro-real.tgz"
    cp "$R/etc/wpa_supplicant.conf" "$W/wpa.real.before"
    check "fw (real package): installs"        fwi /data/pkgs/Adventurer5MPro-real.tgz
    echo "        info: $(chroot "$R" /usr/bin/env -i PATH=/bin:/usr/bin:/sbin:/usr/sbin $ZFH/bin/zforge fw status | head -n 1)"
    check "fw (real package): Wi-Fi config kept" cmp "$W/wpa.real.before" "$R/etc/wpa_supplicant.conf"
    check "fw (real package): hook still there" cmp "$R/etc/init.d/S35zforge" "$ZFX/share/S35zforge"
    check "fw (real package): rcS runs S??*"   grep -q 'for i in /etc/init.d/S??\*' "$R/etc/init.d/rcS"
    check "fw (real package): vendor exit 0"   grep -q "rc=0 Adventurer5MPro-real.tgz" "$ZFX/var/fw-history.log"
    check "fw (real package): identical MCU fw, no flash flag" sh -c "! ls $R/opt/PROGRAM/control/*/Update >/dev/null 2>&1"
    cp "$ZFX/var/log/fw-install.log" "$W/fw-install-real.log" 2>/dev/null
fi
sw_before=$(ls "$R/opt/PROGRAM/software")
cp "$R/etc/wpa_supplicant.conf" "$W/wpa.before"
check "fw: corrupted package refused"          notc fwi /data/pkgs/Adventurer5MPro-9.9.7.tgz
check "fw:   ...with an md5 message"           grep -q "md5sum.list" "$W/fw.out"
check "fw: downgrade refused"                  notc fwi /data/pkgs/Adventurer5MPro-1.0.0.tgz
check "fw: Factory package refused"            notc fwi /data/pkgs/Adventurer5MPro-9.9.8-Factory.tgz
check "fw: wrong machine refused"              notc fwi /data/pkgs/Adventurer5MPro-9.9.6.tgz
check "fw: nothing changed by refusals"        [ "$(ls "$R/opt/PROGRAM/software")" = "$sw_before" ]
check "fw: install a good package"             fwi /data/pkgs/Adventurer5MPro-9.9.9.tgz
check "fw:   new version installed"            [ "$(ls "$R/opt/PROGRAM/software")" = 9.9.9 ]
check "fw:   Wi-Fi config restored"            cmp "$W/wpa.before" "$R/etc/wpa_supplicant.conf"
check "fw:   zforge hook still installed"      cmp "$R/etc/init.d/S35zforge" "$ZFX/share/S35zforge"
check "fw:   history logged"                   grep -q "Adventurer5MPro-9.9.9.tgz.*software=9.9.9" "$ZFX/var/fw-history.log"
check "fw:   staging dir cleaned up"           [ ! -e "$R/data/update" ]
check "fw: status shows the version"           sh -c "chroot $R /usr/bin/env -i PATH=/bin:/usr/bin:/sbin:/usr/sbin $ZFH/bin/zforge fw status | grep -q 'software=9.9.9'"
# MCU firmware: identical -> no flash, normal reboot; new -> keep the flag, ask for a power cycle, no reboot
fwr() { P $ZFH/bin/zforge fw install "$@" >"$W/fw.out" 2>&1; }
ctl_cur=$(ls -1t "$R/opt/PROGRAM/control" | head -n 1)
CONTROL_FROM="$R/opt/PROGRAM/control/$ctl_cur" CONTROL_VER="$ctl_cur" "$FAKE" "$R/data/pkgs/Adventurer5MPro-9.9.11.tgz" 9.9.11
CONTROL_FROM="$R/opt/PROGRAM/control/$ctl_cur" CONTROL_VER=9.9.12 CONTROL_TWEAK=1 "$FAKE" "$R/data/pkgs/Adventurer5MPro-9.9.12.tgz" 9.9.12
rm -f "$R/tmp/zf-reboot-requested"
check "fw: same MCU fw: installs"              fwr /data/pkgs/Adventurer5MPro-9.9.11.tgz
check "fw:   no MCU flash flag left"           sh -c "! ls $R/opt/PROGRAM/control/*/Update >/dev/null 2>&1"
check "fw:   reboots normally"                 [ -e "$R/tmp/zf-reboot-requested" ]
rm -f "$R/tmp/zf-reboot-requested"
check "fw: new MCU fw: installs"               fwr /data/pkgs/Adventurer5MPro-9.9.12.tgz
check "fw:   MCU flash flag kept"              [ -e "$R/opt/PROGRAM/control/9.9.12/Update" ]
check "fw:   asks for a power cycle"           grep -q "POWER-CYCLE" "$W/fw.out"
check "fw:   does NOT warm-reboot"             [ ! -e "$R/tmp/zf-reboot-requested" ]
rm -f "$R/opt/PROGRAM/control/9.9.12/Update"   # (as the successful cold-boot flash would)

# install from a URL on the "internet": the firewall (lan) must open just that host, and only for the download
"$FAKE" "$W/Adventurer5MPro-9.9.10.tgz" 9.9.10
$LAN sh -c "cd $W && exec python3 -m http.server --bind 203.0.113.6 8000" >/dev/null 2>&1 &
sleep 2
check "fw: download host blocked beforehand"   notc reach nc -w2 203.0.113.6 8000
check "fw: install from URL"                   fwi http://203.0.113.6:8000/Adventurer5MPro-9.9.10.tgz
check "fw:   new version installed"            [ "$(ls "$R/opt/PROGRAM/software")" = 9.9.10 ]
check "fw:   temporary allow removed"          sh -c "! ip rule | grep -q '^198:'"
check "fw:   host blocked again"               notc reach nc -w2 203.0.113.6 8000
# OTA window
P $ZFH/bin/zforge fw allow-ota 15s >/dev/null
check "fw: allow-ota opens the internet"       out_to 203.0.113.5
check "fw: allow-ota closes by itself"         wait_for notc out_to 203.0.113.5
fi

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
