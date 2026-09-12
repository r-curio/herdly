"""Drive the interactive Codex CLI in a pty through a Steer handoff, then answer Codex's own prompt.

Usage: python3 resolution_run.py <case> <marker basename> [--answers y,n] [--standin receipt|handoff]
       [--standin-delay S] [--kill-standin-after S] [--wait S] [--prompt-file PATH] [--explore]

Cases are names for the evidence record. The lab project's .codex/hooks.json is swapped for a single
SteerHook PermissionRequest hook and restored on exit; hook trust is bypassed per invocation only.
After the helper hands the request back (its .approval outcome becomes no_decision), the driver
answers each native prompt with the next key in --answers. With --explore it only records the
prompt text and cancels. Nothing here approves through Steer; answers go to Codex's native prompt.
Env: STEER_LAB_PROJECT (trusted lab dir), STEER_HOOK (release SteerHook path).
"""
import argparse, os, pty, sys, time, select, fcntl, termios, struct, signal, subprocess, json, re, shutil, shlex, uuid

parser = argparse.ArgumentParser()
parser.add_argument("case"); parser.add_argument("marker")
parser.add_argument("--answers", default="y")
parser.add_argument("--standin", default="receipt")
parser.add_argument("--standin-delay", type=float, default=2.0)
parser.add_argument("--kill-standin-after", type=float, default=0)
parser.add_argument("--wait", type=float, default=120)
parser.add_argument("--prompt-file")
parser.add_argument("--explore", action="store_true")
args = parser.parse_args()
S = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.environ.get("STEER_LAB_PROJECT", "/Users/rmaisog/Documents/ChatGPT/Steer/output/desktop-hook-lab")
HOOK = os.environ.get("STEER_HOOK", os.path.abspath(os.path.join(S, "..", "..", ".build", "arm64-apple-macosx", "release", "SteerHook")))
events = os.path.join(S, "events-" + args.case); os.makedirs(events, exist_ok=True)
os.makedirs(os.path.join(S, "runs"), exist_ok=True)
marker = os.path.join(PROJECT, args.marker)
hooks_path = os.path.join(PROJECT, ".codex", "hooks.json")
backup = hooks_path + ".steer10-backup"
shutil.copy2(hooks_path, backup)
cmd = f"{shlex.quote(HOOK)} --events-dir {shlex.quote(events)} --installation-id {shlex.quote(str(uuid.uuid4()).upper())}"
with open(hooks_path, "w") as f:
    json.dump({"hooks": {"PermissionRequest": [{"hooks": [{"type": "command", "command": cmd, "timeout": 38}]}]}}, f, indent=2)
standin = subprocess.Popen([sys.executable, os.path.join(S, "companion_standin.py"), events, args.standin, str(args.standin_delay)])
raw = open(os.path.join(S, "runs", f"{args.case}.tty"), "wb")
timeline = []
def note(event, **extra):
    timeline.append({"t": time.time(), "event": event, **extra})
def restore():
    shutil.move(backup, hooks_path)
    if standin.poll() is None: standin.terminate()
def approvals():
    out = {}
    for name in os.listdir(events):
        if name.endswith(".approval"):
            try: out[name[:-9]] = json.load(open(os.path.join(events, name)))
            except Exception: pass
    return out
def plain(b): return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>]", b"", b).decode("utf-8", "replace")
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
    if args.prompt_file:
        prompt = open(args.prompt_file).read().strip()
    else:
        prompt = (f"Run exactly this shell command once and request approval for it: touch {marker} . "
                  "If approval is not granted, do not retry and do not use any other method. Then reply only DONE.")
    data = prompt.encode()
    for i in range(0, len(data), 24):
        os.write(fd, data[i:i + 24]); pump(0.15)
    pump(1); os.write(fd, b"\r"); note("prompt_sent")
    started = time.time()
    answers = list(args.answers.split(",")) if args.answers else []
    handed = set(); receipted = set(); answered_after = 0; killed = False; done = False
    watermark = len(text)  # only text rendered after a handoff can be Codex's own prompt
    answered_total = 0; last_answer = None
    while time.time() - started < args.wait:
        pump(1)
        for rid, req in approvals().items():
            if rid not in receipted and os.path.exists(os.path.join(events, rid + ".receipt")):
                receipted.add(rid); note("receipt_seen", request=rid)
            if rid not in handed and req.get("outcome") == "no_decision":
                if not handed: watermark = max(watermark, len(text) - 2000)
                handed.add(rid); note("handed_back", request=rid, command=req.get("details", {}).get("command"))
        if args.kill_standin_after and receipted and not killed:
            first = min(e["t"] for e in timeline if e["event"] == "receipt_seen")
            if time.time() - first >= args.kill_standin_after:
                standin.kill(); standin.wait(); killed = True; note("standin_killed", pid=standin.pid)
        tail = plain(text[-6000:])
        fresh = plain(text[watermark:])
        prompts_seen = fresh.count("Would you like to run the following command?")
        # A queued second prompt is drawn by partial line updates, so its heading may never reappear in
        # the stream; fall back to answering the next handed-back request 8 s after the previous answer.
        overdue = answered_total < len(handed) and last_answer and time.time() - last_answer > 8
        if handed and answers and ((prompts_seen > answered_after and "Press enter to confirm" in fresh) or overdue):
            if args.explore:
                note("prompt_observed"); pump(2); break
            key = answers.pop(0)
            pump(1.5)
            if key == "esc":
                os.write(fd, b"\x1b"); note("native_answer", key="esc", meaning="No, and tell Codex what to do differently")
                pump(1.5); os.write(fd, b"\r"); note("feedback_submitted_empty")
            else:
                os.write(fd, key.encode()); note("native_answer", key=key, meaning="Yes, proceed")
            answered_total += 1; last_answer = time.time()
            pump(3)
            watermark = len(text)  # the next prompt must be rendered after this answer, not a redraw of it
            answered_after = 0
        if "DONE" in tail[-800:] and (os.path.exists(marker) or handed):
            pump(3); done = True; note("turn_done"); break
    if not done: note("wait_elapsed")
    os.write(fd, b"\x03"); time.sleep(0.5); os.write(fd, b"\x03"); pump(3)
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: pass
finally:
    restore()
report = {
    "case": args.case, "marker": marker, "marker_exists": os.path.exists(marker), "events": events,
    "timeline": timeline, "approvals": approvals(),
}
for name in sorted(os.listdir(events)):
    if name.endswith((".decision", ".receipt")):
        try: report[name] = json.load(open(os.path.join(events, name)))
        except Exception: pass
json.dump(report, open(os.path.join(S, "runs", f"{args.case}.json"), "w"), indent=2)
print(json.dumps(report, indent=2))
lines = [l.strip() for l in plain(text).splitlines() if l.strip()]
keep = [l for l in lines if re.search(r"approv|permission|hook|denied|reject|DONE|touch|Yes|No|allow|Allow|differently|canceled", l, re.I)]
print("=== tui excerpts ===")
seen = set()
for l in keep:
    if l not in seen: seen.add(l); print(l[:200])
