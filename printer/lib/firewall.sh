# zforge firewall: policy routing (`ip rule`), because the stock kernel has
# no netfilter. Phase 1 installs only the base rules that apply in every
# profile; profiles (lan/strict/open) come in Phase 2.
#
# Layout (lower pref = evaluated first):
#   10      inbound blocks that are always on (plain-HTTP Moonraker)
#   100     lookup local          (moved here from pref 0 so the rules above can win)
#   32766   lookup main, 32767 lookup default (kernel defaults)

FW_PREF_BASE=10
FW_PREF_LOCAL=100

fw_has() { zf_ip rule show | grep -q -E "$1"; }

fw_apply_base() {
    # 1. local table at pref 100 (add first, then delete pref 0: no gap)
    fw_has "^$FW_PREF_LOCAL:[[:space:]]+from all lookup local" || zf_ip rule add pref "$FW_PREF_LOCAL" lookup local || return 1
    if fw_has "^0:[[:space:]]+from all lookup local"; then zf_ip rule del pref 0 lookup local || return 1; fi

    # 2. Moonraker's plain-HTTP port is reachable from loopback only.
    #    Rules may name interfaces that don't exist yet (Wi-Fi loads later).
    for i in $NET_IFACES; do
        fw_has "^$FW_PREF_BASE:.* iif $i .*dport $MOONRAKER_HTTP_PORT blackhole" ||
            zf_ip rule add pref "$FW_PREF_BASE" iif "$i" ipproto tcp dport "$MOONRAKER_HTTP_PORT" blackhole || return 1
    done
    zf_log "firewall: base rules applied (tcp/$MOONRAKER_HTTP_PORT loopback-only on: $NET_IFACES)"
}

fw_status() {
    echo "ip rules:"
    zf_ip rule show | sed 's/^/  /'
}
