"""Zellij live targeting proof for issue #208, hosted in WezTerm.

Usage: python3 -I zellij_lab.py --lab-root <dir> [--keep]

Runs an isolated Zellij session `lab` (ZELLIJ_SOCKET_DIR=<lab-root>/zellij/sock, a lab config with
startup tips and release notes off, minimal environment) attached from a WezTerm pane (H1), with
tabs codex, claude, decoy (Codex's title over `sleep`) and split (two shells). For part of the run
a second client attaches from another WezTerm tab (H2). It records pane ids and titles, the
client list and the host tab of each `zellij` client process (by tty, cross-checked with lsof on
the session socket), `focus-pane-id` read back through list-panes, list-clients and the host
pane's title, which client a CLI focus acts on, where `write-chars --pane-id` lands, Codex and
Claude prompt submission, and an unknown pane id. Every write names a pane the lab created;
`dump-screen` of every terminal pane is checked for the probe nonce afterwards.

Launch WezTerm with a clean environment first. Codex and Claude isolation is the same as
iterm2_lab.py. The lab kills its session and host panes at the end. Raw results go to
<lab-root>/zellij/run.json.
"""
import argparse, glob, json, os, re, secrets, shutil, subprocess, sys, time

S = os.path.dirname(os.path.abspath(__file__))
WEZTERM = "/Applications/WezTerm.app/Contents/MacOS/wezterm"
ZELLIJ = "/opt/homebrew/bin/zellij"
BUNDLE = "com.github.wez.wezterm"
CODEX = os.path.expanduser("~/.local/bin/codex")
CLAUDE = os.path.expanduser("~/.local/bin/claude")
CODEX_TITLE = re.compile(r"^[0-9a-f-]{29}\.\.\.$")

ap = argparse.ArgumentParser()
ap.add_argument("--lab-root", required=True)
ap.add_argument("--keep", action="store_true")
args = ap.parse_args()
LAB = os.path.abspath(args.lab_root)
OUT = os.path.join(LAB, "zellij")
SOCK = os.path.join(OUT, "sock")
CFG = os.path.join(OUT, "cfg", "config.kdl")
PROJ = os.path.join(LAB, "project")
CPROJ = os.path.join(LAB, "claude-project")
EVENTS = os.path.join(OUT, "claude-events")
NONCE = secrets.token_hex(4)
ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "LANG": "en_US.UTF-8", "TERM": "xterm-256color",
       "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "ZELLIJ_SOCKET_DIR": SOCK}
log = {"nonce": NONCE, "started": time.time(), "steps": []}


def z(*argv, check=True, timeout=20):
    r = subprocess.run([ZELLIJ, "--session", "lab", "action", *argv], capture_output=True, text=True, timeout=timeout, env=ENV)
    if check and r.returncode != 0:
        raise RuntimeError(f"zellij action {argv[0]} exited {r.returncode}: {r.stderr.strip()[:300]}")
    return r


def wez(*argv, check=True):
    r = subprocess.run([WEZTERM, "cli", "--no-auto-start", *argv], capture_output=True, text=True, timeout=20, env=ENV)
    if check and r.returncode != 0:
        raise RuntimeError(f"wezterm cli {argv[0]} exited {r.returncode}: {r.stderr.strip()[:300]}")
    return r


def panes():
    return [p for p in json.loads(z("list-panes", "--json", "--all").stdout) if not p["is_plugin"]]


def pane(pid):
    return next((p for p in panes() if p["id"] == pid), None)


def clients():
    rows = z("list-clients").stdout.strip().splitlines()[1:]
    return [dict(zip(["client_id", "pane", "command"], r.split(None, 2))) for r in rows]


def screen(pid):
    return z("dump-screen", "--pane-id", f"terminal_{pid}", "--full").stdout


def write(pid, chars):
    return z("write-chars", "--pane-id", f"terminal_{pid}", chars)


def enter(pid):
    return z("write", "--pane-id", f"terminal_{pid}", "13")


def host_title(hp):
    return next((p["title"] for p in json.loads(wez("list", "--format", "json").stdout) if p["pane_id"] == hp), None)


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


def zellij_clients_on_host():
    # zellij client processes and their ttys; the server has no tty ("??").
    rows = subprocess.run(["ps", "-axo", "pid=,tty=,command="], capture_output=True, text=True).stdout.splitlines()
    out = []
    for r in rows:
        pid, tty, cmd = r.split(None, 2)
        if cmd.startswith(ZELLIJ) and "--server" not in cmd and tty != "??":
            out.append({"pid": int(pid), "tty": "/dev/" + tty})
    return out


def lsof_socket_peers():
    sock = os.path.join(SOCK, "contract_version_1", "lab")
    r = subprocess.run(["lsof", "-U", "-F", "pcn"], capture_output=True, text=True)
    hits, pid, cmd = [], None, None
    for line in r.stdout.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("c"):
            cmd = line[1:]
        elif line.startswith("n") and sock in line:
            hits.append({"pid": pid, "command": cmd})
    return hits


def save():
    log["finished"] = time.time()
    with open(os.path.join(OUT, "run.json"), "w") as f:
        json.dump(log, f, indent=2)


# --- setup ---------------------------------------------------------------------------------
shutil.rmtree(SOCK, ignore_errors=True)
for d in (EVENTS, SOCK, os.path.dirname(CFG), PROJ, os.path.join(CPROJ, ".claude")):
    os.makedirs(d, exist_ok=True)
os.chmod(SOCK, 0o700)
for f in glob.glob(os.path.join(EVENTS, "*.json")) + glob.glob(os.path.join(OUT, "leak-*")):
    os.unlink(f)
with open(CFG, "w") as f:
    f.write("show_startup_tips false\nshow_release_notes false\nsession_serialization false\n")
hook = f"/usr/bin/python3 -I {json.dumps(os.path.join(S, 'claude_title_hook.py'))} {json.dumps(EVENTS)}"
with open(os.path.join(CPROJ, ".claude", "settings.json"), "w") as f:
    json.dump({"env": {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"},
               "hooks": {e: [{"hooks": [{"type": "command", "command": hook, "timeout": 10}]}]
                         for e in ("SessionStart", "UserPromptSubmit", "Stop")}}, f, indent=2)

attach = (f"exec env -i HOME=\"$HOME\" USER=\"$USER\" LANG=en_US.UTF-8 TERM=xterm-256color "
          f"PATH=/opt/homebrew/bin:/usr/bin:/bin ZELLIJ_SOCKET_DIR={SOCK} {ZELLIJ} --config {CFG} ")
H1 = int(wez("spawn", "--new-window").stdout)
time.sleep(1.5)
h1_tty = next(p for p in json.loads(wez("list", "--format", "json").stdout) if p["pane_id"] == H1)["tty_name"]
wez("send-text", "--pane-id", str(H1), "--no-paste", attach + "--session lab\r")
wait_for(lambda: subprocess.run([ZELLIJ, "list-sessions", "--short"], capture_output=True, text=True, env=ENV).stdout.strip() == "lab", 15, 0.5)
time.sleep(1.5)
home = panes()[0]["id"]
created = {}
for name in ("codex", "claude", "decoy", "split"):
    before = {p["id"] for p in panes()}
    z("new-tab", "--name", name)
    time.sleep(0.8)
    created[name] = sorted({p["id"] for p in panes()} - before)[0]
before = {p["id"] for p in panes()}
z("new-pane", "--direction", "right")
time.sleep(0.8)
created["split_b"] = sorted({p["id"] for p in panes()} - before)[0]
lab = {"codex": created["codex"], "claude": created["claude"], "decoy": created["decoy"],
       "split_a": created["split"], "split_b": created["split_b"]}
step("version", zellij=subprocess.run([ZELLIJ, "--version"], capture_output=True, text=True).stdout.strip(),
     wezterm=subprocess.run([WEZTERM, "--version"], capture_output=True, text=True).stdout.strip(),
     panes=lab, home=home, host_pane=H1, host_tty=h1_tty)

for key, pid in lab.items():
    write(pid, f"env | cut -d= -f1 | grep -E '^(CLAUDE|CODEX)' > {json.dumps(os.path.join(OUT, 'leak-' + key))}; "
               f"printf '%s' \"$ZELLIJ_PANE_ID\" >> {json.dumps(os.path.join(OUT, 'leak-' + key + '.pane'))}")
    enter(pid)
time.sleep(2)
leaks, pane_env = {}, {}
for key in lab:
    try:
        with open(os.path.join(OUT, "leak-" + key)) as f:
            names = f.read().split()
        with open(os.path.join(OUT, "leak-" + key + ".pane")) as f:
            pane_env[key] = f.read()
    except OSError:
        names = ["<unreadable>"]
    if names:
        leaks[key] = names
step("env_clean", leaks=leaks, zellij_pane_id=pane_env)
if leaks:
    z("close-tab", check=False)
    save()
    sys.exit("Zellij panes inherited agent variables")

write(lab["codex"], f"cd {json.dumps(PROJ)} && exec {CODEX} -C {json.dumps(PROJ)} -s read-only -a never 'Reply with only the word READY.'")
enter(lab["codex"])
write(lab["claude"], f"cd {json.dumps(CPROJ)} && exec {CLAUDE} --setting-sources project 'Reply with only the word READY.'")
enter(lab["claude"])

codex_title = wait_for(lambda: (lambda p: p and CODEX_TITLE.match(p["title"]) and p["title"])(pane(lab["codex"])), 90, 2)
step("codex_title", title=codex_title)
claude_title = wait_for(lambda: (lambda p: p and p["title"].startswith("Herdly Claude ") and p["title"])(pane(lab["claude"])), 150, 2)
step("claude_title", title=claude_title, observed=pane(lab["claude"])["title"])
wait_for(lambda: "READY" in screen(lab["codex"]).split("Reply with only the word READY.")[-1], 90, 2)
wait_for(lambda: "READY" in screen(lab["claude"]).split("Reply with only the word READY.")[-1], 90, 2)

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
    write(lab["decoy"], f"printf '\\033]0;%s\\007' '{codex_title}'; exec sleep 3600")
    enter(lab["decoy"])
time.sleep(2)
step("inventory", panes=[{k: p[k] for k in ("id", "title", "tab_id", "tab_position", "tab_name", "is_focused", "is_floating",
                                             "exited", "terminal_command", "is_selectable")} for p in panes()],
     clients=clients(), zellij_client_processes=zellij_clients_on_host(), socket_peers=lsof_socket_peers(),
     host_title=host_title(H1))

# --- focus-pane-id and read back ------------------------------------------------------------
def focus_case(name, target):
    before = {"clients": clients(), "host_title": host_title(H1)}
    t0 = time.time()
    r = z("focus-pane-id", f"terminal_{target}", check=False)
    settle = wait_for(lambda: (lambda p: p and p["is_focused"] and any(c["pane"] == f"terminal_{target}" for c in clients()))(pane(target)), 3, 0.1)
    elapsed = round(time.time() - t0, 2)
    time.sleep(0.5)
    return step("focus:" + name, target=target, exit=r.returncode, stderr=r.stderr.strip()[:200], before=before,
                after={"clients": clients(), "host_title": host_title(H1),
                       "focused_panes": [p["id"] for p in panes() if p["is_focused"]]},
                matched=bool(settle), elapsed=elapsed)

focus_case("no-keystroke-yet", lab["claude"])
# A keystroke from H1's client (a space then backspace into its focused shell pane) makes it the
# last active client, which is the client CLI focus actions apply to.
wez("send-text", "--pane-id", str(H1), "--no-paste", " \x7f")
time.sleep(1)
focus_case("other-tab", lab["claude"])
focus_case("split-a", lab["split_a"])
focus_case("split-b", lab["split_b"])
focus_case("already-focused", lab["split_b"])
focus_case("back-to-codex", lab["codex"])

# Second client: which client does a CLI focus act on?
H2 = int(wez("spawn", "--window-id", str(next(p for p in json.loads(wez("list", "--format", "json").stdout) if p["pane_id"] == H1)["window_id"])).stdout)
time.sleep(1.5)
h2_tty = next(p for p in json.loads(wez("list", "--format", "json").stdout) if p["pane_id"] == H2)["tty_name"]
wez("send-text", "--pane-id", str(H2), "--no-paste", attach + "attach lab\r")
wait_for(lambda: len(clients()) == 2, 15, 0.5)
step("second_client", host_pane=H2, host_tty=h2_tty, clients=clients(),
     zellij_client_processes=zellij_clients_on_host(), socket_peers=lsof_socket_peers())
focus_case("two-clients-no-keystroke", lab["decoy"])
# A keystroke from H2's client (a space then backspace into its focused pane) makes it the last active client.
wez("send-text", "--pane-id", str(H2), "--no-paste", " \x7f")
time.sleep(1)
focus_case("two-clients-after-h2-keystroke", lab["split_a"])
step("two_clients_hosts", h1=host_title(H1), h2=host_title(H2))
wez("kill-pane", "--pane-id", str(H2), check=False)
wait_for(lambda: len(clients()) == 1, 10, 0.5)
step("second_client_gone", clients=clients())

# --- write landing -------------------------------------------------------------------------
write(lab["split_a"], f"echo PROBE-{NONCE}-I1")
enter(lab["split_a"])
time.sleep(1.5)
step("write:shell", front=front_app())
r_bad = z("write-chars", "--pane-id", "terminal_999", f"echo PROBE-{NONCE}-bad", check=False)
step("write:unknown-pane", exit=r_bad.returncode, stderr=r_bad.stderr.strip()[:200])

P = "Reply with only the word PONG."
results = {}
for key in ("codex", "claude"):
    pid = lab[key]
    write(pid, P + "\r")
    ok = wait_for(lambda: "PONG" in screen(pid).split(P)[-1], 45, 2)
    results[key] = {"text+CR in one write-chars": bool(ok)}
    if not ok:
        enter(pid)
        ok = wait_for(lambda: "PONG" in screen(pid).split(P)[-1], 45, 2)
        results[key]["separate CR"] = bool(ok)
step("write:tui-prompt", results=results)

landing = {}
for p in panes():
    t = screen(p["id"])
    landing[p["id"]] = {"I1": t.count(f"PROBE-{NONCE}-I1"), "bad": t.count(f"PROBE-{NONCE}-bad")}
step("write:landing", panes=landing, I1_target=lab["split_a"])
save()

# --- teardown ------------------------------------------------------------------------------
if not args.keep:
    subprocess.run([ZELLIJ, "kill-session", "lab"], capture_output=True, env=ENV)
    time.sleep(1)
    wez("kill-pane", "--pane-id", str(H1), check=False)
print("wrote", os.path.join(OUT, "run.json"))
