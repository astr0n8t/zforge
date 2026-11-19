# zforge

zforge is a minimal mod for the Flashforge Adventurer 5M Pro. It adds four things:

- root SSH;
- current Moonraker, so stock OrcaSlicer can upload and print;
- stock firmware updates over SSH, while the stock touchscreen keeps working;
- a strict firewall that you control.

See [PLAN.md](PLAN.md) for the design and phases.

## Status

- **Phase 0 (discovery): done.** See [`docs/device-notes.md`](docs/device-notes.md) and [`docs/stock/`](docs/stock/).
- **Phase 1 (SSH, HTTPS Moonraker on stock Klipper): built and tested in simulation.** Not yet run successfully on a printer.
  - The simulation is an x86 host running the real armv7 binaries under qemu.
  - With `STOCK_ROOT=<mounted stock rootfs backup>`, the printer side runs inside the printer's own BusyBox/bash userland.
  - On-printer checks still to do: see "Phase 1: on-printer checklist" in [`PLAN.md`](PLAN.md).

## Layout

| Path | What |
|---|---|
| `build/` | `build-rootfs.sh` (Alpine armv7 chroot with Moonraker, plus static dropbear and sftp-server) and `package.sh` (makes `dist/Adventurer5MPro-zforge-<ver>.tgz`) |
| `printer/` | everything that ends up in `/data/.zforge`: the `zforge` CLI, libs, the boot hook, config templates |
| `installer/` | `flashforge_init.sh`, run by the stock USB updater, or over SSH for upgrades |
| `rescue/` | USB sticks that disable or uninstall zforge without SSH |
| `tools/probe/`, `tools/install/` | PC-side helpers (Phase 0 probe and backup; SSH upgrade) |
| `tests/` | `e2e/printer-sim.sh` (full install, boot and checks in namespaces), `firewall/` |
| `docs/` | [`install.md`](docs/install.md), device notes, stock firmware analysis |

## Build and test

```sh
sudo build/build-rootfs.sh        # needs qemu-user-static + binfmt on x86 (about 20 min)
build/package.sh                  # dist/Adventurer5MPro-zforge-<ver>.tgz
sudo [STOCK_ROOT=/mnt/stock-rootfs] unshare -m -n -p -f --mount-proc sh tests/e2e/printer-sim.sh dist/Adventurer5MPro-zforge-*.tgz
```
