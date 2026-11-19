# Installing zforge

zforge installs from a USB stick through the stock firmware's own updater, the same mechanism official updates use. Later upgrades can also go over SSH.

**What it adds to the stock system:** two small files.
- `/etc/init.d/S35zforge` is the boot hook.
- `/etc/profile.d/zforge.sh` puts `zforge` on the PATH of login shells.

Everything else lives in `/data/.zforge`. Stock firmware updates leave all of it alone (see [stock/update-package.md](stock/update-package.md)), and the boot hook reinstalls the PATH snippet if it's ever missing.

## Before you start: migrating from zmod

The installer refuses to run while zmod is present. zmod patches stock files and runs its own SSH server and Moonraker.

1. **Copy these off the printer while zmod's SSH still works.**
   ```sh
   mkdir zmod-backup && cd zmod-backup
   scp root@PRINTER:/data/.mod/.zmod/root/printer_data/certs/moonraker.cert .
   scp root@PRINTER:/data/.mod/.zmod/root/printer_data/certs/moonraker.key .
   scp root@PRINTER:/opt/config/mod_data/user.moonraker.conf .
   ```
   - **The certificate and key** let Orca keep trusting the printer, with no new certificate to import.
   - **`user.moonraker.conf`** is for reference only. Take just the parts you want, such as the spoolman block, into zforge's `moonraker.user.conf`. Don't copy `[server]` or `[authorization]`: zforge sets those itself and ignores overrides.
2. **Remove zmod completely.**
   - Run `REMOVE_ZMOD FULL=1` in the Fluidd/Mainsail console;
   - or use zmod's USB removal [`flashforge_init.sh`](https://github.com/ghzserg/zmod/blob/main/Native_firmware/rem_zmod/flashforge_init.sh), and wait for three reboots.

   This also removes zmod's SSH server. You'll have no SSH until zforge is installed.
3. **Optional: install the latest stock firmware from USB** (e.g. `Adventurer5MPro-5.2.0-…tgz`) to refresh the stock programs. Use a regular package, **not** a `…-Factory.tgz` one.
   - Remove the stock `.tgz` from the stick afterwards. The updater installs the newest `Adventurer5MPro-*.tgz` it finds, so leaving it there would install it again instead of zforge.

## USB install

Use a FAT32 (MBR) USB stick. At its root, put:

| File | Needed? | Purpose |
|---|---|---|
| `Adventurer5MPro-zforge-<ver>.tgz` | **yes** | the package (keep it the only `Adventurer5MPro-*.tgz` on the stick) |
| `authorized_keys` | **yes** | your SSH public key(s), e.g. a copy of `~/.ssh/id_ed25519.pub`. Password login is compiled out, so without a key there is no SSH |
| `moonraker.cert`, `moonraker.key` | optional | keep your existing HTTPS certificate (from the zmod backup). Without them zforge generates a new self-signed one |
| `moonraker.user.conf` | optional | your extra Moonraker settings |

Then:
1. Power the printer off, insert the stick, and power it on.
2. The stock updater runs the zforge installer, which unpacks about 170 MB onto `/data` and reboots the printer. Allow a few minutes.
3. Remove the stick and read **`zforge-install.log`** on it. It should end with `zforge … installed`. If the installer refused or failed, the log says why, and the printer boots stock firmware as usual.

## First login

```sh
ssh root@PRINTER
zforge status          # sshd / ntp / moonraker running, ports 22 and 7130
zforge apikey show     # Moonraker API key, for Orca
zforge tls show        # certificate details and its SHA-256 fingerprint
```

- **Without imported certificates,** zforge makes one once the printer has an IP address and a correct clock (via NTP). So Moonraker's HTTPS can take a minute longer on the first boot.
- **The certificate names the printer's IP address.** Give the printer a DHCP reservation, or run `zforge tls regen` (and re-trust the certificate) after its IP changes.

## OrcaSlicer

1. In the printer's connection settings, set:
   - host type: **Octo/Klipper**;
   - hostname: **`https://PRINTER_IP:7130`**;
   - API key: the output of `zforge apikey show`.
2. Make Orca trust the certificate. This isn't needed if you imported the zmod certificate that Orca already trusts.
   - **Windows / macOS:** add `moonraker.cert` (from `zforge tls show`, or `scp root@PRINTER:/data/.zforge/var/moonraker/certs/moonraker.cert .`) to the system certificate store or Keychain as trusted.
   - **Linux:** point Orca's "HTTPS CA file" field at `moonraker.cert`.

Plain HTTP on port 7125 exists only on the printer itself; the firewall blocks it from the network. Requests without the API key get `401`.

## Firewall and camera

From 0.2.0 the firewall defaults to the **`lan` profile**:
- SSH, Moonraker HTTPS and the camera are reachable from private-network addresses only.
- The stock firmware gets no internet: no cloud, no touchscreen update checks.
- The Flashforge LAN API (FlashPrint, Orca's native Flashforge connection) is off.

Change any of this in `zforge.conf`, then run `zforge firewall apply` and `zforge firewall confirm`. The details and the lockout rescue are in [firewall.md](firewall.md).

The camera stream is at `http://PRINTER_IP:8080/?action=stream`. Keep the touchscreen's camera setting off.

## Stock firmware updates

See [firmware-updates.md](firmware-updates.md). In short: `zforge fw install <package.tgz|URL>` over SSH, or `zforge fw allow-ota` and then the touchscreen.

## Upgrading

- **Over SSH:** `tools/install/run-install.sh root@PRINTER dist/Adventurer5MPro-zforge-<ver>.tgz`. The printer reboots.
- **By USB:** same as a first install. Your configuration, SSH keys, certificate and Moonraker data in `/data/.zforge/etc` and `/data/.zforge/var` are kept.

## Rescue sticks

Each rescue stick holds just the one `flashforge_init.sh` from `dist/rescue-*/`:
- **`rescue-firewall-open`:** sets the firewall to `open` and reboots. Use it if a firewall setting locked you out.
- **`rescue-disable`:** zforge is skipped at boot, and stock firmware runs untouched. Re-run the installer stick to enable it again.
- **`rescue-uninstall`:** removes the hook and `/data/.zforge`.
