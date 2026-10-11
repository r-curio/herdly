"""tmux live targeting proof for issue #207, hosted in WezTerm.

Usage: python3 -I tmux_lab.py --lab-root <dir> [--keep]

Starts an isolated tmux server (`-L steerlab -f /dev/null`, minimal environment) with windows
codex, claude, decoy (Codex's title over `sleep`) and split (two shells), and attaches one client
from a WezTerm pane (host H1) and, for part of the run, a second client from another WezTerm tab
(H2). It records pane ids, ttys, titles and current commands, the client list with each client's
host tty, `switch-client -c <tty> -t %pane` read back through list-clients, the `focused` client
flag with focus-events off and on, where `send-keys -l` lands (including a pane in copy mode),
Codex and Claude prompt submission, and an unknown pane target. Every send-keys targets a pane id
the lab created; tmux pane contents are checked for the probe nonce afterwards.

Launch WezTerm with a clean environment first. Codex and Claude isolation is the same as
iterm2_lab.py. The lab kills its tmux server and host panes at the end. Raw results go to
<lab-root>/tmux/run.json.
"""
import argparse, glob, json, os, re, secrets, subprocess, sys, time

S = os.path.dirname(os.path.abspath(__file__))
WEZTERM = "/Applications/WezTerm.app/Contents/MacOS/wezterm"
TMUX = "/opt/homebrew/bin/tmux"
BUNDLE = "com.github.wez.wezterm"
CODEX = os.path.expanduser("~/.local/bin/codex")
CLAUDE = os.path.expanduser("~/.local/bin/claude")
CODEX_TITLE = re.compile(r"^[0-9a-f-]{29}\.\.\.$")
SOCKET = "steerlab"
CLEAN_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "LANG": "en_US.UTF-8",
             "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"}

ap = argparse.ArgumentParser()
ap.add_argument("--lab-root", required=True)
ap.add_argument("--keep", action="store_true")
args = ap.parse_args()
LAB = os.path.abspath(args.lab_root)
OUT = os.path.join(LAB, "tmux")
PROJ = os.path.join(LAB, "project")
CPROJ = os.path.join(LAB, "claude-project")
EVENTS = os.path.join(OUT, "claude-events")
NONCE = secrets.token_hex(4)
log = {"nonce": NONCE, "started": time.time(), "steps": []}


def tmux(*argv, check=True, timeout=20):
    r = subprocess.run([TMUX, "-L", SOCKET, *argv], capture_output=True, text=True, timeout=timeout, env=CLEAN_ENV)
    if check and r.returncode != 0:
        raise RuntimeError(f"tmux {argv[0]} exited {r.returncode}: {r.stderr.strip()[:300]}")
    return r


def wez(*argv, check=True):
    r = subprocess.run([WEZTERM, "cli", "--no-auto-start", *argv], capture_output=True, text=True, timeout=20, env=CLEAN_ENV)
    if check and r.returncode != 0:
        raise RuntimeError(f"wezterm cli {argv[0]} exited {r.returncode}: {r.stderr.strip()[:300]}")
    return r


PANE_FMT = "#{pane_id}\t#{pane_tty}\t#{pane_title}\t#{pane_current_command}\t#{pane_pid}\t#{window_id}\t#{window_name}\t#{window_panes}\t#{window_zoomed_flag}\t#{session_name}\t#{session_attached}\t#{pane_active}\t#{window_active}\t#{pane_in_mode}"
PANE_KEYS = ["pane_id", "pane_tty", "pane_title", "pane_current_command", "pane_pid", "window_id", "window_name",
             "window_panes", "window_zoomed_flag", "session_name", "session_attached", "pane_active", "window_active", "pane_in_mode"]
CLIENT_FMT = "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_flags}\t#{window_id}\t#{pane_id}"
CLIENT_KEYS = ["client_tty", "client_pid", "client_session", "client_flags", "window_id", "pane_id"]


def panes():
    out = tmux("list-panes", "-a", "-F", PANE_FMT).stdout.strip().splitlines()
    return [dict(zip(PANE_KEYS, line.split("\t"))) for line in out]


def clients():
    out = tmux("list-clients", "-F", CLIENT_FMT).stdout.strip().splitlines()
    return [dict(zip(CLIENT_KEYS, line.split("\t"))) for line in out]


def pane(pid):
    return next((p for p in panes() if p["pane_id"] == pid), None)


def capture(pid):
    return tmux("capture-pane", "-p", "-J", "-S", "-200", "-t", pid).stdout


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


def save():
    log["finished"] = time.time()
    with open(os.path.join(OUT, "run.json"), "w") as f:
        json.dump(log, f, indent=2)


# --- setup ---------------------------------------------------------------------------------
os.makedirs(EVENTS, exist_ok=True)
os.makedirs(PROJ, exist_ok=True)
os.makedirs(os.path.join(CPROJ, ".claude"), exist_ok=True)
for f in glob.glob(os.path.join(EVENTS, "*.json")) + glob.glob(os.path.join(OUT, "leak-*")):
    os.unlink(f)
hook = f"/usr/bin/python3 -I {json.dumps(os.path.join(S, 'claude_title_hook.py'))} {json.dumps(EVENTS)}"
with open(os.path.join(CPROJ, ".claude", "settings.json"), "w") as f:
    json.dump({"env": {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"},
               "hooks": {e: [{"hooks": [{"type": "command", "command": hook, "timeout": 10}]}]
                         for e in ("SessionStart", "UserPromptSubmit", "Stop")}}, f, indent=2)

if tmux("has-session", check=False).returncode == 0:
    sys.exit("a tmux server is already running on -L steerlab; kill it first")
tmux("-f", "/dev/null", "new-session", "-d", "-s", "lab", "-n", "codex", "-x", "120", "-y", "30")
tmux("new-window", "-t", "lab", "-n", "claude")
tmux("new-window", "-t", "lab", "-n", "decoy")
tmux("new-window", "-t", "lab", "-n", "split")
tmux("split-window", "-h", "-t", "lab:split")
ids = {p["window_name"] + ("" if p["window_name"] != "split" else ("a" if p["pane_active"] == "0" else "b")): p["pane_id"]
       for p in panes()}
lab = {"codex": ids["codex"], "claude": ids["claude"], "decoy": ids["decoy"], "split_a": ids["splita"], "split_b": ids["splitb"]}
step("version", tmux=tmux("-V").stdout.strip() if False else subprocess.run([TMUX, "-V"], capture_output=True, text=True).stdout.strip(),
     wezterm=subprocess.run([WEZTERM, "--version"], capture_output=True, text=True).stdout.strip(),
     socket=tmux("display-message", "-p", "#{socket_path}").stdout.strip(), panes=lab)

for key, pid in lab.items():
    tmux("send-keys", "-t", pid, "-l", f"env | cut -d= -f1 | grep -E '^(CLAUDE|CODEX)' > {json.dumps(os.path.join(OUT, 'leak-' + key))}")
    tmux("send-keys", "-t", pid, "Enter")
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
    tmux("kill-server", check=False)
    save()
    sys.exit("tmux panes inherited agent variables")

# Host: one WezTerm window, client attached from H1.
H1 = int(wez("spawn", "--new-window").stdout)
time.sleep(1.5)
h1_tty = next(p for p in json.loads(wez("list", "--format", "json").stdout) if p["pane_id"] == H1)["tty_name"]
wez("send-text", "--pane-id", str(H1), "--no-paste", f"exec env -i HOME=\"$HOME\" USER=\"$USER\" LANG=en_US.UTF-8 TERM=xterm-256color PATH=/opt/homebrew/bin:/usr/bin:/bin {TMUX} -L {SOCKET} attach -t lab\r")
wait_for(lambda: len(clients()) == 1, 15, 0.5)
step("host_attach", host_pane=H1, host_tty=h1_tty, clients=clients())

for key, cmd in (("codex", f"cd {json.dumps(PROJ)} && exec {CODEX} -C {json.dumps(PROJ)} -s read-only -a never 'Reply with only the word READY.'"),
                 ("claude", f"cd {json.dumps(CPROJ)} && exec {CLAUDE} --setting-sources project 'Reply with only the word READY.'")):
    tmux("send-keys", "-t", lab[key], "-l", cmd)
    tmux("send-keys", "-t", lab[key], "Enter")

codex_title = wait_for(lambda: (lambda p: p and CODEX_TITLE.match(p["pane_title"]) and p["pane_title"])(pane(lab["codex"])), 90, 2)
step("codex_title", title=codex_title)
def host_title():
    return next(p for p in json.loads(wez("list", "--format", "json").stdout) if p["pane_id"] == H1)["title"]

claude_title = wait_for(lambda: (lambda p: p and p["pane_title"].startswith("Steer Claude ") and p["pane_title"])(pane(lab["claude"])), 60, 2)
step("claude_title", title=claude_title, observed=pane(lab["claude"])["pane_title"], host_title=host_title())
wait_for(lambda: "READY" in capture(lab["codex"]).split("Reply with only the word READY.")[-1], 90, 2)
wait_for(lambda: "READY" in capture(lab["claude"]).split("Reply with only the word READY.")[-1], 90, 2)

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
    tmux("send-keys", "-t", lab["decoy"], "-l", f"printf '\\033]0;%s\\007' '{codex_title}'; exec sleep 3600")
    tmux("send-keys", "-t", lab["decoy"], "Enter")
time.sleep(2)
step("inventory", panes=[dict(p, ps_foreground=ps_foreground(p["pane_tty"])) for p in panes()], clients=clients(),
     host_title=next(p for p in json.loads(wez("list", "--format", "json").stdout) if p["pane_id"] == H1)["title"])

# Claude again in a window with allow-passthrough on: where does Steer's OSC 2 title land?
tmux("new-window", "-d", "-t", "lab", "-n", "claude-passthrough")
cp = next(p["pane_id"] for p in panes() if p["window_name"] == "claude-passthrough")
tmux("set", "-p", "-t", cp, "allow-passthrough", "on")
tmux("send-keys", "-t", cp, "-l", f"cd {json.dumps(CPROJ)} && exec {CLAUDE} --setting-sources project 'Reply with only the word READY.'")
tmux("send-keys", "-t", cp, "Enter")
host_before = host_title()
wait_for(lambda: "READY" in capture(cp).split("Reply with only the word READY.")[-1], 150, 2)
time.sleep(1)
step("claude_title_passthrough", pane=cp, pane_title=pane(cp)["pane_title"], host_title_before=host_before,
     host_title_after=host_title(), client_window=clients()[0]["window_id"])
tmux("kill-window", "-t", "lab:claude-passthrough")
time.sleep(1)

# --- switch-client and read back -----------------------------------------------------------
def switch_case(name, target, client_tty):
    before = clients()
    t0 = time.time()
    r = tmux("switch-client", "-c", client_tty, "-t", target, check=False)
    settle = wait_for(lambda: (lambda c: c and c["pane_id"] == target and c)(next((c for c in clients() if c["client_tty"] == client_tty), None)), 3, 0.1)
    return step("switch:" + name, target=target, client=client_tty, exit=r.returncode, stderr=r.stderr.strip()[:200],
                before=before, after=clients(), matched=bool(settle), elapsed=round(time.time() - t0, 2),
                host_title=next(p for p in json.loads(wez("list", "--format", "json").stdout) if p["pane_id"] == H1)["title"])

switch_case("other-window", lab["claude"], h1_tty)
switch_case("split-pane-b", lab["split_b"], h1_tty)
switch_case("split-pane-a", lab["split_a"], h1_tty)
switch_case("back-to-codex", lab["codex"], h1_tty)

# Second client from another host tab: which client does each command affect?
H2 = int(wez("spawn", "--window-id", str(next(p for p in json.loads(wez("list", "--format", "json").stdout) if p["pane_id"] == H1)["window_id"])).stdout)
time.sleep(1.5)
h2_tty = next(p for p in json.loads(wez("list", "--format", "json").stdout) if p["pane_id"] == H2)["tty_name"]
wez("send-text", "--pane-id", str(H2), "--no-paste", f"exec env -i HOME=\"$HOME\" USER=\"$USER\" LANG=en_US.UTF-8 TERM=xterm-256color PATH=/opt/homebrew/bin:/usr/bin:/bin {TMUX} -L {SOCKET} attach -t lab\r")
wait_for(lambda: len(clients()) == 2, 15, 0.5)
step("second_client", host_pane=H2, host_tty=h2_tty, clients=clients(), session_attached=pane(lab["codex"])["session_attached"])
switch_case("two-clients-switch-h1", lab["decoy"], h1_tty)
step("two-clients-after", clients=clients())
tmux("detach-client", "-t", h2_tty, check=False)
wait_for(lambda: len(clients()) == 1, 10, 0.5)
step("second_client_detached", clients=clients())
wez("kill-pane", "--pane-id", str(H2), check=False)

# --- focused flag ----------------------------------------------------------------------------
wez("activate-pane", "--pane-id", str(H1), check=False)
subprocess.run(["open", "-b", BUNDLE], check=True)
time.sleep(1)
f_off_front = clients()
subprocess.run(["open", "-a", "Finder"], check=True)
time.sleep(1)
f_off_back = clients()
tmux("set", "-g", "focus-events", "on")
subprocess.run(["open", "-b", BUNDLE], check=True)
time.sleep(1.5)
f_on_front = clients()
subprocess.run(["open", "-a", "Finder"], check=True)
time.sleep(1.5)
f_on_back = clients()
step("focus-flag", off_front=f_off_front, off_back=f_off_back, on_front=f_on_front, on_back=f_on_back, front=front_app())

# --- send-keys landing -----------------------------------------------------------------------
tmux("send-keys", "-t", lab["split_a"], "-l", f"echo PROBE-{NONCE}-I1")
tmux("send-keys", "-t", lab["split_a"], "Enter")
time.sleep(1)
tmux("copy-mode", "-t", lab["split_b"])
t0 = time.time()
try:
    copy_exit = tmux("send-keys", "-t", lab["split_b"], "-l", f"echo PROBE-{NONCE}-COPY", check=False, timeout=8).returncode
except subprocess.TimeoutExpired:
    copy_exit = "timeout after 8 s"
copy_elapsed = round(time.time() - t0, 2)
tmux("send-keys", "-t", lab["split_b"], "Enter", check=False, timeout=8)
time.sleep(1)
in_mode = pane(lab["split_b"])["pane_in_mode"]
tmux("send-keys", "-t", lab["split_b"], "-X", "cancel", check=False, timeout=8)
time.sleep(0.5)
step("send:copy-mode", exit=copy_exit, elapsed=copy_elapsed, pane_in_mode_after=in_mode,
     ran=capture(lab["split_b"]).count(f"PROBE-{NONCE}-COPY") > 1, typed=f"echo PROBE-{NONCE}-COPY" in capture(lab["split_b"]))
r_bad = tmux("send-keys", "-t", "%999", "-l", f"echo PROBE-{NONCE}-bad", check=False)
step("send:unknown-pane", exit=r_bad.returncode, stderr=r_bad.stderr.strip()[:200])

P = "Reply with only the word PONG."
results = {}
for key in ("codex", "claude"):
    pid = lab[key]
    tmux("send-keys", "-t", pid, "-l", P + "\r")
    ok = wait_for(lambda: "PONG" in capture(pid).split(P)[-1], 45, 2)
    results[key] = {"literal text+CR in one send-keys": bool(ok)}
    if not ok:
        tmux("send-keys", "-t", pid, "Enter")
        ok = wait_for(lambda: "PONG" in capture(pid).split(P)[-1], 45, 2)
        results[key]["separate Enter"] = bool(ok)
step("send:tui-prompt", results=results)

landing = {}
for p in panes():
    t = capture(p["pane_id"])
    landing[p["pane_id"]] = {"I1": t.count(f"PROBE-{NONCE}-I1"), "COPY": t.count(f"PROBE-{NONCE}-COPY"),
                             "bad": t.count(f"PROBE-{NONCE}-bad")}
step("send:landing", panes=landing, I1_target=lab["split_a"])
save()

# --- teardown ------------------------------------------------------------------------------
if not args.keep:
    tmux("kill-server", check=False)
    time.sleep(1)
    wez("kill-pane", "--pane-id", str(H1), check=False)
print("wrote", os.path.join(OUT, "run.json"))
