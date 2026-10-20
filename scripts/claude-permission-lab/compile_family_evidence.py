"""Compile one family's lab runs into its evidence JSON.

Usage: python3 -I compile_family_evidence.py <family>
  file -> docs/evidence/claude-file-approvals.json (#72)     web -> claude-web-approvals.json (#73)
  plan -> claude-plan-approval.json (#74)                   mcp -> claude-mcp-approval.json (#75)


Reads output/claude-file-lab/runs/<case>.json. Keeps hook event names, tool names, tool-input key shapes,
lab-relative targets, decisions, fixture digests and the native dialog's visible lines. Absolute lab paths
become <lab>; no user path, transcript or conversation content is copied.
"""
import json, os, re, shutil, subprocess

S = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(S, "..", ".."))
LAB = os.path.join(REPO, "output", "claude-file-lab")
RUNS = os.path.join(LAB, "runs")
if len(os.sys.argv) != 2 or os.sys.argv[1] not in ("file", "web", "plan", "mcp"):
    raise SystemExit(__doc__)
FAMILY = os.sys.argv[1]
ISSUE, NAME = {"file": (72, "claude-file-approvals"), "web": (73, "claude-web-approvals"),
               "plan": (74, "claude-plan-approval"), "mcp": (75, "claude-mcp-approval")}[FAMILY]
OUT = os.path.join(REPO, "docs", "evidence", NAME + ".json")
order = subprocess.run(["python3", "-I", os.path.join(S, "run_family_case.py"), "--list", FAMILY],
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
        "mcp_server_log": [{"t": round(c["t"] - start, 3), "event": c.get("event", "call"), "pid": c.get("pid"),
                            **({"tool": c["tool"], "arguments": c["arguments"]} if "tool" in c else {})}
                           for c in run.get("mcp_calls", [])],
        "native_dialog": [{"at": p["at"], "lines": [l for l in p["lines"] if not re.fullmatch(r"[╌─━ ]+", l)]}
                          for p in run["native_prompts"]][:1],
        "events_seconds_from_prompt": events,
    }))

report = {
    "issue": ISSUE,
    "recorded": "2026-10-11",
    "claude_code": version,
    # The commit checked out when compiling. Individual runs may predate it; each family doc names the script
    # changes made between runs.
    "repo_commit_at_compile": commit,
    "helper": "scripts/claude-permission-lab/lab_helper.py (the #71 stand-in for HerdlyHook's Claude approval file protocol, any tool); not the shipped HerdlyHook, which decides Bash only",
    "companion": "scripts/claude-permission-lab/run_family_case.py writes receipts and decisions; native answers are keystrokes into Claude's own dialog",
    "decisions": "scripted by the agent at the operator's explicit direction (2026-10-11); not human-clicked",
    "isolation": "claude --setting-sources project --model haiku --strict-mcp-config in <lab>/project with --permission-mode default unless a case sets one; user hooks, rules and auto mode not loaded; every file target is a disposable fixture under <lab>, except that plan cases let Claude write its own plan file to ~/.claude/plans (removed by hand after the runs); web cases fetch only example.com (one via an httpbin.org redirect) and search only for \"example domain\"; MCP cases use scripts/claude-permission-lab/lab_mcp_server.py",
    "cases": cases,
}
with open(OUT, "w") as f:
    json.dump(report, f, indent=2)
    f.write("\n")
print("wrote", os.path.relpath(OUT, REPO))
