#!/usr/bin/env python3
"""Prepare an isolated project to test hooks from the existing Codex desktop.

The recorder never emits a decision, reads transcripts, or stores prompt/tool text.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid

EVENTS = ("SessionStart", "UserPromptSubmit", "Stop", "Interrupt", "SessionEnd",
          "PreToolUse", "PostToolUse", "PermissionRequest")
LIMIT = 1_048_576


def capture(raw, root):
    if len(raw) > LIMIT:
        return
    data = json.loads(raw)
    if not isinstance(data, dict) or data.get("hook_event_name") not in EVENTS:
        return
    cwd = data.get("cwd")
    if not isinstance(cwd, str) or not Path(cwd).resolve().is_relative_to(root.resolve()):
        return  # Reject anything outside this disposable project.
    record = {"capture_id": str(uuid.uuid4()),
              "received_at": datetime.now(timezone.utc).isoformat(),
              "input_fields": sorted(data),
              "tool_input_fields": sorted(data["tool_input"]) if isinstance(data.get("tool_input"), dict) else []}
    for key in ("hook_event_name", "session_id", "turn_id", "tool_name", "tool_use_id", "permission_mode"):
        value = data.get(key)
        if isinstance(value, str):
            record[key] = value[:256]
    destination = root / "events" / (record["capture_id"] + ".json")
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(record, stream, indent=2)


def prepare(root):
    root.mkdir(parents=True, exist_ok=False)
    (root / ".codex").mkdir()
    (root / "events").mkdir(mode=0o700)
    script = root / ".codex" / "record.py"
    shutil.copyfile(__file__, script)
    command = " ".join(shlex.quote(s) for s in (sys.executable, str(script), "--capture", str(root)))
    hooks = {event: [{"hooks": [{"type": "command", "command": command, "timeout": 2}]}]
             for event in EVENTS}
    (root / ".codex" / "hooks.json").write_text(json.dumps({
        "description": "Herdly disposable event recorder: metadata only, no approval decisions.",
        "hooks": hooks}, indent=2) + "\n")
    (root / ".codex" / "config.toml").write_text("[features]\nhooks = true\n")
    (root / ".gitignore").write_text("events/\n")
    (root / "README.md").write_text("""# Herdly desktop hook lab

Open this directory as a local Codex desktop project. Review the recorder and
trust its project hooks through Codex's normal review flow if prompted.
No trust bypass is configured. Existing user/system hooks may still apply.

First prompt: Reply only HERDLY-LIFECYCLE-OK. Do not run tools or change files.
After hooks are trusted, send the prompt again in the same task if necessary.

The recorder keeps event names and correlation IDs in events/. It never stores
prompts, command contents or transcripts, and always returns no decision.
PermissionRequest is observed only if normal Codex policy requests permission.
This lab does not test one-time approval, denial, 30-second delay or disconnect yet.
Do not change your global permission settings to force a request.
""")
    subprocess.run(["git", "init", "--quiet", str(root)], check=True)
    return root


def report(root):
    records = [json.loads(p.read_text()) for p in sorted((root / "events").glob("*.json"))]
    return {"project": str(root), "counts": dict(Counter(r["hook_event_name"] for r in records)),
            "events": sorted(records, key=lambda r: r["received_at"]),
            "verification": "Correlate session IDs with the desktop task before claiming live proof."
                if records else "No events captured; desktop hook execution is not verified."}


def self_test():
    with tempfile.TemporaryDirectory(prefix="herdly-hook-check-") as temporary:
        root = prepare(Path(temporary) / "project with spaces")
        command = json.loads((root / ".codex/hooks.json").read_text())["hooks"]["PermissionRequest"][0]["hooks"][0]["command"]
        sample = {"hook_event_name": "PermissionRequest", "session_id": "fixture-session",
                  "turn_id": "fixture-turn", "cwd": str(root), "tool_name": "Bash",
                  "tool_input": {"command": "DO-NOT-STORE", "description": "DO-NOT-STORE"},
                  "prompt": "DO-NOT-STORE", "transcript_path": "DO-NOT-STORE"}
        result = subprocess.run(shlex.split(command), input=json.dumps(sample).encode(), capture_output=True)
        assert result.returncode == 0 and result.stdout == b"" and result.stderr == b""
        summary = report(root)
        assert summary["counts"] == {"PermissionRequest": 1}
        assert "DO-NOT-STORE" not in json.dumps(summary)
        assert "decision" not in summary["events"][0]
        sample["cwd"] = temporary
        capture(json.dumps(sample).encode(), root)
        assert len(report(root)["events"]) == 1
        for raw in (b"invalid JSON", b"[]", b"x" * (LIMIT + 1)):
            result = subprocess.run(shlex.split(command), input=raw, capture_output=True)
            assert result.returncode == 0 and result.stdout == b"" and result.stderr == b""
        assert len(report(root)["events"]) == 1
    print("Hook lab checks passed; fixtures did not exercise a Codex runtime.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--prepare", type=Path)
    mode.add_argument("--capture", type=Path)
    mode.add_argument("--report", type=Path)
    mode.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.capture:
        try:
            capture(sys.stdin.buffer.read(LIMIT + 1), args.capture)
        except (OSError, ValueError, TypeError):
            pass  # Never change Codex's approval flow because recording failed.
    elif args.prepare:
        print(prepare(args.prepare.resolve()))
    elif args.report:
        print(json.dumps(report(args.report.resolve()), indent=2))
    else:
        self_test()
