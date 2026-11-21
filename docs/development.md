# Development: build, test, release

## Build

```sh
sudo tools/dev/qemu-binfmt.sh        # x86 hosts: run armv7 binaries via qemu-user (F flag)
sudo build/build-rootfs.sh           # Alpine armv7 chroot + Moonraker, static dropbear + sftp-server -> dist/ (~20 min under qemu)
build/package.sh                     # dist/Adventurer5MPro-zforge-<ver>.tgz and dist/rescue-*/
```

**Versions** are pinned in `build/versions.env`:
- Alpine, with the minirootfs sha256;
- Moonraker;
- dropbear;
- OpenSSH, which supplies `sftp-server`;
- `ZFORGE_VERSION`.

`build-rootfs.sh` needs the Alpine mirror and GitHub (for the git clones). Behind an intercepting proxy, pass the proxy's CA file as `BUILD_CA_BUNDLE=<ca file>`; it's used only during the build and never ends up in the rootfs.

## Tests

| Test | What it covers | Where |
|---|---|---|
| `shellcheck` | every script (`#!/bin/sh` files and `printer/lib/*.sh`) | CI and local |
| `tests/firewall/fib-rules-netns.sh` | the policy-routing firewall approach, in network namespaces | CI and local |
| `tests/e2e/printer-sim.sh`, host mode | the whole package on a simulated printer, with the armv7 binaries running under qemu (see the list below) | CI and local |
| `tests/e2e/printer-sim.sh`, stock mode | everything above, inside the printer's **own** rootfs (its BusyBox and bash userland), plus stock firmware updates, `zforge update`, the zmod refusal and Klipper's SD file walk run with the printer's Python | local only |

**What the e2e suite exercises:**
- the USB and SSH installers, the boot hook and the firewall profiles;
- SSH, sftp and scp, with key-only login;
- HTTPS Moonraker with the API key, and Orca's upload API;
- the rollback of unconfirmed firewall changes;
- upgrades, uninstall and the camera service.

```sh
sudo unshare -n -m sh tests/firewall/fib-rules-netns.sh
sudo unshare -m -n -p -f --mount-proc sh tests/e2e/printer-sim.sh dist/Adventurer5MPro-zforge-<ver>.tgz
# stock mode: mount a backup of the printer's rootfs partition (tools/probe/run-backup.sh) read-only
sudo mount -o loop,ro,noload mmcblk0p6.img /mnt/stock-rootfs
sudo STOCK_ROOT=/mnt/stock-rootfs FW_PKG_REAL=Adventurer5MPro-5.2.0-….tgz \
     unshare -m -n -p -f --mount-proc sh tests/e2e/printer-sim.sh dist/Adventurer5MPro-zforge-<ver>.tgz
```

**Why stock mode is local only:** it needs the printer's rootfs image, which contains personal data such as the Wi-Fi configuration. Run it before every release anyway: it is the mode that caught the BusyBox `tar` without `-z`, `/bin/sh` being bash, and the missing `pgrep`.

`FW_PKG_REAL` is optional: a real Flashforge update package to install in the simulation. Never commit vendor packages.

**Limits of the simulation:**
- **No netlink under qemu:** the printer-side `ip` calls are relayed to the host's `ip`.
- **No Klipper and no camera.**
- **No IPv6 sysctls in some sandboxes:** those checks are then reported as `SKIP`.

`PLAN.md` lists the checks that need a real printer.

## CI/CD (GitHub Actions)

- **`.github/workflows/build-test.yml`** runs on every push and pull request:
  - shellcheck;
  - the rootfs build, cached by its inputs so it doesn't rebuild per zforge version;
  - the package, the firewall test and the e2e test in host mode.

  It uploads the package and rescue sticks as an artifact, and the e2e logs on failure.
- **`.github/workflows/release.yml`** runs on a `vX.Y.Z` tag. It runs the same build and test, checks that the tag matches `ZFORGE_VERSION`, then publishes a GitHub release containing:
  - the package;
  - the rescue sticks, as `rescue-<name>-flashforge_init.sh` (rename to `flashforge_init.sh` on the stick);
  - `SHA256SUMS`.

## Releasing

1. Bump `ZFORGE_VERSION` in `build/versions.env`.
2. Build and run both e2e modes locally. Stock mode needs the printer's rootfs image (see above).
3. Commit, then tag: `git tag v<ver> && git push origin v<ver>`. CI publishes the release.
4. On the printer: `zforge update https://github.com/<owner>/<repo>/releases/download/v<ver>/Adventurer5MPro-zforge-<ver>.tgz`.
   - The download follows GitHub's redirect to its download host, and the firewall opens only those hosts, only for the download.
   - The repository is public, so release links work directly. For a private fork, download on the PC and use `tools/install/run-install.sh`, or copy the file over and run `zforge update /data/<file>`.
