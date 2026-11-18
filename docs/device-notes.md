# AD5M Pro device notes (Phase 0 findings)

Fill this in from the output of `tools/probe/run-probe.sh`. Each question names the report file that answers it. Phase 1 starts once every **must-know** item has an answer.

Printer: AD5M Pro · stock firmware version: `?` · zmod version (before removal): `?` · probe date: `?` · backup: 2026-11-17 (p1–p5 + disk head, all md5-verified; p6 `rootfs` and p7 `UDISK` not yet saved)

## Known from the partition backup (2026-11-17)

**Storage:** eMMC `mmcblk0`, 7.3 GiB, GPT with 7 entries (Allwinner layout).

| Part | Name | Size | Contents |
|---|---|---|---|
| p1 | boot-resource | 33.6 MiB | FAT16. **The kernel that actually boots:** `uImage` (Linux 5.4.61, built 2023-08-23), plus `sunxi.dtb`, boot logos, fonts and e-ink `wavefile/` |
| p2 / p3 | env / env-redund | 1 MiB each | U-Boot environment (identical). `bootcmd=run setargs_mmc boot_dsp0 boot_uImage`, `root=/dev/mmcblk0p6`, `bootdelay=3`, `console=ttyS3,115200` |
| p4 | boot | 34.4 MiB | Android boot image (kernel + 5.6 MB ramdisk). **Not used by `bootcmd`**. Probably an SDK leftover or recovery |
| p5 | dsp0 | 1 MiB | Xtensa DSP firmware (HiFi4 on the T113) |
| p6 | rootfs | 1.25 GiB | stock root filesystem (**not yet backed up**) |
| p7 | UDISK | 5.9 GiB | data partition: gcode files, zmod (not backed up; not needed) |

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
| 2 | Init system, and the boot order of network, klippy and firmwareExe | `files/etc/inittab`, `files/etc/init.d/`, `init/etc-tree` | |
| 3 | Where does zmod hook into boot (a model for our single hook)? | `mods/hooks`, `files/etc/init.d/` | |
| 4 | Which script handles USB `flashforge_init.sh` and `*.tgz` updates? | `update/refs`, `update/script-copies`, copies in `files/` | |
| 5 | Klipper: path, version, launch cmdline, API socket path | `klipper/*`, `SUMMARY.txt` (klipper cmdline, unix sockets) | |
| 6 | How does firmwareExe talk to Klipper (socket, port, files)? | `proc/detail` (firmwareExe fds), `strings/*firmwareExe*` | |
| 7 | Partition layout. Which partitions are rootfs, `/opt` and `/data`, and are they rw? | `storage/*`, `SUMMARY.txt` | GPT layout above. Still needed: the mount points of p6/p7 and whether they are rw (`storage/mounts`) |
| 8 | Free space on `/data`, and available RAM with the stock screen running | `SUMMARY.txt`, `sys/meminfo`, `proc/detail` (rss) | |
| 9 | Stock listening ports and which process owns each | `net/listening`, `SUMMARY.txt` | |
| 10 | Stock update and cloud hosts actually referenced | `strings/*`, `net/hosts-blocked` | |

## Nice-to-know

| # | Question | Where to look | Answer |
|---|---|---|---|
| 11 | Are update packages signed or encrypted (look for md5/sha/rsa/aes near update code)? | `strings/*` | |
| 12 | Is `ip route blackhole` supported (firewall fallback)? | `kernel/blackhole-route` | Yes in the kernel (FIB rules/types). The stock BusyBox `ip` may not expose port selectors, so zforge ships iproute2 |
| 13 | Stock Python version (could Moonraker reuse it, or does it need the chroot)? | `klipper/python` | |
| 14 | Gcode directory the stock screen lists | `files/opt/config/`, `strings/*firmwareExe*` | |
| 15 | Is there a stock SSH daemon, and what does zmod use? | `sys/tools`, `init/etc-dropbear` | |

## Separate checks (not covered by the probe)

- [~] Partition backup taken: p1–p5 and the disk head are saved and verified. **p6 `rootfs` is still missing.** The fixed `run-backup.sh` always includes it.
- [ ] A copy of the stock update `.tgz` for the current firmware version is kept with the backup.
- [ ] The UART recovery steps are understood (3.3 V adapter only), and the factory-reset procedure has been read.
