# Stock Klipper on the AD5M Pro, and what zmod changed in it

**Sources compared:**
- **Flashforge's published source:** `AD5M_Series_Klipper-main`, the "Klipper" download on Flashforge's site, from January 2024. Zip sha256 `c45e9dfc1dd4921f3f269315e4a0e058e7ab4f8ea0bd7e34a7cb1e91a9209f13`.
- **The printer's `/opt/klipper`,** from the user's rootfs backup, taken with zmod 1.7.1 installed.

The source's `fw-Ad5m/Mainboard-20230831.bin` is identical to the one in the stock `control-2.2.3`. Its `Eboard-20231012.hex` differs, though the file name is the same.

**The published source is not byte-for-byte the shipped build.** zmod documents the shipped `toolhead.py` as `LOOKAHEAD_FLUSH_TIME = 0.5`, but the source has `0.250`. Restoring a file from the source therefore gets you "Flashforge's code", not necessarily the exact bytes that were shipped.

## Differences, and what they are

| File (in `/opt/klipper/klippy`) | Printer vs Flashforge source | Origin |
|---|---|---|
| `extras/zmod.py`, `extras/ens160.py`, `extras/gcode_shell_command.py` | only on the printer | **zmod additions** |
| `extras/virtual_sdcard.py` | `# zmod 1.1`; skips `.zmod` in the SD file walk; byte-accurate file position | **zmod copy** (identical to zmod's `.shell/virtual_sdcard.py`) |
| `webhooks.py` | `# zmod 1.1`; echoes `gcode/script` commands to zmod's console client (`key 1945`) | **zmod copy** |
| `extras/save_variables.py` | adds `ZLOAD_VARIABLE` | **zmod copy** |
| `extras/spi_temperature.py` | "Zcontrol 1.25": `ZCONTROL_ON` etc. for MAX31856 | **zmod copy** |
| `extras/buttons.py` | newer upstream ack-count arithmetic | **zmod copy** |
| `mcu.py` | `TRSYNC_TIMEOUT 0.025 → 0.1`, plus a log-message change | **zmod patch: "FIX_E0011"** (homing "Communication timeout") |
| `toolhead.py` | `LOOKAHEAD_FLUSH_TIME` → `0.150` (shipped: 0.5 per zmod; source: 0.250) | **zmod patch: "FIX_E0017"** |
| `chelper/stepcompress.c` + `chelper/c_helper.so` | `QUEUE_START_SIZE 2048 → 1024`; a different ARM build of the `.so` | zmod (memory); keep the `.c` and `.so` together |
| `/opt/klipper/start.sh` | `# zmod 1.1` lines that copy zmod's `virtual_sdcard.py` back in at every Klipper start | **zmod patch** |

## Notes for a cleanup

- **zforge doesn't depend on any of these.** Moonraker needs no `webhooks.py` change. Since 0.4.1, the SD file walk is safe with either `virtual_sdcard.py`.
- **`start.sh` must be cleaned first.** Otherwise it re-copies zmod's `virtual_sdcard.py` from `/opt/config/mod/.shell/` at every Klipper start. That's only harmless while the zmod directory is gone, because the copy then simply fails.
- **Remove zmod's modules only after their config is gone.** `printer.cfg`'s `[include ./mod/…]` files are what load `zmod.py` and `gcode_shell_command.py`. Removing a module that a config section still references stops Klipper from starting.
- **`TRSYNC_TIMEOUT` and `LOOKAHEAD_FLUSH_TIME` are behaviour fixes.** They address error codes E0011 and E0017. Reverting them can bring those errors back, so keeping them is a reasonable choice.
- **Treat `c_helper.so` and `stepcompress.c` as a pair.** Klipper tries to rebuild the `.so` if the `.c` is newer, and there's no compiler on the printer. Restore both from the same source, or leave both alone.
