#!/usr/bin/env python3
"""Probe Codex's local app-server daemon socket the way Steer's daemon client would.

Read-only unless `--answer` is given. Speaks JSON-RPC 2.0 over WebSocket on
`~/.codex/app-server-control/app-server-control.sock` (the socket `codex app-server daemon start`
creates and the TUI attaches to): an HTTP upgrade, then one message per text frame, the way
Codex's own clients do on 0.154.0. It never starts, stops or configures the daemon itself.

  python3 scripts/probe_app_server_daemon.py --status
      Whether the socket exists, who owns it, its mode, and `codex app-server daemon version`.
  python3 scripts/probe_app_server_daemon.py --handshake
      Connect, `initialize` as a second client, list the threads loaded in the daemon. Read-only.
  python3 scripts/probe_app_server_daemon.py --watch [--thread ID ...] [--record FILE] [--seconds N]
      Subscribe (`thread/resume`) to the given loaded threads, or every loaded thread, and print each
      `item/tool/requestUserInput`, `serverRequest/resolved`, `turn/completed` and `thread/closed` as
      it arrives. Nothing is answered. `--record` appends every message to a JSONL file for evidence.
  python3 scripts/probe_app_server_daemon.py --watch --answer ITEM_ID --with QUESTION_ID=TEXT ...
      The one writing mode, for the human proof: when the pending request whose `itemId` equals
      ITEM_ID arrives (or is already pending), respond exactly once with the given answers. TEXT is
      an option label or a typed answer. Every question in the request must be given an answer.
  python3 scripts/probe_app_server_daemon.py --self-test

`thread/resume` is only ever sent for a thread id that `thread/loaded/list` reported, so the probe
never loads a thread from disk into the daemon; it only rejoins threads that are already running.
"""
import argparse
import base64
import hashlib
import json
import os
import pwd
import select
import socket
import stat
import struct
import subprocess
import sys
import time

SOCKET = os.path.expanduser("~/.codex/app-server-control/app-server-control.sock")
INTERESTING = {"item/tool/requestUserInput", "serverRequest/resolved", "turn/completed", "thread/closed",
               "turn/started", "thread/started", "item/started", "item/completed"}


def socket_status(path=SOCKET):
    """What Steer's client checks before connecting: a socket owned by this user, private to them."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return {"path": path, "exists": False}
    owner = pwd.getpwuid(info.st_uid).pw_name if info.st_uid >= 0 else None
    return {"path": path, "exists": True, "is_socket": stat.S_ISSOCK(info.st_mode),
            "owner": owner, "owned_by_me": info.st_uid == os.getuid(),
            "mode": oct(stat.S_IMODE(info.st_mode)),
            "private": stat.S_IMODE(info.st_mode) & 0o077 == 0,
            "directory_mode": oct(stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode))}


def daemon_version():
    try:
        run = subprocess.run(["codex", "app-server", "daemon", "version"], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError) as error:
        return {"error": str(error)}
    return {"exit": run.returncode, "stdout": run.stdout.strip(), "stderr": run.stderr.strip()}


WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_accept(key):
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def ws_frame(payload, opcode=0x1):
    """One client frame: FIN set, masked as RFC 6455 requires."""
    mask = os.urandom(4)
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


class Client:
    """Minimal JSON-RPC-over-WebSocket client on the daemon's Unix socket."""

    def __init__(self, path=SOCKET, record=None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 1
        self.record = record
        self.pending = {}
        self.upgrade()

    def upgrade(self):
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
                           f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n").encode())
        while b"\r\n\r\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("connection closed during the WebSocket upgrade")
            self.buffer += chunk
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        lines = head.decode(errors="replace").split("\r\n")
        if " 101 " not in lines[0]:
            raise RuntimeError(f"upgrade refused: {lines[0]}")
        accept = {k.strip().lower(): v.strip() for k, v in (l.split(":", 1) for l in lines[1:] if ":" in l)}.get("sec-websocket-accept")
        if accept != ws_accept(key):
            raise RuntimeError("Sec-WebSocket-Accept mismatch")
        self._log("upgrade", {"status": lines[0]})

    def send(self, message):
        self.sock.sendall(ws_frame(json.dumps(message, separators=(",", ":")).encode()))
        self._log("out", message)

    def _need(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self.buffer += chunk
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def read_frame(self):
        """(opcode, payload) of the next complete frame, or None when the daemon closed."""
        head = self._need(2)
        if head is None:
            return None
        opcode, n = head[0] & 0x0F, head[1] & 0x7F
        masked = head[1] & 0x80
        if n == 126:
            n = struct.unpack(">H", self._need(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._need(8))[0]
        mask = self._need(4) if masked else None
        payload = self._need(n)
        if payload is None:
            return None
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return opcode, payload

    def request(self, method, params=None):
        request_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        while True:
            message = self.read()
            if message is None:
                raise RuntimeError(f"connection closed waiting for {method}")
            if message.get("id") == request_id and "method" not in message:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message.get("result")
            self.handle(message)

    def read(self, timeout=None):
        """The next JSON-RPC message; pings are answered, other control frames skipped."""
        while True:
            if timeout is not None and not self.buffer:
                ready, _, _ = select.select([self.sock], [], [], timeout)
                if not ready:
                    return None
            frame = self.read_frame()
            if frame is None:
                return None
            opcode, payload = frame
            if opcode == 0x9:
                self.sock.sendall(ws_frame(payload, opcode=0xA))
                continue
            if opcode == 0x8:
                return None
            if opcode not in (0x1, 0x2):
                continue
            message = json.loads(payload)
            self._log("in", message)
            return message

    def handle(self, message):
        """Track server requests and their resolution; print what matters for the proof."""
        method = message.get("method")
        if method == "item/tool/requestUserInput":
            params = message.get("params", {})
            self.pending[params.get("itemId")] = message
            print(f"{stamp()} REQUEST id={message.get('id')!r} thread={params.get('threadId')} turn={params.get('turnId')} "
                  f"item={params.get('itemId')} questions="
                  + json.dumps([{"id": q.get("id"), "options": [o.get("label") for o in (q.get("options") or [])],
                                 "isOther": q.get("isOther", False), "isSecret": q.get("isSecret", False)}
                                for q in params.get("questions", [])]))
        elif method == "serverRequest/resolved":
            params = message.get("params", {})
            print(f"{stamp()} RESOLVED request={params.get('requestId')!r} thread={params.get('threadId')}")
            for item, request in list(self.pending.items()):
                if request.get("id") == params.get("requestId"):
                    del self.pending[item]
        elif method in INTERESTING:
            params = message.get("params", {})
            print(f"{stamp()} {method} thread={params.get('threadId')} " + json.dumps(params)[:200])

    def respond(self, request, answers):
        """The one answer: the JSON-RPC result Codex's own TUI would send for this request."""
        self.send({"jsonrpc": "2.0", "id": request["id"],
                   "result": {"answers": {qid: {"answers": [text]} for qid, text in answers.items()}}})

    def _log(self, direction, message):
        if self.record:
            with open(self.record, "a") as file:
                file.write(json.dumps({"t": time.time(), "direction": direction, "message": message}) + "\n")


def stamp():
    return time.strftime("%H:%M:%S")


def initialize(client):
    result = client.request("initialize", {"clientInfo": {"name": "steer-probe", "title": "Steer probe", "version": "0"},
                                           "capabilities": {"experimentalApi": True}})
    client.send({"jsonrpc": "2.0", "method": "initialized"})
    return result


def loaded_threads(client):
    return client.request("thread/loaded/list", {}).get("data", [])


def answers_for(request, given):
    """Every question answered exactly once, or nothing is sent."""
    questions = request.get("params", {}).get("questions", [])
    ids = [q.get("id") for q in questions]
    if set(ids) != set(given):
        return None
    return {qid: given[qid] for qid in ids}


def self_test():
    request = {"id": 7, "params": {"questions": [{"id": "a"}, {"id": "b"}]}}
    assert answers_for(request, {"a": "x", "b": "y"}) == {"a": "x", "b": "y"}
    assert answers_for(request, {"a": "x"}) is None
    assert answers_for(request, {"a": "x", "b": "y", "c": "z"}) is None
    status = socket_status("/definitely/not/here.sock")
    assert status == {"path": "/definitely/not/here.sock", "exists": False}
    # RFC 6455 §4.2.2 example key and accept value.
    assert ws_accept("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    frame = ws_frame(b"hi")
    assert frame[0] == 0x81 and frame[1] == 0x82 and len(frame) == 8
    print("Daemon probe self-check passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", default=SOCKET)
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--handshake", action="store_true")
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--thread", action="append", default=[])
    parser.add_argument("--seconds", type=float, default=None, help="stop watching after this long")
    parser.add_argument("--record", help="append every message to this JSONL file")
    parser.add_argument("--answer", metavar="ITEM_ID", help="answer the pending request with this itemId, once")
    parser.add_argument("--with", dest="given", action="append", default=[], metavar="QUESTION_ID=TEXT")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.status:
        print(json.dumps({"socket": socket_status(args.socket), "daemon_version": daemon_version()}, indent=2))
        return 0
    if not (args.handshake or args.watch):
        parser.error("choose --status, --handshake, --watch or --self-test")
    status = socket_status(args.socket)
    if not status["exists"]:
        print(json.dumps({"socket": status, "result": "no daemon socket; nothing to connect to"}, indent=2))
        return 1
    if not (status["is_socket"] and status["owned_by_me"] and status["private"]):
        print(json.dumps({"socket": status, "result": "socket is not a private socket owned by this user; refusing"}, indent=2))
        return 1
    client = Client(args.socket, record=args.record)
    info = initialize(client)
    threads = loaded_threads(client)
    print(json.dumps({"socket": status, "initialize": info, "loaded_threads": threads}, indent=2))
    if not args.watch:
        return 0
    wanted = args.thread or threads
    subscribed = set()
    for thread in wanted:
        if thread not in threads:
            print(f"{stamp()} thread {thread} is not loaded in the daemon; not resuming it")
            continue
        try:
            result = client.request("thread/resume", {"threadId": thread})
        except RuntimeError as error:
            print(f"{stamp()} not yet subscribed to {thread}: {error}")
            continue
        subscribed.add(thread)
        print(f"{stamp()} subscribed to {thread}: thread status " + json.dumps((result or {}).get("thread", {}).get("status"))[:120])
    given = dict(item.split("=", 1) for item in args.given)
    answered = False
    started = time.time()
    next_poll = time.time() + 5
    print(f"{stamp()} watching; Ctrl-C to stop")
    try:
        while args.seconds is None or time.time() - started < args.seconds:
            message = client.read(timeout=1)
            if message is not None:
                client.handle(message)
            # Threads that attach later (a TUI started after the probe) are subscribed as they appear,
            # unless specific --thread ids were asked for.
            if not args.thread and time.time() >= next_poll:
                next_poll = time.time() + 5
                for thread in loaded_threads(client):
                    if thread not in subscribed:
                        try:
                            result = client.request("thread/resume", {"threadId": thread})
                        except RuntimeError as error:
                            # A brand-new thread has no rollout yet; the daemon refuses to resume it
                            # until its first turn is recorded. Try again on the next poll.
                            print(f"{stamp()} not yet subscribed to {thread}: {error}", flush=True)
                            continue
                        subscribed.add(thread)
                        print(f"{stamp()} subscribed to {thread}: thread status " + json.dumps((result or {}).get("thread", {}).get("status"))[:120], flush=True)
            if args.answer and not answered and args.answer in client.pending:
                request = client.pending[args.answer]
                answers = answers_for(request, given)
                if answers is None:
                    print(f"{stamp()} --with does not cover exactly the request's question ids; not answering")
                    answered = True
                else:
                    client.respond(request, answers)
                    answered = True
                    print(f"{stamp()} ANSWERED item={args.answer} request={request['id']!r} " + json.dumps(answers))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
