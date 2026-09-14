#!/usr/bin/env python3
"""Drive Steer's daemon client against a fake app-server daemon on a scratch socket.

Everything happens in a disposable lab directory: a fake daemon that speaks JSON-RPC over
WebSocket (the framing Codex's daemon uses on its control socket) with the shapes from the
installed CLI's generated schema, an isolated events directory, and an
isolated rollouts directory. The real `~/.codex/app-server-control` socket is never touched and no
Codex configuration is read or written. Each run starts the real Steer binary with
`--daemon-socket` pointing at the fake and reads the JSON it writes via `--daemon-report`.
Steer never answers anything here: the lab proves connect, initialize, subscribe and receive, and
that a socket readable by other users is refused. The real daemon's behaviour (whether a second
client receives the pending request at all) is a separate, human proof; see
docs/user-input-requests.md.

    python3 scripts/daemon_lab.py --steer .build/debug/Steer --out docs/evidence/app-server-daemon-lab.json
"""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

THREAD = "01a09d9b-7642-7b51-bcce-9b66cfe5361f"
TURN = "01a09db7-0c51-7f33-9ebc-4e44f91df22c"
ITEM = "call_daemonlab_1"
# A second session, finished and blocked on nothing: its completion card carries the reply field.
# It is a separate session because a session waiting on a question is still in a turn, and a reply
# to a session in a turn is refused.
DONE_THREAD = "01a09dc4-1f22-7aa4-8c31-5b71a0c24d10"
DONE_TURN = "01a09dd0-6b8e-7c05-9f42-2d6083e51ab7"


WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def server_frame(payload, opcode=0x1):
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + payload


def parse_frame(buffer):
    """(opcode, payload, rest) for one complete client frame, or None when incomplete."""
    if len(buffer) < 2:
        return None
    opcode, n, masked, offset = buffer[0] & 0x0F, buffer[1] & 0x7F, buffer[1] & 0x80, 2
    if n == 126:
        if len(buffer) < 4:
            return None
        n, offset = struct.unpack(">H", buffer[2:4])[0], 4
    elif n == 127:
        if len(buffer) < 10:
            return None
        n, offset = struct.unpack(">Q", buffer[2:10])[0], 10
    mask = None
    if masked:
        if len(buffer) < offset + 4:
            return None
        mask, offset = buffer[offset:offset + 4], offset + 4
    if len(buffer) < offset + n:
        return None
    payload = buffer[offset:offset + n]
    if mask:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload, buffer[offset + n:]


class FakeDaemon(threading.Thread):
    """Accepts one client, completes the WebSocket upgrade, answers initialize and the thread
    requests, then pushes a question. Records whether the client masked its frames as required."""

    def __init__(self, path):
        super().__init__(daemon=True)
        self.path = path
        self.log = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        os.chmod(path, 0o600)
        self.server.listen(1)
        self.server.settimeout(15)
        self.response = None
        self.upgrade_request = None

    def run(self):
        try:
            conn, _ = self.server.accept()
        except socket.timeout:
            self.log.append({"event": "no client connected"})
            return
        conn.settimeout(15)
        buffer = b""
        pushed = False
        started = time.time()
        # The HTTP upgrade first; a client that skips it never gets a frame back.
        while b"\r\n\r\n" not in buffer and time.time() - started < 20:
            try:
                chunk = conn.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                self.log.append({"event": "client closed before upgrading"})
                conn.close()
                return
            buffer += chunk
        if b"\r\n\r\n" not in buffer:
            conn.close()
            return
        head, buffer = buffer.split(b"\r\n\r\n", 1)
        lines = head.decode(errors="replace").split("\r\n")
        headers = {k.strip().lower(): v.strip() for k, v in (l.split(":", 1) for l in lines[1:] if ":" in l)}
        self.upgrade_request = {"request_line": lines[0], "upgrade": headers.get("upgrade"), "key_present": "sec-websocket-key" in headers}
        self.log.append({"direction": "in", "upgrade": self.upgrade_request})
        if headers.get("upgrade", "").lower() != "websocket" or "sec-websocket-key" not in headers:
            conn.close()
            return
        accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + WS_GUID).encode()).digest()).decode()
        conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nconnection: Upgrade\r\nupgrade: websocket\r\n"
                      f"sec-websocket-accept: {accept}\r\n\r\n").encode())
        while time.time() - started < 20:
            frame = parse_frame(buffer)
            if frame is None:
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    self.log.append({"event": "client closed"})
                    break
                buffer += chunk
                continue
            opcode, payload, buffer = frame
            if opcode == 0x8:
                self.log.append({"event": "client sent close"})
                break
            if opcode != 0x1:
                continue
            message = json.loads(payload)
            self.log.append({"direction": "in", "message": message})
            method = message.get("method")
            if method == "initialize":
                self.send(conn, {"jsonrpc": "2.0", "id": message["id"],
                                 "result": {"userAgent": "fake-daemon", "codexHome": "/tmp", "platformFamily": "unix", "platformOs": "macos"}})
            elif method == "thread/loaded/list":
                self.send(conn, {"jsonrpc": "2.0", "id": message["id"], "result": {"data": [THREAD, DONE_THREAD]}})
            elif method == "thread/resume":
                self.send(conn, {"jsonrpc": "2.0", "id": message["id"],
                                 "result": {"thread": {"id": message["params"]["threadId"], "status": {"type": "active"}}}})
                if not pushed and message["params"]["threadId"] == THREAD:
                    pushed = True
                    self.send(conn, {"jsonrpc": "2.0", "id": 900, "method": "item/tool/requestUserInput",
                                     "params": {"threadId": THREAD, "turnId": TURN, "itemId": ITEM,
                                                "questions": [{"id": "shape", "header": "Shape", "question": "Which?",
                                                               "options": [{"label": "A", "description": ""}, {"label": "B", "description": ""}]},
                                                              {"id": "name", "header": "Name", "question": "Call it?", "options": None}]}})
            elif method is None and message.get("id") == 900:
                self.response = message
        conn.close()

    def send(self, conn, message):
        self.log.append({"direction": "out", "message": message})
        conn.sendall(server_frame(json.dumps(message).encode()))


def now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def seed_pending_question(events, rollouts):
    """A CLI session whose rollout holds the same call the fake daemon will push, still unanswered,
    so the queue shows the question and the report can say which path its card would use. A second
    session finished its only turn, so the queue also holds a completion whose card offers the reply
    field; the report says where that field would send, and the lab sends nothing."""
    def hook(name, session, turn):
        record = {"hook_event_name": name, "session_id": session, "turn_id": turn, "received_at": now_iso(),
                  "source": "daemon-lab", "installation_id": str(uuid.uuid4())}
        (events / f"{uuid.uuid4()}.json").write_text(json.dumps(record) + "\n")

    hook("UserPromptSubmit", DONE_THREAD, DONE_TURN)
    hook("Stop", DONE_THREAD, DONE_TURN)
    hook("UserPromptSubmit", THREAD, TURN)
    done = [
        {"timestamp": now_iso(), "type": "session_meta", "payload": {"id": DONE_THREAD, "source": "cli"}},
        {"timestamp": now_iso(), "type": "event_msg", "payload": {"type": "task_started", "turn_id": DONE_TURN}},
        {"timestamp": now_iso(), "type": "event_msg", "payload": {"type": "task_complete", "turn_id": DONE_TURN}},
    ]
    (rollouts / f"rollout-2026-09-14T00-00-01-{DONE_THREAD}.jsonl").write_text("".join(json.dumps(l) + "\n" for l in done))
    lines = [
        {"timestamp": now_iso(), "type": "session_meta", "payload": {"id": THREAD, "source": "cli"}},
        {"timestamp": now_iso(), "type": "event_msg", "payload": {"type": "task_started", "turn_id": TURN}},
        {"timestamp": now_iso(), "type": "response_item",
         "payload": {"type": "function_call", "name": "request_user_input", "call_id": ITEM,
                     "internal_chat_message_metadata_passthrough": {"turn_id": TURN},
                     "arguments": json.dumps({"questions": [
                         {"id": "shape", "header": "Shape", "question": "Which?",
                          "options": [{"label": "A", "description": ""}, {"label": "B", "description": ""}]},
                         {"id": "name", "header": "Name", "question": "Call it?"}]})}},
    ]
    (rollouts / f"rollout-2026-09-14T00-00-00-{THREAD}.jsonl").write_text("".join(json.dumps(l) + "\n" for l in lines))


def run_steer(steer, socket_path, lab, name, extra=()):
    report = lab / f"{name}.json"
    events = lab / f"{name}-events"
    events.mkdir(exist_ok=True)
    rollouts = lab / f"{name}-rollouts"
    rollouts.mkdir(exist_ok=True)
    seed_pending_question(events, rollouts)
    command = [str(steer), "--daemon-socket", socket_path, "--daemon-report", str(report),
               "--reminder-events", str(events), "--reminder-rollouts", str(rollouts),
               "--attention-snapshot", str(lab / f"{name}-snapshot.json"), *extra]
    run = subprocess.run(command, capture_output=True, text=True, timeout=60)
    return {"exit": run.returncode, "report": json.loads(report.read_text()) if report.exists() else None,
            "stderr": run.stderr[-2000:]}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--steer", type=Path, required=True, help="the built Steer executable")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    results = {"recorded": datetime.now(timezone.utc).isoformat(), "steer": str(args.steer), "runs": {}}
    with tempfile.TemporaryDirectory(prefix="steer-daemon-lab-") as directory:
        lab = Path(directory)
        # Run 1: a private socket with a fake daemon behind it.
        path = str(lab / "d.sock")
        daemon = FakeDaemon(path)
        daemon.start()
        results["runs"]["private-socket"] = run_steer(args.steer, path, lab, "private")
        daemon.join(timeout=25)
        results["runs"]["private-socket"]["daemon_log"] = daemon.log
        results["runs"]["private-socket"]["answer_written_by_steer"] = daemon.response
        # Run 2: the same socket made readable by other users: Steer must refuse to connect.
        shared = str(lab / "shared.sock")
        shared_daemon = FakeDaemon(shared)
        os.chmod(shared, 0o666)
        shared_daemon.start()
        results["runs"]["shared-socket"] = run_steer(args.steer, shared, lab, "shared")
        shared_daemon.join(timeout=20)
        results["runs"]["shared-socket"]["daemon_log"] = shared_daemon.log
        # Run 3: no socket at all.
        results["runs"]["no-socket"] = run_steer(args.steer, str(lab / "missing.sock"), lab, "missing")
    private = results["runs"]["private-socket"]["report"] or {}
    checks = {
        "private_connected": private.get("connected") is True,
        "private_subscribed": private.get("subscribed") == sorted([THREAD, DONE_THREAD]),
        "private_received_request": [r.get("item_id") for r in private.get("pending_requests", [])] == [ITEM],
        "private_question_ids": [q["id"] for r in private.get("pending_requests", []) for q in r["questions"]] == ["shape", "name"],
        "private_card_uses_daemon": [r.get("route", "").startswith("daemon(") for r in private.get("pending_requests", [])] == [True],
        # The completion card's reply field targets that completion's own thread, and only it.
        "private_reply_targets_the_thread": private.get("completion_reply_targets")
        == [f"{DONE_THREAD}: daemon(thread: {DONE_THREAD.upper()})"],
        # With no daemon there is no reply path at all, and the card says so.
        "no_socket_reply_unavailable": (results["runs"]["no-socket"]["report"] or {}).get("completion_reply_targets")
        == [f"{DONE_THREAD}: unavailable(SteerCore.SessionReplyPolicy.Rejection.noDaemon)"],
        "shared_card_falls_back": any("ghosttyRelay" in r for r in (results["runs"]["shared-socket"]["report"] or {}).get("question_routes", [])),
        "nothing_answered": results["runs"]["private-socket"]["answer_written_by_steer"] is None,
        "upgraded_to_websocket": (results["runs"]["private-socket"]["daemon_log"] or [{}])[0].get("upgrade", {}).get("upgrade", "").lower() == "websocket",
        "initialized_as_steer": any(m.get("message", {}).get("method") == "initialize"
                                    and m["message"]["params"]["clientInfo"]["name"] == "steer"
                                    for m in results["runs"]["private-socket"]["daemon_log"]),
        "shared_refused": (results["runs"]["shared-socket"]["report"] or {}).get("connected") is False
        and "readable by other users" in (results["runs"]["shared-socket"]["report"] or {}).get("status", "")
        and not any(m.get("direction") == "in" for m in results["runs"]["shared-socket"]["daemon_log"]),
        "missing_reported": "not running" in (results["runs"]["no-socket"]["report"] or {}).get("status", ""),
    }
    results["checks"] = checks
    results["passed"] = all(checks.values())
    text = json.dumps(results, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.write_text(text)
    print(json.dumps({"checks": checks, "passed": results["passed"]}, indent=2))
    return 0 if results["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
