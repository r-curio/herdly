"""Drive the interactive Codex CLI in a pty for one approval case (allow, deny, timeout).

Usage: python3 tui_run.py <allow|deny|timeout> <marker path> <seconds to wait>
Swaps the trusted lab project's .codex/hooks.json for a single HerdlyHook PermissionRequest hook
and restores it on exit. Hook trust is bypassed per invocation; nothing persisted changes.
Env: HERDLY_LAB_PROJECT (trusted lab dir), HERDLY_HOOK (release HerdlyHook path).
"""
import os, pty, sys, time, select, fcntl, termios, struct, signal, subprocess, json, re, shutil, shlex, uuid
mode, marker, wait_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
S = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.environ.get("HERDLY_LAB_PROJECT", "/Users/dev/code/Herdly/output/desktop-hook-lab")
HOOK = os.environ.get("HERDLY_HOOK", os.path.abspath(os.path.join(S, "..", "..", "output", "Herdly.app", "Contents", "Helpers", "HerdlyHook")))
events = os.path.join(S, "events-" + mode); os.makedirs(events, exist_ok=True)
hooks_path = os.path.join(PROJECT, ".codex", "hooks.json")
backup = hooks_path + ".herdly9-backup"
shutil.copy2(hooks_path, backup)
cmd = f"{shlex.quote(HOOK)} --events-dir {shlex.quote(events)} --installation-id {shlex.quote(str(uuid.uuid4()).upper())}"
with open(hooks_path, "w") as f:
    json.dump({"hooks": {"PermissionRequest": [{"hooks": [{"type": "command", "command": cmd, "timeout": 38}]}]}}, f, indent=2)
standin = subprocess.Popen([sys.executable, os.path.join(S, "companion_standin.py"), events, mode, "1.5"])
raw = open(os.path.join(S, "runs", f"{mode}.tty"), "wb")
def restore():
    shutil.move(backup, hooks_path)
    standin.terminate()
try:
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.chdir(PROJECT)
        os.execvp("/opt/homebrew/bin/codex", ["codex", "-C", PROJECT, "-s", "read-only", "-a", "on-request",
                                              "--dangerously-bypass-hook-trust"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    text = b""
    def pump(seconds):
        global text
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if fd in r:
                try: chunk = os.read(fd, 65536)
                except OSError: return False
                if not chunk: return False
                raw.write(chunk); raw.flush(); text += chunk
        return True
    pump(12)
    prompt = (f"Run exactly this shell command once and request approval for it: touch {marker} . "
              "If approval is not granted, do not retry and do not use any other method. Then reply only DONE.")
    data = prompt.encode()
    for i in range(0, len(data), 24):
        os.write(fd, data[i:i + 24]); pump(0.15)
    pump(1); os.write(fd, b"\r")
    started = time.time()
    while time.time() - started < wait_s:
        pump(2)
        plain = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", text[-4000:])
        if os.path.exists(marker) and b"DONE" in plain: break
        if mode != "allow" and b"DONE" in plain and (b"denied" in plain or b"not granted" in plain.lower()): break
    os.write(fd, b"\x03"); time.sleep(0.5); os.write(fd, b"\x03"); pump(3)
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: pass
finally:
    restore()
plain = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", text).decode("utf-8", "replace")
print("=== marker ===", os.path.exists(marker))
print("=== events ===", sorted(os.listdir(events)))
for name in sorted(os.listdir(events)):
    p = os.path.join(events, name)
    if name.endswith((".approval", ".decision", ".receipt", ".log")):
        print("--", name); print(open(p).read())
lines = [l.strip() for l in plain.splitlines() if l.strip()]
keep = [l for l in lines if re.search(r"approv|permission|hook|denied|DONE|touch|exit|error|Permission", l, re.I)]
print("=== tui excerpts ===")
seen = set()
for l in keep:
    if l not in seen: seen.add(l); print(l[:200])
