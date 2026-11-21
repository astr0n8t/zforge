# zforge firewall: policy routing (`ip rule`), because the stock kernel has
# no netfilter. Rules are stateless; every packet's route lookup walks them
# in order (lower pref first) and the first match decides:
#
#   10   blocks that apply in every profile: plain-HTTP Moonraker (always),
#        the stock LAN API and the camera port when switched off
#   20   inbound allows (lan/strict): listed ports from listed sources,
#        plus replies (ephemeral ports), DHCP, NTP replies, ICMP
#   30   inbound default deny (lan/strict): blackhole all other TCP/UDP
#        (never protocol-less: that would break ARP, see fw_plan)
#   100  lookup local (moved from pref 0 so the rules above can win)
#   200  outbound allows (lan/strict): LAN, multicast/broadcast, DNS and NTP
#        servers, ALLOW_OUT (strict)
#   290  outbound default deny (lan/strict): prohibit
#
# Profiles: open (stock behaviour + the always-on blocks), lan (LAN only,
# plus DNS/NTP), strict (lan + ALLOW_OUT). IPv6 can't be policed (no IPv6
# policy tables in the stock kernel), so lan/strict turn it off.
#
# Changes go through apply -> confirm: an unconfirmed change reverts after
# FW_CONFIRM_SECONDS, and at the next boot. The rules always come from the
# last confirmed config (var/firewall.confirmed.conf) except while a change
# is pending.

FW_P_BLOCK=10
FW_P_ALLOW=20
FW_P_INDENY=30
FW_P_LOCAL=100
FW_P_OUT=200
FW_P_OUTDENY=290
FW_PREFS="$FW_P_BLOCK $FW_P_ALLOW $FW_P_INDENY $FW_P_OUT $FW_P_OUTDENY"

FW_CONFIRMED=$ZF_VAR/firewall.confirmed.conf
FW_PENDING=$ZF_VAR/firewall.pending
FW_PLAN=$ZF_VAR/firewall.plan        # rules currently installed (one `ip rule add` arg list per line)
STOCK_API_TCP="8898 8899"
STOCK_API_UDP="48899 19000"

fw_has() { zf_ip rule show | grep -q -E "$1"; }

# --------------------------------------------------------------- helpers

# Is $1 an IPv4 address or CIDR?
fw_is_ip4() {
    case "$1" in
        *[!0-9./]*|'') return 1 ;;
    esac
    echo "$1" | grep -q -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'
}

# Resolve names to IPv4 addresses (IPs/CIDRs pass through). Needs network and
# the chroot (Python's resolver); unresolvable names are logged and skipped.
fw_resolve() {
    names=""
    for n in "$@"; do
        if fw_is_ip4 "$n"; then echo "$n"
        else
            case "$n" in *[!A-Za-z0-9.-]*) zf_log "firewall: ignoring invalid name '$n'"; continue ;; esac
            names="$names $n"
        fi
    done
    [ -n "$names" ] || return 0
    zf_root_ready && [ -x "$ZF_CROOT/usr/bin/python3" ] || return 0
    # shellcheck disable=SC2086
    zf_chroot /usr/bin/python3 -c '
import socket, sys
for h in sys.argv[1:]:
    try:
        for a in sorted({i[4][0] for i in socket.getaddrinfo(h, None, socket.AF_INET)}):
            print(a)
    except Exception:
        print("firewall: cannot resolve " + h + " (yet)", file=sys.stderr)
' $names 2>>"$ZF_LOG/zforge.log"
}

fw_dns_servers() {
    awk '$1 == "nameserver" {print $2}' "$ZF_SYSROOT/etc/resolv.conf" 2>/dev/null | while read -r a; do
        fw_is_ip4 "$a" && echo "$a"
    done
}

fw_ephemeral() {  # "lo-hi" from the kernel's local port range
    r=$(cat "$ZF_SYSROOT/proc/sys/net/ipv4/ip_local_port_range" 2>/dev/null) || r="32768 60999"
    set -- $r
    echo "$1-$2"
}

# --------------------------------------------------------------- plan

# Print the rules for the current settings, one `ip rule add` argument list per
# line. RESOLVE=1 resolves host names (needs network); at early boot it's 0.
fw_plan() {
    lan=$(for c in $LAN_CIDRS; do fw_is_ip4 "$c" && echo "$c"; done)
    srcs() { for c in ${1:-$lan}; do fw_is_ip4 "$c" && echo "$c" || zf_log "firewall: ignoring invalid source '$c'" >&2; done; }

    # 10: always-on blocks
    for i in $NET_IFACES; do
        echo "pref $FW_P_BLOCK iif $i ipproto tcp dport $MOONRAKER_HTTP_PORT blackhole"
        if [ "$STOCK_LAN_API" != on ]; then
            for p in $STOCK_API_TCP; do echo "pref $FW_P_BLOCK iif $i ipproto tcp dport $p blackhole"; done
            for p in $STOCK_API_UDP; do echo "pref $FW_P_BLOCK iif $i ipproto udp dport $p blackhole"; done
        fi
        [ "$CAMERA" = on ] || echo "pref $FW_P_BLOCK iif $i ipproto tcp dport $CAMERA_PORT blackhole"
    done

    case "$FIREWALL_PROFILE" in
        open) return 0 ;;
        lan|strict) ;;
        *) zf_log "firewall: unknown FIREWALL_PROFILE '$FIREWALL_PROFILE', using lan" >&2 ;;
    esac

    eph=$(fw_ephemeral)
    for i in $NET_IFACES; do
        # 20: inbound allows
        for s in $(srcs "$SSH_ALLOW"); do echo "pref $FW_P_ALLOW iif $i from $s ipproto tcp dport $SSH_PORT lookup local"; done
        for s in $(srcs "$MOONRAKER_ALLOW"); do echo "pref $FW_P_ALLOW iif $i from $s ipproto tcp dport $MOONRAKER_HTTPS_PORT lookup local"; done
        if [ "$CAMERA" = on ]; then
            for s in $(srcs "$CAMERA_ALLOW"); do echo "pref $FW_P_ALLOW iif $i from $s ipproto tcp dport $CAMERA_PORT lookup local"; done
        fi
        if [ "$STOCK_LAN_API" = on ]; then
            for s in $lan; do
                for p in $STOCK_API_TCP; do echo "pref $FW_P_ALLOW iif $i from $s ipproto tcp dport $p lookup local"; done
                for p in $STOCK_API_UDP; do echo "pref $FW_P_ALLOW iif $i from $s ipproto udp dport $p lookup local"; done
            done
        fi
        # replies to the printer's own connections (stateless: by port range)
        echo "pref $FW_P_ALLOW iif $i ipproto tcp dport $eph lookup local"
        echo "pref $FW_P_ALLOW iif $i ipproto udp dport $eph lookup local"
        echo "pref $FW_P_ALLOW iif $i ipproto udp dport 68 lookup local"    # DHCP client
        echo "pref $FW_P_ALLOW iif $i ipproto udp dport 123 lookup local"   # NTP replies
        echo "pref $FW_P_ALLOW iif $i ipproto icmp lookup local"
        # 30: all other TCP/UDP inbound is dropped. Only TCP/UDP: a rule
        # without ipproto would also catch the kernel's ARP check (a route
        # lookup with protocol 0), and the printer would stop answering ARP.
        echo "pref $FW_P_INDENY iif $i ipproto tcp blackhole"
        echo "pref $FW_P_INDENY iif $i ipproto udp blackhole"
    done

    # 200: outbound allows
    for c in $lan 224.0.0.0/4 255.255.255.255/32; do echo "pref $FW_P_OUT to $c lookup main"; done
    out=$(fw_dns_servers)
    if [ "${RESOLVE:-1}" = 1 ]; then
        # shellcheck disable=SC2086
        out="$out $(fw_resolve $NTP_SERVERS)"
        # shellcheck disable=SC2086
        [ "$FIREWALL_PROFILE" = strict ] && out="$out $(fw_resolve $ALLOW_OUT)"
    fi
    for a in $out; do echo "$a"; done | sort -u | while read -r a; do
        [ -n "$a" ] && echo "pref $FW_P_OUT to $a lookup main"
    done
    # 290: everything else outbound is refused
    echo "pref $FW_P_OUTDENY prohibit"
}

# --------------------------------------------------------------- install

fw_local_rule() {  # local table at pref 100 (add first, then delete pref 0: no gap)
    fw_has "^$FW_P_LOCAL:[[:space:]]+from all lookup local" || zf_ip rule add pref "$FW_P_LOCAL" lookup local || return 1
    if fw_has "^0:[[:space:]]+from all lookup local"; then zf_ip rule del pref 0 lookup local || return 1; fi
}

fw_ipv6() {
    v=0; [ "$FIREWALL_PROFILE" = open ] || v=1
    for f in all default $NET_IFACES; do
        c="$ZF_SYSROOT/proc/sys/net/ipv6/conf/$f/disable_ipv6"
        [ -w "$c" ] && echo "$v" >"$c"   # interfaces that don't exist yet get "default"
    done
    return 0
}

# One firewall change at a time (apply, refresh and the rollback timer can
# otherwise interleave their flush/add sequences). mkdir is atomic.
FW_LOCK=$ZF_RUN/fw.lock
# fw_lock [TIMEOUT]: wait up to TIMEOUT seconds (default 300; 0 = forever).
# The rollback timer and the boot apply wait forever: they must never be
# skipped, or an unconfirmed (maybe locking-out) change could stay.
fw_lock() {
    limit=${1:-300}
    deadline=$(( $(date +%s) + limit ))
    me=$(sh -c 'echo $PPID')      # this (sub)shell's own pid; $$ would be the parent's
    while ! mkdir "$FW_LOCK" 2>/dev/null; do
        owner=$(cat "$FW_LOCK/pid" 2>/dev/null)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then   # stale lock
            rm -f "$FW_LOCK/pid"; rmdir "$FW_LOCK" 2>/dev/null; continue
        fi
        if [ "$limit" != 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
            zf_log "firewall: lock held by pid ${owner:-?} for ${limit}s, giving up"
            return 1
        fi
        sleep 1
    done
    echo "$me" >"$FW_LOCK/pid"
}
fw_unlock() { rm -f "$FW_LOCK/pid"; rmdir "$FW_LOCK" 2>/dev/null; return 0; }

# Install a plan file: replace zforge's rules (prefs 10-290) with its lines.
fw_install() {
    fw_local_rule || return 1
    for p in $FW_PREFS; do
        while zf_ip rule del pref "$p" 2>/dev/null; do :; done
    done
    rc=0
    while read -r line; do
        # shellcheck disable=SC2086
        zf_ip rule add $line || { zf_log "firewall: ip rule add $line FAILED"; rc=1; }
    done <"$1"
    cp "$1" "$FW_PLAN"
    fw_ipv6
    return $rc
}

# Apply the given config file's firewall settings (in a subshell, so the
# rest of zforge keeps its current settings). Skips the reinstall if the
# resulting rules are unchanged, unless FORCE=1.
fw_apply_conf() {
    (
        fw_lock "${FW_LOCK_TIMEOUT:-300}" || exit 1
        trap fw_unlock EXIT
        zf_defaults
        # shellcheck disable=SC1090
        . "$1"
        plan="$ZF_RUN/firewall.plan.$$"
        fw_plan >"$plan" || exit 1
        if [ "${FORCE:-0}" != 1 ] && cmp -s "$plan" "$FW_PLAN" && fw_has "^$FW_P_LOCAL:.*lookup local"; then
            rm -f "$plan"; exit 0
        fi
        fw_install "$plan"; rc=$?
        rm -f "$plan"
        zf_log "firewall: profile $FIREWALL_PROFILE applied ($(grep -c . "$FW_PLAN") rules)$( [ $rc = 0 ] || echo ', WITH ERRORS')"
        exit $rc
    )
}

# The config the firewall follows: the pending one while a change awaits
# confirmation, else the last confirmed one.
fw_effective_conf() {
    [ -f "$FW_CONFIRMED" ] || cp "$ZF_CONF" "$FW_CONFIRMED" 2>/dev/null || : >"$FW_CONFIRMED"
    if [ -e "$FW_PENDING" ]; then echo "$ZF_CONF"; else echo "$FW_CONFIRMED"; fi
}

# --------------------------------------------------------------- entry points

# Boot (before the network): a change still unconfirmed at reboot is
# dropped. Names aren't resolvable yet; the refresh service fills them in.
fw_boot() {
    if [ -e "$FW_PENDING" ]; then
        rm -f "$FW_PENDING"
        zf_log "firewall: an unconfirmed change was pending at reboot; using the last confirmed settings"
    fi
    FW_LOCK_TIMEOUT=0 FORCE=1 RESOLVE=0 fw_apply_conf "$(fw_effective_conf)"
}

# Periodic re-resolve (DNS answers and resolv.conf change).
fw_refresh() { FW_LOCK_TIMEOUT=120 RESOLVE=1 fw_apply_conf "$(fw_effective_conf)"; }

fw_cmd_apply() {
    secs=${1:-$FW_CONFIRM_SECONDS}
    case "$secs" in *[!0-9]*|'') zf_die "usage: zforge firewall apply [SECONDS]" ;; esac
    fw_effective_conf >/dev/null      # make sure a confirmed baseline exists
    zf_mount_chroot
    : >"$FW_PENDING"
    if ! FORCE=1 fw_apply_conf "$ZF_CONF"; then
        zf_log "firewall: applying failed; reverting"
        rm -f "$FW_PENDING"; FORCE=1 fw_apply_conf "$FW_CONFIRMED"
        return 1
    fi
    # rollback timer, detached so it survives a dropped SSH session
    [ -f "$ZF_RUN/fw-rollback.pid" ] && kill "$(cat "$ZF_RUN/fw-rollback.pid")" 2>/dev/null
    setsid "$ZF_SELF" __fw_rollback "$secs" </dev/null >/dev/null 2>&1 &
    echo "$!" >"$ZF_RUN/fw-rollback.pid"
    date +%s >"$FW_PENDING"
    echo "Firewall changes applied. Run 'zforge firewall confirm' within ${secs}s to keep them;"
    echo "otherwise they are reverted (also at the next reboot)."
}

fw_cmd_rollback_timer() {
    sleep "$1"
    if [ -e "$FW_PENDING" ]; then
        rm -f "$FW_PENDING"
        zf_log "firewall: change not confirmed within $1s, reverting to the last confirmed settings"
        FW_LOCK_TIMEOUT=0 FORCE=1 fw_apply_conf "$FW_CONFIRMED"
    fi
    rm -f "$ZF_RUN/fw-rollback.pid"
}

fw_cmd_confirm() {
    [ -e "$FW_PENDING" ] || { echo "nothing to confirm"; return 0; }
    cp "$ZF_CONF" "$FW_CONFIRMED.new" && mv "$FW_CONFIRMED.new" "$FW_CONFIRMED"
    rm -f "$FW_PENDING"
    [ -f "$ZF_RUN/fw-rollback.pid" ] && kill "$(cat "$ZF_RUN/fw-rollback.pid")" 2>/dev/null
    rm -f "$ZF_RUN/fw-rollback.pid"
    zf_log "firewall: change confirmed"
    echo "confirmed"
}

fw_status() {
    eff=$(fw_effective_conf)
    # shellcheck disable=SC1090
    prof=$( (zf_defaults; . "$eff"; echo "$FIREWALL_PROFILE") )
    echo "firewall profile: $prof"
    if [ -e "$FW_PENDING" ]; then
        t=$(cat "$FW_PENDING" 2>/dev/null); now=$(date +%s)
        echo "  PENDING: unconfirmed change applied $( [ -n "$t" ] && echo "$((now - t))s ago"); 'zforge firewall confirm' to keep it"
    fi
    if ! cmp -s "$ZF_CONF" "$eff"; then
        echo "  note: zforge.conf differs from the active firewall settings; 'zforge firewall apply' to use it"
    fi
    echo "ip rules:"
    zf_ip rule show | sed 's/^/  /'
}
