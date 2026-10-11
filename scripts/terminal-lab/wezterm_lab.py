"""WezTerm live targeting proof for issue #206.

Usage: python3 -I wezterm_lab.py --lab-root <dir> [--keep]

Talks to the running WezTerm GUI only through `wezterm cli --no-auto-start` (run with a minimal
environment) and creates its own windows, tabs and panes: A1 Codex, A2 Claude, A3 a decoy
carrying Codex's title over `sleep`, A4a/A4b a split tab, and B1 a shell in a second window. It
records pane ids, ttys, titles, `activate-pane` plus app activation read back through
`list-clients` and the front app, focus while another app is in front, where `send-text` lands
(paste and --no-paste), and what an unknown pane id does. Every send-text names a pane the lab
spawned; afterwards every pane's text is checked for the probe nonce.

Launch WezTerm with a clean environment first (`env -i HOME="$HOME" USER="$USER" /usr/bin/open
-a WezTerm`); the lab refuses to run if a lab shell sees CLAUDE*/CODEX* variables. Codex and
Claude isolation is the same as iterm2_lab.py. Raw results go to <lab-root>/wezterm/run.json.
"""
import argparse, glob, json, os, re, secrets, subprocess, sys, time

S = os.path.dirname(os.path.abspath(__file__))
WEZTERM = "/Applications/WezTerm.app/Contents/MacOS/wezterm"
BUNDLE = "com.github.wez.wezterm"
CODEX = os.path.expanduser("~/.local/bin/codex")
CLAUDE = os.path.expanduser("~/.local/bin/claude")
CODEX_TITLE = re.compile(r"^[0-9a-f-]{29}\.\.\.$")
CLEAN_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}

ap = argparse.ArgumentParser()
ap.add_argument("--lab-root", required=True)
ap.add_argument("--keep", action="store_true")
args = ap.parse_args()
LAB = os.path.abspath(args.lab_root)
OUT = os.path.join(LAB, "wezterm")
PROJ = os.path.join(LAB, "project")
CPROJ = os.path.join(LAB, "claude-project")
EVENTS = os.path.join(OUT, "claude-events")
NONCE = secrets.token_hex(4)
log = {"nonce": NONCE, "started": time.time(), "steps": []}


def cli(*argv, check=True):
    r = subprocess.run([WEZTERM, "cli", "--no-auto-start", *argv], capture_output=True, text=True,
                       timeout=20, env=CLEAN_ENV)
    if check and r.returncode != 0:
        raise RuntimeError(f"wezterm cli {argv[0]} exited {r.returncode}: {r.stderr.strip()[:300]}")
    return r


def panes():
    return json.loads(cli("list", "--format", "json").stdout)


def clients():
    return json.loads(cli("list-clients", "--format", "json").stdout)


def pane(pid):
    return next((p for p in panes() if p["pane_id"] == pid), None)


def text(pid):
    return cli("get-text", "--pane-id", str(pid), "--start-line", "-200").stdout


def send(pid, data, paste=False):
    argv = ["send-text", "--pane-id", str(pid)] + ([] if paste else ["--no-paste"]) + [data]
    return cli(*argv)


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


def ps_foreground(tty):
    rows = subprocess.run(["ps", "-o", "pid=,stat=,comm=", "-t", tty.removeprefix("/dev/")],
                          capture_output=True, text=True).stdout.splitlines()
    return [os.path.basename(r.split(None, 2)[2]) for r in rows if len(r.split(None, 2)) == 3 and "+" in r.split(None, 2)[1]]


def raise_other_app():
    subprocess.run(["open", "-a", "Finder"], check=True)
    wait_for(lambda: front_app() == "com.apple.finder", 5, 0.2)


def focused():
    return [{"focused_pane_id": c.get("focused_pane_id"), "workspace": c.get("workspace")} for c in clients()]


def save():
    log["finished"] = time.time()
    with open(os.path.join(OUT, "run.json"), "w") as f:
        json.dump(log, f, indent=2)


# --- setup ---------------------------------------------------------------------------------
os.makedirs(EVENTS, exist_ok=True)
os.makedirs(PROJ, exist_ok=True)
os.makedirs(os.path.join(CPROJ, ".claude"), exist_ok=True)
for f in glob.glob(os.path.join(EVENTS, "*.json")) + glob.glob(os.path.join(OUT, "leak-*")) + glob.glob(os.path.join(OUT, "env-*")):
    os.unlink(f)
hook = f"/usr/bin/python3 -I {json.dumps(os.path.join(S, 'claude_title_hook.py'))} {json.dumps(EVENTS)}"
with open(os.path.join(CPROJ, ".claude", "settings.json"), "w") as f:
    json.dump({"env": {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"},
               "hooks": {e: [{"hooks": [{"type": "command", "command": hook, "timeout": 10}]}]
                         for e in ("SessionStart", "UserPromptSubmit", "Stop")}}, f, indent=2)

version = subprocess.run([WEZTERM, "--version"], capture_output=True, text=True, env=CLEAN_ENV).stdout.strip()
step("version", version=version, front=front_app(), clients=clients())
preexisting = [p["pane_id"] for p in panes()]
step("preexisting", count=len(preexisting))

A1 = int(cli("spawn", "--new-window").stdout)
win_a = pane(A1)["window_id"]
A2 = int(cli("spawn", "--window-id", str(win_a)).stdout)
A3 = int(cli("spawn", "--window-id", str(win_a)).stdout)
A4a = int(cli("spawn", "--window-id", str(win_a)).stdout)
A4b = int(cli("split-pane", "--pane-id", str(A4a), "--right").stdout)
B1 = int(cli("spawn", "--new-window").stdout)
lab = {"A1": A1, "A2": A2, "A3": A3, "A4a": A4a, "A4b": A4b, "B1": B1}
step("created", panes=lab, windows=[win_a, pane(B1)["window_id"]])
time.sleep(2)

for key, pid in lab.items():
    send(pid, f"printf '%s' \"$WEZTERM_PANE\" > {json.dumps(os.path.join(OUT, 'env-' + key))}; "
              f"env | cut -d= -f1 | grep -E '^(CLAUDE|CODEX)' > {json.dumps(os.path.join(OUT, 'leak-' + key))}\r")
time.sleep(2)
leaks, wezterm_pane = {}, {}
for key in lab:
    try:
        with open(os.path.join(OUT, "leak-" + key)) as f:
            names = f.read().split()
        with open(os.path.join(OUT, "env-" + key)) as f:
            wezterm_pane[key] = f.read()
    except OSError:
        names = ["<unreadable>"]
    if names:
        leaks[key] = names
step("env_clean", leaks=leaks, wezterm_pane=wezterm_pane)
if leaks:
    save()
    sys.exit("WezTerm shells inherited agent variables; relaunch WezTerm with a clean environment")

send(A1, f"cd {json.dumps(PROJ)} && exec {CODEX} -C {json.dumps(PROJ)} -s read-only -a never 'Reply with only the word READY.'\r")
send(A2, f"cd {json.dumps(CPROJ)} && exec {CLAUDE} --setting-sources project 'Reply with only the word READY.'\r")

codex_title = wait_for(lambda: (lambda p: p and CODEX_TITLE.match(p["title"]) and p["title"])(pane(A1)), 90, 2)
step("codex_title", title=codex_title)
claude_title = wait_for(lambda: (lambda p: p and p["title"].startswith("Steer Claude ") and p["title"])(pane(A2)), 60, 2)
step("claude_title", title=claude_title, observed=pane(A2)["title"])
wait_for(lambda: "READY" in text(A1).split("Reply with only the word READY.")[-1], 90, 2)
wait_for(lambda: "READY" in text(A2).split("Reply with only the word READY.")[-1], 90, 2)

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
step("codex_rollout_ids", ids=codex_ids[-2:])
claude_events = []
for path in sorted(glob.glob(os.path.join(EVENTS, "*.json"))):
    with open(path) as f:
        claude_events.append(json.load(f))
step("claude_hook_events", events=claude_events)

if codex_title:
    send(A3, f"printf '\\033]0;%s\\007' '{codex_title}'; exec sleep 3600\r")
time.sleep(2)
inv = panes()
step("inventory", panes=[dict(p, ps_foreground=ps_foreground(p["tty_name"])) for p in inv if p["pane_id"] in lab.values()],
     clients=focused())

# --- select and read back ------------------------------------------------------------------
def select_case(name, target, raise_app, other_app_first):
    if other_app_first:
        raise_other_app()
    before = {"front": front_app(), "focused": focused()}
    t0 = time.time()
    r = cli("activate-pane", "--pane-id", str(target), check=False)
    if raise_app:
        subprocess.run(["open", "-b", BUNDLE], check=True)
    settle = wait_for(lambda: (lambda f: front_app() == BUNDLE and any(c["focused_pane_id"] == target for c in f) and f)(focused()), 3, 0.1)
    elapsed = round(time.time() - t0, 2)
    time.sleep(0.5)
    after = {"front": front_app(), "focused": focused(),
             "active_in_tab": {p["pane_id"]: p["is_active"] for p in panes() if p["pane_id"] in lab.values()}}
    return step("select:" + name, target=target, raise_app=raise_app, activate_exit=r.returncode,
                before=before, after=after, matched=bool(settle), elapsed=elapsed)

subprocess.run(["open", "-b", BUNDLE], check=True)
time.sleep(1)
select_case("activate-pane-other-tab", A2, False, False)
select_case("activate-pane-other-window", B1, False, False)
select_case("activate-pane-split", A4b, False, False)
select_case("activate-pane+open-from-finder-same-window", A1, True, True)
select_case("activate-pane+open-from-finder-other-window", B1, True, True)
select_case("activate-pane+open-from-finder-back-window", A3, True, True)

raise_other_app()
time.sleep(1)
step("focus:other-app-front", front=front_app(), focused=focused())

# --- send-text landing ---------------------------------------------------------------------
send(A4a, f"echo PROBE-{NONCE}-I1\r")
send(B1, f"echo PROBE-{NONCE}-I2", paste=True)
time.sleep(1.5)
i2_before = text(B1)
send(B1, "\r")
time.sleep(1.5)
step("send:paste-then-cr", typed_visible=f"echo PROBE-{NONCE}-I2" in i2_before,
     ran_before_cr=i2_before.count(f"PROBE-{NONCE}-I2") > 1, ran_after_cr=text(B1).count(f"PROBE-{NONCE}-I2") > 1,
     front=front_app())

bad = max(p["pane_id"] for p in panes()) + 1000
r = cli("send-text", "--pane-id", str(bad), "--no-paste", f"echo PROBE-{NONCE}-bad\r", check=False)
step("send:unknown-pane", pane_id=bad, exit=r.returncode, stderr=r.stderr.strip()[:200])

P = "Reply with only the word PONG."
results = {}
for key, pid in (("codex", A1), ("claude", A2)):
    send(pid, P + "\r")
    ok = wait_for(lambda: "PONG" in text(pid).split(P)[-1], 45, 2)
    results[key] = {"no-paste text+CR": bool(ok)}
    if not ok:
        send(pid, "\r")
        ok = wait_for(lambda: "PONG" in text(pid).split(P)[-1], 45, 2)
        results[key]["separate CR"] = bool(ok)
step("send:tui-prompt", results=results)

landing = {}
for p in panes():
    t = text(p["pane_id"])
    landing[p["pane_id"]] = {"I1": t.count(f"PROBE-{NONCE}-I1"), "I2": t.count(f"PROBE-{NONCE}-I2"),
                             "bad": t.count(f"PROBE-{NONCE}-bad"), "lab": p["pane_id"] in lab.values()}
step("send:landing", panes=landing, I1_target=A4a, I2_target=B1)
save()

# --- teardown ------------------------------------------------------------------------------
if not args.keep:
    for pid in lab.values():
        cli("kill-pane", "--pane-id", str(pid), check=False)
print("wrote", os.path.join(OUT, "run.json"))
