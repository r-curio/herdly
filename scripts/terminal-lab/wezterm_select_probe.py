"""WezTerm select probe for issue #206: what does `wezterm cli activate-pane` actually bring forward?

Usage: python3 -I wezterm_select_probe.py --lab-root <dir>

WezTerm 20240203's CLI cannot report which tab a window shows (`list` has only the pane that is
active within each tab, and `list-clients` keeps a stale focused_pane_id). This probe gives each
lab pane a unique OSC 2 title, runs `activate-pane` with and without raising the app, and reads
the front WezTerm window's title from the window server (onscreen_windows.swift, which needs the
calling process to have Screen Recording permission). WezTerm titles each window after its active
tab's active pane, so the front window's title names the pane on screen.

It also records which title wins when a pane sets both an OSC 1 icon title and an OSC 2 window
title. Results go to <lab-root>/wezterm/select-probe.json; all lab panes are killed afterwards.
"""
import argparse, json, os, re, secrets, subprocess, sys, time

S = os.path.dirname(os.path.abspath(__file__))
WEZTERM = "/Applications/WezTerm.app/Contents/MacOS/wezterm"
BUNDLE = "com.github.wez.wezterm"
CLEAN_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}

ap = argparse.ArgumentParser()
ap.add_argument("--lab-root", required=True)
ap.add_argument("--single-window", action="store_true",
                help="omit window Y so window X is the only WezTerm window and its tab switches are visible")
ap.add_argument("--close-pane", type=int, action="append", default=[],
                help="with --single-window: a pane the lab owner opened earlier (e.g. WezTerm's launch window) to close first")
args = ap.parse_args()
LAB = os.path.abspath(args.lab_root)
OUT = os.path.join(LAB, "wezterm")
HELPER = os.path.join(LAB, "bin", "onscreen_windows")
if not os.path.exists(HELPER):
    os.makedirs(os.path.dirname(HELPER), exist_ok=True)
    subprocess.run(["swiftc", "-O", os.path.join(S, "onscreen_windows.swift"), "-o", HELPER], check=True)
TAG = "LAB" + secrets.token_hex(2)
log = {"tag": TAG, "steps": []}


def cli(*argv, check=True):
    r = subprocess.run([WEZTERM, "cli", "--no-auto-start", *argv], capture_output=True, text=True, timeout=20, env=CLEAN_ENV)
    if check and r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[:300])
    return r


def panes():
    return json.loads(cli("list", "--format", "json").stdout)


def front_app():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(["lsappinfo", "info", "-only", "bundleid", asn], capture_output=True, text=True).stdout
    m = re.search(r'"CFBundleIdentifier"="([^"]+)"', info)
    return m.group(1) if m else info.strip()


def front_window_name():
    rows = [w for w in json.loads(subprocess.run([HELPER, BUNDLE], capture_output=True, text=True).stdout or "[]") if w["layer"] == 0]
    return rows[0].get("name") if rows else None


def state():
    return {"front_app": front_app(), "front_wezterm_window": front_window_name(),
            "focused_pane_ids": [c.get("focused_pane_id") for c in json.loads(cli("list-clients", "--format", "json").stdout)],
            "active_in_tab": {p["pane_id"]: p["is_active"] for p in panes() if p["pane_id"] in lab.values()},
            "window_titles": {p["window_id"]: p["window_title"] for p in panes() if p["pane_id"] in lab.values()}}


def step(name, **data):
    data = {"step": name, **data}
    log["steps"].append(data)
    print(json.dumps(data)[:500], flush=True)


x1 = int(cli("spawn", "--new-window").stdout)
win_x = next(p for p in panes() if p["pane_id"] == x1)["window_id"]
x2 = int(cli("spawn", "--window-id", str(win_x)).stdout)
x2b = int(cli("split-pane", "--pane-id", str(x2), "--right").stdout)
lab = {"x1": x1, "x2": x2, "x2b": x2b}
for pid in args.close_pane:
    cli("kill-pane", "--pane-id", str(pid), check=False)
if not args.single_window:
    lab["y1"] = int(cli("spawn", "--new-window").stdout)
time.sleep(1.5)
for key, pid in lab.items():
    title = f"{TAG}-{key}"
    seq = f"printf '\\033]1;ICON-{title}\\007\\033]2;{title}\\007'" if key == "x2b" else f"printf '\\033]2;{title}\\007'"
    cli("send-text", "--pane-id", str(pid), "--no-paste", f"{seq}; exec sleep 600\r")
time.sleep(2)
step("titles", panes={p["pane_id"]: {"title": p["title"], "tab_title": p["tab_title"], "window_title": p["window_title"]}
                      for p in panes() if p["pane_id"] in lab.values()}, lab=lab)

def case(name, target, raise_app, from_finder):
    if from_finder:
        subprocess.run(["open", "-a", "Finder"], check=True)
        time.sleep(1)
    before = state()
    r = cli("activate-pane", "--pane-id", str(lab[target]), check=False)
    if raise_app:
        subprocess.run(["open", "-b", BUNDLE], check=True)
    time.sleep(1.2)
    after = state()
    step("select:" + name, target=target, raise_app=raise_app, activate_exit=r.returncode, before=before, after=after,
         front_names_target=after["front_wezterm_window"] == f"{TAG}-{target}" and after["front_app"] == BUNDLE)

subprocess.run(["open", "-b", BUNDLE], check=True)
time.sleep(1)
if args.single_window:
    case("single:other-tab", "x1", False, False)
    case("single:back-to-split-tab", "x2b", False, False)
    case("single:split-sibling", "x2", False, False)
    case("single:other-tab-raise-from-finder", "x1", True, True)
    case("single:split-tab-raise-from-finder", "x2b", True, True)
cases_multi = not args.single_window
if cases_multi:
  case("pane-in-other-tab-same-window", "x1", False, False)
  case("back-to-split-tab", "x2b", False, False)
  case("split-sibling", "x2", False, False)
  case("other-window-with-raise-from-finder", "y1", True, True)
  case("back-window-with-raise-from-finder", "x2b", True, True)
  case("other-tab-with-raise-from-finder", "x1", True, True)

with open(os.path.join(OUT, "select-probe-single.json" if args.single_window else "select-probe.json"), "w") as f:
    json.dump(log, f, indent=2)
for pid in lab.values():
    cli("kill-pane", "--pane-id", str(pid), check=False)
print("wrote", OUT)
