"""Compile issue #72 lab runs into docs/evidence/claude-file-approvals.json.

Reads output/claude-file-lab/runs/<case>.json. Keeps hook event names, tool names, tool-input key shapes,
lab-relative targets, decisions, fixture digests and the native dialog's visible lines. Absolute lab paths
become <lab>; no user path, transcript or conversation content is copied.
"""
import json, os, re, shutil, subprocess

S = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(S, "..", ".."))
LAB = os.path.join(REPO, "output", "claude-file-lab")
RUNS = os.path.join(LAB, "runs")
OUT = os.path.join(REPO, "docs", "evidence", "claude-file-approvals.json")
order = subprocess.run(["python3", "-I", os.path.join(S, "run_file_case.py"), "--list"],
                       capture_output=True, text=True, check=True).stdout.split()

claude = shutil.which("claude", path="/opt/homebrew/bin:/usr/local/bin:" + os.path.expanduser("~/.local/bin") + ":" + os.environ.get("PATH", ""))
version = subprocess.run([claude, "--version"], capture_output=True, text=True).stdout.strip()
commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=REPO).stdout.strip()


def redact(value):
    if isinstance(value, str):
        home = os.path.expanduser("~")
        for prefix in (LAB, "~" + LAB[len(home):]):
            value = value.replace(prefix, "<lab>")
        return value.replace(REPO, "<repo>").replace("~" + REPO[len(home):], "<repo>").replace(home, "~")
    if isinstance(value, dict):
        return {k: redact(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


cases = []
for name in order:
    path = os.path.join(RUNS, name + ".json")
    if not os.path.exists(path):
        continue
    run = json.load(open(path))
    start = next(e["t"] for e in run["timeline"] if e["event"] == "prompt_submitted")
    events = []
    for h in run["hooks"]:
        if h["event"] in ("SessionStart", "UserPromptSubmit"):
            continue
        e = {"t": round(h["t"] - start, 3), "hook": h["event"]}
        for k in ("tool_name", "tool_use_id", "request_id", "outcome", "decision", "permission_mode", "targets", "tool_input_shape"):
            if h.get(k) is not None:
                e[k] = h[k]
        events.append(e)
    for d in run["timeline"]:
        if d["event"] in ("prompt_submitted", "case_end"):
            continue
        events.append({"t": round(d["t"] - start, 3), "driver": d["event"],
                       **{k: v for k, v in d.items() if k not in ("t", "event")}})
    events.sort(key=lambda e: e["t"])
    perm = [h for h in run["hooks"] if h["event"] == "PermissionRequest"]
    cases.append(redact({
        "case": name,
        "companion": run["decision"],
        "settings_extra": run["extra"],
        "prompt": run["prompt"],
        "permission_requests": len(perm),
        "permission_request_keys": perm[0]["keys"] if perm else None,
        "files_changed": {k: [run["files_before"][k], run["files_after"][k]]
                          for k in run["files_before"] if run["files_before"][k] != run["files_after"][k]},
        "native_dialog": [{"at": p["at"], "lines": [l for l in p["lines"] if not re.fullmatch(r"[╌─━ ]+", l)]}
                          for p in run["native_prompts"]][:1],
        "events_seconds_from_prompt": events,
    }))

report = {
    "issue": 72,
    "recorded": "2026-10-11",
    "claude_code": version,
    "repo_commit": commit,
    "helper": "scripts/claude-permission-lab/lab_helper.py (the #71 stand-in for SteerHook's Claude approval file protocol, any tool); not the shipped SteerHook, which decides Bash only",
    "companion": "scripts/claude-permission-lab/run_file_case.py writes receipts and decisions; native answers are keystrokes into Claude's own dialog",
    "decisions": "scripted by the agent at the operator's explicit direction (2026-10-11); not human-clicked",
    "isolation": "claude --setting-sources project --model haiku --strict-mcp-config in <lab>/project with --permission-mode default unless a case sets one; user hooks, rules and auto mode not loaded; every target is a disposable fixture under <lab>",
    "cases": cases,
}
with open(OUT, "w") as f:
    json.dump(report, f, indent=2)
    f.write("\n")
print("wrote", os.path.relpath(OUT, REPO))
