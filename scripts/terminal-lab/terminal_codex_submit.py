"""Supplemental Terminal.app check for issue #205: does Codex submit a prompt sent by `do script`?

Usage: python3 -I terminal_codex_submit.py <terminal.js> <codex-project> <out-dir>

Opens one standalone Terminal window (no tab group needed), starts a disposable read-only Codex
session, sends a prompt with `do script "<text>" in <tab>`, and if Codex does not answer, sends
`do script ""` (a lone newline) as a separate call. Writes codex-separate-newline.json to <out-dir>,
then ends the session and closes its window.
"""
import json, os, subprocess, sys, time
DRIVER, PROJ, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
def tm(op, **kw):
    r = subprocess.run(["osascript", "-l", "JavaScript", DRIVER, json.dumps({"op": op, **kw})], capture_output=True, text=True, timeout=30)
    if r.returncode: raise RuntimeError(r.stderr)
    return json.loads(r.stdout)
def screen(t): return tm("contents", tty=t)["text"]
def wait(fn, n):
    end=time.time()+n
    while time.time()<end:
        if fn(): return True
        time.sleep(2)
    return False
res={"at": time.time()}
tty = tm("newWindow")["tty"]; res["tty"]=tty
time.sleep(1)
tm("doScript", tty=tty, text=f"cd {json.dumps(PROJ)} && exec {os.path.expanduser('~/.local/bin/codex')} -C {json.dumps(PROJ)} -s read-only -a never 'Reply with only the word READY.'")
res["ready"]=wait(lambda: "READY" in screen(tty).split("Reply with only the word READY.")[-1], 90)
P="Reply with only the word PONG."
for attempt in ("text+newline", "separate-newline", "separate-newline-2"):
    tm("doScript", tty=tty, text=P if attempt=="text+newline" else "")
    ok=wait(lambda: "PONG" in screen(tty).split(P)[-1], 30)
    res[attempt]=ok
    if ok: break
pids=subprocess.run(["ps","-o","pid=","-t",tty.removeprefix("/dev/")],capture_output=True,text=True).stdout.split()
if pids: subprocess.run(["kill","-TERM",*pids])
time.sleep(2)
inv=tm("inventory")
for t in inv["tabs"]:
    if t["tty"]==tty: tm("closeWindow", window=t["window"])
json.dump(res, open(os.path.join(OUT,"codex-separate-newline.json"),"w"), indent=1)
print(json.dumps(res))
