"""Drive interactive Claude Code in a pty through one issue #71 permission case.

Usage: python3 -I run_case.py <case> [--wait S]

Cases (the companion is this script; it writes receipt/decision records for lab_helper.py):
  explore      receipt only, then cancel the native prompt after the helper's deadline; records shapes
  allow        receipt, allow after 2 s
  deny         receipt, deny after 2 s
  handoff      receipt, no_decision after 2 s, then answer the native prompt Yes
  native       receipt, native Yes at 3 s while the helper waits, then a late companion deny at 6 s
  native-no    receipt, native No (Esc) at 3 s while the helper waits; record what Claude reports afterwards
  native-no-3  as native-no, but choose the dialog's "No" option with the 3 key
  timeout      receipt only; helper hands back at 30 s; then native No
  helper-loss  receipt, SIGKILL the helper at 3 s, then native No
  overlap      two identical Write calls in one turn (Claude runs them one after another): receipt the first,
               native Yes at 3 s while its helper waits; when the second request exists, receipt it, send a late
               allow for the FIRST, then deny the SECOND 3 s later

Isolation: Claude runs with --setting-sources project in output/claude-permission-lab/project, whose
.claude/settings.json registers only lab_helper.py. User hooks, permission rules and auto mode are not
loaded and nothing under ~/.claude/settings.json changes. Writes go only to the lab project.
"""
import glob, json, os, pty, re, select, signal, shutil, struct, sys, time, fcntl, termios

CASE = sys.argv[1]
WAIT = float(sys.argv[sys.argv.index("--wait") + 1]) if "--wait" in sys.argv else 75
S = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(S, "..", ".."))
LAB = os.path.join(REPO, "output", "claude-permission-lab")
PROJECT = os.path.join(LAB, "project")
EVENTS = os.path.join(LAB, "events", CASE)
RUNS = os.path.join(LAB, "runs")
CLAUDE = shutil.which("claude", path="/opt/homebrew/bin:/usr/local/bin:" + os.path.expanduser("~/.local/bin") + ":" + os.environ.get("PATH", ""))

shutil.rmtree(EVENTS, ignore_errors=True)
os.makedirs(EVENTS)
os.makedirs(RUNS, exist_ok=True)
os.makedirs(os.path.join(PROJECT, ".claude"), exist_ok=True)
hook = f"/usr/bin/python3 -I {json.dumps(os.path.join(S, 'lab_helper.py'))} {json.dumps(EVENTS)}"
entry = [{"hooks": [{"type": "command", "command": hook, "timeout": 45}]}]
settings = {"permissions": {"defaultMode": "default"},
            "hooks": {e: entry for e in ("PermissionRequest", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                                         "Notification", "UserPromptSubmit", "Stop", "SessionStart",
                                         "PermissionDenied", "PostToolBatch", "StopFailure", "SessionEnd")}}
with open(os.path.join(PROJECT, ".claude", "settings.json"), "w") as f:
    json.dump(settings, f, indent=2)
for name in os.listdir(PROJECT):
    if name.startswith("marker-"):
        os.unlink(os.path.join(PROJECT, name))

marker = f"marker-{CASE}.txt"
if CASE == "overlap":
    prompt = (f"In ONE response, issue two Write tool calls in parallel, both creating {marker} with the exact content "
              "lab . Do not use Bash or any other tool. If a write is not permitted, do not retry. Then reply only DONE.")
else:
    prompt = (f"Use the Write tool exactly once to create {marker} with the exact content lab . Do not use Bash or "
              "any other tool. If the write is not permitted, do not retry. Then reply only DONE.")

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

def receipt(rid):
    now = time.time()
    atomic(os.path.join(EVENTS, rid + ".receipt"), {"request_id": rid, "received_at": now, "expires_at": now + 30})
    note("companion_receipt", request_id=rid)

def decide(rid, decision):
    atomic(os.path.join(EVENTS, rid + ".decision"), {"request_id": rid, "decision": decision, "decided_at": time.time()})
    note("companion_decision", request_id=rid, decision=decision)

def helper_pid(rid):
    for line in open(os.path.join(EVENTS, "hooks.jsonl")):
        e = json.loads(line)
        if e.get("request_id") == rid: return e["pid"]

raw = open(os.path.join(RUNS, CASE + ".tty"), "wb")
import threading
registry_changes = []
def watch_registry():
    # Every status change in Claude's session registry, polled every 25 ms.
    last = None
    while not stop_watch.is_set():
        try:
            r = registry()
        except Exception as error:
            registry_changes.append({"t": time.time(), "status": "watch-error " + repr(error), "statusUpdatedAt": 0})
            return
        state = (r.get("status"), r.get("statusUpdatedAt"))
        if "status" in r and state != last:
            last = state
            registry_changes.append({"t": time.time(), "status": r["status"],
                                     "statusUpdatedAt": (r.get("statusUpdatedAt") or 0) / 1000})
        time.sleep(0.025)
stop_watch = threading.Event()
text = b""
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    # Run as a normal top-level session even when launched from inside another Claude Code session,
    # which marks children as nested (no session registry entry or transcript).
    for name in [n for n in os.environ if n == "CLAUDECODE" or n.startswith(("CLAUDE_CODE_", "CLAUDE_PID", "CLAUDE_EFFORT"))]:
        del os.environ[name]
    os.chdir(PROJECT)
    os.execv(CLAUDE, ["claude", "--setting-sources", "project", "--permission-mode", "default",
                      "--model", "haiku", "--strict-mcp-config"])
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
            raw.write(chunk); raw.flush(); text += chunk

def screen(n=6000):
    return re.sub(rb"\x1b\[[0-9;?<>=]*[A-Za-z]|\x1b\][^\x07]*\x07", b" ", text[-n:]).decode("utf-8", "replace")

def registry():
    # Claude's live session registry, found by the session id the hooks reported.
    try:
        sid = next(json.loads(l)["session_id"] for l in open(os.path.join(EVENTS, "hooks.jsonl")))
        for path in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
            o = json.load(open(path))
            if o.get("sessionId") == sid:
                return {k: o.get(k) for k in ("status", "kind", "statusUpdatedAt")}
        return {"unavailable": "no entry"}
    except Exception as error:
        return {"unavailable": type(error).__name__}

def key(data, label):
    note("registry_before_key", key=label, registry=registry())
    os.write(fd, data); note("native_key", key=label); pump(0.5)
    if label.startswith("native"):
        for delay in (0.5, 2.5):
            pump(delay); note("registry_after_key", key=label, after=delay + 0.5, registry=registry())

threading.Thread(target=watch_registry, daemon=True).start()
try:
    pump(6)
    if re.search(r"trust (the files in )?this folder", screen(), re.I):
        key(b"\r", "trust-folder-enter"); pump(4)
    data = prompt.encode()
    for i in range(0, len(data), 32):
        os.write(fd, data[i:i + 32]); pump(0.08)
    pump(0.8); os.write(fd, b"\r"); note("prompt_submitted")
    started, handled, step = time.time(), set(), {}
    while time.time() - started < WAIT:
        pump(0.3)
        reqs = requests()
        for r in reqs:
            rid = r["request_id"]
            if rid in handled: continue
            handled.add(rid)
            note("request_seen", request_id=rid, tool=r.get("tool_name"), tool_use_id=r.get("tool_use_id"))
            if CASE == "overlap" and "first" in step:
                receipt(rid); step.update(second=rid, second_at=time.time())
                decide(step["first"], "allow")  # late answer to the first, now that the second exists
                continue
            receipt(rid); step = {"rid": rid, "at": time.time()}
            if CASE == "overlap": step["first"] = rid
        if step and "done" not in step:
            age = time.time() - step["at"]
            if CASE in ("allow", "deny") and age >= 2:
                decide(step["rid"], CASE); step["done"] = 1
            elif CASE == "handoff" and age >= 2:
                decide(step["rid"], "no_decision"); step["done"] = 1; step["native_at"] = time.time() + 2
            elif CASE == "native" and age >= 3 and "native" not in step:
                key(b"1", "native-yes"); step["native"] = 1
            elif CASE in ("native-no", "native-no-3") and age >= 3 and "native" not in step:
                key(b"3" if CASE == "native-no-3" else b"\x1b", "native-no-" + ("3" if CASE == "native-no-3" else "esc"))
                step["native"] = 1
            elif CASE in ("native-no", "native-no-3") and age >= 12:
                step["done"] = 1; step["native_answered"] = 1
            elif CASE == "native" and age >= 6:
                decide(step["rid"], "deny"); step["done"] = 1
            elif CASE == "helper-loss" and age >= 3:
                p = helper_pid(step["rid"])
                os.kill(p, signal.SIGKILL); note("helper_killed", pid=p); step["done"] = 1; step["native_at"] = time.time() + 3
            elif CASE in ("timeout", "explore") and age >= 33:
                step["done"] = 1; step["native_at"] = time.time()
            elif CASE == "overlap" and age >= 3 and "native" not in step:
                key(b"1", "native-yes-first"); step["native"] = 1
            elif CASE == "overlap" and "second_at" in step and time.time() - step["second_at"] >= 3:
                decide(step["second"], "deny"); step["done"] = 1
        if step.get("native_at") and time.time() >= step["native_at"] and "native_answered" not in step:
            if re.search(r"Do you want", screen(3000)):
                key(b"1" if CASE == "handoff" else b"\x1b", "native-yes" if CASE == "handoff" else "native-no-esc")
            else:
                note("no_native_prompt_visible")
            step["native_answered"] = 1
        if CASE in ("native-no", "native-no-3") and "native_answered" in step: break
        if "native_answered" in step or (step.get("done") and CASE in ("allow", "deny", "native", "overlap")):
            if re.search(r"DONE", screen(2500)) and time.time() - step["at"] > 4: break
    for line in open(os.path.join(EVENTS, "hooks.jsonl")):
        tp = json.loads(line).get("transcript_path")
        if tp:
            break
    # Before exit: did Claude record the call's result where a helper could see it?
    found = []
    if tp and os.path.exists(tp):
        for line in open(tp):
            o = json.loads(line)
            content = (o.get("message") or {}).get("content") if isinstance(o.get("message"), dict) else None
            for b in content if isinstance(content, list) else []:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    found.append({"tool_use_id": b.get("tool_use_id"), "is_error": b.get("is_error"),
                                  "timestamp": o.get("timestamp")})
    note("transcript_tool_results", exists=bool(tp and os.path.exists(tp)), results=found)
    stop_watch.set()
    for change in registry_changes:
        timeline.append({"t": change["t"], "event": "registry_status", "status": change["status"],
                         "status_updated_at": change["statusUpdatedAt"]})
    timeline.sort(key=lambda e: e["t"])
    note("case_end")
    pump(2)
    key(b"\x03", "ctrl-c"); key(b"\x03", "ctrl-c"); pump(2)
finally:
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: pass

hooks = [json.loads(l) for l in open(os.path.join(EVENTS, "hooks.jsonl"))] if os.path.exists(os.path.join(EVENTS, "hooks.jsonl")) else []
records = {}
for name in sorted(os.listdir(EVENTS)):
    if name.endswith((".request", ".receipt", ".decision", ".delivery", ".live")):
        records[name] = json.load(open(os.path.join(EVENTS, name)))
result = {"case": CASE, "marker": marker, "marker_exists": os.path.exists(os.path.join(PROJECT, marker)),
          "marker_content": open(os.path.join(PROJECT, marker)).read() if os.path.exists(os.path.join(PROJECT, marker)) else None,
          "timeline": timeline, "hooks": hooks, "records": records}
json.dump(result, open(os.path.join(RUNS, CASE + ".json"), "w"), indent=2)
plain = screen(len(text))
excerpt = [l.strip() for l in plain.splitlines() if re.search(r"Do you want|Write|DONE|denied|hook|permission|Yes|No,", l, re.I)]
print(json.dumps({k: result[k] for k in ("case", "marker_exists", "marker_content")}))
for e in timeline: print(f"{e['t']:.3f}", e["event"], {k: v for k, v in e.items() if k not in ('t', 'event')})
for h in hooks: print(f"{h['t']:.3f}", "hook", {k: v for k, v in h.items() if v is not None and k not in ('t', 'keys')})
print("PermissionRequest keys:", next((h["keys"] for h in hooks if h["event"] == "PermissionRequest"), None))
print("--- screen excerpts ---")
seen = set()
for l in excerpt:
    l = re.sub(r"\s+", " ", l)[:180]
    if l not in seen: seen.add(l); print(l)
