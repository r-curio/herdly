#!/usr/bin/env python3
"""Probe Codex's local app-server daemon socket the way Steer's daemon client would.

Read-only unless `--answer` is given. Speaks newline-delimited JSON-RPC 2.0 to
`~/.codex/app-server-control/app-server-control.sock` (the socket `codex app-server daemon start`
creates and the TUI attaches to), and never starts, stops or configures the daemon itself.

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
import json
import os
import pwd
import select
import socket
import stat
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


class Client:
    """Minimal JSON-RPC client over the daemon's Unix socket; one line per message."""

    def __init__(self, path=SOCKET, record=None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 1
        self.record = record
        self.pending = {}

    def send(self, message):
        line = json.dumps(message, separators=(",", ":")) + "\n"
        self.sock.sendall(line.encode())
        self._log("out", message)

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
        if timeout is not None:
            ready, _, _ = select.select([self.sock], [], [], timeout)
            if not ready:
                return None
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        message = json.loads(line)
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
    for thread in wanted:
        if thread not in threads:
            print(f"{stamp()} thread {thread} is not loaded in the daemon; not resuming it")
            continue
        result = client.request("thread/resume", {"threadId": thread})
        print(f"{stamp()} subscribed to {thread}: thread status " + json.dumps((result or {}).get("thread", {}).get("status"))[:120])
    given = dict(item.split("=", 1) for item in args.given)
    answered = False
    started = time.time()
    print(f"{stamp()} watching; Ctrl-C to stop")
    try:
        while args.seconds is None or time.time() - started < args.seconds:
            message = client.read(timeout=1)
            if message is None:
                if client.buffer == b"" and not select.select([client.sock], [], [], 0)[0]:
                    pass
            else:
                client.handle(message)
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
