# zforge

zforge is a minimal mod for the Flashforge Adventurer 5M Pro. It adds four things:

- root SSH;
- current Moonraker, so stock OrcaSlicer can upload and print;
- stock firmware updates over SSH, while the stock touchscreen keeps working;
- a strict firewall that you control.

See [PLAN.md](PLAN.md) for the design and phases.

## Status: Phase 0 (discovery)

The tools in [`tools/probe/`](tools/probe/README.md) read the printer over SSH and change nothing on it:

```sh
tools/probe/run-probe.sh  root@PRINTER_IP   # what's on the printer
tools/probe/run-backup.sh root@PRINTER_IP   # raw partition backup, md5-verified
```

Findings go in [`docs/device-notes.md`](docs/device-notes.md).
