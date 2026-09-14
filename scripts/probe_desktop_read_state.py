#!/usr/bin/env python3
"""Read-only probe of the Codex desktop app's unread set, for ongoing format checks.

Prints the state file's write time and the local unread thread ids, then applies Steer's rule to
the desktop completions in Steer's attention snapshot so a human can compare with what the running
app cleared. Nothing is written. Exit status 1 means the format is not what Steer expects.

  python3 scripts/probe_desktop_read_state.py [--codex-home ~/.codex] [--snapshot PATH] [--watch]
"""
import argparse
import datetime as dt
import json
import os
import sys
import time
import uuid

SETTLE_MARGIN = 3.0
LIMIT = 20 * 1024 * 1024


def read_state(path):
    st = os.lstat(path)
    if not os.path.isfile(path) or os.path.islink(path) or st.st_size > LIMIT:
        raise ValueError("not a regular file within the size bound")
    with open(path, "rb") as f:
        root = json.load(f)
    local = root["electron-persisted-atom-state"]["unread-thread-ids-by-host-v1"]["local"]
    unread = set()
    for entry in local:
        unread.add(str(uuid.UUID(entry)))
    return unread, st.st_mtime


def load_snapshot(path):
    try:
        with open(path, "rb") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def report(codex_home, snapshot_path):
    path = os.path.join(codex_home, ".codex-global-state.json")
    try:
        unread, mtime = read_state(path)
    except (OSError, KeyError, TypeError, ValueError) as error:
        print(f"UNAVAILABLE {path}: {error}")
        return 1
    when = dt.datetime.fromtimestamp(mtime).isoformat(timespec="seconds")
    print(f"file written {when} ({time.time() - mtime:.1f}s ago); {len(unread)} local unread threads")
    snapshot = load_snapshot(snapshot_path)
    if snapshot is None:
        print(f"no Steer snapshot at {snapshot_path}")
        return 0
    for completion in snapshot.get("completions", []):
        if completion.get("source") != "desktop":
            continue
        session = str(uuid.UUID(completion["session"]))
        arrived = completion["arrivedAt"]
        if session in unread:
            verdict = "unread in Codex"
        elif mtime < arrived + SETTLE_MARGIN:
            verdict = "no evidence yet (file older than completion + margin)"
        else:
            verdict = "WOULD CLEAR (absent from unread set after completion)"
        print(f"  {session} turn {completion['turn'][:8]} arrived {dt.datetime.fromtimestamp(arrived).isoformat(timespec='seconds')}: {verdict}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--codex-home", default=os.path.expanduser("~/.codex"))
    parser.add_argument("--snapshot", default=os.path.expanduser("~/Library/Application Support/Steer/attention-snapshot.json"))
    parser.add_argument("--watch", action="store_true", help="repeat every 2 seconds until interrupted")
    args = parser.parse_args()
    status = report(args.codex_home, args.snapshot)
    while args.watch:
        time.sleep(2)
        print("---")
        status = report(args.codex_home, args.snapshot)
    return status


if __name__ == "__main__":
    sys.exit(main())
