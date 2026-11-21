# zforge TLS: Moonraker's HTTPS certificate (self-signed).
# Moonraker only starts its HTTPS server if the cert exists when it starts,
# so (re)start Moonraker after changing it.

TLS_CERT_REL=$MR_DATA_REL/certs/moonraker.cert
TLS_KEY_REL=$MR_DATA_REL/certs/moonraker.key

tls_have() { [ -s "$ZF_SYSROOT$TLS_CERT_REL" ] && [ -s "$ZF_SYSROOT$TLS_KEY_REL" ]; }

tls_ips() {  # IPv4 addresses on NET_IFACES
    for i in $NET_IFACES; do
        # only real "inet A.B.C.D/NN" entries (ignore any error text)
        zf_ip -4 -o addr show dev "$i" 2>/dev/null |
            awk '$3 == "inet" && $4 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// {sub("/.*", "", $4); print $4}'
    done
}

# Subject alternative names: hostname, hostname.local, the printer's IPv4
# addresses, plus TLS_EXTRA_NAMES (DNS names and/or IP addresses) from zforge.conf.
tls_san() {
    set -f   # no globbing of wildcard names like *.home.arpa (runs in a $( ) subshell)
    san="DNS:$1,DNS:$1.local"
    for ip in $(tls_ips); do san="$san,IP:$ip"; done
    for n in ${TLS_EXTRA_NAMES:-}; do
        case "$n" in
            # only characters valid in names/addresses: nothing that could
            # inject into openssl's -addext value
            *[!A-Za-z0-9.:*-]*|'') zf_die "TLS_EXTRA_NAMES: invalid entry '$n'" ;;
            *:*)       san="$san,IP:$n" ;;     # IPv6 address
            *[!0-9.]*) san="$san,DNS:$n" ;;    # has letters, '-' or '*': a DNS name
            *)         san="$san,IP:$n" ;;     # digits and dots: IPv4 address
        esac
    done
    echo "$san"
}

tls_generate() {
    ZF_COMPONENT=tls
    zf_clock_ok || zf_die "clock not set (year $(date +%Y)); the certificate would be invalid. Wait for NTP or set the date."
    host=$(hostname 2>/dev/null || echo printer)
    san=$(tls_san "$host") || exit 1
    mkdir -p "$MR_DATA/certs" && chmod 700 "$MR_DATA/certs"
    zf_chroot openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 \
        -days "$TLS_DAYS" -subj "/CN=$host" \
        -addext "subjectAltName=$san" \
        -addext "extendedKeyUsage=serverAuth" \
        -keyout "$TLS_KEY_REL.new" -out "$TLS_CERT_REL.new" >"$ZF_LOG/openssl.err" 2>&1 ||
        zf_die "openssl failed: $(tail -n 3 "$ZF_LOG/openssl.err" | tr '\n' ' ')"
    chmod 600 "$ZF_SYSROOT$TLS_KEY_REL.new"
    mv "$ZF_SYSROOT$TLS_KEY_REL.new" "$ZF_SYSROOT$TLS_KEY_REL"
    mv "$ZF_SYSROOT$TLS_CERT_REL.new" "$ZF_SYSROOT$TLS_CERT_REL"
    zf_log "new self-signed certificate for $san"
}

tls_import() {  # tls_import CERT KEY (paths on the printer)
    ZF_COMPONENT=tls
    [ -s "$1" ] && [ -s "$2" ] || zf_die "certificate or key file missing"
    # the key must belong to the certificate
    c=$(zf_chroot_file_pubkey x509 "$1") || zf_die "not a PEM certificate: $1"
    k=$(zf_chroot_file_pubkey pkey "$2") || zf_die "not a PEM private key: $2"
    [ "$c" = "$k" ] || zf_die "the key does not match the certificate"
    mkdir -p "$MR_DATA/certs" && chmod 700 "$MR_DATA/certs"
    cp "$1" "$ZF_SYSROOT$TLS_CERT_REL" && cp "$2" "$ZF_SYSROOT$TLS_KEY_REL" && chmod 600 "$ZF_SYSROOT$TLS_KEY_REL"
    zf_log "imported certificate $1"
}

# print the public key of a certificate (x509) or private key (pkey), read from stdin
zf_chroot_file_pubkey() {
    case "$1" in
        x509) zf_chroot openssl x509 -noout -pubkey <"$2" 2>>"$ZF_LOG/openssl.err" ;;
        pkey) zf_chroot openssl pkey -pubout <"$2" 2>>"$ZF_LOG/openssl.err" ;;
    esac
}

tls_show() {
    tls_have || zf_die "no certificate yet (zforge tls regen)"
    zf_chroot openssl x509 -in "$TLS_CERT_REL" -noout -subject -enddate -ext subjectAltName -fingerprint -sha256
    echo
    cat "$ZF_SYSROOT$TLS_CERT_REL"
}

# Boot: make sure a certificate exists. Generating one needs an IP address
# (for the SAN) and a correct clock, both of which can take a while after boot.
tls_ensure_wait() {
    tls_have && return 0
    export ZF_COMPONENT=tls
    zf_log "no certificate yet: waiting for an IP address and a synced clock (up to 10 min)"
    i=0
    while [ $i -lt 120 ]; do
        if [ -n "$(tls_ips)" ] && zf_clock_ok; then
            ( tls_generate ) && return 0
        fi
        sleep 5; i=$((i + 1))
    done
    zf_log "WARNING: still no certificate; Moonraker starts without HTTPS. Fix the clock/network, then: zforge tls regen"
    return 1
}
