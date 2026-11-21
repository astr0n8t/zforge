# zforge: start Moonraker's prints through the stock touchscreen app.
#
# Moonraker normally starts a print with Klipper's SDCARD_PRINT_FILE. The
# stock touchscreen app (firmwareExe) then doesn't know about it, so the screen
# shows no print. Instead, this asks firmwareExe to start the file through its
# LAN protocol on 127.0.0.1:8899 ("~M23 0:/user/<file>", what FlashPrint
# sends), so the screen starts, owns and shows the print as if it had been
# started there. Klipper still runs it; Moonraker still tracks it.
#
# If firmwareExe isn't reachable (not running, port closed), the print starts
# the normal Moonraker way. The firewall's blocks are per network interface, so
# they never touch this loopback connection.
#
# Copied into Moonraker's components by zforge (printer/lib/moonraker.sh) and
# enabled by the [zforge_screen] section; SCREEN_PRINT=off in zforge.conf
# leaves it out.
#
# Copyright (C) 2026 zforge contributors. GPLv3, like Moonraker.

from __future__ import annotations

import asyncio
import logging
from typing import TYPE_CHECKING, Any, Optional

if TYPE_CHECKING:
    from ..confighelper import ConfigHelper


class ZforgeScreen:
    def __init__(self, config: ConfigHelper) -> None:
        self.server = config.get_server()
        self.host = config.get("host", "127.0.0.1")
        self.port = config.getint("port", 8899)
        self.prefix = config.get("path_prefix", "0:/user/")
        self.timeout = config.getfloat("timeout", 10.)
        # klippy_apis is a core component, loaded before any extra one
        self.kapis: Any = self.server.lookup_component("klippy_apis")
        self._klipper_start = self.kapis.start_print
        self.kapis.start_print = self.start_print
        logging.info(
            f"zforge_screen: prints start through the touchscreen app "
            f"({self.host}:{self.port})")

    async def start_print(
        self,
        filename: str,
        wait_klippy_started: bool = False,
        user: Optional[Any] = None
    ) -> str:
        if filename.startswith("/"):
            filename = filename[1:]
        if wait_klippy_started:
            await self.kapis.klippy.wait_started()
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(self.host, self.port), self.timeout)
        except (OSError, asyncio.TimeoutError) as e:
            logging.info(
                f"zforge_screen: touchscreen app unreachable ({e!r}); "
                f"starting {filename} through Klipper")
            return await self._klipper_start(filename, False, user)
        try:
            logging.info(f"Requesting Job Start via touchscreen, filename = {filename}")
            writer.write(f"~M23 {self.prefix}{filename}\r\n".encode("utf-8"))
            await writer.drain()
            reply = await asyncio.wait_for(reader.read(1024), self.timeout)
        except (OSError, asyncio.TimeoutError) as e:
            # The request may have reached the app: don't risk a second start.
            raise self.server.error(
                f"touchscreen app didn't answer the print request: {e!r}", 503)
        finally:
            writer.close()
        text = reply.decode("utf-8", "replace").strip()
        logging.info(f"zforge_screen: touchscreen app replied {text!r}")
        if "M23 Received" not in text or "busy" in text.lower():
            raise self.server.error(
                f"the touchscreen refused the print ({text or 'no reply'}). "
                "Is it showing a dialog, or printing already?", 409)
        self.server.send_event("klippy_apis:job_start_complete", user)
        return "ok"


def load_component(config: ConfigHelper) -> ZforgeScreen:
    return ZforgeScreen(config)
