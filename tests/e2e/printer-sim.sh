#!/bin/sh
# End-to-end test of a zforge package on a simulated printer.
#
#   unshare -m -n sh tests/e2e/printer-sim.sh dist/Adventurer5MPro-zforge-<ver>.tgz
#
# Runs the real package (armv7 binaries via qemu-user binfmt on x86) inside
# private mount + network namespaces:
#   /data, /etc/init.d, /opt/config, /mnt, /tmp, /run  -> scratch mounts
#   "wlan0" (10.9.0.1) <-veth-> netns "lan" (10.9.0.2) playing the user's PC
# Flow: USB-mode install (stick with authorized_keys) -> S35zforge start ->
# checks from the LAN side -> shutdown. Nothing on the host is modified
# except the empty mount-point directories /data and /opt/config.
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

# ------------------------------------------------------------------ simulated printer
rm -rf "$W"; mkdir -p "$W/initd" "$W/optconfig" "$W/shim" "$W/pc"
mkdir -p /data /opt/config
mount -t tmpfs -o size=1500m tmpfs /data
mount --bind "$W/initd" /etc/init.d
mount --bind "$W/optconfig" /opt/config
mount -t tmpfs tmpfs /mnt
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp      # /tmp/uds lives here (no Klipper in the simulation)
printf '[virtual_sdcard]\npath: /data/\n' >/opt/config/printer.cfg

# the installer checks the machine; reboot must not reboot the host
printf '#!/bin/sh\n[ "${1:-}" = -m ] && { echo armv7l; exit 0; }\nexec /bin/uname "$@"\n' >"$W/shim/uname"
printf '#!/bin/sh\necho "[shim] reboot requested"\n' >"$W/shim/reboot"
chmod +x "$W/shim/"*

ip link set lo up
ip netns add lan
ip link add wlan0 type veth peer name pc0
ip link set pc0 netns lan
ip addr add 10.9.0.1/24 dev wlan0; ip link set wlan0 up
$LAN ip link set lo up; $LAN ip addr add 10.9.0.2/24 dev pc0; $LAN ip link set pc0 up

ssh-keygen -q -t ed25519 -N '' -f "$W/pc/id"
SSHC="ssh -i $W/pc/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

echo "== install (USB mode)"
cp "$W/pc/id.pub" /mnt/authorized_keys
# a user file that tries to undo the policy (like the current zmod config); zforge must win
printf '[server]\n# user include from the stick\nport: 0\n\n[authorization]\ntrusted_clients:\n  0.0.0.0/0\ncors_domains:\n  *\n' >/mnt/moonraker.user.conf
mkdir -p /data/update && tar -xf "$PKG" -C /data/update
PATH="$W/shim:$PATH" sh /data/update/flashforge_init.sh Adventurer5MPro 0024 >"$W/install.out" 2>&1
check "installer exit 0"                       grep -q "installed" /mnt/zforge-install.log
check "installer asked for reboot"             grep -q "reboot requested" "$W/install.out"
check "boot hook installed"                    cmp /etc/init.d/S35zforge /data/.zforge/share/S35zforge
check "SSH key imported from stick"            grep -qF "$(cat "$W/pc/id.pub")" /data/.zforge/etc/ssh/authorized_keys
check "moonraker.user.conf imported"           grep -q "user include from the stick" /data/.zforge/etc/moonraker.user.conf
echo 'SWAP_MB=16' >>/data/.zforge/etc/zforge.conf
echo 'NTP_SERVERS=""' >>/data/.zforge/etc/zforge.conf

echo "== boot (S35zforge start)"
/etc/init.d/S35zforge start
check "firewall: local table moved to pref 100" sh -c "ip rule | grep -q '^100:.*lookup local'"
check "firewall: no pref-0 local rule"          sh -c "! ip rule | grep -q '^0:.*lookup local'"
check "firewall: 7125 blackholed on wlan0"      sh -c "ip rule | grep -q 'iif wlan0 .*dport 7125 blackhole'"

printf "  waiting for Moonraker HTTPS (qemu is slow)"
i=0; while [ $i -lt 120 ]; do
    $LAN curl -sk -o /dev/null --max-time 3 https://10.9.0.1:7130/server/info && break
    printf "."; sleep 3; i=$((i + 1))
done; echo
CERT=/data/.zforge/var/moonraker/certs/moonraker.cert
KEY=$(/data/.zforge/bin/zforge apikey show 2>/dev/null)
code() { $LAN curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }

echo "== SSH (from the LAN)"
check "ssh root with key works"                sh -c "$LAN $SSHC root@10.9.0.1 echo hello | grep -qx hello"
check "only publickey auth offered"            sh -c "$LAN $SSHC -o PreferredAuthentications=password -o BatchMode=yes root@10.9.0.1 true 2>&1 | grep -q 'Permission denied (publickey)'"
echo "G1 X10" >"$W/pc/t1.gcode"
check "sftp upload"                            sh -c "echo 'put $W/pc/t1.gcode /data/sftp.gcode' | $LAN sftp -q -i $W/pc/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -b - root@10.9.0.1 && [ -f /data/sftp.gcode ]"
check "scp (legacy protocol) upload"           sh -c "$LAN scp -q -O -i $W/pc/id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $W/pc/t1.gcode root@10.9.0.1:/data/scp.gcode && [ -f /data/scp.gcode ]"

echo "== Moonraker over TLS (from the LAN)"
check "API key readable (zforge apikey show)"  [ -n "$KEY" ]
check "HTTPS without key -> 401"               [ "$(code -k https://10.9.0.1:7130/server/info)" = 401 ]
check "HTTPS with key -> 200"                  [ "$(code -k -H "X-Api-Key: $KEY" https://10.9.0.1:7130/server/info)" = 200 ]
check "cert verifies for the IP (no -k)"       [ "$(code --cacert "$CERT" -H "X-Api-Key: $KEY" https://10.9.0.1:7130/server/info)" = 200 ]
check "CORS off: no ACAO header"               sh -c "! $LAN curl -sk -D - -o /dev/null -H 'Origin: http://evil.example' -H 'X-Api-Key: $KEY' https://10.9.0.1:7130/server/info | grep -qi access-control-allow-origin"
check "plain HTTP 7125 from LAN: no answer"    [ "$(code http://10.9.0.1:7125/server/info)" = 000 ]
check "plain HTTP 7125 on loopback answers"    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:7125/server/info | grep -q 401"
check "nothing else listening on the LAN IP"   sh -c "! netstat -tln | awk 'NR>2{print \$4}' | grep -v -E ':(22|7125|7130)\$' | grep -q ."

echo "== OrcaSlicer path (OctoPrint API)"
check "GET /api/version with key"              [ "$(code -k -H "X-Api-Key: $KEY" https://10.9.0.1:7130/api/version)" = 200 ]
echo "G28" >"$W/pc/orca.gcode"
check "upload via /api/files/local"            sh -c "$LAN curl -sk -f --max-time 60 -H 'X-Api-Key: $KEY' -F file=@$W/pc/orca.gcode https://10.9.0.1:7130/api/files/local >/dev/null && [ -f /data/orca.gcode ]"
check "file list shows uploads, hides .zforge" sh -c "$LAN curl -sk -H 'X-Api-Key: $KEY' https://10.9.0.1:7130/server/files/list | grep -q orca.gcode && ! $LAN curl -sk -H 'X-Api-Key: $KEY' https://10.9.0.1:7130/server/files/list | grep -q '.zforge'"

echo "== key rotation and certificate tools"
/data/.zforge/bin/zforge apikey rotate >"$W/newkey" 2>/dev/null
NEW=$(tail -n 1 "$W/newkey")
i=0; while [ $i -lt 60 ]; do [ "$(code -k -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ] && break; sleep 3; i=$((i + 1)); done
check "rotated key works"                      [ "$(code -k -H "X-Api-Key: $NEW" https://10.9.0.1:7130/server/info)" = 200 ]
check "old key rejected"                       [ "$(code -k -H "X-Api-Key: $KEY" https://10.9.0.1:7130/server/info)" = 401 ]
check "tls show prints a SHA-256 fingerprint"  sh -c "/data/.zforge/bin/zforge tls show | grep -qi 'sha256 fingerprint'"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$W/other.key" -out "$W/other.crt" -subj /CN=x -days 1 >/dev/null 2>&1
check "tls import rejects a mismatched key"    sh -c "! /data/.zforge/bin/zforge tls import $CERT $W/other.key"

echo "== shutdown and disable"
/etc/init.d/S35zforge stop
check "services stopped"                       sh -c "! pgrep -f 'moonraker.py|dropbear' >/dev/null"
check "chroot mounts gone"                     sh -c "! grep -q ' /data/.zforge/rootfs/' /proc/mounts"
: >/data/.zforge/disabled
/etc/init.d/S35zforge start >/dev/null
sleep 3
check "disabled: nothing starts"               sh -c "! pgrep -f 'moonraker.py|dropbear' >/dev/null"

echo
if [ "$FAILS" = 0 ]; then echo "ALL PASSED"; else
    echo "$FAILS FAILED. Logs: $W (install.out), /data/.zforge/var/log/ (inside the namespace)"
    cp -r /data/.zforge/var/log "$W/zforge-logs" 2>/dev/null
    cp /data/.zforge/var/moonraker/logs/moonraker.log "$W/zforge-logs/" 2>/dev/null
fi
exit "$FAILS"
