#!/usr/bin/env python3
"""H7 lab for #270: does a running Herdly relaunch a terminal app that quits?

WARNING: this QUITS THE REAL APP (SIGTERM to its process). Every window, tab and shell
in it ends, including any running Codex or Claude session. Run it only with the
operator's explicit consent, from a terminal app other than the one named, and only
after saving any work in that app. It never launches, types into or scripts any app.

    python3 scripts/terminal-lab/quit_relaunch_lab.py iterm2|terminal|ghostty|wezterm \
        --i-understand-this-quits-the-app [--seconds 120]

It checks that Herdly is running and the named app is running (its own process, with
no controlling terminal), sends SIGTERM to that process, then polls the process table
every second for `--seconds` (default 120) and reports whether a new process of the
app appeared. Exit status: 0 stayed closed, 1 relaunched, 2 precondition or usage
failure. Record the result with the Herdly build under test (docs/cli-notch-integration.md,
"Never launching the app (#270)").
"""
import argparse
import os
import signal
import subprocess
import sys
import time

APPS = {
    "iterm2": "/iTerm.app/Contents/MacOS/iTerm2",
    "terminal": "/Terminal.app/Contents/MacOS/Terminal",
    "ghostty": "/Ghostty.app/Contents/MacOS/ghostty",
    "wezterm": "/WezTerm.app/Contents/MacOS/wezterm-gui",
}
HERDLY = "/Herdly.app/Contents/MacOS/Herdly"


def app_processes(suffix):
    """PIDs whose executable path ends with `suffix` and that have no controlling terminal."""
    result = subprocess.run(["/bin/ps", "-axo", "pid=,tty=,comm="], capture_output=True, text=True,
                            timeout=10, check=True)
    pids = []
    for line in result.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] == "??" and parts[2].endswith(suffix):
            pids.append(int(parts[0]))
    return pids


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", choices=sorted(APPS))
    parser.add_argument("--i-understand-this-quits-the-app", dest="consent", action="store_true")
    parser.add_argument("--seconds", type=int, default=120)
    args = parser.parse_args()
    if not args.consent:
        print("Refusing: this quits the real app. Pass --i-understand-this-quits-the-app with the operator's consent.",
              file=sys.stderr)
        return 2
    if not 1 <= args.seconds <= 600:
        print("--seconds must be between 1 and 600", file=sys.stderr)
        return 2
    herdly = app_processes(HERDLY)
    if not herdly:
        print("Herdly is not running; the check needs it running with the app's switch on.", file=sys.stderr)
        return 2
    suffix = APPS[args.app]
    before = app_processes(suffix)
    if len(before) != 1:
        print(f"Expected one running {args.app} process, found {before}.", file=sys.stderr)
        return 2
    print(f"Herdly pid(s) {herdly}; quitting {args.app} pid {before[0]} with SIGTERM.")
    os.kill(before[0], signal.SIGTERM)
    start = time.monotonic()
    while time.monotonic() - start < args.seconds:
        time.sleep(1)
        current = [pid for pid in app_processes(suffix) if pid != before[0]]
        if current:
            print(f"RELAUNCHED: new {args.app} pid(s) {current} after {time.monotonic() - start:.0f} s.")
            return 1
    still = app_processes(suffix)
    if before[0] in still:
        print(f"{args.app} pid {before[0]} did not exit within {args.seconds} s; inconclusive.", file=sys.stderr)
        return 2
    print(f"STAYED CLOSED: no {args.app} process for {args.seconds} s.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
