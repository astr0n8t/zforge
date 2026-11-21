# Updating the stock firmware

zforge leaves the stock firmware in charge, and updating it works in three ways. In all of them, zforge's two files on the stock system and everything in `/data/.zforge` survive the update (see [stock/update-package.md](stock/update-package.md)). The boot hook reinstalls the PATH snippet if it's ever missing.

## 1. Over SSH: `zforge fw install` (recommended)

Download the update from Flashforge (a regular `Adventurer5MPro-<ver>-….tgz`, **not** a `…-Factory.tgz`), then:

```sh
scp Adventurer5MPro-5.2.0-….tgz root@PRINTER:/data/
ssh root@PRINTER zforge fw install /data/Adventurer5MPro-5.2.0-….tgz
# or straight from a URL (the firewall opens just that host, only for the download):
ssh root@PRINTER zforge fw install https://example.com/Adventurer5MPro-5.2.0-….tgz
```

**Before installing anything, it checks:**
- **The model:** the package must be for the Adventurer 5M Pro (`MACHINE` and `PID` in its installer).
- **Integrity:** every component must pass its own `md5sum.list`, checked with the printer's own `md5sum`.
- **No downgrade:** no component may be older than the installed one.
- **No Factory package:** those skip the model check and overwrite your Wi-Fi and printer configs.
- **No print running:** it asks Moonraker. If Moonraker can't say and Klipper is running, it refuses.
- **Disk space** on `/data` and `/`.

`--force` overrides the downgrade, Factory and "can't tell if printing" checks. It never overrides the model or integrity checks.

**Then it:**
1. Saves `/etc/wpa_supplicant.conf`, the hotspot config, `printer.cfg` and `printer.base.cfg` to `/data/.zforge/var/fw-backup/<date>/`.
2. Runs Flashforge's own installer exactly as the stock USB updater does.
3. Restores your Wi-Fi config if the update replaced it, and tells you if the printer configs changed.
4. Logs the update to `/data/.zforge/var/fw-history.log`.
5. Reboots. Use `--no-reboot` to reboot later yourself.

`zforge fw status` shows the installed component versions, the recent updates, and whether the OTA window is open.

The installer's own output goes to `/data/.zforge/var/log/fw-install.log`.

**Side effects:** every stock update resets the stock root password in `/etc/shadow`. zforge's SSH uses keys only, so that doesn't matter.

**MCU firmware:** stock packages carry the mainboard and toolhead MCU firmware (`control-<ver>`).
- **If it's identical to what's installed** (true for 5.2.0 over 3.2.x), `fw install` skips the redundant flash, and the normal reboot is safe.
- **If it's new,** `fw install` doesn't reboot. It asks you to **power-cycle**, because the toolhead MCU only takes a flash after a cold power-up; a warm reboot makes the stock flash step fail and loop.

## 2. From the touchscreen (OTA)

In the `lan` and `strict` firewall profiles, the stock firmware has no internet, so the touchscreen can't find updates. Open a temporary window:

```sh
zforge fw allow-ota          # 30 minutes; or e.g. "zforge fw allow-ota 10"
```

Then check for and install the update from the touchscreen. The window closes by itself, and at the next reboot. `zforge fw close-ota` closes it early.

While the window is open, **all** outbound traffic is allowed, the stock cloud included, because the update servers and download hosts aren't known in advance.

## 3. From USB (stock)

Works as it always has: put the package on a FAT32 stick, power on, wait, power off, **remove the stick**, and power on. The stock updater installs the package again on every boot while the stick stays in.

A Factory package installed this way overwrites your Wi-Fi settings, and there's no zforge step afterwards to restore them.

## Back up first

Before a major update, take a partition backup from your PC with [`tools/probe/run-backup.sh`](../tools/probe/README.md). Keep a known-good update package for your current version with it.
