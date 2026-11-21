# zforge Moonraker setup: data dir layout and config generation.
#
# Data path (inside and outside the chroot): /data/.zforge/var/moonraker
#   config/moonraker.conf    generated from share/moonraker.conf.in on every start
#   config/stock = /opt/config   stock Klipper config (bind mount, chroot only)
#   gcodes = /data           the stock virtual_sdcard path (bind mount, chroot only)
#   certs/moonraker.{cert,key}    HTTPS certificate (see tls.sh)
#   database/, logs/, comms/
# User overrides: /data/.zforge/etc/moonraker.user.conf (included last).

mr_prepare() {
    for d in config certs database logs comms; do mkdir -p "$MR_DATA/$d"; done
    chmod 700 "$MR_DATA/certs" "$MR_DATA/database"
    # gcodes (-> /data) and config/stock (-> /opt/config) are bind mounts made
    # by zf_mount_chroot, inside the chroot only (see common.sh)

    user="$ZF_ETC/moonraker.user.conf"
    [ -f "$user" ] || cat >"$user" <<'EOF'
# Your Moonraker settings, included after zforge's generated config.
# Sections here override or extend /data/.zforge/var/moonraker/config/moonraker.conf.
# Example:
#[spoolman]
#server: https://spoolman.example.lan
EOF
    # SCREEN_PRINT=on: Moonraker's prints start through the touchscreen app,
    # so the screen shows them (share/zforge_screen.py)
    screen="# SCREEN_PRINT=off in zforge.conf: prints start through Klipper directly"
    if [ "$SCREEN_PRINT" = on ] && zf_root_ready &&
        cp "$ZF_SHARE/zforge_screen.py" "$ZF_CROOT/opt/moonraker/moonraker/components/zforge_screen.py"; then
        screen="[zforge_screen]"
    fi
    for f in moonraker moonraker.enforced; do
        sed -e "s|@HTTP_PORT@|$MOONRAKER_HTTP_PORT|g" \
            -e "s|@SCREEN_PRINT@|$screen|" \
            -e "s|@HTTPS_PORT@|$MOONRAKER_HTTPS_PORT|g" \
            -e "s|@USER_CONF@|$ZF_HOME/etc/moonraker.user.conf|g" \
            "$ZF_SHARE/$f.conf.in" >"$MR_DATA/config/$f.conf.new" &&
            mv "$MR_DATA/config/$f.conf.new" "$MR_DATA/config/$f.conf"
    done
}

# mr_sql DB show|rotate : read or regenerate the API key (same SQL as
# Moonraker's scripts/fetch-apikey.sh). Moonraker must be restarted after rotate.
mr_sql() {
    zf_chroot /opt/moonraker-env/bin/python - "$1" "$2" <<'EOF'
import sqlite3, sys, uuid
db, action = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
q = "SELECT password FROM authorized_users WHERE username='_API_KEY_USER_'"
row = conn.execute(q).fetchone()
if row is None:
    sys.exit("no API key in the database yet (start Moonraker once)")
if action == "rotate":
    with conn:
        conn.execute("UPDATE authorized_users SET password = ? WHERE username='_API_KEY_USER_'",
                     (uuid.uuid4().hex,))
    row = conn.execute(q).fetchone()
print(row[0])
EOF
}
