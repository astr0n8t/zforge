# Firewall and camera

## How the firewall works

The stock kernel has no netfilter, so there is no iptables and no nftables. zforge builds its firewall from policy-routing rules (`ip rule`) instead. Every packet's route lookup walks the rules in order, and the first match decides. The rules are **stateless**:
- replies to the printer's own connections are let in by port range, not by tracking connections;
- there is no logging or rate limiting.

That covers the goal: the stock firmware can't phone home, and only the hosts you choose can reach the printer's services.

| Profile | Inbound | Outbound |
|---|---|---|
| `open` | stock behaviour, apart from the blocks that are always on (below) | anything |
| `lan` (default) | only the services below, from `LAN_CIDRS` (or each service's `*_ALLOW`); everything else is dropped | the LAN, multicast and broadcast, DNS servers (from `/etc/resolv.conf`), and `NTP_SERVERS` |
| `strict` | like `lan` | like `lan`, plus `ALLOW_OUT` |

**Services allowed in** (`lan`/`strict`):

| Service | Port | Setting |
|---|---|---|
| SSH | TCP 22 | from `SSH_ALLOW` |
| Moonraker HTTPS | TCP 7130 | from `MOONRAKER_ALLOW` |
| Camera | TCP 8080 | from `CAMERA_ALLOW`, only when `CAMERA=on` |
| Stock LAN API | TCP 8898/8899, UDP 48899/19000 | only when `STOCK_LAN_API=on` |

**Always on, in every profile:**
- Moonraker's plain-HTTP port 7125 is blocked from the network.
- The stock LAN API ports are blocked when `STOCK_LAN_API=off`, and the camera port when `CAMERA=off`.

**IPv6 is turned off** in `lan`/`strict`: the stock kernel has no IPv6 policy tables, so IPv6 couldn't be filtered.

**Host names** in `NTP_SERVERS` and `ALLOW_OUT` are resolved to addresses once the network is up, and again every 30 minutes by the `fwrefresh` service.

**Limits:**
- Replies are let in by the kernel's ephemeral port range (usually 32768–60999). A service that listens on a *random* high port is therefore reachable from anywhere. zmod's `port: 0` Moonraker was such a service; zforge's services all use fixed ports.
- The firewall chooses by destination, not by program, because every stock process runs as root.
- So in `strict`, anything on the printer, not only the program you meant to allow, can reach an `ALLOW_OUT` host.

## Changing it safely

1. Edit `/data/.zforge/etc/zforge.conf`.
2. Run `zforge firewall apply`. The new rules take effect immediately.
3. Run `zforge firewall confirm` within `FW_CONFIRM_SECONDS` (default 120) to keep them.

If you don't confirm (for example, because the change cut off your SSH), the previous confirmed rules come back by themselves. An unconfirmed change is also dropped at the next reboot.

`zforge firewall status` shows:
- the active profile;
- a pending change, if there is one;
- whether `zforge.conf` differs from what's active;
- every rule.

If you're locked out anyway, use the **`rescue-firewall-open` stick**. Put that `flashforge_init.sh` alone on a FAT32 stick and power on. It sets `FIREWALL_PROFILE=open` and reboots.

## Camera

`CAMERA=on` (the default) runs the stock `/opt/mjpg-streamer`:
- **Native MJPEG:** the camera's own MJPEG is passed through, never re-encoded.
- **No snapshots:** nothing is written to `/data`.
- **Commands off:** mjpg-streamer's remote-command interface is disabled.
- **Priority:** it runs at nice 5, below Klipper.

The stream is **plain HTTP with no login**, by choice, to keep the CPU for printing:
```
http://PRINTER_IP:8080/?action=stream      (a single frame: ?action=snapshot)
```
Who can watch is decided by the firewall alone, through `CAMERA_ALLOW`, or `LAN_CIDRS` if that's empty.

Settings: `CAMERA_DEVICE` (default `/dev/video0`), `CAMERA_RES` (default `1280x720`), `CAMERA_FPS` (default `15`) and `CAMERA_PORT` (default `8080`). Apply them with `zforge restart camera`.

**Keep the touchscreen's camera setting off.** A USB camera can be opened by only one program at a time. While the stock stream is running, zforge waits and says so in `zforge log camera`.

To show the stream in a Moonraker client, add this to `/data/.zforge/etc/moonraker.user.conf`, then run `zforge restart moonraker`:
```ini
[webcam printer]
service: mjpegstreamer
stream_url: http://PRINTER_IP:8080/?action=stream
snapshot_url: http://PRINTER_IP:8080/?action=snapshot
```
