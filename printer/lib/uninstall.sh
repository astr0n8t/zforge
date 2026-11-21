# zforge uninstall: the SSH equivalent of the rescue-uninstall stick, plus it
# undoes the live state (firewall rules, IPv6) and keeps a copy of what you'd
# want back: config, SSH keys, the HTTPS certificate, Moonraker's database.

# Remove every zforge ip rule and give the local table its pref-0 rule back.
fw_remove_all() {
    fw_lock 0 || return 1
    zf_ip rule show | grep -q -E "^0:[[:space:]]+from all lookup local" || zf_ip rule add pref 0 lookup local
    for p in $FW_PREFS "$FWU_P_TEMP" "$FWU_P_OTA" "$FW_P_LOCAL"; do
        while zf_ip rule del pref "$p" 2>/dev/null; do :; done
    done
    fw_unlock
    for f in all default $NET_IFACES; do
        c="$ZF_SYSROOT/proc/sys/net/ipv6/conf/$f/disable_ipv6"
        [ -w "$c" ] && echo 0 >"$c"
    done
    rm -f "$FW_PLAN"
    return 0
}

zf_cmd_uninstall() {
    if [ "${1:-}" != --yes ]; then
        cat <<EOF
This removes zforge from the printer:
  - stops zforge's services (SSH, Moonraker, camera, NTP) and removes its firewall rules
  - removes /etc/init.d/S35zforge, /etc/profile.d/zforge.sh and /data/.zforge
  - keeps a copy of your config, SSH keys, certificate and Moonraker database
    in /data/zforge-uninstalled-<date>/
The stock firmware is not touched. This SSH session keeps working until you
close it; after that there is no SSH (zforge provided it).

To go ahead:  zforge uninstall --yes
EOF
        return 2
    fi
    export ZF_COMPONENT=uninstall
    keep="$ZF_SYSROOT/data/zforge-uninstalled-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$keep" || zf_die "cannot create $keep"
    cp -a "$ZF_ETC" "$keep/etc" 2>/dev/null
    cp -a "$MR_DATA/certs" "$keep/moonraker-certs" 2>/dev/null
    cp -a "$MR_DATA/database" "$keep/moonraker-database" 2>/dev/null
    cp -a "$MR_DATA/config/moonraker.conf" "$keep/" 2>/dev/null
    zf_log "uninstall: saved config, keys and certificate to ${keep#"$ZF_SYSROOT"}"

    cmd_shutdown                  # services, boot, timers, swap, chroot mounts
    fw_remove_all || zf_log "uninstall: could not remove all firewall rules (they go away at reboot)"
    zf_umount_chroot              # fw_remove_all may have used the chroot's ip
    rm -f "$ZF_HOOK" "$ZF_PROFILE"

    if grep -q -E " ($ZF_HOME|$ZF_CROOT_REL)[ /]" "$ZF_SYSROOT/proc/mounts"; then
        zf_log "uninstall: zforge mounts are still active; hook removed, files kept. Reboot, then: rm -rf $ZF_HOME"
        return 1
    fi
    rm -rf "$ZF" "$ZF_SYSROOT/data/.zforge-update" "$ZF_SYSROOT/data/.zforge-update.run"
    echo "zforge removed. Your config, keys and certificate: ${keep#"$ZF_SYSROOT"}"
    echo "To install again: the zforge USB installer (keys from that folder's etc/ssh/authorized_keys)."
}
