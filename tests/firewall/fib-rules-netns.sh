#!/bin/sh
# Proves the zforge firewall approach without netfilter: only `ip rule`
# (policy routing), which is all the AD5M Pro stock kernel offers.
#
# Builds a throwaway "printer" network namespace behind a veth link to a
# "LAN/internet" side, runs listeners, applies zforge-style rules and checks:
#   - SSH stays reachable from the LAN
#   - an inbound port (8899) is blocked by an iif+dport rule
#   - a local service (8898) is silenced by blocking its replies (sport rule)
#   - outbound to the internet is denied, except an allow-listed host
#   - LAN and loopback keep working
#
# Needs root, iproute2 and OpenBSD netcat. Run it inside a private namespace,
# so nothing touches the host's networking:
#   unshare -n -m sh tests/firewall/fib-rules-netns.sh
set -eu

[ "$(id -u)" = 0 ] || { echo "needs root" >&2; exit 2; }
mount -t tmpfs none /run   # private /run for `ip netns` (we are in our own mount ns)

ip netns add pr
ip link add v0 type veth peer name v1
ip link set v1 netns pr
ip link set lo up; ip link set v0 up
ip addr add 10.9.0.2/24 dev v0        # PC on the LAN
ip addr add 203.0.113.5/32 dev v0     # internet host: vendor cloud
ip addr add 203.0.113.6/32 dev v0     # internet host: allow-listed (e.g. NTP)
P="ip netns exec pr"
$P ip link set lo up; $P ip link set v1 up
$P ip addr add 10.9.0.1/24 dev v1
$P ip route add default via 10.9.0.2

for port in 22 8899 8898; do
    $P sh -c "while true; do echo hi-$port | nc -l -N 10.9.0.1 $port >/dev/null 2>&1; done" &
done
sh -c 'while true; do echo web | nc -l -N 0.0.0.0 80 >/dev/null 2>&1; done' &
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
sleep 1

FAILS=0
check() {  # check EXPECT(open|blocked) DESC CMD...
    want=$1 desc=$2; shift 2
    if out=$(timeout 3 "$@" </dev/null 2>/dev/null) && [ -n "$out" ]; then got=open; else got=blocked; fi
    if [ "$got" = "$want" ]; then r=ok; else r=FAIL; FAILS=$((FAILS + 1)); fi
    printf '  %-4s %-28s %s\n' "$r" "$desc" "$got"
}

echo "== baseline (no rules): everything open"
check open "LAN -> printer:8899" nc -w2 10.9.0.1 8899
check open "printer -> cloud:80" $P nc -w2 203.0.113.5 80

# ---- the zforge rule layout (see PLAN.md, Firewall) ----
$P ip rule add pref 100 lookup local
$P ip rule del pref 0
$P ip rule add pref 10 iif v1 ipproto tcp dport 8899 blackhole
$P ip rule add pref 11 ipproto tcp sport 8898 prohibit
$P ip rule add pref 200 to 10.9.0.0/24 lookup main
$P ip rule add pref 210 to 203.0.113.6 lookup main
$P ip rule add pref 300 prohibit

echo "== with rules"
$P ip rule | sed 's/^/  | /'
check open    "LAN -> printer:22"         nc -w2 10.9.0.1 22
check blocked "LAN -> printer:8899"       nc -w2 10.9.0.1 8899
check blocked "LAN -> printer:8898"       nc -w2 10.9.0.1 8898
check blocked "printer -> cloud:80"       $P nc -w2 203.0.113.5 80
check open    "printer -> allowlisted:80" $P nc -w2 203.0.113.6 80
check open    "printer -> LAN pc:80"      $P nc -w2 10.9.0.2 80
check open    "printer -> self:22"        $P nc -w2 10.9.0.1 22

if [ "$FAILS" = 0 ]; then echo "PASS"; else echo "FAILED: $FAILS check(s)"; exit 1; fi
