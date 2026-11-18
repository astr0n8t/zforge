# AD5M Pro device notes (Phase 0 findings)

Fill this in from the output of `tools/probe/run-probe.sh` (items 1–7, 10, 13–15 were answered offline from the partition backup). Each question names the report file that answers it. Phase 1 starts once every **must-know** item has an answer.

Printer: AD5M Pro · stock firmware **3.2.3** (`/opt/PROGRAM/software/3.2.3`, library 2.3.0, kernel pkg 2.1.6, MCU control 2.2.3) · zmod **1.7.1** · backups: 2026-11-17 (p1–p5 + disk head md5-verified; p6 `rootfs` saved, but live-fs `MISMATCH`, so good for analysis and not a pristine restore image; p7 `UDISK` not saved)

## Known from the partition backup (2026-11-17)

**Storage:** eMMC `mmcblk0`, 7.3 GiB, GPT with 7 entries (Allwinner layout).

| Part | Name | Size | Contents |
|---|---|---|---|
| p1 | boot-resource | 33.6 MiB | FAT16. **The kernel that actually boots:** `uImage` (Linux 5.4.61, built 2023-08-23), plus `sunxi.dtb`, boot logos, fonts and e-ink `wavefile/` |
| p2 / p3 | env / env-redund | 1 MiB each | U-Boot environment (identical). `bootcmd=run setargs_mmc boot_dsp0 boot_uImage`, `root=/dev/mmcblk0p6`, `bootdelay=3`, `console=ttyS3,115200` |
| p4 | boot | 34.4 MiB | Android boot image (kernel + 5.6 MB ramdisk). **Not used by `bootcmd`**. Probably an SDK leftover or recovery |
| p5 | dsp0 | 1 MiB | Xtensa DSP firmware (HiFi4 on the T113) |
| p6 | rootfs | 1.25 GiB | ext4 root, mounted rw (`inittab` remounts `/` rw). Holds `/etc`, `/opt` (stock app, Klipper, Python 3.7, config) |
| p7 | UDISK | 5.9 GiB | ext4, mounted at **`/data`** by `auto_run.sh`: gcode files (stock screen lists `/data`), logs, camera, zmod chroot `/data/.mod/.zmod` |

**SoC:** Allwinner `sun8iw20` (T113), ARMv7. Kernel vermagic `5.4.61 SMP preempt mod_unload ARMv7 p2v8`, built with Linaro GCC 5.3. Modules have no signing or modversions. The full config is in [`stock/kernel-5.4.61-ad5mpro.config`](stock/kernel-5.4.61-ad5mpro.config).

**Boot path:** U-Boot fatloads `uImage` and `sunxi.dtb` from p1, then mounts p6 as root with `init=/init`. Two consequences:
- An alternative kernel would be a file swap on a FAT partition, which is easy to revert.
- U-Boot waits 3 seconds on the UART, which is the recovery path.

**Kernel features that matter:**

| Feature | State | Consequence |
|---|---|---|
| `CONFIG_NETFILTER` | **not set** | no iptables/nftables, and no way to add them as modules |
| `CONFIG_IP_MULTIPLE_TABLES` / `FIB_RULES` / `IP_ADVANCED_ROUTER` | y | **firewall via `ip rule`** (ipproto/sport/dport), validated in `tests/firewall/` |
| `CONFIG_IPV6` | y, but `IPV6_MULTIPLE_TABLES` not set | disable IPv6 via sysctl, since it can't be policed |
| `CONFIG_INOTIFY_USER` | **not set** | Moonraker needs `file_system_observer: none` |
| `CONFIG_BLK_DEV_LOOP`, `OVERLAY_FS`, `SQUASHFS` | not set | the chroot must be a plain directory |
| `CONFIG_CGROUPS`, `NAMESPACES`, `SECCOMP`, `BPF_SYSCALL` | not set | no containers or sandboxing; plain chroot only |
| `CONFIG_NET_SCHED` | not set | no tc-based filtering either |
| `CONFIG_SWAP` | y | a swap file on `/data` is possible if RAM is tight |
| `CONFIG_EPOLL`, `EVENTFD`, `TIMERFD`, `SIGNALFD`, `FUTEX`, `AIO`, `DEVTMPFS`, `TMPFS` | y | Python, asyncio and Moonraker are fine |
| `CONFIG_USB_STORAGE`, `VFAT_FS` | y | USB stick recovery path works |
| `CONFIG_USB_VIDEO_CLASS` | y | UVC camera |


## Must-know

| # | Question | Where to look | Answer |
|---|---|---|---|
| 1 | Does the kernel have netfilter? Which parts (nf_tables, iptables, conntrack, ipset)? | `SUMMARY.txt`, `kernel/config-netfilter`, `kernel/netfilter-proc` | **No netfilter at all** (from the kernel's embedded config, see above). Policy routing is available instead |
| 2 | Init system, and the boot order of network, klippy and firmwareExe | `files/etc/inittab`, `files/etc/init.d/`, `init/etc-tree` | **BusyBox init (Buildroot).** `inittab` runs `/etc/preinit`, remounts `/` rw, `swapon -a`, then `rcS`. `rcS` runs `/etc/init.d/S??*` in order: S01 syslogd, S02 klogd, S10 udev, S20 urandom, S30 dbus, **S40 network** (`ifup -a`), S50 postgresql, S50 telnet (fails, no telnetd), S80 dnsmasq. It then starts `adb_conf.sh` and **`/opt/auto_run.sh &`** in the background. auto_run mounts `/data` (p7), loads the `8821cu` Wi-Fi module, handles USB updates, runs `usb_map.sh`, checks the MCU OTA flag, then starts `/opt/PROGRAM/ffstartup-arm`. That launches `software/3.2.3/firmwareExe`, **which starts Klipper** via `/opt/klipper/start.sh` |
| 3 | Where does zmod hook into boot (a model for our single hook)? | `mods/hooks`, `files/etc/init.d/` | Symlinks in `/etc/init.d` (`S00fix`, `S60dropbear`, `S98zssh`, `S99camera`, `S99moon`, `K99moon`, `prepare.sh`) pointing to `/opt/config/mod/.shell/*`. Its chroot is `/data/.mod/.zmod`. It also **patches stock files**: `/opt/klipper/start.sh`, `klippy/extras/{virtual_sdcard,zmod,gcode_shell_command,ens160}.py`, `/bin/dropbear*`, python site-packages. So a factory reset is needed for a clean base |
| 4 | Which script handles USB `flashforge_init.sh` and `*.tgz` updates? | `update/refs`, `update/script-copies`, copies in `files/` | **`/opt/auto_run.sh`**, at boot. It takes the newest `/mnt/Adventurer5MPro-*.tgz`, copies it to `/data`, `tar -xvf` into `/data/update/`, then runs `/data/update/flashforge_init.sh Adventurer5MPro 0024`. On exit 0 it sleeps forever (the script reboots). Failing that, a bare `/mnt/flashforge_init.sh` is run the same way. **No signature check in this path**, just a plain tar. An SSH update can reproduce it exactly. MCU OTA is separate: an `Update` flag in `/opt/PROGRAM/control/<ver>/` makes `run.sh` flash the mainboard and head MCUs, then `reboot -f` |
| 5 | Klipper: path, version, launch cmdline, API socket path | `klipper/*`, `SUMMARY.txt` (klipper cmdline, unix sockets) | `/opt/klipper` (Flashforge fork, ~0.11). Started by firmwareExe through `start.sh`: `/opt/Python-3.7.11/bin/python3.7 /opt/klipper/klippy/klippy.py /opt/config/printer.cfg -l /data/logFiles/printer.log -a /tmp/uds` |
| 6 | How does firmwareExe talk to Klipper (socket, port, files)? | `proc/detail` (firmwareExe fds), `strings/*firmwareExe*` | Through the Klipper API socket **`/tmp/uds`**, the same one Moonraker uses, so both can share it. It also reads `/opt/config/Adventurer5M.json` and checks `md5sum.list` |
| 7 | Partition layout. Which partitions are rootfs, `/opt` and `/data`, and are they rw? | `storage/*`, `SUMMARY.txt` | p6 = `/` (incl. `/opt`), ext4 rw. p7 = `/data`, ext4 rw. `/tmp`, `/run`, `/dev/shm` are tmpfs |
| 8 | Free space on `/data`, and available RAM with the stock screen running | `SUMMARY.txt`, `sys/meminfo`, `proc/detail` (rss) | |
| 9 | Stock listening ports and which process owns each | `net/listening`, `SUMMARY.txt` | |
| 10 | Stock update and cloud hosts actually referenced | `strings/*`, `net/hosts-blocked` | From firmwareExe: `update.sz3dp.com:10443`, `update.cn.sz3dp.com:10443`, `cloud.sz3dp.com`, `hz.sz3dp.com:11002`, `api.fdmcloud.flashforge.com` (+`/healthx/liveness`), `polar3d.com`, `printer2.polar3d.com`, `qvs.qiniuapi.com`, **`qvs-live.qnvideo.flashforge.com`, `qvs-publish.qnvideo.flashforge.com`** (both missing from zmod's hosts block), plus an Alibaba Cloud OSS client. This argues for default-deny outbound |

## Nice-to-know

| # | Question | Where to look | Answer |
|---|---|---|---|
| 11 | Are update packages signed or encrypted (look for md5/sha/rsa/aes near update code)? | `strings/*` | |
| 12 | Is `ip route blackhole` supported (firewall fallback)? | `kernel/blackhole-route` | Yes in the kernel (FIB rules/types). The stock BusyBox `ip` may not expose port selectors, so zforge ships iproute2 |
| 13 | Stock Python version (could Moonraker reuse it, or does it need the chroot)? | `klipper/python` | 3.7.11 (`/opt/Python-3.7.11`). Current Moonraker needs **≥ 3.10**, so the chroot is required |
| 14 | Gcode directory the stock screen lists | `files/opt/config/`, `strings/*firmwareExe*` | `/data` (top level), with `/data/3mf/…` for 3mf jobs. zmod uses `/data` as Moonraker's gcode root |
| 15 | Is there a stock SSH daemon, and what does zmod use? | `sys/tools`, `init/etc-dropbear` | Stock has **no SSH server and no telnetd** (the `S50telnet` script exists, but there's no binary). zmod installs `/bin/dropbear`. Stock also runs **`adbd`** on the USB gadget port, a possible physical recovery path |

## Separate checks (not covered by the probe)

- [x] Partition backup: p1–p5 and the disk head are verified. p6 `rootfs` is saved but changed during the read. That's fine for reference, but **the official firmware `.tgz` plus factory reset is the real restore path**.
- [ ] A copy of the stock update `.tgz` for the current firmware version is kept with the backup.
- [ ] The UART recovery steps are understood (3.3 V adapter only), and the factory-reset procedure has been read.
