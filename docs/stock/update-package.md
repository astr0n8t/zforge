# Stock firmware update package format (AD5M Pro)

This was worked out from `Adventurer5MPro-3.1.3-2.2.3-20250107-Factory.tgz`, downloaded from the zmod mirror (`ghzserg/FF` releases).

- **Package:** sha256 `f0f578c62728a823d954098d51afc4dac43eafeb3dbfb708125a6d5ace946f85`.
- **Integrity:** its components pass their own `md5sum.list` checks.
- **Authenticity:** `uImage` and `sunxi.dtb` are byte-identical to those on the user's printer (kernel package 2.1.6).

**Do not install this package on a printer running 3.2.3.** It would downgrade the software to 3.1.3. It is used here only as a reference for the format.

## Container

Despite the `.tgz` name, the outer file is an **uncompressed GNU tar**. Stock `auto_run.sh` unpacks it with `tar -xvf` into `/data/update/` and runs `/data/update/flashforge_init.sh Adventurer5MPro 0024`.

| File | Purpose |
|---|---|
| `flashforge_init.sh` | the installer (see below) |
| `software-<v>.tar.xz` | touchscreen app: `firmwareExe`, `auto_run.sh`, `rcS`, web client, Wi-Fi tools |
| `library-<v>.tar.xz` | `ffstartup-arm`, `ffstartup.cfg`, `env.cfg`, `nim.tar` (Qt/runtime) |
| `kernel-<v>.tar.xz` | `uImage`, `sunxi.dtb`, boot logos, `8821cu.ko` Wi-Fi driver, `rcS`, `udhcpd.conf` |
| `control-<v>.tar.xz` | MCU firmware (`Mainboard-*.bin`, `Eboard-*.hex`) and flashing tools |
| `printer.cfg`, `printer.base.cfg`, `tmc.py` | Klipper config and a patched extra |
| `shadow`, `inittab`, `wpa_supplicant.conf`, `rtl_hostapd_2G.conf` | system files (copied unconditionally) |
| `screwflag` | "factory" marker (present in *Factory* packages) |
| `boot.img`, `start.img`, `end.img`, `play`, `mencoder`, `Cube-PLA-Test.gx` | screen images, a jingle, a video encoder, a test print |

The component `*.tar.xz` files are **also plain tar** (not xz). Each contains an `md5sum.list`.

## What `flashforge_init.sh` does

1. **Checks** that `uname -m` is `armv7l`.
   - Unless `screwflag` is in the package, it also requires args `Adventurer5MPro` / `0024`.
   - **Factory packages skip the model check.**
2. **Overwrites** `/etc/rtl_hostapd_2G.conf`, **`/etc/wpa_supplicant.conf`** (wipes the saved Wi-Fi config), **`/etc/shadow`** (resets the root password) and `/etc/inittab`.
   - The inittab in this package is identical to the current one.
3. **Creates** an RSA key pair in `/opt` (`private.pem`, `key.pub`, `key.priv`) if one doesn't exist yet.
4. **Copies** `screwflag`, `boot.img` and `mencoder` to `/opt`, the test print to `/data` and `/root`, `printer.cfg` and `printer.base.cfg` to `/opt/config/`, and `tmc.py` into `/opt/klipper/klippy/extras/`.
5. **Installs each component** (control, kernel, software, library). For each one it:
   - untars into `/opt/PROGRAM/<comp>/temp`;
   - runs `md5sum -c md5sum.list`. On success it deletes all other versions and renames `temp` to `<version>`; on failure it discards `temp`;
   - runs the component's `run.sh`:
     - **kernel:** writes `uImage`, `sunxi.dtb` and the logos onto the FAT `boot-resource` partition (p1), plus `/lib/modules/8821cu.ko`, `/etc/init.d/rcS` and `/etc/udhcpd.conf`;
     - **software:** writes `/opt/auto_run.sh`, `/etc/init.d/rcS`, `/sbin/iwlist`, `/bin/zip` and `/bin/wifi_reconnect`;
     - **library:** writes `/bin/create-rsa.sh` and `/opt/PROGRAM/ffstartup.cfg`, and unpacks `nim.tar` into `/opt`;
     - **control:** its `run.sh` is *not* run here. MCU flashing happens on a later boot through the `Update` flag and `auto_run.sh`.
6. Shows `end.img`, plays a sound, and **exits 0 without rebooting**. `auto_run.sh` then sleeps until the printer is power-cycled.

## Consequences for zforge

- **The `/etc/init.d/S35zforge` hook survives updates.** Nothing in the update writes `/etc/init.d/S*`, and the replacement `rcS` still runs `S??*` in order. `/data/zforge` is never touched either.
- **Root SSH survives** because zforge's dropbear uses its own key file on `/data`, not `/etc/shadow`. The update still resets the stock root password.
- **`zforge fw install` must:**
  - snapshot `/etc/wpa_supplicant.conf` (and the hostapd conf) and restore them after the update, so Wi-Fi survives;
  - back up `printer.cfg` and `printer.base.cfg` to `/data/zforge/backup/` before the vendor's copies overwrite them;
  - check each component's `md5sum.list` before running anything, and refuse a package that fails;
  - refuse a **downgrade** unless forced, by comparing `software-<v>` with `/opt/PROGRAM/software/<current>`;
  - refuse *Factory* packages (`screwflag` present) unless forced. They bypass the model check, and copy `screwflag` into `/opt`. This printer already has `/opt/screwflag`, from an earlier Factory install;
  - run the installer with `Adventurer5MPro 0024`, then reboot. No reboot shim is needed.
- **Kernel updates rewrite `uImage` on p1.** That only matters if zforge ever ships a custom kernel, which is not planned.
