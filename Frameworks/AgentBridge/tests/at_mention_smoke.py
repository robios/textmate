#!/usr/bin/env python3
"""Fake agent CLI for the tm_agent seam: connects to the bridge exactly like
protocol_smoke.py, prints READY, then waits for one at_mentioned notification
and prints its params as sorted JSON. Exits 0 when the notification arrives,
1 on timeout.

Mentions are scoped to a project, so run both halves from the same directory
inside an open TextMate project — this process announces its pid, from which
the bridge derives that directory. Run from outside every open project, this
client is unscoped and still hears every mention, but tm_agent then has no
project to attribute the mention to and is refused.

Usage (with TextMate running):

    python3 Frameworks/AgentBridge/tests/at_mention_smoke.py [timeout] &
    tm_agent mention --file /some/file --line-start 3 --line-end 7

Expected output line: {"filePath": "/some/file", "lineEnd": 7, "lineStart": 3}
"""

import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from protocol_smoke import WSClient, find_textmate_lock


def main():
    timeout = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0
    port, lock = find_textmate_lock()
    ws = WSClient(port, lock["authToken"], timeout=timeout)
    ws.rpc("initialize", {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "at_mention_smoke", "version": "1.0"},
    })
    ws.notify("notifications/initialized")
    ws.notify("ide_connected", {"pid": os.getpid()})
    print("READY", flush=True)

    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            message = json.loads(ws.recv_text())
        except socket.timeout:
            break
        if message.get("method") == "at_mentioned":
            print(json.dumps(message.get("params"), sort_keys=True), flush=True)
            return 0
    print("TIMEOUT: no at_mentioned received", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
