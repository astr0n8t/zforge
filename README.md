# zforge

A minimal mod for the **Flashforge Adventurer 5M Pro** that keeps the stock firmware (touchscreen, stock Klipper, stock updates) in charge.

It adds:
- **Root SSH** with key-only login, including `scp` and `sftp`.
- **Current Moonraker over HTTPS only,** with an API key. Stock OrcaSlicer uploads and prints with host type *Octo/Klipper* at `https://PRINTER:7130`.
- **A firewall you control.** By default the stock firmware gets no internet, and only your LAN reaches the printer. Changes roll back unless you confirm them.
- **Stock firmware updates over SSH,** with checks first and your Wi-Fi config preserved: `zforge fw install`.
- **A low-overhead camera stream:** the stock mjpg-streamer at `http://PRINTER:8080/?action=stream`.
- **Self-updates:** `zforge update <file|URL>`.

On the stock system it puts two small files, `/etc/init.d/S35zforge` and `/etc/profile.d/zforge.sh`. Everything else lives in `/data/.zforge`, and stock firmware updates leave all of it alone.

## Using it

- **Install, migrate from zmod, set up Orca:** [docs/install.md](docs/install.md)
- **Firewall and camera:** [docs/firewall.md](docs/firewall.md)
- **Stock firmware updates:** [docs/firmware-updates.md](docs/firmware-updates.md)
- **On the printer:** `zforge help` lists every command. `zforge status` shows the services, ports, memory and firewall.

Rescue USB sticks work without SSH: disable zforge, uninstall it, open the firewall, or deal with a stuck MCU update. See the end of [install.md](docs/install.md).

## Status

**0.5.0.** Phases 0–3 of [PLAN.md](PLAN.md) are done and in use on a printer:
- Phase 0: discovery;
- Phase 1: SSH and HTTPS Moonraker;
- Phase 2: firewall and camera;
- Phase 3: firmware updates.

Phase 5, CI/CD and polish, is also done. Phase 4 (mainline Klipper) is dropped by choice: zforge runs the stock Klipper.

## Layout

| Path | What |
|---|---|
| `build/` | `build-rootfs.sh` (Alpine armv7 chroot with Moonraker, plus static dropbear and sftp-server), `package.sh`, pinned `versions.env` |
| `printer/` | what ends up in `/data/.zforge`: the `zforge` CLI and its libs, the boot hook, config templates |
| `installer/` | `flashforge_init.sh`: the stock USB updater runs it; it's also used over SSH for upgrades |
| `rescue/` | USB sticks: disable, uninstall, firewall-open, mcu-diag, skip-mcu-update |
| `tools/` | PC-side helpers: `probe/` (read-only probe, partition backup, zmod-remnants inventory), `install/run-install.sh`, `dev/` |
| `tests/` | `e2e/printer-sim.sh` (whole package on a simulated printer), `firewall/` |
| `docs/` | user guides, [development.md](docs/development.md), [device-notes.md](docs/device-notes.md), and `stock/` (analysis of the stock firmware, update packages and Klipper) |
| `.github/workflows/` | CI (`build-test.yml`) and releases (`release.yml`) |

## Development

See [docs/development.md](docs/development.md) for building under qemu, the test suites (host and stock-rootfs modes), CI and the release process.
