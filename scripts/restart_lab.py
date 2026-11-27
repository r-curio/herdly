#!/usr/bin/env python3
"""Drive the built Herdly.app through restart, crash, corrupt-snapshot and saved-dismissal runs.

Everything happens in a disposable lab directory: an isolated events directory, an isolated
rollouts directory standing in for ~/.codex/sessions, and an isolated attention snapshot.
No Codex configuration, hook, or real rollout is read or written. Each reported run starts
the real app, waits for its first scan, and reads the JSON the app writes via --restart-report.

    python3 scripts/restart_lab.py --app output/Herdly.app --out output/restart-recovery.json
"""
import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def hook(events, name, session, turn=None):
    record = {"hook_event_name": name, "session_id": session, "received_at": now_iso(),
              "source": "restart-lab", "installation_id": str(uuid.uuid4())}
    if turn:
        record["turn_id"] = turn
    write_json(events / f"{uuid.uuid4()}.json", record)


def lowercase_ids(value):
    """The app prints UUIDs uppercase; the lab compares them case-insensitively."""
    if isinstance(value, dict):
        return {k: lowercase_ids(v) for k, v in value.items()}
    if isinstance(value, list):
        return [lowercase_ids(v) for v in value]
    if isinstance(value, str):
        try:
            return str(uuid.UUID(value))
        except ValueError:
            return value
    return value


def tree_digest(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(root)).encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


class Lab:
    def __init__(self, app, root):
        self.binary = Path(app) / "Contents/MacOS/Herdly"
        self.root = root
        self.events = root / "events"
        self.rollouts = root / "rollouts"
        self.snapshot = root / "attention-snapshot.json"
        self.events.mkdir()
        self.rollouts.mkdir()
        self.runs = []

    def args(self):
        return ["--desktop-events", str(self.events), "--reminder-rollouts", str(self.rollouts),
                "--attention-snapshot", str(self.snapshot)]

    def reported_run(self, name, note):
        report = self.root / f"{name}.json"
        started = time.monotonic()
        process = subprocess.Popen([str(self.binary), "--restart-report", str(report)] + self.args(),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            raise SystemExit(f"{name}: the app did not write its restart report within 30 s")
        if not report.exists():
            raise SystemExit(f"{name}: no report written (exit {process.returncode})")
        value = lowercase_ids(json.loads(report.read_text()))
        value["run"] = name
        value["note"] = note
        value["startup_seconds"] = round(time.monotonic() - started, 2)
        value["exit_code"] = process.returncode
        value["snapshot_on_disk"] = self.snapshot_state()
        self.runs.append(value)
        return value

    def snapshot_state(self):
        if not self.snapshot.exists():
            return {"exists": False}
        raw = self.snapshot.read_bytes()
        try:
            parsed = json.loads(raw)
            return {"exists": True, "valid_json": True, "bytes": len(raw),
                    "completions": [c["turn"].lower() for c in parsed.get("completions", [])],
                    "acknowledged": len(parsed.get("acknowledged", []))}
        except ValueError:
            return {"exists": True, "valid_json": False, "bytes": len(raw)}

    def crash_run(self, name, live_turn):
        """Start the app, let it observe a live completion, then SIGKILL it mid-run."""
        process = subprocess.Popen([str(self.binary)] + self.args(),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(3.5)  # first (restoring) scan done
        session, turn = live_turn
        hook(self.events, "UserPromptSubmit", session, turn)
        hook(self.events, "Stop", session, turn)
        time.sleep(4.5)  # a later scan observes the live completion and persists it
        process.send_signal(signal.SIGKILL)
        process.wait()
        value = {"run": name, "note": "SIGKILLed 8 s after launch, 4.5 s after a live completion arrived",
                 "signal": "SIGKILL", "exit_code": process.returncode, "snapshot_on_disk": self.snapshot_state()}
        self.runs.append(value)
        return value


def check(condition, message, failures):
    print(("ok   " if condition else "FAIL ") + message)
    if not condition:
        failures.append(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", default="output/Herdly.app")
    parser.add_argument("--out")
    parser.add_argument("--keep", action="store_true", help="keep the lab directory for inspection")
    options = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="herdly-restart-lab-"))
    lab = Lab(options.app, root)
    failures = []

    desktop_session = str(uuid.uuid4())
    turn1, turn2 = str(uuid.uuid4()), str(uuid.uuid4())
    cli_session = str(uuid.uuid4())
    cli_turn = str(uuid.uuid4())
    request_id = str(uuid.uuid4())

    # A desktop completion recorded before Herdly starts (metadata-only hook records).
    hook(lab.events, "SessionStart", desktop_session)
    hook(lab.events, "UserPromptSubmit", desktop_session, turn1)
    hook(lab.events, "Stop", desktop_session, turn1)
    # A CLI session rollout so the request below is classified as a CLI request.
    meta = {"type": "session_meta", "timestamp": now_iso(), "payload": {"id": cli_session, "source": "cli"}}
    (lab.rollouts / f"rollout-2026-09-12T00-00-00-{cli_session}.jsonl").write_text(json.dumps(meta) + "\n")
    # A "saved approval record": a pending request plus a companion receipt from a previous run, no decision.
    write_json(lab.events / f"{request_id}.approval", {
        "request_id": request_id, "session_id": cli_session, "turn_id": cli_turn,
        "details": {"command": "touch HERDLY11-RESTART", "action": "Bash", "project": str(root)},
        "captured_at": 0, "expires_at": 0, "outcome": "pending"})
    received = time.time()
    write_json(lab.events / f"{request_id}.receipt", {"request_id": request_id, "received_at": received,
                                                      "expires_at": received + 30})
    rollouts_before = tree_digest(lab.rollouts)

    a = lab.reported_run("A-restart-with-saved-receipt", "fresh start over prior evidence and a saved receipt")
    items = {i.get("turn") or i.get("request"): i for i in a["items"]}
    check(items.get(turn1, {}).get("kind") == "completion" and items[turn1]["uncertain"] is True,
          "A: prior completion restored as uncertain", failures)
    check(a["completion_presentation"]["presented"] is True and a["completion_presentation"]["expanded"] is False,
          "A: restored completion is silent (no first presentation, no popup)", failures)
    check(items.get(request_id, {}).get("state") == "handedBack", "A: saved receipt yields no Approve/Deny", failures)
    check(a["released_unverified_requests"] == [request_id], "A: unverified request released to Codex once", failures)
    decision = json.loads((lab.events / f"{request_id}.decision").read_text())
    check(decision["decision"] == "no_decision", "A: no-decision record written, never allow", failures)
    check(a["working_count"] == 0, "A: nothing shown as running without live evidence", failures)
    check(a["snapshot_on_disk"].get("completions") == [turn1], "A: snapshot holds the one completion", failures)

    b = lab.crash_run("B-crash", (desktop_session, turn2))
    check(b["snapshot_on_disk"].get("valid_json") is True and set(b["snapshot_on_disk"]["completions"]) == {turn1, turn2},
          "B: snapshot valid after SIGKILL and holds the live completion", failures)

    c = lab.reported_run("C-restart-after-crash", "restart after SIGKILL")
    c_items = {i.get("turn") or i.get("request"): i for i in c["items"]}
    check({t for t, i in c_items.items() if i["kind"] == "completion"} == {turn1, turn2}
          and all(i["uncertain"] for i in c_items.values() if i["kind"] == "completion"),
          "C: both completions restored, both uncertain", failures)
    check(c["completion_presentation"]["presented"] is True, "C: no replayed sound after crash", failures)
    check(c_items.get(request_id, {}).get("state") == "handedBack" and c["released_unverified_requests"] == [],
          "C: request stays handed back; nothing re-released", failures)

    # Make sure there is at least one dismissal to lose: turn1 acknowledged as Dismiss would persist it.
    snapshot = json.loads(lab.snapshot.read_text())
    snapshot["acknowledged"].append({"source": "desktop", "session": desktop_session, "turn": turn1})
    snapshot["completions"] = [c for c in snapshot["completions"] if c["turn"].lower() != turn1]
    write_json(lab.snapshot, snapshot)
    pre = lab.reported_run("C2-dismissal-before-corruption", "turn1 dismissed; saves a good snapshot and its backup")
    check([i["turn"] for i in pre["items"] if i["kind"] == "completion"] == [turn2], "C2: dismissed turn1 stays cleared", failures)
    lab.snapshot.write_bytes(b'{"version":1,"completions":[{"source":"desktop"')  # interrupted save
    (root / ".attention-snapshot.json.herdly-partial").write_bytes(b"\x00\xff garbage")
    d = lab.reported_run("D-corrupt-snapshot", "truncated snapshot plus a leftover temporary file")
    d_items = {i.get("turn"): i for i in d["items"] if i["kind"] == "completion"}
    check(set(d_items) == {turn2}, "D: startup proceeds; undismissed completion rebuilt, dismissed one still cleared", failures)
    check(d["snapshot_on_disk"].get("valid_json") is True, "D: corrupt snapshot replaced by a valid one", failures)
    check(d["acknowledged_count"] == pre["acknowledged_count"], "D: acknowledgments survived via the previous good snapshot", failures)

    snapshot = json.loads(lab.snapshot.read_text())
    snapshot["acknowledged"].append({"source": "desktop", "session": desktop_session, "turn": turn2})
    snapshot["completions"] = []
    write_json(lab.snapshot, snapshot)
    turn3 = str(uuid.uuid4())
    hook(lab.events, "UserPromptSubmit", desktop_session, turn3)
    hook(lab.events, "Stop", desktop_session, turn3)
    e = lab.reported_run("E-saved-dismissal-later-turn", "turn2 dismissed too; a later turn3 arrived while quit")
    e_turns = [i["turn"] for i in e["items"] if i["kind"] == "completion"]
    check(e_turns == [turn3], "E: both dismissed completions stay cleared; the later turn is eligible", failures)
    check(all(i["uncertain"] for i in e["items"] if i["kind"] == "completion"), "E: the turn that arrived while quit is uncertain", failures)

    check(tree_digest(lab.rollouts) == rollouts_before, "rollouts (Codex data stand-in) never modified", failures)
    for run in lab.runs:
        if "startup_seconds" in run:
            check(run["exit_code"] == 0 and run["startup_seconds"] < 30, f"{run['run']}: ordinary startup and exit", failures)

    evidence = {"recorded_at": now_iso(), "app": str(Path(options.app).resolve()), "lab": str(root),
                "identities": {"desktop_session": desktop_session, "turn1": turn1, "turn2": turn2, "turn3": turn3,
                               "cli_session": cli_session, "cli_turn": cli_turn, "request_id": request_id},
                "runs": lab.runs, "failures": failures}
    if options.out:
        write_json(Path(options.out), evidence)
    if not options.keep:
        shutil.rmtree(root, ignore_errors=True)
    print(json.dumps({"failures": failures}, indent=2))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
