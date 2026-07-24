#!/usr/bin/env python3
"""Protocol smoke test for TextMate's Claude Code IDE bridge (AgentBridge).

Run against a live TextMate instance (dev or release build with AgentBridge):

    python3 Frameworks/AgentBridge/tests/protocol_smoke.py

It discovers the newest TextMate lock file in $CLAUDE_CONFIG_DIR/ide (or
~/.claude/ide), connects with the recorded auth token and exercises the MCP
surface: initialize (plus the initial selection_changed that seeds a new
client's editor context), tools/list, getWorkspaceFolders,
getCurrentSelection, getOpenEditors, getDiagnostics, and the document
round trip openFile → checkDocumentDirty → saveDocument. It also asserts
that wrong-token and missing-token connections are rejected, and that an
abruptly killed half-open connection does not take the server down.

The bridge PROVIDES CONTEXT ONLY — it advertises no write or approval tools.
Agent edits land in the working tree and are reviewed after the fact against
git; openDiff/close_tab/closeAllDiffTabs and the review-session machinery
they drove are gone, and Claude falls back to its own terminal approval UI.

NOTE: the openFile scenario opens a scratch document tab in the running
TextMate instance and brings it frontmost — that is the tool's documented
behavior, not a bug. The scratch tab remains open afterwards (the protocol
has no tool that closes a real document tab); close it by hand.

Pure stdlib on purpose (hand-rolled RFC 6455 client) so it can smoke-test
any future Claude CLI update in seconds with no dependencies.
"""

import base64
import hashlib
import json
import os
import secrets
import socket
import struct
import sys
import tempfile
import time
from urllib.parse import unquote, urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
EXPECTED_TOOLS = {
    "openFile", "getCurrentSelection", "getLatestSelection",
    "getOpenEditors", "getWorkspaceFolders", "getDiagnostics",
    "checkDocumentDirty", "saveDocument", "executeCode",
}


def lock_directory():
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(base, "ide")


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def find_textmate_lock():
    directory = lock_directory()
    candidates = []
    for name in os.listdir(directory):
        if not name.endswith(".lock"):
            continue
        path = os.path.join(directory, name)
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if data.get("ideName") != "TextMate" or data.get("transport") != "ws":
            continue
        if not pid_alive(int(data.get("pid", 0))):
            continue
        port = int(os.path.splitext(name)[0])
        candidates.append((os.path.getmtime(path), port, data))
    if not candidates:
        raise SystemExit(f"no live TextMate lock file found in {directory} — is TextMate running?")
    candidates.sort()
    _, port, data = candidates[-1]
    return port, data


class RejectedError(Exception):
    pass


class WSClient:
    """Minimal RFC 6455 client: handshake, masked send, unmasked recv."""

    def __init__(self, port, token, timeout=5.0):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.buffer = b""
        self.next_id = 0
        self.responses = {}  # buffered responses by request id
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        headers = [
            f"GET / HTTP/1.1",
            f"Host: 127.0.0.1:{port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
        ]
        if token is not None:
            headers.append(f"x-claude-code-ide-authorization: {token}")
        self.sock.sendall(("\r\n".join(headers) + "\r\n\r\n").encode())

        response = b""
        try:
            while b"\r\n\r\n" not in response:
                chunk = self.sock.recv(4096)
                if not chunk:
                    raise RejectedError("connection closed during handshake")
                response += chunk
        except (socket.timeout, ConnectionResetError) as e:
            raise RejectedError(f"handshake failed: {e}")

        status_line = response.split(b"\r\n", 1)[0].decode(errors="replace")
        if " 101 " not in status_line + " ":
            raise RejectedError(f"handshake rejected: {status_line}")

        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        assert accept.encode() in response, "bad Sec-WebSocket-Accept from server"

    def close(self):
        self.sock.close()

    def send_text(self, payload):
        data = payload.encode()
        mask = secrets.token_bytes(4)
        header = bytes([0x81])  # FIN + text
        n = len(data)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(header + mask + masked)

    def _read_exact(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("connection closed")
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def recv_text(self):
        message = b""
        while True:
            b0, b1 = self._read_exact(2)
            opcode, masked, n = b0 & 0x0F, b1 & 0x80, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else b""
            payload = self._read_exact(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:  # close
                raise ConnectionError("server sent close frame")
            if opcode == 0x9:  # ping → pong
                self.send_frame_pong(payload)
                continue
            if opcode == 0xA:  # pong
                continue
            message += payload
            if b0 & 0x80:  # FIN
                return message.decode()

    def send_frame_pong(self, payload):
        mask = secrets.token_bytes(4)
        header = bytes([0x8A, 0x80 | len(payload)])
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def notify(self, method, params=None):
        self.send_text(json.dumps({"jsonrpc": "2.0", "method": method, "params": params or {}}))

    def request(self, method, params=None):
        """Send a request and return its id without waiting (deferred replies)."""
        self.next_id += 1
        request_id = self.next_id
        self.send_text(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}}))
        return request_id

    def wait_response(self, request_id, timeout=5):
        """Wait for a response by id; other responses are buffered, notifications dropped."""
        if request_id in self.responses:
            return self.responses.pop(request_id)
        deadline = time.time() + timeout
        while time.time() < deadline:
            message = json.loads(self.recv_text())
            if "id" in message and ("result" in message or "error" in message):
                if message["id"] == request_id:
                    return message
                self.responses[message["id"]] = message
        raise TimeoutError(f"no response to request {request_id}")

    def wait_notification(self, method, timeout=5):
        """Wait for a notification by method; responses are buffered for wait_response."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            message = json.loads(self.recv_text())
            if "id" in message and ("result" in message or "error" in message):
                self.responses[message["id"]] = message
            elif message.get("method") == method:
                return message
        raise TimeoutError(f"no {method} notification")

    def rpc(self, method, params=None):
        return self.wait_response(self.request(method, params))

    def call_tool(self, name, arguments=None):
        return self.rpc("tools/call", {"name": name, "arguments": arguments or {}})

    def call_tool_async(self, name, arguments=None):
        return self.request("tools/call", {"name": name, "arguments": arguments or {}})


def tool_text(response):
    return json.loads(response["result"]["content"][0]["text"])


def main():
    port, lock = find_textmate_lock()
    token = lock["authToken"]
    print(f"lock file: port={port} pid={lock['pid']} folders={lock['workspaceFolders']}")

    passed = []

    # 1. authorized connect + initialize
    ws = WSClient(port, token)
    init = ws.rpc("initialize", {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "protocol_smoke", "version": "1.0"},
    })
    server_info = init["result"]["serverInfo"]
    assert server_info["name"] == "TextMate", server_info
    assert init["result"]["protocolVersion"] == "2024-11-05", init["result"]
    ws.notify("notifications/initialized")
    passed.append(f"initialize (serverInfo={server_info})")

    # 1b. handshake completion seeds the client's editor context: an initial
    #     selection_changed carrying the active document's filePath must
    #     arrive without any caret movement in the IDE (requires a file to be
    #     open in the frontmost TextMate window).
    note = ws.wait_notification("selection_changed")
    params = note["params"]
    assert params.get("filePath"), f"initial selection_changed lacks the active document's filePath: {params}"
    assert params["fileUrl"].startswith("file://"), params
    assert {"start", "end", "isEmpty"} <= set(params["selection"]), params
    passed.append(f"initial selection_changed on connect (filePath={os.path.basename(params['filePath'])})")

    # 2. tools/list advertises exactly the context-only tool set
    tools = ws.rpc("tools/list")
    names = {tool["name"] for tool in tools["result"]["tools"]}
    assert names == EXPECTED_TOOLS, f"tool set mismatch: {names ^ EXPECTED_TOOLS}"
    assert all("inputSchema" in tool for tool in tools["result"]["tools"])
    passed.append(f"tools/list ({len(EXPECTED_TOOLS)} tools with schemas, no write/approval tools)")

    # 3. getWorkspaceFolders (URIs are percent-encoded file:// URLs)
    folders = tool_text(ws.call_tool("getWorkspaceFolders"))
    assert folders["success"] is True, folders
    assert [f["path"] for f in folders["folders"]] == lock["workspaceFolders"], folders
    for folder in folders["folders"]:
        parts = urlparse(folder["uri"])
        assert parts.scheme == "file" and unquote(parts.path) == folder["path"], folder
        assert folder["name"] == os.path.basename(folder["path"]), folder
    passed.append(f"getWorkspaceFolders ({len(folders['folders'])} folders)")

    # 4. getCurrentSelection (either a selection or a graceful no-editor answer)
    selection = tool_text(ws.call_tool("getCurrentSelection"))
    assert "success" in selection, selection
    if selection["success"]:
        assert {"start", "end", "isEmpty"} <= set(selection["selection"]), selection
    passed.append(f"getCurrentSelection (success={selection['success']})")

    # 5. getOpenEditors
    editors = tool_text(ws.call_tool("getOpenEditors"))
    assert "tabs" in editors, editors
    passed.append(f"getOpenEditors ({len(editors['tabs'])} tabs)")

    # 5b. getDiagnostics (shape only — whether any server is attached varies)
    diagnostics = tool_text(ws.call_tool("getDiagnostics"))
    assert isinstance(diagnostics, list), diagnostics
    for entry in diagnostics:
        assert {"uri", "diagnostics"} <= set(entry), entry
    passed.append(f"getDiagnostics ({len(diagnostics)} files)")

    # 6. document round trip against a scratch file: openFile brings it up as
    #    a real tab, checkDocumentDirty reports the clean buffer, saveDocument
    #    succeeds. No tool in the set can write file CONTENTS — that is the
    #    point of the context-only surface.
    scratch_dir = tempfile.mkdtemp(prefix="tm-agent-bridge-smoke-")
    scratch = os.path.join(scratch_dir, "smoke_test.txt")
    baseline = "alpha\nbeta\ngamma\n"
    with open(scratch, "w") as f:
        f.write(baseline)

    opened = ws.call_tool("openFile", {"filePath": scratch})
    assert "Opened file" in opened["result"]["content"][0]["text"], opened
    time.sleep(1.0)  # allow the async open/focus to settle

    editors = tool_text(ws.call_tool("getOpenEditors"))
    assert any(scratch in tab["uri"] or scratch == unquote(urlparse(tab["uri"]).path) for tab in editors["tabs"]), editors

    dirty = tool_text(ws.call_tool("checkDocumentDirty", {"filePath": scratch}))
    assert dirty["success"] is True and dirty["isDirty"] is False, dirty

    save = tool_text(ws.call_tool("saveDocument", {"filePath": scratch}))
    # success only reports that the RPC was handled; saved is the actual
    # write result, so a broken save path would slip past a success-only check
    assert save["success"] is True, save
    assert save["saved"] is True, save
    with open(scratch) as f:
        assert f.read() == baseline, "saveDocument must not alter an unedited document's contents"
    passed.append("openFile → getOpenEditors → checkDocumentDirty → saveDocument round trip")

    # 6b. the retired review tools must be gone from the wire, not just unused
    for retired in ("openDiff", "close_tab", "closeAllDiffTabs"):
        response = ws.call_tool(retired, {})
        assert "error" in response, f"{retired} is still handled: {response}"
        assert response["error"]["code"] == -32601, response
    passed.append("retired review tools (openDiff/close_tab/closeAllDiffTabs) rejected as unknown")

    # 7. half-open socket: kill a client mid-frame, server must survive
    rude = WSClient(port, token)
    rude.sock.sendall(bytes([0x81, 0x85, 0x01, 0x02]))  # truncated masked frame
    rude.sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))  # RST on close
    rude.sock.close()
    time.sleep(0.2)
    ping = ws.rpc("ping")
    assert ping.get("result") == {}, ping
    passed.append("half-open socket (server survived RST mid-frame)")

    # 8. wrong token rejected
    try:
        bad = WSClient(port, "0" * 32)
        bad.close()
        raise SystemExit("FAIL: wrong-token connection was accepted")
    except RejectedError as e:
        passed.append(f"wrong token rejected ({e})")

    # 9. missing token rejected
    try:
        missing = WSClient(port, None)
        missing.close()
        raise SystemExit("FAIL: missing-token connection was accepted")
    except RejectedError as e:
        passed.append(f"missing token rejected ({e})")

    ws.close()
    for line in passed:
        print(f"  PASS  {line}")
    print(f"OK — {len(passed)} checks passed")


if __name__ == "__main__":
    main()
