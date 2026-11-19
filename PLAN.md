# zforge: implementation plan

A minimal alternative to zmod for the Flashforge Adventurer 5M Pro (AD5M Pro).

## Goals

1. Root SSH access (key-based).
2. Current Moonraker, **reachable over TLS only** with a self-signed certificate, and later current Klipper, so stock OrcaSlicer can upload and print using the "Octo/Klipper" host type (`https://PRINTER_IP:7130`).
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
- **Cloud:** firmwareExe talks to many hosts, and the list grows with each release. 5.2.0 adds the voxelshare.com and flash3dcloud.com endpoints, the liveplay/livepush streaming hosts and ipinfo.io, and **syncs its domain list at runtime** through a bootstrap URL. zmod's `/etc/hosts` block covers only some of them, so **outbound must be default-deny**, not a blocklist.
- **Kernel:** 5.4.61 with no netfilter, inotify, loop, overlayfs, cgroups or namespaces. Policy routing is available.
- **Gcode:** the stock screen lists `/data`.
- **Memory:** 110 MB usable. Under zmod it runs about 40 MB into a 128 MB swap file, with one atomic allocation failure in the kernel log. zforge therefore **creates a 128 MB swap file on `/data`** (not on rootfs) and keeps Moonraker lean: no extra components, no web UI by default, and a lower process priority (`nice`) than klippy.
- **Stock LAN services (confirmed):** firmwareExe listens on TCP 8898 (LAN IP only) and 8899 (FlashPrint, Orca native), plus UDP 48899 and 19000 (discovery). The camera stream is TCP 8080. The firewall's `STOCK_LAN_API` and `CAMERA` toggles map to these ports (`dport` rules for TCP and UDP).
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
| Moonraker | chroot | talks to stock klippy's API socket (`/tmp/uds`); **HTTPS on :7130** for the network, plain HTTP on :7125 reachable only from the printer itself (see TLS below); `file_system_observer: none` (kernel has no inotify) |
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
zforge tls show|regen|import <cert> <key>   Moonraker's HTTPS certificate
zforge apikey show|rotate         Moonraker API key (the only way in; no trusted clients)
zforge klipper stock|mainline     switch host klipper (+MCU) — Phase 4
zforge update                     update zforge itself from a release tgz
zforge uninstall                  remove hook + /data/zforge, restore backups
```

## Firmware updates (goal 3)

The package format and installer are documented in [`docs/stock/update-package.md`](docs/stock/update-package.md). Updates never touch `/etc/init.d/S*` or `/data`, so **the zforge hook and install survive stock updates as they are**. The update does overwrite the Wi-Fi config, `/etc/shadow` and the printer config files, and it never reboots by itself.

1. **`zforge fw install <file.tgz|url>`** is the supported path. It:
   - pre-flights the package:
     - an `Adventurer5MPro-` name and an outer tar containing `flashforge_init.sh`;
     - every component's `md5sum.list` passes;
     - no downgrade and no *Factory* (`screwflag`) package unless `--force`;
     - an optional SHA256 the user supplies;
   - checks the printer: no print running, enough free space on `/data`, MCU on stock firmware;
   - snapshots `/etc/wpa_supplicant.conf`, the hostapd conf and `/opt/config/printer*.cfg` into `/data/zforge/backup/<date>/`;
   - does exactly what `auto_run.sh` does: copies the package to `/data`, `tar -xf` into `/data/update/`, and runs `flashforge_init.sh Adventurer5MPro 0024`;
   - restores the Wi-Fi config, checks the hook is still there, records the new stock version, and reboots.
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
- *Outbound:* default deny. Allowed: the LAN, DNS to the configured resolver, NTP, and named allow-lists. NTP goes to a configured server; stock 5.2.0 uses `pool.ntp.org` via `/opt/ntpclient`, so allow that or point it at a LAN NTP server. `zforge fw check` opens only the update hosts (`update.sz3dp.com:10443`, `update.flash3dcloud.com:32445`, `update.voxelshare.com`), and only while it runs. Stock processes all run as root, so the policy is per destination, not per process.
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
MOONRAKER_HTTPS_PORT=7130   # plain HTTP (7125) is loopback-only, always
```

## Moonraker over TLS (goal 2)

Moonraker can't turn off its plain-HTTP listener. It always serves HTTP on `port`, and adds HTTPS on `ssl_port` once it finds a certificate. One `host` setting applies to both, so HTTP can't be bound to localhost alone. zforge's setup:

- **`[server]`:** `host: 0.0.0.0`, `port: 7125`, `ssl_port: 7130`. The certificate and key live in Moonraker's default spot, `<data_path>/certs/moonraker.cert` and `moonraker.key`, under `/data/zforge/var/moonraker/`.
- **Plain HTTP is blocked from the network in every firewall profile**, including `open`: a base rule `iif <wlan0|eth0> ipproto tcp dport 7125 blackhole` that profiles can't turn off. Loopback still works, so zforge's CLI and health checks can use `http://127.0.0.1:7125`.
- **Why not `port: 0`?** That's the zmod setup in use now. It doesn't disable HTTP; it binds it to a *random* port (40955 in the probe) on all interfaces. That port falls in the range the stateless rules must leave open for replies to the printer's own connections, so it can't be blocked reliably. A fixed port plus an explicit block can.
- **Certificate:** a self-signed ECDSA P-256 server certificate, made with `openssl` in the chroot on first boot when none exists:
  - SANs: the printer's IP address(es), hostname and `hostname.local`;
  - extended key usage `serverAuth`;
  - valid 825 days, so macOS accepts it.

  The key is root-only (0600).
  - `zforge tls import <cert> <key>` keeps an existing certificate, such as the one zmod uses now, so Orca keeps trusting it.
  - `zforge tls regen` makes a new one, for example if the printer's IP changes. A DHCP reservation for the printer avoids that.
  - `zforge tls show` prints the certificate and its SHA-256 fingerprint for trusting it on clients.
- **User overrides:** zforge generates `moonraker.conf` and `[include]`s `/data/zforge/etc/moonraker.user.conf` (the counterpart of zmod's `user.moonraker.conf`) for anything else, like spoolman.
- **Authorization: API key only.**
  - `[authorization]` sets `enable_api_key: True` and leaves `trusted_clients` empty, so no address gets access just by where it connects from. Every request needs the API key in an `X-Api-Key` header, or a Moonraker login token.
  - `cors_domains` is left at Moonraker's default, which means CORS is off.
  - Moonraker creates the key on first start and keeps it in its own database.
  - `zforge apikey show` prints it. It reads the key from Moonraker's database the same way Moonraker's `fetch-apikey.sh` does.
  - `zforge apikey rotate` makes a new one through `POST /access/api_key`.
  - zforge's own calls (CLI, health checks) use the key against `http://127.0.0.1:7125`, or Moonraker's local unix socket `<data_path>/comms/moonraker.sock`. Neither is reachable from the network.
  - The current zmod setup (`trusted_clients: 0.0.0.0/0`, `cors_domains: *`) is deliberately not carried over.

## OrcaSlicer (goal 2)

Stock Orca: Printer → Connection → host type "Octo/Klipper", host **`https://PRINTER_IP:7130`**, and **API Key** set to the output of `zforge apikey show`. Orca checks the certificate: on Windows and macOS the self-signed certificate has to be trusted in the system certificate store or Keychain, and on Linux Orca's "HTTPS CA file" field points to it. This is the setup that already works with zmod, and importing the existing certificate keeps it working. Upload and print go through Moonraker's `/server/files/upload` with `print=true`. Moonraker's gcode root is symlinked to the stock gcode directory, so files show up on the touchscreen too. Phase 1 checks that the stock screen sees them and that a print started from Moonraker shows progress on the screen.

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
- The hook, `zforge boot`, the swap file on `/data`, dropbear with persistent host keys, and Moonraker running against stock klippy, with HTTPS on 7130 and the always-on block of 7125 from the network.
- Migration from zmod: **before** removing zmod, copy off `/data/.mod/.zmod/root/printer_data/certs/moonraker.{cert,key}`, the dropbear `authorized_keys`, and `mod_data/user.moonraker.conf`. `zforge tls import` and the installer reuse them.
- **Exit criteria:** you can SSH in as root with a key, Orca uploads and prints over `https://…:7130` using the API key, requests without the key get `401`, `:7125` and any other Moonraker port are unreachable from the LAN, the stock screen works normally, and the printer survives reboots.

**Status (0.1.1):** passing `tests/e2e/printer-sim.sh` in both modes: 44 checks on the host userland, and 45 inside the printer's stock rootfs image (`STOCK_ROOT`), which also checks that the installer refuses while zmod is present.

The first real install (0.1.0) failed because the stock BusyBox 1.29.3 `tar` has no `-z`. The stock-rootfs test mode was added to catch exactly this class of bug. That mode also found:
- legacy `scp`, and `zforge` in non-login SSH commands, needed dropbear's `DEFAULT_ROOT_PATH`;
- a missing `eth0` could leak error text into the certificate's SAN list;
- login shells needed `/etc/profile.d/zforge.sh`.

Covered, among others:
- USB install with key, certificate and user-config import from the stick;
- the boot hook and base firewall;
- key-only SSH, plus sftp and scp;
- HTTPS with the API key, with the certificate verifying for the IP address;
- port 7125 unreachable from the LAN;
- Orca's OctoPrint upload path;
- key rotation and certificate regeneration;
- an SSH upgrade that keeps state;
- shutdown and disable.

Found and fixed along the way:
- Moonraker rejects duplicate sections in one file, so the enforced settings now live in their own included file.
- Dropbear needs a non-writable directory path to `authorized_keys`, so zforge tightens `/data` if needed.
- Service stop now signals the whole process group.

**Phase 1: on-printer checklist.** These can't be covered by the simulation:
1. The boot order holds: `/data` mounts in S35 and the stock `auto_run.sh` still works; Wi-Fi comes up; the touchscreen and stock Klipper are unaffected.
2. The bundled armv7 `ip` adds the rules on the printer's native 5.4 kernel. qemu can't emulate netlink for it; the simulation used the host's `ip`.
3. Moonraker connects to stock Klipper on `/tmp/uds`; an Orca upload with "print" starts the job; the touchscreen shows the file and the progress.
4. Memory: `zforge status` and `free` while printing, with zforge's swap on `/data`. Check for `page allocation failure` in `dmesg`.
5. NTP to the configured server works, and the certificate is generated on the first boot (if none was imported).
6. Reboot and power-cycle: everything comes back; the rescue-disable stick works.

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
