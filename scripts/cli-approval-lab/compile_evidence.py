"""Compile the issue #10 lab runs into output/cli-approval-resolution.json (ignored; copy a redacted
summary into docs/evidence by hand).

Reads runs/<case>.json (driver timeline and helper records), runs/<case>.resolution.json (the real
reader's output for that case's events directory) and runs/helper-race.json. Only identifiers,
timings, commands and outcomes are copied; no prompt or transcript text.
"""
import json, os, glob, subprocess

S = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(S, "..", "..", "output", "cli-approval-resolution.json")
os.makedirs(os.path.dirname(OUT), exist_ok=True)
version = subprocess.run(["/opt/homebrew/bin/codex", "--version"], capture_output=True, text=True).stdout.strip()
commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=S).stdout.strip()

cases = []
for path in sorted(glob.glob(os.path.join(S, "runs", "*.json"))):
    name = os.path.basename(path)[:-5]
    if name in ("helper-race", "explore") or name.endswith(".resolution"): continue
    run = json.load(open(path))
    resolution_path = os.path.join(S, "runs", name + ".resolution.json")
    resolution = json.load(open(resolution_path)) if os.path.exists(resolution_path) else {}
    requests = []
    for rid, req in run["approvals"].items():
        receipt = run.get(rid + ".receipt", {})
        decision = run.get(rid + ".decision")
        requests.append({
            "request_id": rid, "session_id": req["session_id"], "turn_id": req["turn_id"],
            "command": req["details"].get("command"), "action": req["details"].get("action"),
            "companion_received_at": receipt.get("received_at"), "expires_at": receipt.get("expires_at"),
            "companion_decision_record": decision, "helper_outcome": req.get("outcome"),
            "helper_outcome_written_at": None,
            "reader_resolution": next((r for r in resolution.get("resolutions", []) if r["request_id"] == rid), None),
        })
    events = [{"t": e["t"], "event": e["event"], **{k: v for k, v in e.items() if k not in ("t", "event")}} for e in run["timeline"]]
    cases.append({
        "case": name, "marker": run["marker"], "marker_exists": run["marker_exists"],
        "requests": requests, "driver_timeline": events,
        "completed_turns": resolution.get("completed_turns"), "canceled_turns": resolution.get("canceled_turns"),
        "queue_requests_remaining_after_scan": resolution.get("remaining_queue_requests"),
    })
report = {
    "recorded": "2026-09-12", "codex_cli": version, "helper": f"HerdlyHook release build from branch codex/10-approval-reconciliation ({commit})",
    "native_answers": "keystrokes into the lab TUI's own approval prompt after Herdly handed back; never a Herdly decision",
    "isolation": "lab project hooks.json swapped per run and restored; --dangerously-bypass-hook-trust per invocation; no global hooks, policies or settings changed",
    "cli_cases": cases,
    "helper_race": json.load(open(os.path.join(S, "runs", "helper-race.json")))["cases"],
}
json.dump(report, open(OUT, "w"), indent=2)
print("wrote", os.path.relpath(OUT, os.path.join(S, "..", "..")))
