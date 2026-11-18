# zforge: implementation plan

A minimal alternative to zmod for the Flashforge Adventurer 5M Pro (AD5M Pro).

## Goals

1. Root SSH access (key-based).
2. Current Moonraker, and later current Klipper, so stock OrcaSlicer can upload and print using the "Octo/Klipper" host type.
3. Stock firmware stays upgradeable, through SSH or Moonraker as well as the touchscreen.
4. A strict firewall the user controls, so the stock firmware can be cut off from the network.
5. The stock touchscreen and stock behavior keep working.

## Non-goals

Anything zmod offers beyond those goals: macro libraries, Fluidd/Mainsail theming, alternative screens, Telegram, cloud relays, plugin systems. If one of these is wanted later, it should be an opt-in add-on, not part of the core.

## Guiding principles

- **Touch the stock root filesystem as little as possible.** Exactly one hook file goes into the stock rootfs. Everything else lives in one directory on the data partition (`/data/zforge`). Uninstalling means deleting the hook and the directory.
- **Self-contained userland.** zforge ships its own armv7 rootfs (an Alpine minirootfs) and runs it through `chroot`. That rootfs carries Python, Moonraker, Klipper, dropbear and nftables. Stock binaries and libraries are never patched.
- **Stock firmware stays in charge of the hardware.** By default the stock screen (`firmwareExe`) and the stock Klipper keep running. zforge adds to the system and swaps components in only where a feature needs it.
- **Every risky change can be undone without SSH.** Each risky step has a matching USB recovery path that works through the stock `flashforge_init.sh` mechanism.
- **Plain shell where possible.** The CLI, the hook and the installer are POSIX `sh`, so there is no daemon of our own to maintain.

## How the stock printer behaves (background)

These points come from the zmod docs and scripts. Phase 0 confirms each of them on the real device.

- At boot, stock firmware runs `flashforge_init.sh` as root from the root of a FAT32 USB stick. It also installs `Adventurer5MPro-*.tgz` update packages found there. This is how zmod, the root installer and the official updates all get onto the printer.
- Stock Klipper (a Flashforge fork of roughly v0.11) lives at `/opt/klipper`. Its config is in `/opt/config`.
- Stock cloud and update hosts include `update.sz3dp.com`, `update.cn.sz3dp.com`, `cloud.sz3dp.com`, `hz.sz3dp.com`, `api.cloud.flashforge.com`, `api.fdmcloud.flashforge.com`, `printer2.polar3d.com`, `polar3d.com` and `qvs.qiniuapi.com`. zmod blocks them through `/etc/hosts`, which also disables stock update checks.
- Stock LAN services: ports 8898/8899 carry the Flashforge LAN protocol, which FlashPrint and Orca's native "Flashforge" connection use.
- The board has 128 MB of RAM, and the stock screen takes about 13–20 MB of it. Memory is the main constraint.
- Moving to mainline Klipper requires reflashing the MCU to match. zmod does this with `UPDATE_MCU`, and it has to be reversed before stock firmware updates.

## Architecture

```
stock rootfs (untouched except one file)
 └─ /etc/init.d/S99zforge  ──►  /data/zforge/bin/zforge boot   (a no-op if zforge is missing or disabled)

/data/zforge/
 ├─ rootfs/              Alpine armv7 chroot: python3, moonraker, klipper, dropbear, nftables
 ├─ etc/zforge.conf      the only file a user normally edits
 ├─ etc/firewall.d/      rule profiles + user rules
 ├─ etc/ssh/             authorized_keys, host keys (persistent)
 ├─ bin/zforge           CLI (sh)
 ├─ var/                 logs, moonraker db, gcodes symlink → stock gcode dir
 └─ backup/              stock files replaced at any point (for rollback)
```

### Process model (default "stock-klipper" mode)

| Process | Source | Notes |
|---|---|---|
| firmwareExe (screen) | stock | unchanged |
| Klipper | stock `/opt/klipper` | unchanged; zforge only adds a `[include zforge.cfg]` if needed for Moonraker |
| Moonraker | chroot | talks to stock klippy's API socket; binds :7125 |
| dropbear | chroot | :22, root login by key only (password optional) |
| nftables ruleset | chroot binary, host kernel | applied at boot before network services start |

### Optional "mainline-klipper" mode (Phase 4)

The stock klippy is stopped, and mainline Klipper runs from the chroot on the same socket and config paths, so the stock screen keeps working. Flashforge-specific extras are ported or vendored for it: the load-cell/"tenz" probe, the camera and LED hooks, and whatever else the screen relies on. The MCU is flashed to match. `zforge klipper stock` reverts both the host and the MCU.

## The `zforge` CLI

The CLI is the whole user-facing surface. It works over SSH, and the same subcommands are exposed to Moonraker as `[shell_command]`/macros, so they can also be run from Orca's device tab or any Moonraker client.

```
zforge status                     versions, mode, firewall profile, memory
zforge enable|disable             toggle everything at next boot (hook stays, does nothing)
zforge fw check                   query Flashforge's update endpoint (temporarily allowed through firewall)
zforge fw install <file.tgz|url>  run a stock firmware update, then re-arm zforge
zforge fw backup                  dump stock partitions / /opt to a tarball you scp off
zforge firewall apply [--confirm 120]   apply rules; auto-revert unless confirmed
zforge firewall profile <open|lan|strict>
zforge firewall allow|deny <host|cidr> [port]
zforge klipper stock|mainline     switch host klipper (+MCU) — Phase 4
zforge update                     update zforge itself from a release tgz
zforge uninstall                  remove hook + /data/zforge, restore backups
```

## Firmware updates (goal 3)

The hard part is making zforge survive a stock update. An update rewrites the stock rootfs, so it can delete the hook. Plan:

1. **`zforge fw install`** is the supported path. It:
   - verifies the package: model prefix `Adventurer5MPro-`, a sane tar layout, an optional SHA256 the user supplies;
   - checks preconditions: MCU on stock firmware (if not, it refuses or offers `zforge klipper stock`), enough free space, no print running;
   - unpacks the package into a staging dir and runs the vendor's own installer script. The script runs with `reboot` shimmed through `PATH`, so control comes back to zforge before the reboot;
   - reinstalls the one-line hook into the new rootfs, records the new stock version, and reboots for real.
   - The exact mechanics depend on what Phase 0 finds inside a real update `.tgz`.
2. **Touchscreen OTA keeps working.** `zforge fw allow-ota` opens just the update hosts for a while. After an OTA install the hook may be gone. Because everything else is on `/data`, re-arming takes either a tiny USB `flashforge_init.sh` (ships in every release) or, if the hook survived, nothing at all.
3. **USB updates keep working** exactly as stock. The same re-arm stick applies afterwards.

The firewall stays strict by default. You download the `.tgz` on a PC and `scp` it over, or let `zforge fw install <url>` fetch it through a temporary allow rule.

## Firewall (goal 4)

**Kernel capability decides the design, so it is the first thing Phase 0 checks** (`/proc/config.gz`, `/lib/modules`, `nft list ruleset`, `iptables -L`):

- **Primary (netfilter present):** an nftables ruleset loaded at boot, before the stock network services come up.
  - *Inbound:* default deny. Allow 22, 7125 and 80 (optional web UI) from the configured LAN CIDR(s). Stock ports 8898/8899 (Flashforge LAN, FlashPrint, Orca native) and 8080 (camera) are toggles.
  - *Outbound:* default deny. Allow LAN, DNS to the configured resolver, NTP, plus named allow-lists. Stock processes all run as root, so per-process rules are not possible. The policy is per destination instead.
  - Hosts in `allow` are resolved to IP sets at apply time and refreshed periodically.
  - Profiles: `open` (stock behavior), `lan` (no internet at all), `strict` (LAN plus explicit allow-list). The default is `lan`.
- **Fallback (no netfilter in the stock kernel):** `/etc/hosts` sinkholing (as zmod does), plus `ip route add blackhole` for the vendor IP ranges, plus a default route limited to the LAN when the profile is `lan`. This is weaker, because it cannot restrict inbound ports. We document that and do not pretend otherwise. A later option is building the missing netfilter modules for the stock kernel version, if the kernel source and config are available.
- **Lockout protection:** `zforge firewall apply` rolls back after N seconds unless confirmed. Holding a USB stick with `zforge-firewall-off` at boot also skips the firewall.

Config example (`/data/zforge/etc/zforge.conf`):

```sh
FIREWALL_PROFILE=strict
LAN_CIDRS="192.168.1.0/24"
ALLOW_OUT="pool.ntp.org"
STOCK_LAN_API=off        # 8898/8899
CAMERA=on
SSH_PASSWORD_AUTH=off
```

## OrcaSlicer (goal 2)

Stock Orca: Printer → Connection → host type "Octo/Klipper", host `PRINTER_IP:7125`. Upload and print go through Moonraker's `/server/files/upload` with `print=true`. Moonraker's gcode root is symlinked to the stock gcode directory, so files show up on the touchscreen too. Phase 1 checks that the stock screen sees them and that a print started from Moonraker shows progress on the screen.

## Phases

### Phase 0: Discovery and safety (on the real printer, using the zmod root you already have)
- Back up everything: partition table, `/opt`, `/etc`, the stock update `.tgz` for the current version, and a `dmesg`/`ps`/`netstat` snapshot.
- Answer these questions and record the answers in `docs/device-notes.md`:
  - Is netfilter or nftables in the kernel?
  - Which init system and init scripts start firmwareExe and klippy, and in what order relative to the network coming up?
  - What does a stock update `.tgz` contain, and which script runs it? Is it signed or encrypted?
  - Where is the klippy API socket, and how does firmwareExe talk to Klipper?
  - Free space on `/data`, and RAM headroom with the stock screen running.
- Obtain or confirm the UART recovery path, and confirm the factory reset procedure.
- **Exit criteria:** every assumption in this document is either confirmed or rewritten.

### Phase 1: Skeleton, SSH, Moonraker (stock Klipper)
- Build script: Alpine armv7 minirootfs plus packages, giving a reproducible rootfs tarball (CI on GitHub Actions with qemu-user).
- Packaging: `Adventurer5MPro-zforge-<ver>.tgz` / `flashforge_init.sh` USB installer, which installs onto clean stock firmware *or* migrates away from zmod. Migration means running zmod's `REMOVE_ZMOD FULL=1` or USB removal first, then a factory reset, as zmod itself requires.
- The hook, `zforge boot`, dropbear with persistent host keys, and Moonraker running against stock klippy.
- **Exit criteria:** you can SSH in as root with a key, Orca uploads and prints, the stock screen works normally, and the printer survives reboots.

### Phase 2: Firewall
- Profiles, CLI, the confirm/rollback timer, the USB escape hatch, and the fallback mode if needed.
- **Exit criteria:** with `strict`, a capture on the LAN gateway shows no traffic to vendor hosts over 24 h, and Orca, SSH and NTP still work.

### Phase 3: Firmware update path
- `zforge fw check|install|backup`, Moonraker macros for them, and the re-arm USB stick.
- **Exit criteria:** an update from version N−1 to N works via SSH and via the touchscreen OTA plus re-arm, with zforge active afterwards.

### Phase 4: Mainline Klipper (opt-in)
- Mainline Klipper in the chroot, the ported Flashforge extras, MCU build and flash, and a tested path back to stock.
- **Exit criteria:** with mainline Klipper running, the stock screen can print, level and run the load-cell probe, and switching back to stock fully restores the stock MCU firmware.

### Phase 5: Polish
- `zforge update`, an optional web UI (Fluidd, which is static files served by Moonraker), docs and a release workflow.

## Risks and open questions

| Risk | Mitigation |
|---|---|
| Stock kernel has no netfilter | Fallback mode (documented as weaker); investigate building modules |
| 128 MB RAM is too tight for Moonraker + stock screen + Klipper | Measure in Phase 0; lean Moonraker config (no extra components); optional swap file on `/data`; screen-off mode as last resort |
| Update packages are signed/encrypted, or the installer can't be shimmed | Fall back to "update via screen/USB, then re-arm" (still meets the goal) |
| Stock firmware updates move the hook location or init system | Hook installer checks several known locations; re-arm USB stick is always available |
| Mainline Klipper breaks the stock screen | Phase 4 is opt-in and fully reversible; core goals don't depend on it |
| Bricking | Phase 0 backups and UART recovery verified *before* any rootfs write |

## Decisions to confirm

1. **Start from clean stock firmware rather than layering on zmod.** This assumes zforge replaces zmod and does not extend it, and the plan uses zmod and xblax's klipper_mod only as reference material.
2. **Moonraker first, mainline Klipper second.** Stock Klipper 0.11 with new Moonraker already covers Orca uploads. Mainline Klipper is where most of the complexity and risk sits.
3. **Default firewall profile is `lan`**, meaning no internet unless explicitly allowed.
