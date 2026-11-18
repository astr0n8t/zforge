# AD5M Pro device notes (Phase 0 findings)

Fill this in from the output of `tools/probe/run-probe.sh`. Each question names the report file that answers it. Phase 1 starts once every **must-know** item has an answer.

Printer: AD5M Pro · stock firmware version: `?` · zmod version (before removal): `?` · probe date: `?`

## Must-know

| # | Question | Where to look | Answer |
|---|---|---|---|
| 1 | Does the kernel have netfilter? Which parts (nf_tables, iptables, conntrack, ipset)? | `SUMMARY.txt`, `kernel/config-netfilter`, `kernel/netfilter-proc` | |
| 2 | Init system, and the boot order of network, klippy and firmwareExe | `files/etc/inittab`, `files/etc/init.d/`, `init/etc-tree` | |
| 3 | Where does zmod hook into boot (a model for our single hook)? | `mods/hooks`, `files/etc/init.d/` | |
| 4 | Which script handles USB `flashforge_init.sh` and `*.tgz` updates? | `update/refs`, `update/script-copies`, copies in `files/` | |
| 5 | Klipper: path, version, launch cmdline, API socket path | `klipper/*`, `SUMMARY.txt` (klipper cmdline, unix sockets) | |
| 6 | How does firmwareExe talk to Klipper (socket, port, files)? | `proc/detail` (firmwareExe fds), `strings/*firmwareExe*` | |
| 7 | Partition layout. Which partitions are rootfs, `/opt` and `/data`, and are they rw? | `storage/*`, `SUMMARY.txt` | |
| 8 | Free space on `/data`, and available RAM with the stock screen running | `SUMMARY.txt`, `sys/meminfo`, `proc/detail` (rss) | |
| 9 | Stock listening ports and which process owns each | `net/listening`, `SUMMARY.txt` | |
| 10 | Stock update and cloud hosts actually referenced | `strings/*`, `net/hosts-blocked` | |

## Nice-to-know

| # | Question | Where to look | Answer |
|---|---|---|---|
| 11 | Are update packages signed or encrypted (look for md5/sha/rsa/aes near update code)? | `strings/*` | |
| 12 | Is `ip route blackhole` supported (firewall fallback)? | `kernel/blackhole-route` | |
| 13 | Stock Python version (could Moonraker reuse it, or does it need the chroot)? | `klipper/python` | |
| 14 | Gcode directory the stock screen lists | `files/opt/config/`, `strings/*firmwareExe*` | |
| 15 | Is there a stock SSH daemon, and what does zmod use? | `sys/tools`, `init/etc-dropbear` | |

## Separate checks (not covered by the probe)

- [ ] Partition backup taken (`tools/probe/run-backup.sh`), and `manifest.txt` shows every partition `saved`.
- [ ] A copy of the stock update `.tgz` for the current firmware version is kept with the backup.
- [ ] The UART recovery steps are understood (3.3 V adapter only), and the factory-reset procedure has been read.
