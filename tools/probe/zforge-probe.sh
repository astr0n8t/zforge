#!/bin/sh
# zforge-probe: read-only discovery of a Flashforge AD5M / AD5M Pro.
#
# Collects everything Phase 0 of PLAN.md needs, then writes a gzipped tar
# to STDOUT. It changes nothing on the printer; its only scratch space is a
# small tmpfs directory that it deletes before exiting.
#
# Usage (from your PC):
#   ssh root@PRINTER 'sh -s' < zforge-probe.sh > probe.tar.gz
# or just use tools/probe/run-probe.sh.
#
# Written for BusyBox ash. Every command is optional: whatever is missing
# gets logged and skipped.

# shellcheck disable=SC2016  # snippets are intentionally single-quoted for sh -c
set -u
export LC_ALL=C
PATH="$PATH:/sbin:/usr/sbin:/bin:/usr/bin:/opt/bin:/opt/sbin"

PROBE_VERSION=2
TMPBASE=${ZFORGE_PROBE_TMP:-/tmp}
OUT="$TMPBASE/zforge-probe.$$"

log() { echo "[probe] $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() { rm -rf "$OUT" "$TMPBASE/zforge-probe.$$.tgz"; }
trap cleanup EXIT INT TERM


# run NAME CMD... : capture stdout+stderr of a command into $OUT/NAME
run() {
    _name=$1; shift
    mkdir -p "$(dirname "$OUT/$_name")"
    {
        echo "# \$ $*"
        "$@" 2>&1
        echo "# exit=$?"
    } >"$OUT/$_name" 2>&1
}

# sh_run NAME 'shell snippet'
sh_run() {
    _name=$1; shift
    mkdir -p "$(dirname "$OUT/$_name")"
    {
        echo "# \$ $1"
        sh -c "$1" 2>&1
        echo "# exit=$?"
    } >"$OUT/$_name" 2>&1
}

# grab SRC [DEST_DIR] : copy a small file/dir (if it exists), preserving path
grab() {
    [ -e "$1" ] || return 0
    _dest="$OUT/files$(dirname "$1")"
    mkdir -p "$_dest"
    cp -a "$1" "$_dest/" 2>/dev/null || cp -r "$1" "$_dest/" 2>/dev/null || true
}

# grab_small DIR MAXKB : copy regular files under DIR no larger than MAXKB
grab_small() {
    [ -d "$1" ] || return 0
    find "$1" -xdev -type f -size -"$2"k 2>/dev/null | while read -r f; do
        grab "$f"
    done
}

# printable strings from a binary (busybox has no `strings`)
bin_strings() {
    tr -cs 'A-Za-z0-9_./:%?&=+@-' '\n' <"$1" 2>/dev/null | awk 'length($0) >= 5'
}

###############################################################################
# Everything below runs inside main(), which is only called on the last line.
# When the script is piped in via `ssh ... 'sh -s' < zforge-probe.sh`, this
# guarantees the shell has read the whole file before any command runs, and
# main's stdin is /dev/null so no command can swallow the rest of the script.
main() {
mkdir -p "$OUT" || { log "cannot create $OUT"; exit 1; }
log "system"
run sys/uname          uname -a
sh_run sys/os-release  'cat /etc/os-release /etc/issue /etc/version* 2>/dev/null'
run sys/uptime         cat /proc/uptime
run sys/date           date
run sys/cpuinfo        cat /proc/cpuinfo
run sys/meminfo        cat /proc/meminfo
run sys/free           free
run sys/cmdline        cat /proc/cmdline
run sys/dmesg          dmesg
sh_run sys/busybox     'busybox 2>&1 | head -40'
sh_run sys/tools       'for t in sh bash busybox python python3 iptables iptables-save ip6tables nft ip tc ss netstat dropbear sshd ssh scp sftp-server curl wget openssl tar gzip xz unzip opkg chroot mount losetup dd strings sha256sum md5sum crond runsv start-stop-daemon systemctl; do printf "%-18s %s\n" "$t" "$(command -v $t 2>/dev/null || echo -)"; done'

log "storage"
run storage/mounts     cat /proc/mounts
run storage/df         df -k
run storage/partitions cat /proc/partitions
sh_run storage/mtd     'cat /proc/mtd 2>/dev/null || echo "no /proc/mtd"'
sh_run storage/blkid   'blkid 2>/dev/null || echo "no blkid"'
sh_run storage/by-name 'ls -l /dev/block/by-name /dev/disk/by-* 2>/dev/null'
sh_run storage/fstab   'cat /etc/fstab 2>/dev/null'

log "kernel / netfilter"
sh_run kernel/config   'if [ -r /proc/config.gz ]; then zcat /proc/config.gz; else echo "no /proc/config.gz"; fi'
sh_run kernel/config-netfilter 'if [ -r /proc/config.gz ]; then zcat /proc/config.gz | grep -E "NETFILTER|NF_|_NFT|IP_NF|IP6_NF|NFT_|XT_|BRIDGE_NF"; else echo "no /proc/config.gz"; fi'
run kernel/modules-loaded cat /proc/modules
sh_run kernel/modules-avail 'find /lib/modules -name "*.ko*" 2>/dev/null | sort'
sh_run kernel/netfilter-proc 'ls -la /proc/net/netfilter /proc/sys/net/netfilter 2>&1; for f in /proc/net/ip_tables_names /proc/net/ip_tables_targets /proc/net/ip_tables_matches /proc/net/ip6_tables_names; do echo "== $f"; cat $f 2>&1; done'
sh_run kernel/sys-module 'ls /sys/module'
sh_run kernel/iptables 'if command -v iptables >/dev/null; then iptables -S 2>&1; iptables -t nat -S 2>&1; else echo "no iptables binary"; fi'
sh_run kernel/nft      'if command -v nft >/dev/null; then nft list ruleset 2>&1; else echo "no nft binary"; fi'
sh_run kernel/blackhole-route 'ip route help 2>&1 | grep -i -E "blackhole|unreachable|prohibit" || echo "ip route help unavailable"'

log "network"
sh_run net/ip          'ip addr 2>&1; ip route 2>&1; ip -6 route 2>&1; ip rule 2>&1'
sh_run net/ifconfig    'ifconfig -a 2>&1; route -n 2>&1'
sh_run net/listening   'netstat -tulnp 2>/dev/null || netstat -tuln 2>&1'
sh_run net/connections 'netstat -tunp 2>/dev/null || netstat -tun 2>&1'
sh_run net/unix        'netstat -xlp 2>/dev/null || cat /proc/net/unix'
for f in tcp tcp6 udp udp6 unix; do run "net/proc-$f" cat "/proc/net/$f"; done
grab /etc/hosts
grab /etc/resolv.conf
grab /etc/network
sh_run net/wpa-present 'ls -la /etc/wpa_supplicant* 2>&1  # contents not copied (Wi-Fi password)'
sh_run net/hosts-blocked 'grep -n -E "sz3dp|flashforge|polar3d|qiniu" /etc/hosts 2>&1'
sh_run net/sockets-fs  'find /tmp /run /var /opt /data /usr/data -xdev -type s 2>/dev/null'

log "processes"
run proc/ps            ps
sh_run proc/ps-w       'ps -w 2>/dev/null || ps -ef 2>/dev/null'
sh_run proc/detail '
for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ -r "$d/cmdline" ] || continue
    cmd=$(tr "\0" " " <"$d/cmdline" 2>/dev/null)
    [ -n "$cmd" ] || continue
    exe=$(readlink "$d/exe" 2>/dev/null)
    rss=$(awk "/^VmRSS/ {print \$2\" \"\$3}" "$d/status" 2>/dev/null)
    ppid=$(awk "/^PPid/ {print \$2}" "$d/status" 2>/dev/null)
    uid=$(awk "/^Uid/ {print \$2}" "$d/status" 2>/dev/null)
    cwd=$(readlink "$d/cwd" 2>/dev/null)
    root=$(readlink "$d/root" 2>/dev/null)
    echo "pid=$p ppid=$ppid uid=$uid rss=$rss exe=$exe root=$root cwd=$cwd"
    echo "    cmd: $cmd"
    for fd in "$d"/fd/*; do
        t=$(readlink "$fd" 2>/dev/null) || continue
        case "$t" in socket:*|/dev/tty*|/dev/fb*|/dev/input*|/dev/video*|*.sock|*uds*) echo "    fd ${fd##*/} -> $t";; esac
    done
done'

log "init system / boot path"
grab /etc/inittab
grab /etc/rc.local
grab_small /etc/init.d 256
grab_small /etc/rc.d 256
grab_small /etc/profile.d 64
grab /etc/profile
grab /etc/passwd
grab /etc/group
grab /etc/shells
sh_run init/etc-tree   'ls -la /etc /etc/init.d /etc/rc.d 2>&1'
sh_run init/etc-dropbear 'ls -la /etc/dropbear /etc/ssh 2>&1'
sh_run init/crontabs   'ls -la /etc/crontabs /var/spool/cron 2>&1; cat /etc/crontabs/* 2>/dev/null'

log "stock firmware layout"
sh_run fw/opt-tree     'find /opt -xdev -maxdepth 3 2>/dev/null | sort'
sh_run fw/opt-du       'du -sk /opt/* 2>/dev/null'
sh_run fw/usr-prog     'find /usr/prog /usr/data -xdev -maxdepth 3 2>/dev/null | sort | head -500'
sh_run fw/data-tree    'for d in /data /usr/data; do [ -d $d ] && { echo "== $d"; du -sk $d/* $d/.[!.]* 2>/dev/null; find $d -xdev -maxdepth 2 2>/dev/null | grep -v "/gcode" | sort | head -300; }; done'
sh_run fw/versions     'for f in /opt/config/version* /opt/version* /etc/version* /root/version* /usr/data/version*; do [ -f "$f" ] && { echo "== $f"; cat "$f"; }; done; ls -la /opt/PROGRAM 2>/dev/null'
grab_small /opt/config 256
grab_small /usr/data/config 256

log "klipper"
sh_run klipper/where   'for d in /opt/klipper /usr/prog/klipper /usr/data/klipper; do [ -d $d ] && echo $d; done'
sh_run klipper/version 'for d in /opt/klipper /usr/prog/klipper; do [ -d $d ] || continue; echo "== $d"; cat $d/klippy/.version 2>/dev/null; (cd $d && git describe --always --tags 2>/dev/null); grep -rh "APP_VERSION\|^VERSION" $d/klippy/*.py 2>/dev/null | head; done'
sh_run klipper/extras  'for d in /opt/klipper /usr/prog/klipper; do [ -d $d/klippy/extras ] && { echo "== $d"; ls -la $d/klippy/extras; }; done'
sh_run klipper/tree    'for d in /opt/klipper /usr/prog/klipper; do [ -d $d ] && find $d -xdev -maxdepth 2 | sort; done'
sh_run klipper/python  'for p in python3 python /opt/klipper/../bin/python* /usr/bin/python*; do command -v $p >/dev/null 2>&1 && { echo "== $p"; $p --version 2>&1; }; done'
sh_run klipper/mcu-fw  'find / -xdev \( -name "*.bin" -o -name "*.hex" -o -name "*.elf" \) -path "*klip*" 2>/dev/null | head -50; find / -xdev -iname "*mcu*" 2>/dev/null | grep -v "^/proc" | head -50'

log "update mechanism"
# Which files mention the USB init script, update packages or update hosts?
# One grep pass over all candidate files (text and binary, gcode excluded),
# then classify the hits by pattern.
mkdir -p "$OUT/update"
UPDATE_PATS='flashforge_init|\.tgz|Adventurer5M|sz3dp|update\.cn|klipper_mod_skip|/mnt/'
find /etc /opt /usr/bin /usr/sbin /bin /sbin /root -xdev -type f \
        ! -name '*.gcode' ! -name '*.3mf' ! -path '*/gcodes/*' \
        -exec grep -l -E "$UPDATE_PATS" {} + 2>/dev/null >"$OUT/update-hits.tmp" || true
{
    for pat in flashforge_init '\.tgz' Adventurer5M sz3dp 'update\.cn' klipper_mod_skip '/mnt/'; do
        echo "== pattern: $pat"
        while read -r f; do grep -q -E "$pat" "$f" 2>/dev/null && echo "$f"; done <"$OUT/update-hits.tmp" | head -60
    done
} >"$OUT/update/refs" 2>&1
rm -f "$OUT/update-hits.tmp"
sh_run update/script-copies '
for pat in flashforge_init "\.tgz"; do
    grep -rlI -E "$pat" /etc /opt /usr/bin /usr/sbin /bin /sbin /root 2>/dev/null
done | sort -u | while read -r f; do
    sz=$(wc -c <"$f"); [ "$sz" -lt 262144 ] && echo "$f"
done'
# Copy the small text scripts that handle updates so we can read them.
grep -v '^#' "$OUT/update/script-copies" 2>/dev/null | while read -r f; do [ -f "$f" ] && grab "$f"; done

log "stock binaries (strings excerpts)"
mkdir -p "$OUT/strings"
for pid_dir in /proc/[0-9]*; do readlink "$pid_dir/exe" 2>/dev/null; done | sort -u | while read -r exe; do
    case "$exe" in
        /bin/busybox|/bin/*|/sbin/*|/usr/bin/python*|"") continue ;;
    esac
    [ -f "$exe" ] || continue
    name=$(echo "$exe" | tr '/' '_')
    {
        echo "# $exe ($(wc -c <"$exe") bytes)"
        bin_strings "$exe" | grep -i -E 'http|https|://|\.tgz|flashforge_init|/mnt|/tmp/|\.sock|uds|sz3dp|flashforge|polar3d|qiniu|update|upgrade|firmware|klipper|moonraker|:[0-9]{4}|port|md5|sha|sign|rsa|aes|decrypt|iptables|hosts' | sort -u | head -2000
    } >"$OUT/strings/$name.txt" 2>&1
done
# Also look at well-known stock binaries even if not running
for exe in /opt/PROGRAM/ffstartup-arm /opt/PROGRAM/firmwareExe /opt/PROGRAM/*; do
    [ -f "$exe" ] || continue
    name=$(echo "$exe" | tr '/' '_')
    [ -f "$OUT/strings/$name.txt" ] && continue
    {
        echo "# $exe ($(wc -c <"$exe") bytes)"
        bin_strings "$exe" | grep -i -E 'http|://|\.tgz|flashforge_init|/mnt|/tmp/|\.sock|uds|sz3dp|update|upgrade|firmware|klipper|:[0-9]{4}|md5|sha|sign|rsa|aes|decrypt' | sort -u | head -2000
    } >"$OUT/strings/$name.txt" 2>&1
done

log "existing mods (zmod etc.)"
sh_run mods/zmod 'ls -la /opt/config/mod /opt/config/mod_data /data/.mod /usr/data/.mod /usr/data/config/mod 2>&1; cat /opt/config/mod_data/variables.cfg 2>/dev/null'
sh_run mods/hooks 'grep -rn -E "zmod|\.mod/|mod_data|klipper_mod|forge-x" /etc 2>/dev/null | head -50'

###############################################################################
log "summary"
tcp_listen_ports() {
    for f in /proc/net/tcp /proc/net/tcp6; do
        awk 'NR>1 && $4=="0A"{n=split($2,a,":"); print a[n]}' "$f" 2>/dev/null
    done | sort -u | while read -r h; do printf '%d ' "0x$h"; done
}
yesno() { if eval "$1" >/dev/null 2>&1; then echo yes; else echo no; fi; }
{
    echo "zforge probe v$PROBE_VERSION  $(date)"
    echo
    echo "kernel:              $(uname -r) $(uname -m)"
    echo "mem total/avail kB:  $(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print t"/"a}' /proc/meminfo)"
    echo "/proc/config.gz:     $(yesno '[ -r /proc/config.gz ]')"
    if [ -r /proc/config.gz ]; then
        for k in CONFIG_NETFILTER CONFIG_NF_TABLES CONFIG_NF_TABLES_INET CONFIG_NFT_CT CONFIG_NF_CONNTRACK CONFIG_IP_NF_IPTABLES CONFIG_IP_NF_FILTER CONFIG_NETFILTER_XT_MATCH_STATE CONFIG_NETFILTER_XT_MATCH_CONNTRACK CONFIG_IP_SET CONFIG_IP_ADVANCED_ROUTER CONFIG_IPV6; do
            printf '  %-38s %s\n' "$k" "$(zcat /proc/config.gz | grep -E "^$k=|^# $k is not set" | head -1)"
        done
    fi
    echo "ip_tables in /proc:  $(yesno '[ -e /proc/net/ip_tables_names ]')"
    echo "nf_tables module:    $(yesno 'grep -q nf_tables /proc/modules || find /lib/modules -name "nf_tables*" | grep -q .')"
    echo "iptables binary:     $(command -v iptables || echo -)"
    echo "nft binary:          $(command -v nft || echo -)"
    echo
    echo "init:                $( [ -f /etc/inittab ] && echo "inittab (busybox/sysv)" ) $( [ -d /etc/init.d ] && ls /etc/init.d | tr '\n' ' ')"
    echo "root fs:             $(awk '$2=="/"{print $1" "$3" "$4}' /proc/mounts)"
    echo "data mounts:         $(awk '$2 ~ /^\/(data|usr\/data|opt)/{print $2"("$3","$4")"}' /proc/mounts | tr '\n' ' ')"
    echo "free kB on / /opt /data: $(df -k / /opt /data 2>/dev/null | awk 'NR>1{printf "%s=%s ", $6, $4}')"
    echo
    echo "klipper dirs:        $(for d in /opt/klipper /usr/prog/klipper; do [ -d $d ] && printf '%s ' $d; done)"
    echo "klipper cmdline:     $(for d in /proc/[0-9]*; do c=$(tr '\0' ' ' <$d/cmdline 2>/dev/null); case "$c" in *klippy*) echo "$c"; break;; esac; done)"
    echo "unix sockets:        $(find /tmp /run -xdev -type s 2>/dev/null | tr '\n' ' ')"
    echo "listening tcp ports: $(tcp_listen_ports)"
    echo
    echo "flashforge_init refs: $(grep -rlI flashforge_init /etc /opt 2>/dev/null | tr '\n' ' ')"
    echo "zmod present:        $(yesno '[ -d /opt/config/mod ] || [ -d /data/.mod ]')"
} >"$OUT/SUMMARY.txt" 2>&1

echo "$PROBE_VERSION" >"$OUT/PROBE_VERSION"
log "packing ($(du -sk "$OUT" | awk '{print $1}') kB)"
# BusyBox tar may be built without gzip; fall back to tar|gzip, then plain tar.
# run-probe.sh detects which format arrived.
cd "$OUT" || exit 1
if tar -czf "$TMPBASE/zforge-probe.$$.tgz" . 2>/dev/null; then
    cat "$TMPBASE/zforge-probe.$$.tgz"
elif have gzip; then
    tar -cf - . | gzip -c
else
    tar -cf - .
fi
rm -f "$TMPBASE/zforge-probe.$$.tgz"
log "done"
}

main "$@" </dev/null
