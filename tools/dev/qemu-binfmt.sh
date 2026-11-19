#!/bin/sh
# Register qemu-arm-static for armv7 ELF binaries (with the F flag, so it also
# works inside chroots). Needed on x86 for build/build-rootfs.sh and the e2e
# tests. Idempotent.
set -eu
[ -e /proc/sys/fs/binfmt_misc/qemu-arm ] && { echo "qemu-arm already registered"; exit 0; }
command -v qemu-arm-static >/dev/null || apt-get install -y qemu-user-static >/dev/null
grep -q binfmt_misc /proc/mounts || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
printf '%s' ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-arm-static:F' \
    >/proc/sys/fs/binfmt_misc/register
echo "qemu-arm registered"
