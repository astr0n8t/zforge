# zforge services: tiny supervisor (restart on exit) for sshd, ntp, moonraker.
#
# Each service runs as `zforge __run NAME` inside its own session (setsid),
# so stopping it is one signal to the process group.

svc_pidfile() { echo "$ZF_RUN/$1.pid"; }

svc_alive() {
    p=$(cat "$(svc_pidfile "$1")" 2>/dev/null) || return 1
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

svc_status() {
    if svc_alive "$1"; then echo "running (pid $(cat "$(svc_pidfile "$1")"))"; else echo "stopped"; fi
}

svc_pre() {  # one-time preparation before the first start
    case "$1" in
        sshd)
            mkdir -p "$ZF_ETC/ssh" && chmod 700 "$ZF_ETC/ssh"
            if [ ! -f "$ZF_ETC/ssh/dropbear_ed25519_host_key" ]; then
                zf_log "generating SSH host key"
                "$ZF_BIN/dropbearkey" -t ed25519 -f "$ZF_ETC/ssh/dropbear_ed25519_host_key" >/dev/null 2>&1 ||
                    { zf_log "dropbearkey failed"; return 1; }
            fi
            # dropbear refuses authorized_keys if any directory on its path is
            # group/other-writable (or not root-owned): keep the chain strict.
            for d in "$ZF_SYSROOT/data" "$ZF" "$ZF_ETC" "$ZF_ETC/ssh"; do
                if [ -n "$(find "$d" -maxdepth 0 -perm -g+w -o -maxdepth 0 -perm -o+w 2>/dev/null)" ]; then
                    zf_log "tightening permissions on $d (was group/other-writable; dropbear requires this)"
                    chmod go-w "$d"
                fi
            done
            [ -s "$ZF_ETC/ssh/authorized_keys" ] ||
                zf_log "WARNING: $ZF_HOME/etc/ssh/authorized_keys is empty; nobody can log in (password login is compiled out)"
            chmod 600 "$ZF_ETC/ssh/authorized_keys" 2>/dev/null
            ;;
    esac
    return 0
}

svc_start() {
    n=$1
    if svc_alive "$n"; then return 0; fi
    svc_pre "$n" || return 1
    logf="$ZF_LOG/$n.log"
    # keep logs small: one rotation at 512 KB
    if [ -f "$logf" ] && [ "$(wc -c <"$logf")" -gt 524288 ]; then mv -f "$logf" "$logf.1"; fi
    # shellcheck disable=SC2016  # expanded by the supervisor shell
    setsid sh -c '
        while :; do
            "$0" __run "$1"
            echo "[supervise] $1 exited (rc=$?), restarting in 5s"
            sleep 5
        done' "$ZF_SELF" "$n" >>"$logf" 2>&1 </dev/null &
    echo "$!" >"$(svc_pidfile "$n")"
    zf_log "started $n (pid $!)"
}

svc_stop() {
    n=$1; pf=$(svc_pidfile "$n")
    p=$(cat "$pf" 2>/dev/null) || return 0
    # The supervisor is a session/group leader: signal the whole group so the
    # service (e.g. Moonraker inside chroot) goes with it. No "--": dash's
    # kill doesn't take it; BusyBox and dash both accept a negative PGID.
    if kill -0 "-$p" 2>/dev/null || kill -0 "$p" 2>/dev/null; then
        kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null
        i=0
        while kill -0 "-$p" 2>/dev/null && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
        kill -KILL "-$p" 2>/dev/null
        zf_log "stopped $n"
    fi
    rm -f "$pf"
}

svc_restart() { svc_stop "$1"; [ "$1" = moonraker ] && mr_prepare; svc_start "$1"; }

# The actual service commands (called via `zforge __run NAME`).
svc_exec() {
    case "$1" in
        sshd)
            exec "$ZF_BIN/dropbear" -F -E -p "$SSH_PORT" \
                -r "$ZF_HOME/etc/ssh/dropbear_ed25519_host_key" \
                -D "$ZF_HOME/etc/ssh"
            ;;
        ntp)
            set --
            for s in $NTP_SERVERS; do set -- "$@" -p "$s"; done
            [ $# -gt 0 ] || { echo "no NTP_SERVERS configured"; sleep 3600; exit 0; }
            exec chroot "$ZF_CROOT" /bin/busybox ntpd -n "$@"
            ;;
        moonraker)
            exec chroot "$ZF_CROOT" /usr/bin/env -i \
                PATH=/opt/moonraker-env/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
                nice -n 10 /opt/moonraker-env/bin/python /opt/moonraker/moonraker/moonraker.py \
                -d "$MR_DATA_REL" -c "$MR_DATA_REL/config/moonraker.conf" -l "$MR_DATA_REL/logs/moonraker.log"
            ;;
        camera)
            # The stock touchscreen app runs its own mjpg_streamer (with
            # output_file.so) when its camera setting is on; a UVC device can
            # only be opened once, so wait rather than fight over it.
            said=""
            while grep -q -s '[o]utput_file.so' /proc/[0-9]*/cmdline 2>/dev/null; do   # [o]: don't match this grep
                [ -n "$said" ] || { echo "the stock camera stream is on (touchscreen setting); waiting for it to stop"; said=1; }
                sleep 30
            done
            said=""
            while [ ! -e "$CAMERA_DEVICE" ]; do
                [ -n "$said" ] || { echo "waiting for $CAMERA_DEVICE (no camera connected?)"; said=1; }
                sleep 10
            done
            # Stock mjpg-streamer, the camera's own MJPEG passed through (no
            # re-encoding), no snapshots to disk, no remote commands.
            LD_LIBRARY_PATH=/opt/mjpg-streamer/lib
            export LD_LIBRARY_PATH
            exec nice -n 5 /opt/mjpg-streamer/bin/mjpg_streamer \
                -i "/opt/mjpg-streamer/lib/input_uvc.so -d $CAMERA_DEVICE -r $CAMERA_RES -f $CAMERA_FPS" \
                -o "/opt/mjpg-streamer/lib/output_http.so -p $CAMERA_PORT -n -w /opt/mjpg-streamer/www"
            ;;
        fwrefresh)
            # re-resolve firewall host names (DNS, NTP, ALLOW_OUT) once the
            # network is up, then every 30 minutes
            sleep 60
            while :; do "$ZF_SELF" firewall refresh; sleep 1800; done
            ;;
        *) echo "unknown service $1"; exit 2 ;;
    esac
}
