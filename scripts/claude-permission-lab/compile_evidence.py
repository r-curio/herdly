"""Compile issue #71 lab runs into output/claude-permission-lab/claude-permission-transport.json.

Reads output/claude-permission-lab/runs/<case>.json. Copies only identifiers, timings, hook event names,
payload key names, file basenames and outcomes; no prompt, transcript or file content.
"""
import glob, json, os, shutil, subprocess

S = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(S, "..", ".."))
RUNS = os.path.join(REPO, "output", "claude-permission-lab", "runs")
OUT = os.path.join(REPO, "output", "claude-permission-lab", "claude-permission-transport.json")
os.makedirs(os.path.dirname(OUT), exist_ok=True)
ORDER = ["allow", "deny", "handoff", "native", "native-no", "timeout", "helper-loss", "overlap"]

claude = shutil.which("claude", path="/opt/homebrew/bin:/usr/local/bin:" + os.path.expanduser("~/.local/bin") + ":" + os.environ.get("PATH", ""))
version = subprocess.run([claude, "--version"], capture_output=True, text=True).stdout.strip()
commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=REPO).stdout.strip()


def rel(t, start):
    return round(t - start, 3)


cases = []
for name in ORDER:
    path = os.path.join(RUNS, name + ".json")
    if not os.path.exists(path):
        continue
    run = json.load(open(path))
    start = next(e["t"] for e in run["timeline"] if e["event"] == "prompt_submitted")
    events = []
    for h in run["hooks"]:
        if h["event"] in ("SessionStart", "UserPromptSubmit"):
            continue
        e = {"t": rel(h["t"], start), "hook": h["event"]}
        for k in ("tool_name", "tool_use_id", "request_id", "outcome", "decision", "notification_type"):
            if h.get(k) is not None:
                e[k] = h[k]
        if h.get("file_path"):
            e["file"] = os.path.basename(h["file_path"])
        events.append(e)
    for d in run["timeline"]:
        if d["event"] in ("prompt_submitted", "case_end", "registry_before_key", "registry_after_key",
                          "transcript_tool_results") or d.get("key") in ("ctrl-c", "trust-folder-enter"):
            continue
        if d["event"] == "registry_status":
            if d.get("status"):
                events.append({"t": rel(d["t"], start), "registry_status": d["status"],
                               "status_changed": rel(d["status_updated_at"], start)})
            continue
        events.append({"t": rel(d["t"], start), "driver": d["event"],
                       **{k: v for k, v in d.items() if k not in ("t", "event")}})
    events.sort(key=lambda e: e["t"])
    perm = [h for h in run["hooks"] if h["event"] == "PermissionRequest"]
    cases.append({
        "case": name,
        "session_id": perm[0]["session_id"] if perm else None,
        "prompt_id": perm[0]["prompt_id"] if perm else None,
        "permission_request_keys": perm[0]["keys"] if perm else None,
        "marker_created": run["marker_exists"],
        "records_left": sorted(n.rsplit(".", 1)[1] + ":" + n.split(".")[0][:8] for n in run["records"]),
        "events_seconds_from_prompt": events,
    })

report = {
    "issue": 71,
    "recorded": "2026-10-11",
    "claude_code": version,
    "repo_commit": commit,
    "helper": "scripts/claude-permission-lab/lab_helper.py (lab stand-in mirroring HerdlyHook's Claude approval file protocol for any tool); not the shipped HerdlyHook, which decides Bash only",
    "companion": "scripts/claude-permission-lab/run_case.py writes receipts and decisions; native answers are keystrokes into Claude's own prompt",
    "decisions": "scripted by the agent at the operator's explicit direction (2026-10-11); not human-clicked",
    "session_mode": "top-level interactive sessions (the driver clears CLAUDECODE/CLAUDE_CODE_* so a launch from inside Claude Code is not marked nested)",
    "isolation": "claude --setting-sources project --permission-mode default --model haiku --strict-mcp-config in output/claude-permission-lab/project; user hooks, permission rules and auto mode not loaded; only Write calls creating marker files in the lab project",
    "cases": cases,
}
with open(OUT, "w") as f:
    json.dump(report, f, indent=2)
    f.write("\n")
print("wrote", os.path.relpath(OUT, REPO))
