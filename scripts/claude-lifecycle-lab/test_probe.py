#!/usr/bin/env python3
"""Regression check for Claude PermissionRequest output."""
import json
import os
import subprocess
import tempfile
import threading
import time


with tempfile.TemporaryDirectory() as run:
    def answer():
        requests = os.path.join(run, "requests")
        while not os.path.isdir(requests) or not os.listdir(requests):
            time.sleep(0.01)
        request = json.load(open(os.path.join(requests, os.listdir(requests)[0])))
        rid = request["request_id"]
        now = time.time()
        for directory, body in (
            ("receipts", {"request_id": rid, "received_at": now}),
            ("decisions", {"request_id": rid, "decision": "allow", "decided_at": now}),
        ):
            os.makedirs(os.path.join(run, directory), exist_ok=True)
            with open(os.path.join(run, directory, rid + ".json"), "w") as f:
                json.dump(body, f)

    threading.Thread(target=answer, daemon=True).start()
    payload = {"hook_event_name": "PermissionRequest", "session_id": "test", "prompt_id": "prompt",
               "tool_name": "Bash", "tool_input": {"command": "true"}}
    result = subprocess.run(
        ["python3", os.path.join(os.path.dirname(__file__), "probe.py"), "permission"],
        input=json.dumps(payload), text=True, capture_output=True, check=True,
        env={**os.environ, "STEER_LAB_RUN": run}, timeout=5,
    )
    output = json.loads(result.stdout)
    assert output == {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {
        "behavior": "allow"
    }}}, output

print("permission output: ok")
