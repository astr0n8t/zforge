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
- **Self-contained userland.** zforge ships its own armv7 rootfs (an Alpine minirootfs) and runs it through `chroot`. That rootfs carries Python, Moonraker, Klipper, dropbear and iproute2. It is a plain directory on the data partition, because the kernel has no loop device, overlayfs or squashfs. Stock binaries and libraries are never patched.
- **Stock firmware stays in charge of the hardware.** By default the stock screen (`firmwareExe`) and the stock Klipper keep running. zforge adds to the system and swaps components in only where a feature needs it.
- **Every risky change can be undone without SSH.** Each risky step has a matching USB recovery path that works through the stock `flashforge_init.sh` mechanism.
- **Plain shell where possible.** The CLI, the hook and the installer are POSIX `sh`, so there is no daemon of our own to maintain.

## How the stock printer behaves

Confirmed from the partition backup of firmware 3.2.3 (details in [`docs/device-notes.md`](docs/device-notes.md)), unless marked otherwise:

- **Boot:** BusyBox init runs `rcS`, which runs `/etc/init.d/S??*` in order (S40 brings the network up), then starts `/opt/auto_run.sh` in the background.
  - auto_run mounts `/data` (p7) and handles USB updates.
  - It then starts `ffstartup-arm`, which runs `firmwareExe` (the touchscreen app).
  - **firmwareExe starts stock Klipper** (`/opt/klipper`, Python 3.7.11) with its API socket at **`/tmp/uds`**, which Moonraker can share.
- **Updates:**
  - USB: `auto_run.sh` unpacks the newest `/mnt/Adventurer5MPro-*.tgz` into `/data/update/` with plain `tar` and runs `flashforge_init.sh Adventurer5MPro 0024`. There is no signature check, and a bare `/mnt/flashforge_init.sh` is run the same way.
  - MCU OTA: an `Update` flag under `/opt/PROGRAM/control/<ver>/` triggers `run.sh`.
- **Cloud:** firmwareExe talks to several hosts, some of which zmod's `/etc/hosts` block misses (`qvs-live`/`qvs-publish.qnvideo.flashforge.com`), plus an Alibaba Cloud OSS client.
- **Kernel:** 5.4.61 with no netfilter, inotify, loop, overlayfs, cgroups or namespaces. Policy routing is available.
- **Gcode:** the stock screen lists `/data`.
- **Memory:** 128 MB of RAM; the stock screen takes about 13–20 MB. Memory is the main constraint (headroom not yet measured).
- **Stock LAN services:** 8898/8899 (Flashforge LAN protocol, FlashPrint and Orca's native connection). *Not yet confirmed on this unit.*
- **zmod's approach:** it hooks in through `/etc/init.d` symlinks to `/opt/config/mod/.shell/*`, runs a chroot at `/data/.mod/.zmod`, and patches stock Klipper files. That's why a factory reset comes before zforge.
- **Mainline Klipper (later):** requires reflashing the MCU to match.

## Architecture

```
stock rootfs (untouched except one file)
 └─ /etc/init.d/S35zforge  ──►  /data/zforge/bin/zforge boot   (a no-op if zforge is missing or disabled)
       S35 runs before S40network, so the firewall is in place before any interface comes up.
       It then starts sshd, and starts Moonraker in the background once /tmp/uds appears (Klipper starts late, via firmwareExe).

/data/zforge/
 ├─ rootfs/              Alpine armv7 chroot (plain dir): python3, moonraker, klipper, dropbear, iproute2
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
| Moonraker | chroot | talks to stock klippy's API socket; binds :7125; `file_system_observer: none` (kernel has no inotify) |
| dropbear | chroot | :22, root login by key only (password optional) |
| policy-routing firewall | `ip rule` from chroot iproute2 | applied at boot before network services start |

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
   - does exactly what `auto_run.sh` does: copies the package to `/data`, `tar -xf` into `/data/update/`, and runs `flashforge_init.sh Adventurer5MPro 0024`. The script runs with `reboot` shimmed through `PATH`, so control comes back to zforge before the reboot;
   - reinstalls the one-line hook if the update removed it, records the new stock version, and reboots for real.
   - *Still open:* what a stock `flashforge_init.sh` touches (whether it rewrites `/etc/init.d` or uses `reboot`, `reboot -f` or sysrq). Read it from a real 3.2.x update `.tgz` before implementing.
2. **Touchscreen OTA keeps working.** `zforge fw allow-ota` opens just the update hosts for a while. After an OTA install the hook may be gone. Because everything else is on `/data`, re-arming takes either a tiny USB `flashforge_init.sh` (ships in every release) or, if the hook survived, nothing at all.
3. **USB updates keep working** exactly as stock. The same re-arm stick applies afterwards.

The firewall stays strict by default. You download the `.tgz` on a PC and `scp` it over, or let `zforge fw install <url>` fetch it through a temporary allow rule.

## Firewall (goal 4)

**Finding (Phase 0, from the backed-up kernel's embedded config):** the stock kernel, Linux 5.4.61, has **no netfilter** (`# CONFIG_NETFILTER is not set`). So there is no iptables and no nftables. Netfilter can't be added as a module either, because its hooks are compiled into the core network stack. The kernel does have policy routing (`CONFIG_IP_MULTIPLE_TABLES`, `CONFIG_FIB_RULES`). Since kernel 4.17, `ip rule` can match on protocol and port (`ipproto`, `sport`, `dport`), and the firewall is built on that. IPv6 has no policy tables (`# CONFIG_IPV6_MULTIPLE_TABLES is not set`), so zforge turns IPv6 off with sysctl.

**Firewall = an ordered list of `ip rule`s.** It is applied at boot before the stock network services start. Each packet's route lookup walks the rules in order:

```
pref 10-99   iif <wlan/eth> [from <src>] ipproto tcp|udp dport <port> blackhole   # inbound port blocks
pref 10-99   ipproto tcp sport <port> prohibit                                     # silence a local service's replies
pref 100     lookup local                                                          # (moved from pref 0 so the rules above can win)
pref 200     to <LAN_CIDRS> lookup main                                            # LAN reachable
pref 210+    to <allow-listed IPs> lookup main                                     # resolved from ALLOW_OUT
pref 300     prohibit                                                              # all other destinations: denied (profile lan/strict)
```

- *Inbound:* stock ports 8898/8899 (Flashforge LAN API, FlashPrint, Orca native) and 8080 (camera) are toggles. The rule set can also restrict SSH and Moonraker to given source addresses.
- *Outbound:* default deny. Allowed: the LAN, DNS to the configured resolver, NTP, and named allow-lists. Stock processes all run as root, so the policy is per destination, not per process.
  - Allow-listed host names are resolved to /32 rules when the firewall is applied, and refreshed periodically.
  - `/etc/hosts` sinkholing of the vendor hosts stays as defence in depth.
  - DHCP renewals rewrite the `main` table, not the rules, so the firewall survives them.
- *Profiles:* `open` (stock behavior), `lan` (no internet at all), `strict` (LAN plus explicit allow-list). The default is `lan`.
- *Validated* in a network-namespace test (`tests/` in Phase 2):
  - an inbound port block and a reply block each shut a service off while SSH stays open;
  - an internet destination is denied while LAN, allow-listed and loopback traffic work.

  Re-check it on the printer's 5.4 kernel and its iproute2. zforge ships a full `ip` binary, because BusyBox's `ip` may lack the port selectors.
- *Limits compared with netfilter:* the rules are stateless, with no logging, rate limiting or ICMP filtering. Inbound blocks apply per port and per source, not per connection state. That's enough for "the stock firmware can't phone home, and only my hosts can reach it."
- *Optional later:* a custom 5.4 kernel with netfilter, booted from the FAT `boot-resource` partition (U-Boot loads `uImage` from there, so swapping and reverting is easy), and only if the policy-routing firewall proves insufficient. It risks driver mismatches and needs UART for recovery.
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
| ~~Stock kernel has no netfilter~~ **Confirmed** | Policy-routing firewall (validated in netns); custom kernel only if needed |
| Kernel lacks inotify, cgroups, namespaces, loop, overlayfs | Moonraker without inotify; plain-directory chroot; no containers |
| 128 MB RAM is too tight for Moonraker + stock screen + Klipper | Measure in Phase 0; lean Moonraker config (no extra components); optional swap file on `/data`; screen-off mode as last resort |
| Update packages are signed/encrypted, or the installer can't be shimmed | Fall back to "update via screen/USB, then re-arm" (still meets the goal) |
| Stock firmware updates move the hook location or init system | Hook installer checks several known locations; re-arm USB stick is always available |
| Mainline Klipper breaks the stock screen | Phase 4 is opt-in and fully reversible; core goals don't depend on it |
| Bricking | Phase 0 backups and UART recovery verified *before* any rootfs write |

## Decisions to confirm

1. **Start from clean stock firmware rather than layering on zmod.** This assumes zforge replaces zmod and does not extend it, and the plan uses zmod and xblax's klipper_mod only as reference material.
2. **Moonraker first, mainline Klipper second.** Stock Klipper 0.11 with new Moonraker already covers Orca uploads. Mainline Klipper is where most of the complexity and risk sits.
3. **Default firewall profile is `lan`**, meaning no internet unless explicitly allowed.
