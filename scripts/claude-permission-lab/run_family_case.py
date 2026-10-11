"""Drive interactive Claude Code through one permission-family case (issues #72-#75).

Usage: python3 -I run_family_case.py <case> [--wait S]
       python3 -I run_family_case.py --list [family]     families: file (#72), web (#73), plan (#74), mcp (#75)

Each case names a tool action, a companion decision for every PermissionRequest it raises, and optional
project permission rules or mode. The companion is this script, writing receipt/decision records for
lab_helper.py (the #71 stand-in for SteerHook's Claude approval protocol). Decisions:
  allow / deny     receipt, then that decision 2 s later
  handoff          receipt, then no_decision 2 s later; the native prompt is then answered No (Esc)
  observe          no receipt; any native prompt is answered No (Esc) 3 s after it appears
A case may limit its decision to one tool ("decide_tool"); requests for other tools are observed. MCP cases
start lab_mcp_server.py through --mcp-config; "kill_mcp" kills that server after the receipt, before the decision.

Isolation: Claude runs with --setting-sources project in output/claude-file-lab/project, whose
.claude/settings.json registers only lab_helper.py. User hooks, rules and auto mode are not loaded, and no
user settings file changes. Every file read or written is a disposable lab file under output/claude-file-lab. Web cases fetch only
example.com (and one httpbin.org redirect to it) and search only for "example domain".
Results go to output/claude-file-lab/runs/<case>.json.
"""
import hashlib, json, os, pty, re, select, shutil, signal, struct, sys, time, fcntl, termios

S = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(S, "..", ".."))
LAB = os.path.join(REPO, "output", "claude-file-lab")
PROJECT = os.path.join(LAB, "project")
OUTSIDE = os.path.join(LAB, "outside")
RUNS = os.path.join(LAB, "runs")

ONLY = " Do not use any other tool except Read on a file inside the current folder. If it is not permitted, do not retry. Then reply only DONE."
ANY = " Do not use any other tool, except ToolSearch if you need it to load the tool. If it is not permitted, do not retry. Then reply only DONE."
PLAN = ("Without reading or searching any files, write a one-line plan to create plan.txt containing the word lab, and present it"
        " with ExitPlanMode immediately. If the plan is not approved, stop and reply only DONE.")
REDIRECT = "https://httpbin.org/redirect-to?url=https%3A%2F%2Fexample.com%2F"
# Outside-folder cases name an absolute path the lab owns; the call itself is the point of the case.
OUT = (" The path is a disposable lab fixture and you are allowed to request access to it. Make the call even though it"
       " is outside the current folder. Do not use any other tool. If it is not permitted, do not retry. Then reply only DONE.")
CASES = {
    # Edit of a project file: needs a prior in-project Read, which does not prompt.
    "edit-allow": ("Read target.txt, then use the Edit tool exactly once to change the word alpha to beta in target.txt." + ONLY, "allow", {}),
    "edit-deny": ("Read target.txt, then use the Edit tool exactly once to change the word alpha to beta in target.txt." + ONLY, "deny", {}),
    "edit-handoff": ("Read target.txt, then use the Edit tool exactly once to change the word alpha to beta in target.txt." + ONLY, "handoff", {}),
    "notebook-allow": ("Read nb.ipynb, then use the NotebookEdit tool exactly once to replace the source of the only cell in nb.ipynb with print(2)." + ONLY, "allow", {}),
    "notebook-deny": ("Read nb.ipynb, then use the NotebookEdit tool exactly once to replace the source of the only cell in nb.ipynb with print(2)." + ONLY, "deny", {}),
    "write-outside-allow": ("Use the Write tool exactly once to create {outside}/created.txt with the exact content lab ." + OUT, "allow", {}),
    "write-outside-deny": ("Use the Write tool exactly once to create {outside}/created.txt with the exact content lab ." + OUT, "deny", {}),
    "read-outside-allow": ("Use the Read tool exactly once to read {outside}/outside.txt and report its first word." + OUT, "allow", {}),
    "read-outside-deny": ("Use the Read tool exactly once to read {outside}/outside.txt and report its first word." + OUT, "deny", {}),
    "read-outside-handoff": ("Use the Read tool exactly once to read {outside}/outside.txt and report its first word." + OUT, "handoff", {}),
    "grep-outside": ("Use the Grep tool exactly once to search for the word gamma with path {outside}." + OUT, "observe", {}),
    "glob-outside": ("Use the Glob tool exactly once with pattern *.txt and path {outside}." + OUT, "observe", {}),
    # Policy: a hook allow against an ask rule, and a deny rule that should stop the request before the hook.
    "edit-ask-rule-allow": ("Read target.txt, then use the Edit tool exactly once to change the word alpha to beta in target.txt." + ONLY, "allow",
                            {"permissions": {"ask": ["Edit"]}}),
    "edit-deny-rule": ("Read target.txt, then use the Edit tool exactly once to change the word alpha to beta in target.txt." + ONLY, "observe",
                       {"permissions": {"deny": ["Edit"]}}),
    # Mode: acceptEdits should approve an in-project Edit without a request.
    "edit-accept-edits": ("Read target.txt, then use the Edit tool exactly once to change the word alpha to beta in target.txt." + ONLY, "observe",
                          {"mode": "acceptEdits"}),
    # #72 gaps.
    "write-overwrite-allow": ("Read target.txt, then use the Write tool exactly once to overwrite target.txt with the exact content lab ." + ONLY, "allow", {}),
    "read-outside-range-allow": ("Use the Read tool exactly once to read {outside}/outside.txt with offset 1 and limit 1." + OUT, "allow", {}),
    "notebook-insert-allow": ("Read nb.ipynb, then use the NotebookEdit tool exactly once to insert a new code cell with source print(3) after cell c1 in nb.ipynb." + ONLY, "allow", {}),
    "notebook-delete-allow": ("Read nb.ipynb, then use the NotebookEdit tool exactly once to delete cell c1 in nb.ipynb." + ONLY, "allow", {}),
    # #73 web.
    "webfetch-allow": ("Use the WebFetch tool exactly once to fetch https://example.com/ and report its title." + ANY, "allow", {}),
    "webfetch-deny": ("Use the WebFetch tool exactly once to fetch https://example.com/ and report its title." + ANY, "deny", {}),
    "webfetch-handoff": ("Use the WebFetch tool exactly once to fetch https://example.com/ and report its title." + ANY, "handoff", {}),
    "webfetch-redirect-allow": ("Use the WebFetch tool to fetch " + REDIRECT + " and report the final page title. If WebFetch reports a redirect,"
                                " fetch the redirect target once with WebFetch." + ANY, "allow", {}),
    "webfetch-domain-deny-rule": ("Use the WebFetch tool exactly once to fetch https://example.com/ and report its title." + ANY, "observe",
                                  {"permissions": {"deny": ["WebFetch(domain:example.com)"]}}),
    "websearch-allow": ("Use the WebSearch tool exactly once to search for: example domain." + ANY, "allow", {}),
    "websearch-deny": ("Use the WebSearch tool exactly once to search for: example domain." + ANY, "deny", {}),
    "websearch-handoff": ("Use the WebSearch tool exactly once to search for: example domain." + ANY, "handoff", {}),
    # #74 plan approval, in plan mode. Only ExitPlanMode is decided; any follow-up request is observed (native No).
    "plan-allow": (PLAN, "allow", {"mode": "plan", "decide_tool": "ExitPlanMode"}),
    "plan-deny": (PLAN, "deny", {"mode": "plan", "decide_tool": "ExitPlanMode"}),
    "plan-handoff": (PLAN, "handoff", {"mode": "plan", "decide_tool": "ExitPlanMode"}),
    # #75 one bounded lab MCP tool.
    "mcp-allow": ("Use the lab_echo MCP tool exactly once with text hello." + ANY, "allow", {"mcp": True}),
    "mcp-deny": ("Use the lab_echo MCP tool exactly once with text hello." + ANY, "deny", {"mcp": True}),
    "mcp-handoff": ("Use the lab_echo MCP tool exactly once with text hello." + ANY, "handoff", {"mcp": True}),
    "mcp-user-interaction-allow": ("Use the lab_confirm MCP tool exactly once with text hello." + ANY, "allow", {"mcp": True}),
    "mcp-server-loss-allow": ("Use the lab_echo MCP tool exactly once with text hello." + ANY, "allow", {"mcp": True, "kill_mcp": True}),
}
FAMILIES = {"file": ("edit", "notebook", "write", "read", "grep", "glob"), "web": ("webfetch", "websearch"),
            "plan": ("plan",), "mcp": ("mcp",)}

def family(case):
    return next(f for f, prefixes in FAMILIES.items() if case.split("-")[0] in prefixes)

if "--list" in sys.argv:
    wanted = sys.argv[sys.argv.index("--list") + 1:]
    print("\n".join(c for c in CASES if not wanted or family(c) in wanted)); sys.exit(0)
CASE = sys.argv[1]
WAIT = float(sys.argv[sys.argv.index("--wait") + 1]) if "--wait" in sys.argv else 75
prompt_text, DECISION, extra = CASES[CASE]
prompt = prompt_text.format(outside=OUTSIDE)
EVENTS = os.path.join(LAB, "events", CASE)
CLAUDE = shutil.which("claude", path="/opt/homebrew/bin:/usr/local/bin:" + os.path.expanduser("~/.local/bin") + ":" + os.environ.get("PATH", ""))

# Fresh disposable fixtures for every case.
shutil.rmtree(EVENTS, ignore_errors=True); os.makedirs(EVENTS)
os.makedirs(RUNS, exist_ok=True)
shutil.rmtree(OUTSIDE, ignore_errors=True); os.makedirs(OUTSIDE)
os.makedirs(os.path.join(PROJECT, ".claude"), exist_ok=True)
for name in os.listdir(PROJECT):
    if name != ".claude":
        os.unlink(os.path.join(PROJECT, name))
FIXTURES = {
    os.path.join(PROJECT, "target.txt"): "alpha\n",
    os.path.join(PROJECT, "nb.ipynb"): json.dumps({"cells": [{"cell_type": "code", "id": "c1", "metadata": {}, "execution_count": None,
                                                               "outputs": [], "source": ["print(1)"]}],
                                                    "metadata": {}, "nbformat": 4, "nbformat_minor": 5}, indent=1) + "\n",
    os.path.join(OUTSIDE, "outside.txt"): "gamma lab file\n",
}
for path, content in FIXTURES.items():
    with open(path, "w") as f: f.write(content)
WATCHED = list(FIXTURES) + [os.path.join(OUTSIDE, "created.txt"), os.path.join(PROJECT, "plan.txt")]
DECIDE_TOOL = extra.get("decide_tool")
MCP_CONFIG = os.path.join(EVENTS, "mcp.json")
with open(MCP_CONFIG, "w") as f:
    servers = {"steer-lab": {"command": "/usr/bin/python3", "args": ["-I", os.path.join(S, "lab_mcp_server.py"), EVENTS]}}
    json.dump({"mcpServers": servers if extra.get("mcp") else {}}, f)

def digest(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()[:12] if os.path.exists(path) else None

before = {os.path.relpath(p, LAB): digest(p) for p in WATCHED}
hook = f"/usr/bin/python3 -I {json.dumps(os.path.join(S, 'lab_helper.py'))} {json.dumps(EVENTS)}"
entry = [{"hooks": [{"type": "command", "command": hook, "timeout": 45}]}]
settings = {"permissions": {"defaultMode": "default", **extra.get("permissions", {})},
            "hooks": {e: entry for e in ("PermissionRequest", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                                         "Notification", "UserPromptSubmit", "Stop", "SessionStart",
                                         "PermissionDenied", "PostToolBatch", "StopFailure", "SessionEnd")}}
with open(os.path.join(PROJECT, ".claude", "settings.json"), "w") as f:
    json.dump(settings, f, indent=2)

timeline = []
def note(event, **kw):
    timeline.append({"t": time.time(), "event": event, **kw})

def atomic(path, obj):
    tmp = os.path.join(EVENTS, ".drv-" + str(time.time_ns()))
    with open(tmp, "w") as f: json.dump(obj, f)
    os.link(tmp, path); os.unlink(tmp)

def requests():
    out = []
    for name in sorted(os.listdir(EVENTS)):
        if name.endswith(".request"):
            try: out.append(json.load(open(os.path.join(EVENTS, name))))
            except Exception: pass
    return sorted(out, key=lambda r: r["published_at"])

def hooks():
    path = os.path.join(EVENTS, "hooks.jsonl")
    return [json.loads(l) for l in open(path)] if os.path.exists(path) else []

text = b""
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    for name in [n for n in os.environ if n == "CLAUDECODE" or n.startswith(("CLAUDE_CODE_", "CLAUDE_PID", "CLAUDE_EFFORT"))]:
        del os.environ[name]
    os.chdir(PROJECT)
    os.execv(CLAUDE, ["claude", "--setting-sources", "project", "--permission-mode", extra.get("mode", "default"),
                      "--model", "haiku", "--strict-mcp-config", "--mcp-config", MCP_CONFIG])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))

def pump(seconds):
    global text
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if fd in r:
            try: chunk = os.read(fd, 65536)
            except OSError: return
            if not chunk: return
            text += chunk

def screen(n=6000):
    return re.sub(rb"\x1b\[[0-9;?<>=]*[A-Za-z]|\x1b\][^\x07]*\x07", b" ", text[-n:]).decode("utf-8", "replace")

prompts_seen = []
def native_prompt_open():
    return bool(re.search(r"Do you want|Would you like to proceed|Esc to cancel", screen(2500)))

def capture_prompt(label):
    # The text Claude's own dialog shows, for the display contract.
    lines = [re.sub(r"\s+", " ", l).strip() for l in screen(4000).splitlines()]
    lines = [l for l in lines if l][-18:]
    prompts_seen.append({"at": label, "lines": lines})

try:
    pump(6)
    if re.search(r"trust (the files in )?this folder", screen(), re.I):
        os.write(fd, b"\r"); pump(4)
    data = prompt.encode()
    for i in range(0, len(data), 32):
        os.write(fd, data[i:i + 32]); pump(0.08)
    pump(0.8); os.write(fd, b"\r"); note("prompt_submitted")
    started, steps, native_since = time.time(), {}, None
    while time.time() - started < WAIT:
        pump(0.3)
        now = time.time()
        for r in requests():
            rid = r["request_id"]
            if rid in steps: continue
            decide = DECISION != "observe" and DECIDE_TOOL in (None, r.get("tool_name"))
            steps[rid] = {"seen": now, "decide": decide}
            note("request_seen", request_id=rid, tool=r.get("tool_name"), decided_by_companion=decide)
            if decide:
                atomic(os.path.join(EVENTS, rid + ".receipt"), {"request_id": rid, "received_at": now, "expires_at": now + 30})
                note("companion_receipt", request_id=rid)
                if extra.get("kill_mcp"):
                    # Server loss while the request waits: kill the lab MCP server before deciding.
                    import subprocess
                    subprocess.run(["pkill", "-f", "lab_mcp_server.py " + EVENTS]); note("mcp_server_killed")
        for rid, step in steps.items():
            if step["decide"] and "decided" not in step and now - step["seen"] >= 2:
                if native_prompt_open(): capture_prompt("before_decision")
                kind = "no_decision" if DECISION == "handoff" else DECISION
                atomic(os.path.join(EVENTS, rid + ".decision"), {"request_id": rid, "decision": kind, "decided_at": now})
                note("companion_decision", request_id=rid, decision=kind); step["decided"] = now
        # Native prompt with no pending companion decision: answer it No after 3 s.
        pending = any(s["decide"] and "decided" not in s for s in steps.values())
        if native_prompt_open() and not pending:
            native_since = native_since or now
            if now - native_since >= 3:
                capture_prompt("native_before_no")
                os.write(fd, b"\x1b"); note("native_no_esc"); native_since = None; pump(1.5)
        else:
            native_since = None
        if any(h["event"] == "Stop" for h in hooks()) and (steps or DECISION == "observe") and now - started > 6:
            pump(1.5); break
        # A native No fires no hook (#71), so stop waiting for Stop a few seconds after it.
        last_no = [e["t"] for e in timeline if e["event"] == "native_no_esc"]
        if last_no and now - last_no[-1] >= 6 and not native_prompt_open():
            break
    note("case_end")
    os.write(fd, b"\x03"); pump(0.5); os.write(fd, b"\x03"); pump(2)
finally:
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: pass

after = {os.path.relpath(p, LAB): digest(p) for p in WATCHED}
records = {n: json.load(open(os.path.join(EVENTS, n))) for n in sorted(os.listdir(EVENTS))
           if n.endswith((".request", ".receipt", ".decision", ".delivery"))}
result = {"case": CASE, "decision": DECISION, "extra": extra, "prompt": prompt.replace(LAB, "<lab>"),
          "files_before": before, "files_after": after, "timeline": timeline, "hooks": hooks(),
          "records": records, "native_prompts": prompts_seen,
          "mcp_calls": [json.loads(l) for l in open(os.path.join(EVENTS, "mcp-calls.jsonl"))]
                       if os.path.exists(os.path.join(EVENTS, "mcp-calls.jsonl")) else [],
          "final_screen": [l for l in (re.sub(r"\s+", " ", l).strip() for l in screen(5000).splitlines()) if l][-25:]}
with open(os.path.join(RUNS, CASE + ".json"), "w") as f:
    json.dump(result, f, indent=2)

def short(h):
    keep = ("event", "tool_name", "tool_use_id", "request_id", "outcome", "decision", "permission_mode", "targets", "tool_input_shape")
    return {k: h[k] for k in keep if h.get(k) is not None}
print(json.dumps({"case": CASE, "changed": {k: (before[k], after[k]) for k in before if before[k] != after[k]}}))
for h in result["hooks"]:
    if h["event"] not in ("SessionStart", "UserPromptSubmit"):
        print(f"{h['t'] - timeline[0]['t']:6.2f}", short(h))
for e in timeline: print(f"{e['t'] - timeline[0]['t']:6.2f}", e["event"], {k: v for k, v in e.items() if k not in ("t", "event")})
for p in prompts_seen:
    print("--- native prompt", p["at"]); print("\n".join(p["lines"]))
