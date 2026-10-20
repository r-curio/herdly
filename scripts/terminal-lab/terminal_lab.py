"""Terminal.app live targeting proof for issue #205.

Usage: python3 -I terminal_lab.py --lab-root <dir> [--tab-wait S] [--keep]

Terminal's scripting dictionary cannot create a tab (`make new tab` fails with "AppleEvent
handler failed") and System Events keystrokes need Accessibility, so the lab opens window W1,
prints a banner in it, and waits up to --tab-wait seconds for a person to press Cmd-T twice in
W1 (or adopts an existing three-tab group with --adopt-window <id>). On current macOS each
Terminal tab is its own scripting window in a native tab group; the lab treats windows sharing
W1's bounds as its tabs and asks the window server (onscreen_windows.swift, built into
<lab-root>/bin) which tab is actually on screen. Everything after that is automated: one disposable Codex CLI session, one disposable Claude
Code session, a decoy carrying Codex's title, and a shell in a second window W2. It records tab
ttys, titles, processes, select/frontmost read-back, focus while another app is frontmost, where
`do script ... in <tab>` lands, and what `do script` does against a stale tab reference.

Every `do script` names a tab the lab created or saw created in W1, resolved fresh by tty. The
stale-reference case only ever runs `printf` into a file under the lab root. Afterwards every
Terminal tab's contents are checked for the probe nonce.

Launch Terminal with a clean environment first (`env -i HOME="$HOME" USER="$USER" /usr/bin/open
-a Terminal`); the lab refuses to run if a lab shell sees CLAUDE*/CODEX* variables. Isolation of
Codex and Claude is the same as iterm2_lab.py. Raw results go to <lab-root>/terminal/run.json.
"""
import argparse, glob, json, os, re, secrets, subprocess, sys, time

S = os.path.dirname(os.path.abspath(__file__))
DRIVER = os.path.join(S, "terminal.js")
CODEX = os.path.expanduser("~/.local/bin/codex")
CLAUDE = os.path.expanduser("~/.local/bin/claude")
CODEX_TITLE = re.compile(r"[0-9a-f-]{29}\.\.\.")

ap = argparse.ArgumentParser()
ap.add_argument("--lab-root", required=True)
ap.add_argument("--tab-wait", type=float, default=600)
ap.add_argument("--keep", action="store_true")
ap.add_argument("--adopt-window", type=int, help="use this existing window's tab group as W1")
args = ap.parse_args()
LAB = os.path.abspath(args.lab_root)
OUT = os.path.join(LAB, "terminal")
PROJ = os.path.join(LAB, "project")
CPROJ = os.path.join(LAB, "claude-project")
EVENTS = os.path.join(OUT, "claude-events")
NONCE = secrets.token_hex(4)
log = {"nonce": NONCE, "started": time.time(), "steps": []}


def tm(op, **kw):
    r = subprocess.run(["osascript", "-l", "JavaScript", DRIVER, json.dumps({"op": op, **kw})],
                       capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:300])
    return json.loads(r.stdout)


def try_tm(op, **kw):
    try:
        return {"ok": True, "result": tm(op, **kw)}
    except Exception as e:
        return {"ok": False, "error": str(e).split("execution error: ")[-1]}


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


def tab_of(inv, tty):
    return next((t for t in inv["tabs"] if t["tty"] == tty), None)


def screen(tty):
    return tm("contents", tty=tty)["text"]


def ps_foreground(tty):
    rows = subprocess.run(["ps", "-o", "pid=,stat=,comm=", "-t", tty.removeprefix("/dev/")],
                          capture_output=True, text=True).stdout.splitlines()
    return [os.path.basename(r.split(None, 2)[2]) for r in rows if len(r.split(None, 2)) == 3 and "+" in r.split(None, 2)[1]]


HELPER = os.path.join(LAB, "bin", "onscreen_windows")
if not os.path.exists(HELPER):
    os.makedirs(os.path.dirname(HELPER), exist_ok=True)
    subprocess.run(["swiftc", "-O", os.path.join(S, "onscreen_windows.swift"), "-o", HELPER], check=True)


def onscreen():
    out = subprocess.run([HELPER, "com.apple.Terminal"], capture_output=True, text=True, timeout=10).stdout
    return [w["id"] for w in json.loads(out or "[]") if w["layer"] == 0]


def raise_other_app():
    subprocess.run(["open", "-a", "Finder"], check=True)
    wait_for(lambda: front_app() == "com.apple.finder", 5, 0.2)


def save():
    log["finished"] = time.time()
    with open(os.path.join(OUT, "run.json"), "w") as f:
        json.dump(log, f, indent=2)


# --- setup ---------------------------------------------------------------------------------
os.makedirs(EVENTS, exist_ok=True)
os.makedirs(PROJ, exist_ok=True)
os.makedirs(os.path.join(CPROJ, ".claude"), exist_ok=True)
for f in glob.glob(os.path.join(EVENTS, "*.json")) + glob.glob(os.path.join(OUT, "leak-*")) + [os.path.join(OUT, "null-probe")]:
    if os.path.exists(f):
        os.unlink(f)
hook = f"/usr/bin/python3 -I {json.dumps(os.path.join(S, 'claude_title_hook.py'))} {json.dumps(EVENTS)}"
with open(os.path.join(CPROJ, ".claude", "settings.json"), "w") as f:
    json.dump({"env": {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"},
               "hooks": {e: [{"hooks": [{"type": "command", "command": hook, "timeout": 10}]}]
                         for e in ("SessionStart", "UserPromptSubmit", "Stop")}}, f, indent=2)

step("version", **tm("version"), front=front_app())
preexisting = [t["tty"] for t in tm("inventory")["tabs"]]
step("preexisting", count=len(preexisting))

if args.adopt_window:
    w1_window = args.adopt_window
    preexisting = [t["tty"] for t in tm("inventory")["tabs"] if t["window"] != w1_window
                   and t["bounds"] != next(x["bounds"] for x in tm("inventory")["tabs"] if x["window"] == w1_window)]
else:
    W1 = tm("newWindow", text="clear; echo; echo '  HERDLY LAB: press Cmd-T twice in THIS window, then leave the keyboard alone.'; echo")
    w1_window = tab_of(tm("inventory"), W1["tty"])["window"]
step("waiting_for_tabs", window=w1_window, timeout=args.tab_wait)


def group(inv):
    anchor = next((t for t in inv["tabs"] if t["window"] == w1_window), None)
    return [t for t in inv["tabs"] if anchor and t["bounds"] == anchor["bounds"] and t["tty"] not in preexisting]

got = wait_for(lambda: (lambda i: len(group(i)) >= 3 and i)(tm("inventory")), args.tab_wait, 1)
if not got:
    step("tabs_not_created")
    save()
    sys.exit("timed out waiting for Cmd-T twice in the lab window")
members = sorted(group(got), key=lambda t: t["window"])[:3]
step("tab_group", members=[{"window": t["window"], "tty": t["tty"], "windowTabs": t["windowTabs"],
                            "selected": t["selected"], "bounds": t["bounds"]} for t in members])
w1_tabs = [t["tty"] for t in members]
window_of = {t["tty"]: t["window"] for t in members}
time.sleep(1)
W2 = tm("newWindow")
lab = {"T1": w1_tabs[0], "T2": w1_tabs[1], "T3": w1_tabs[2], "B1": W2["tty"]}
w2_window = tab_of(tm("inventory"), W2["tty"])["window"]
window_of[W2["tty"]] = w2_window
step("created", windows=[w1_window, w2_window], tabs=lab, window_of=window_of,
     w2_in_group=W2["tty"] in [t["tty"] for t in group(tm("inventory"))])

for key, tty in lab.items():
    tm("doScript", tty=tty, text=f"env | cut -d= -f1 | grep -E '^(CLAUDE|CODEX)' > {json.dumps(os.path.join(OUT, 'leak-' + key))}")
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
    save()
    sys.exit("Terminal shells inherited agent variables; relaunch Terminal with a clean environment")

tm("doScript", tty=lab["T1"], text=f"cd {json.dumps(PROJ)} && exec {CODEX} -C {json.dumps(PROJ)} -s read-only -a never 'Reply with only the word READY.'")
tm("doScript", tty=lab["T2"], text=f"cd {json.dumps(CPROJ)} && exec {CLAUDE} --setting-sources project 'Reply with only the word READY.'")

# --- titles and processes ------------------------------------------------------------------
def title_view(label):
    inv = tm("inventory")
    rows = [{"key": k, "selected": t["selected"], "customTitle": t["customTitle"], "windowName": t["windowName"],
             "titleDisplaysCustomTitle": t["titleDisplaysCustomTitle"], "busy": t["busy"],
             "processes": t["processes"], "ps_foreground": ps_foreground(tty)}
            for k, tty in lab.items() for t in [tab_of(inv, tty)] if t]
    return step("titles:" + label, rows=rows, current=inv["current"], onscreen=onscreen())

wait_for(lambda: "READY" in screen(lab["T1"]).split("Reply with only the word READY.")[-1], 90, 2)
wait_for(lambda: "READY" in screen(lab["T2"]).split("Reply with only the word READY.")[-1], 90, 2)
title_view("after-ready")

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
codex_id = codex_ids[-1] if codex_ids else None
codex_title = codex_id[:29] + "..." if codex_id else None
step("codex_rollout_id", id=codex_id, expected_title=codex_title)
claude_events = []
for path in sorted(glob.glob(os.path.join(EVENTS, "*.json"))):
    with open(path) as f:
        claude_events.append(json.load(f))
step("claude_hook_events", events=claude_events)

# Each agent tab selected in turn, so its title is seen both as the selected and a background tab.
for key in ("T1", "T2"):
    tm("select", tty=lab[key], steps=["window", "activate"])
    time.sleep(1.5)
    title_view("selected-" + key)

if codex_title:
    tm("doScript", tty=lab["T3"], text=f"printf '\\033]0;%s\\007' '{codex_title}'; exec sleep 3600")
time.sleep(2)
tm("select", tty=lab["T3"], steps=["window", "activate"])
time.sleep(1.5)
title_view("selected-T3-decoy")

# --- select and read back ------------------------------------------------------------------
def select_case(name, target, steps, other_app_first):
    if other_app_first:
        raise_other_app()
    lab_windows = set(window_of.values())
    def shown():
        c = tm("current")
        on = [w for w in onscreen() if w in lab_windows]
        ok = c.get("selectedTty") == target and c.get("frontmost") and window_of[target] in on and \
            not [w for w in on if w != window_of[target] and w in [window_of[t] for t in w1_tabs] and window_of[target] in [window_of[t] for t in w1_tabs]]
        return ok and {"current": c, "onscreen_lab": on}
    before = {"front": front_app(), "current": tm("current"), "onscreen_lab": [w for w in onscreen() if w in lab_windows]}
    t0 = time.time()
    tm("select", tty=target, steps=steps)
    settle = wait_for(shown, 3, 0.1)
    elapsed = round(time.time() - t0, 2)
    time.sleep(0.5)
    after = {"front": front_app(), "current": tm("current"), "onscreen_lab": [w for w in onscreen() if w in lab_windows]}
    return step("select:" + name, target=target, target_window=window_of[target], steps=steps, before=before,
                after=after, matched=bool(settle), elapsed=elapsed)

select_case("tab-selected-only", lab["T1"], ["tab"], False)
select_case("window-frontmost-only", lab["T1"], ["window"], False)
select_case("index-only", lab["T2"], ["index"], False)
select_case("window+activate-other-window", lab["B1"], ["window", "activate"], False)
select_case("window+activate-from-finder", lab["T2"], ["window", "activate"], True)
select_case("index+activate-from-finder", lab["T3"], ["index", "activate"], True)
select_case("window+activate-background-tab", lab["T1"], ["window", "activate"], False)

raise_other_app()
step("focus:other-app-front", front=front_app(), current=tm("current"), onscreen=onscreen())

# --- do script landing ---------------------------------------------------------------------
tm("doScript", tty=lab["B1"], text=f"echo PROBE-{NONCE}-I1")
time.sleep(1.5)
step("doScript:shell", front_after=front_app(), current_after=tm("current"))

tm("doScript", tty=lab["T1"], text="Reply with only the word PONG.")
tm("doScript", tty=lab["T2"], text="Reply with only the word PONG.")
codex_pong = wait_for(lambda: "PONG" in screen(lab["T1"]).split("Reply with only the word PONG.")[-1], 45, 2)
claude_pong = wait_for(lambda: "PONG" in screen(lab["T2"]).split("Reply with only the word PONG.")[-1], 45, 2)
step("doScript:tui-prompt", codex_submitted=bool(codex_pong), claude_submitted=bool(claude_pong),
     codex_has_text="Reply with only the word PONG." in screen(lab["T1"]),
     claude_has_text="Reply with only the word PONG." in screen(lab["T2"]))
if not codex_pong:
    # As in iTerm2, try the submit as its own `do script ""` (a lone newline).
    tm("doScript", tty=lab["T1"], text="")
    codex_pong = wait_for(lambda: "PONG" in screen(lab["T1"]).split("Reply with only the word PONG.")[-1], 45, 2)
    step("doScript:tui-prompt-separate-newline", codex_submitted=bool(codex_pong))

stale_window = tm("newWindow")["tty"]
stale_window_id = tab_of(tm("inventory"), stale_window)["window"]
time.sleep(1)
null_probe = os.path.join(OUT, "null-probe")
before_windows = tm("version")["windows"]
stale = try_tm("staleDoScript", window=stale_window_id, text=f"printf PROBE-{NONCE}-stale > {json.dumps(null_probe)}")
time.sleep(2)
stale_inv = tm("inventory")
new_tabs = [t["tty"] for t in stale_inv["tabs"] if t["tty"] not in preexisting and t["tty"] not in lab.values()]
step("doScript:stale-reference", result=stale, windows_before=before_windows,
     windows_after=tm("version")["windows"], unexpected_tabs=new_tabs,
     probe_file_written=os.path.exists(null_probe))

landing = {}
for t in tm("inventory")["tabs"]:
    text = screen(t["tty"])
    landing[t["tty"]] = {"I1": text.count(f"PROBE-{NONCE}-I1"), "stale": text.count(f"PROBE-{NONCE}-stale"),
                         "lab": t["tty"] in lab.values()}
step("doScript:landing", tabs=landing, I1_target=lab["B1"])
save()

# --- teardown ------------------------------------------------------------------------------
if not args.keep:
    extra = new_tabs
    for tty in list(lab.values()) + extra:
        pids = subprocess.run(["ps", "-o", "pid=", "-t", tty.removeprefix("/dev/")],
                              capture_output=True, text=True).stdout.split()
        if pids:
            subprocess.run(["kill", "-TERM", *pids])
    time.sleep(2)
    for w in set(window_of.values()):
        try_tm("closeWindow", window=w)
    for t in tm("inventory")["tabs"]:
        if t["tty"] in extra:
            try_tm("closeWindow", window=t["window"])
print("wrote", os.path.join(OUT, "run.json"))
