# Phase 0 tools: probe and backup

These scripts run from your PC over SSH. They only **read** from the printer. Nothing is copied to the printer, installed on it or changed on it. The printer-side scripts reach it through `ssh … 'sh -s' < script`, and the results come back on stdout.

Requirements:
- **PC:** `ssh`, `tar`, `gzip`, `md5sum` (or `md5` on macOS).
- **Printer:** root SSH. You already have this from zmod: user `root`, password `root` unless you changed it.

If the printer's dropbear rejects your client, pass extra options:
`SSH_OPTS="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"`.

## 1. Probe (about a minute)

```sh
tools/probe/run-probe.sh root@PRINTER_IP
```

This prints `SUMMARY.txt` and unpacks the full report into `probe-<date>/report/`. Printer-side progress and errors are saved to `probe-<date>/probe.log`. If the probe fails, that file says why.

| Path | Contents |
|---|---|
| `SUMMARY.txt` | the key answers at a glance (netfilter, init, sockets, ports, free space) |
| `kernel/` | kernel config (netfilter options), modules, current iptables/nft state |
| `init/`, `files/etc/` | init scripts, inittab, rc.local: shows where a boot hook can go |
| `proc/detail` | every process with its exe, RSS, chroot, sockets: shows how the screen talks to Klipper |
| `update/` | files that mention `flashforge_init.sh` / `.tgz` / update hosts, plus copies of the small scripts among them |
| `strings/` | URL, host, path and port strings pulled from the running stock binaries |
| `klipper/`, `files/opt/config/` | stock Klipper version, extras, and config |
| `mods/` | what zmod has installed and hooked |
| `net/` | interfaces, routes, listening ports, `/etc/hosts` blocks |

The report holds config files (printer.cfg, hosts, network settings). It leaves out SSH host keys, `/etc/shadow` and the contents of `wpa_supplicant.conf`. Review it anyway before sharing it publicly.

## 2. Backup (do this before any write to the printer)

```sh
tools/probe/run-backup.sh -n root@PRINTER_IP     # dry run: list what would be saved
tools/probe/run-backup.sh root@PRINTER_IP        # save it
```

What gets saved:
- **Each partition** as `NAME.img.gz`.
- **The first 16 MiB of each whole disk**, which holds the partition table and the bootloader area.
- **eMMC hardware boot partitions and raw MTD devices**, if the printer has them.

Partitions over 1 GiB are skipped and listed in `manifest.txt`. On the AD5M Pro that is only `UDISK`, the gcode/data partition. The stock `rootfs` partition is always saved, whatever its size. Use `-m MB` to change the limit or `-a` to include everything.

Checks:
- **Checksums:** each image is md5-checked against a second read on the printer.
- **`MISMATCH`:** that filesystem changed while it was being read, which can happen when it's mounted read-write. Re-run when the printer is idle.
- **`FAILED`:** the device couldn't be read. The error is printed above the line.

Keep the backup somewhere safe. Together with UART access, it is the recovery path for everything later phases do.

## 3. Record findings

Fill in [`docs/device-notes.md`](../../docs/device-notes.md) from the report, or just send me the report and I'll do it. Every later phase builds on those answers.
