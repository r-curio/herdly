"""Lab stand-in for HerdlyHook's Claude --terminal-title behaviour (terminal-host live proofs).

Usage (registered in the lab project's .claude/settings.json only):
  python3 -I claude_title_hook.py <events-dir>

Records the hook event's session id, the terminal-host variables in its environment and the
controlling tty of its ancestors, then, for SessionStart, prints the same OSC 2 title HerdlyHook
emits (`Herdly Claude <session id>`). Prints nothing else on stdout.
"""
import json, os, subprocess, sys, time

ENV_KEYS = ("ITERM_SESSION_ID", "TERM_SESSION_ID", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
            "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET", "TMUX", "TMUX_PANE",
            "ZELLIJ", "ZELLIJ_PANE_ID", "ZELLIJ_SESSION_NAME")


def ancestor_ttys():
    out, pid = [], os.getppid()
    for _ in range(8):
        try:
            line = subprocess.run(["ps", "-o", "ppid=,tty=,comm=", "-p", str(pid)], capture_output=True,
                                  text=True, timeout=2).stdout.split(None, 2)
        except Exception:
            break
        if len(line) < 3:
            break
        out.append({"pid": pid, "tty": line[1], "comm": os.path.basename(line[2].strip())})
        pid = int(line[0])
        if pid <= 1:
            break
    return out


def main():
    events = sys.argv[1]
    os.makedirs(events, exist_ok=True)
    payload = json.load(sys.stdin)
    event = payload.get("hook_event_name")
    session = payload.get("session_id")
    record = {"at": time.time(), "event": event, "session_id": session,
              "env": {k: os.environ.get(k) for k in ENV_KEYS if k in os.environ},
              "ancestors": ancestor_ttys()}
    with open(os.path.join(events, f"{time.time_ns()}-{event}.json"), "w") as f:
        json.dump(record, f)
    if event == "SessionStart" and isinstance(session, str):
        sys.stdout.write(json.dumps({"terminalSequence": f"\x1b]2;Herdly Claude {session}\x07"}))


main()
