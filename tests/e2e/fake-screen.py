#!/usr/bin/env python3
# Stand-in for the stock touchscreen app's LAN port (firmwareExe, TCP 8899):
# answers one request with REPLY and writes what it received to LOG.
# usage: fake-screen.py LOG REPLY [PORT]
import socket
import sys

log, reply = sys.argv[1], sys.argv[2]
port = int(sys.argv[3]) if len(sys.argv) > 3 else 8899
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
s.settimeout(60)
c, _ = s.accept()
data = c.recv(1024)
with open(log, "wb") as f:
    f.write(data)
c.sendall(reply.encode().replace(b"\\n", b"\r\n"))
c.close()
