#!/bin/sh
# Runs INSIDE the armv7 Alpine chroot (natively on ARM, or via qemu-user).
# Installs Moonraker + deps into the rootfs and builds the static host-side
# binaries (dropbear, sftp-server) into /out.
#
# Inputs (env): MOONRAKER_*, DROPBEAR_*, OPENSSH_* from versions.env.
set -eu
export LC_ALL=C

log() { echo "[inside] $*"; }

# Paths the printer-side scripts rely on (see printer/lib/zforge/common.sh).
ZF_PREFIX=/data/.zforge

log "apk: runtime packages"
apk add --no-cache \
    python3 py3-pip \
    py3-pillow py3-tornado py3-jinja2 py3-markupsafe \
    libsodium openssl ca-certificates tzdata \
    iproute2 sqlite

log "apk: build packages (removed at the end)"
apk add --no-cache --virtual .zforge-build \
    build-base linux-headers python3-dev git \
    autoconf automake

# ---------------------------------------------------------------- Moonraker
log "moonraker $MOONRAKER_REF"
rm -rf /opt/moonraker
git clone -q --depth 1 -b "$MOONRAKER_REF" "$MOONRAKER_REPO" /opt/moonraker
rm -rf /opt/moonraker/.git /opt/moonraker/docs /opt/moonraker/tests

python3 -m venv --system-site-packages /opt/moonraker-env
# SKIP_CYTHON: zeroconf/dbus-fast fall back to pure Python (fast build, less RAM)
SKIP_CYTHON=1 /opt/moonraker-env/bin/pip install --no-cache-dir --disable-pip-version-check \
    -r /opt/moonraker/scripts/moonraker-requirements.txt
/opt/moonraker-env/bin/python -c "import tornado, PIL, jinja2, libnacl, streaming_form_data, zeroconf; print('moonraker deps import OK')"
/opt/moonraker-env/bin/python -m compileall -q /opt/moonraker/moonraker >/dev/null || true

mkdir -p /out

# ---------------------------------------------------------------- dropbear (static, runs on the stock system)
log "dropbear $DROPBEAR_REF (static)"
rm -rf /src/dropbear && mkdir -p /src
git clone -q --depth 1 -b "$DROPBEAR_REF" "$DROPBEAR_REPO" /src/dropbear
cat >/src/dropbear/localoptions.h <<EOF
/* zforge: key-only root SSH on the stock system */
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_AGENTFWD 0
#define DROPBEAR_X11FWD 0
#define SFTPSERVER_PATH "$ZF_PREFIX/bin/sftp-server"
#define DEFAULT_PATH "/usr/bin:/bin:/usr/sbin:/sbin:$ZF_PREFIX/bin"
/* root sessions use this one: zforge, scp (legacy -O) and sftp-server live in $ZF_PREFIX/bin */
#define DEFAULT_ROOT_PATH "/usr/sbin:/usr/bin:/sbin:/bin:$ZF_PREFIX/bin"
#define DROPBEAR_PIDFILE "/var/run/zforge-dropbear.pid"
EOF
(
    cd /src/dropbear
    ./configure --enable-static --disable-zlib --disable-lastlog \
        --disable-utmp --disable-utmpx --disable-wtmp --disable-wtmpx \
        --disable-pututline --disable-pututxline >/dev/null
    make -s -j"$(nproc)" PROGRAMS="dropbear dropbearkey scp" MULTI=1 STATIC=1
    strip dropbearmulti
    cp dropbearmulti /out/dropbearmulti
)

# ---------------------------------------------------------------- sftp-server (static)
log "openssh $OPENSSH_REF sftp-server (static)"
rm -rf /src/openssh
git clone -q --depth 1 -b "$OPENSSH_REF" "$OPENSSH_REPO" /src/openssh
(
    cd /src/openssh
    autoreconf -i >/dev/null 2>&1
    LDFLAGS=-static ./configure --without-openssl --without-zlib \
        --without-pam --without-selinux >/dev/null
    make -s -j"$(nproc)" sftp-server
    strip sftp-server
    cp sftp-server /out/sftp-server
)
file_type() { head -c 4 "$1" | od -An -tx1 | tr -d ' '; }
for b in /out/dropbearmulti /out/sftp-server; do
    [ "$(file_type "$b")" = 7f454c46 ] || { echo "not an ELF: $b"; exit 1; }
done

# ---------------------------------------------------------------- slim down
log "cleanup"
apk del --no-cache .zforge-build >/dev/null
rm -rf /src /root/.cache /var/cache/apk/* /usr/share/man /usr/share/doc /tmp/*
find /opt/moonraker-env /usr/lib/python3* -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true

log "done"
