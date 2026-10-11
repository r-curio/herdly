"""iTerm2 live targeting proof for issue #204.

Usage: python3 -I iterm2_lab.py --lab-root <dir> [--keep]

Creates its own iTerm2 windows, starts one disposable Codex CLI session and one disposable
Claude Code session in them, and records what iTerm2's AppleScript surface reports: session
GUIDs, ttys, OSC titles, foreground jobs, select/activate read-back, focus while another app is
frontmost, and where `write text` lands. Every write goes to a session this script created and
named by GUID; afterwards the contents of every iTerm2 session (including ones it did not
create) are checked for the probe nonce.

Isolation: Codex runs read-only with approvals never in <lab-root>/project (inside a trusted
checkout). Claude runs with --setting-sources project in <lab-root>/claude-project, whose
.claude/settings.json registers only claude_title_hook.py. Nothing under ~/.codex or ~/.claude
is written by this script. Raw results go to <lab-root>/iterm2/run.json.

Keep the keyboard and mouse idle while it runs: select checks move focus. Launch iTerm2 with a
clean environment first (`env -i HOME="$HOME" USER="$USER" /usr/bin/open -a iTerm`): `open`
passes the caller's environment, so an iTerm2 started from an agent session hands that agent's
variables to every shell. The lab refuses to run if a lab shell sees CLAUDE*/CODEX* variables.
Teardown ends the lab sessions' processes, but iTerm2 can keep their emptied tabs on screen;
stop iTerm2 after a run if they remain.
"""
import argparse, glob, json, os, re, secrets, subprocess, sys, time

S = os.path.dirname(os.path.abspath(__file__))
DRIVER = os.path.join(S, "iterm2.js")
CODEX = os.path.expanduser("~/.local/bin/codex")
CLAUDE = os.path.expanduser("~/.local/bin/claude")
CODEX_TITLE = re.compile(r"^[0-9a-f-]{29}\.\.\.$")

ap = argparse.ArgumentParser()
ap.add_argument("--lab-root", required=True)
ap.add_argument("--keep", action="store_true", help="leave lab windows open")
args = ap.parse_args()
LAB = os.path.abspath(args.lab_root)
OUT = os.path.join(LAB, "iterm2")
PROJ = os.path.join(LAB, "project")
CPROJ = os.path.join(LAB, "claude-project")
EVENTS = os.path.join(OUT, "claude-events")
NONCE = secrets.token_hex(4)
log = {"nonce": NONCE, "started": time.time(), "steps": []}


def it(op, **kw):
    r = subprocess.run(["osascript", "-l", "JavaScript", DRIVER, json.dumps({"op": op, **kw})],
                       capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:300])
    return json.loads(r.stdout)


def try_it(op, **kw):
    try:
        return {"ok": True, "result": it(op, **kw)}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def front_app():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(["lsappinfo", "info", "-only", "bundleid", asn], capture_output=True, text=True).stdout
    m = re.search(r'"CFBundleIdentifier"="([^"]+)"', info)
    return m.group(1) if m else info.strip()


def step(name, **data):
    data = {"step": name, "at": round(time.time() - log["started"], 2), **data}
    log["steps"].append(data)
    print(json.dumps(data)[:400], flush=True)
    return data


def wait_for(fn, timeout, interval=1.0):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(interval)
    return None


def session_of(inv, sid):
    return next((s for s in inv["sessions"] if s["session"] == sid), None)


def contents(sid):
    return it("contents", session=sid)["text"]


def raise_other_app():
    subprocess.run(["open", "-a", "Finder"], check=True)
    wait_for(lambda: front_app() == "com.apple.finder", 5, 0.2)


# --- setup ---------------------------------------------------------------------------------
os.makedirs(EVENTS, exist_ok=True)
os.makedirs(PROJ, exist_ok=True)
os.makedirs(os.path.join(CPROJ, ".claude"), exist_ok=True)
for f in glob.glob(os.path.join(EVENTS, "*.json")):
    os.unlink(f)
with open(os.path.join(PROJ, "README.md"), "w") as f:
    f.write("Disposable project for Steer terminal-host live proofs.\n")
hook = f"/usr/bin/python3 -I {json.dumps(os.path.join(S, 'claude_title_hook.py'))} {json.dumps(EVENTS)}"
with open(os.path.join(CPROJ, ".claude", "settings.json"), "w") as f:
    json.dump({"env": {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"},
               "hooks": {e: [{"hooks": [{"type": "command", "command": hook, "timeout": 10}]}]
                         for e in ("SessionStart", "UserPromptSubmit", "Stop")}}, f, indent=2)

step("version", **it("version"), front=front_app())
before = it("inventory")
preexisting = [s["session"] for s in before["sessions"]]
step("preexisting", count=len(preexisting))

A = it("newWindow")                                   # A1: Codex
A2 = it("newTab", window=A["window"])                 # A2: Claude
A3 = it("newTab", window=A["window"])                 # A3: decoy with Codex's title
A4 = it("newTab", window=A["window"])                 # A4a + A4b: split tab
A4b = it("split", session=A4["session"])
B = it("newWindow")                                   # B1: shell in a second window
lab = {"A1": A["session"], "A2": A2["session"], "A3": A3["session"], "A4a": A4["session"],
       "A4b": A4b["session"], "B1": B["session"]}
step("created", windows=[A["window"], B["window"]], sessions=lab)
time.sleep(2)

for key, sid in lab.items():
    it("write", session=sid, text=f"printf '%s' \"$ITERM_SESSION_ID\" > {json.dumps(os.path.join(OUT, 'env-' + key))}; "
                                  f"env | cut -d= -f1 | grep -E '^(CLAUDE|CODEX)' > {json.dumps(os.path.join(OUT, 'leak-' + key))}")
time.sleep(2)
leaks = {}
for key in lab:
    try:
        with open(os.path.join(OUT, "leak-" + key)) as f:
            names = f.read().split()
    except OSError:
        names = ["<unreadable>"]
    if names:
        leaks[key] = names
step("env_clean", leaks=leaks)
if leaks:
    sys.exit("iTerm2 shells inherited agent variables; relaunch iTerm2 with a clean environment")

it("write", session=lab["A1"], text=f"cd {json.dumps(PROJ)} && exec {CODEX} -C {json.dumps(PROJ)} -s read-only -a never 'Reply with only the word READY.'")
it("write", session=lab["A2"], text=f"cd {json.dumps(CPROJ)} && exec {CLAUDE} --setting-sources project 'Reply with only the word READY.'")

# --- C1/C2: Codex title, Claude title, foreground jobs ---------------------------------------
codex_title = wait_for(lambda: (lambda s: s and s["terminalIconName"] and CODEX_TITLE.match(s["terminalIconName"]) and s["terminalIconName"])(session_of(it("inventory"), lab["A1"])), 90, 2)
step("codex_title", title=codex_title)
claude_title = wait_for(lambda: (lambda s: s and (s["terminalWindowName"] or "").startswith("Steer Claude ") and s["terminalWindowName"])(session_of(it("inventory"), lab["A2"])), 90, 2)
step("claude_title", title=claude_title)
wait_for(lambda: "READY" in contents(lab["A1"]).split("Reply with only the word READY.")[-1], 90, 2)
wait_for(lambda: "READY" in contents(lab["A2"]).split("Reply with only the word READY.")[-1], 90, 2)

rollouts = sorted(glob.glob(os.path.expanduser("~/.codex/sessions/*/*/*/rollout-*.jsonl")), key=os.path.getmtime)[-20:]
codex_ids = []
for path in rollouts:
    try:
        with open(path) as f:
            meta = json.loads(f.readline())
    except (OSError, ValueError):
        continue
    if meta.get("payload", {}).get("cwd") == PROJ:
        codex_ids.append(meta["payload"].get("id"))
step("codex_rollout_ids", ids=codex_ids[-3:])
claude_events = []
for path in sorted(glob.glob(os.path.join(EVENTS, "*.json"))):
    with open(path) as f:
        claude_events.append(json.load(f))
step("claude_hook_events", events=claude_events)
env = {}
for key in lab:
    try:
        with open(os.path.join(OUT, "env-" + key)) as f:
            env[key] = f.read()
    except OSError:
        env[key] = None
step("iterm_session_id_env", env=env)

# Decoy: another session carrying Codex's exact title, running a non-Codex job.
if codex_title:
    it("write", session=lab["A3"], text=f"printf '\\033]0;%s\\007' '{codex_title}'; exec sleep 3600")
time.sleep(2)
def ps_foreground(tty):
    # Processes in the tty's foreground process group carry '+' in their state.
    rows = subprocess.run(["ps", "-o", "pid=,stat=,comm=", "-t", tty.removeprefix("/dev/")],
                          capture_output=True, text=True).stdout.splitlines()
    return [os.path.basename(r.split(None, 2)[2]) for r in rows if len(r.split(None, 2)) == 3 and "+" in r.split(None, 2)[1]]


def job_snapshot(label):
    inv = it("inventory")
    rows = [{"key": k, "jobName": s["jobName"], "deepestJob": s["deepestJob"], "processTitle": s["processTitle"],
             "ps_foreground": ps_foreground(s["tty"])}
            for k, sid in lab.items() for s in [session_of(inv, sid)] if s]
    step("jobs:" + label, rows=rows)
    return inv

inv = job_snapshot("t0")
step("inventory", sessions=[s for s in inv["sessions"] if s["session"] in lab.values()],
     preexisting=[s for s in inv["sessions"] if s["session"] in preexisting])
time.sleep(10)
job_snapshot("t10")

# --- C3: select and read back --------------------------------------------------------------
def select_case(name, target, steps, other_app_first):
    if other_app_first:
        raise_other_app()
    before = {"front": front_app(), "current": it("current")}
    t0 = time.time()
    it("select", session=target, steps=steps)
    settle = wait_for(lambda: (lambda c: c.get("session") == target and c.get("frontmost") and c)(it("current")), 3, 0.1)
    elapsed = round(time.time() - t0, 2)
    time.sleep(0.5)
    after = {"front": front_app(), "current": it("current")}
    return step("select:" + name, target=target, steps=steps, before=before, after=after,
                matched=bool(settle), elapsed=elapsed)

select_case("session-only-other-tab", lab["A2"], ["session"], False)
select_case("tab+session-other-window", lab["A2"], ["tab", "session"], False)
it("select", session=lab["A3"], steps=["window", "tab", "session", "activate"])
time.sleep(0.5)
select_case("tab+session-same-window", lab["A2"], ["tab", "session"], False)
select_case("full-from-finder-backwindow", lab["A1"], ["window", "tab", "session", "activate"], True)
select_case("full-other-window", lab["B1"], ["window", "tab", "session", "activate"], False)
select_case("full-split-pane", lab["A4b"], ["window", "tab", "session", "activate"], True)

job_snapshot("after-selects")

# --- C4: focus report while another app is frontmost ----------------------------------------
raise_other_app()
step("focus:other-app-front", front=front_app(), current=it("current"))

# --- C5: write text landing ----------------------------------------------------------------
it("write", session=lab["A4a"], text=f"echo PROBE-{NONCE}-I1")
time.sleep(1.5)
it("write", session=lab["B1"], text=f"echo PROBE-{NONCE}-I2", newline=False)
time.sleep(1.5)
i2_before = contents(lab["B1"])
it("write", session=lab["B1"], text="")
time.sleep(1.5)
i2_after = contents(lab["B1"])
step("write:newline-false", typed_visible=f"echo PROBE-{NONCE}-I2" in i2_before,
     ran_before_return=i2_before.count(f"PROBE-{NONCE}-I2") > 1,
     ran_after_return=i2_after.count(f"PROBE-{NONCE}-I2") > 1)

closed = it("newTab", window=B["window"])["session"]
time.sleep(1)
it("close", session=closed)
time.sleep(1)
step("write:closed-session", **try_it("write", session=closed, text=f"echo PROBE-{NONCE}-closed"))

# Typed prompt into each TUI: does `write text` (text + CR) submit a turn?
it("write", session=lab["A1"], text="Reply with only the word PONG.")
it("write", session=lab["A2"], text="Reply with only the word PONG.")
codex_pong = wait_for(lambda: "PONG" in contents(lab["A1"]).split("Reply with only the word PONG.")[-1], 45, 2)
claude_pong = wait_for(lambda: "PONG" in contents(lab["A2"]).split("Reply with only the word PONG.")[-1], 45, 2)
step("write:tui-prompt", codex_submitted=bool(codex_pong), claude_submitted=bool(claude_pong),
     codex_tail=contents(lab["A1"])[-600:], claude_tail=contents(lab["A2"])[-600:])
if not codex_pong:
    # Text and CR in one write may read as a paste burst; try a lone CR as a separate write.
    it("write", session=lab["A1"], text="")
    codex_pong = wait_for(lambda: "PONG" in contents(lab["A1"]).split("Reply with only the word PONG.")[-1], 45, 2)
    step("write:tui-prompt-separate-cr", codex_submitted=bool(codex_pong), codex_tail=contents(lab["A1"])[-600:])

landing = {}
for s in it("inventory")["sessions"]:
    text = contents(s["session"])
    landing[s["session"]] = {"I1": text.count(f"PROBE-{NONCE}-I1"), "I2": text.count(f"PROBE-{NONCE}-I2"),
                             "closed": text.count(f"PROBE-{NONCE}-closed"), "lab": s["session"] in lab.values()}
step("write:landing", sessions=landing, I1_target=lab["A4a"], I2_target=lab["B1"])

# --- teardown ------------------------------------------------------------------------------
log["finished"] = time.time()
with open(os.path.join(OUT, "run.json"), "w") as f:
    json.dump(log, f, indent=2)
if not args.keep:
    for key, sid in lab.items():
        tty = (session_of(it("inventory"), sid) or {}).get("tty")
        if tty:
            # pkill -t does not match ttysNNN names on macOS; kill the tty's processes by PID.
            pids = subprocess.run(["ps", "-o", "pid=", "-t", tty.removeprefix("/dev/")],
                                  capture_output=True, text=True).stdout.split()
            if pids:
                subprocess.run(["kill", "-TERM", *pids])
    time.sleep(2)
    for key, sid in lab.items():
        try_it("close", session=sid)
print("wrote", os.path.join(OUT, "run.json"))
