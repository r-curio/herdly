#!/usr/bin/env python3
"""Stand-in for the Steer notch, driven by the human in a second terminal.

Usage: companion.py <run-dir> [auto-mode]

It watches <run>/requests, writes a receipt for each new pending request at
once (unless auto-mode is "none"), prints the request, and then waits for the
human to type a decision. It never decides on its own.

Commands at the prompt (n = request number as printed):
  a n          allow request n now
  d n          deny request n now
  h n          hand back without a decision now (Open in Claude / focus handoff)
  late a n S   allow request n after S seconds (late click); same for late d
  dup a n      write a second decision record for n (should be ignored)
  wrong a n    write a decision whose request_id does not match n (should be ignored)
  answer n X   answer question request n with selected label(s) or free text X
  late-answer n S X  write that answer after S seconds
  q            quit

auto-mode (optional, for unattended timing runs only):
  receipt   receipt only, never a decision (helper hands back at its deadline)
  none      do not even write a receipt (companion absent)
"""
import json, os, sys, threading, time, uuid

RUN = sys.argv[1]
AUTO = sys.argv[2] if len(sys.argv) > 2 else "manual"
REQ, RCPT, DEC = (os.path.join(RUN, d) for d in ("requests", "receipts", "decisions"))
for d in (REQ, RCPT, DEC):
    os.makedirs(d, exist_ok=True)
LOG = open(os.path.join(RUN, "companion.log"), "a")
seen, order = {}, []


def log(msg):
    line = f"{time.time():.6f} {msg}"
    LOG.write(line + "\n"); LOG.flush()
    print(line, flush=True)


def atomic(path, obj):
    tmp = path + "." + uuid.uuid4().hex
    with open(tmp, "w") as f:
        json.dump(obj, f, sort_keys=True)
    try:
        os.link(tmp, path)
    except FileExistsError:
        log(f"refused to replace existing record {os.path.basename(path)}")
    os.unlink(tmp)


def decide(n, decision, delay=0.0, wrong=False):
    rid = order[n - 1]
    if delay:
        log(f"scheduled {decision} for #{n} {rid} in {delay}s")
        time.sleep(delay)
    target = str(uuid.uuid4()).upper() if wrong else rid
    atomic(os.path.join(DEC, rid + ".json"), {"request_id": target, "decision": decision, "decided_at": time.time()})
    log(f"wrote decision {decision} for #{n} file={rid} request_id={target}")


def answer(n, value, delay=0.0):
    rid = order[n - 1]
    req = seen[rid]
    if delay:
        log(f"scheduled answer for #{n} {rid} in {delay}s")
        time.sleep(delay)
    atomic(os.path.join(DEC, rid + ".json"), {
        "request_id": rid, "session_id": req.get("session_id"),
        "prompt_id": req.get("prompt_id"), "tool_use_id": req.get("tool_use_id"),
        "answer": value, "decided_at": time.time(),
    })
    log(f"wrote answer {value!r} for #{n} file={rid}")


def watcher():
    while True:
        for name in sorted(os.listdir(REQ)):
            if not name.endswith(".json") or "." in name[:-5]:
                continue
            rid = name[:-5]
            if rid in seen:
                continue
            try:
                req = json.load(open(os.path.join(REQ, name)))
            except Exception:
                continue
            seen[rid] = req; order.append(rid)
            n = len(order)
            if AUTO != "none":
                atomic(os.path.join(RCPT, rid + ".json"), {"request_id": rid, "received_at": time.time(),
                                                            "expires_at": req.get("expires_at")})
            if req.get("kind") == "question":
                questions = (req.get("tool_input") or {}).get("questions") or []
                rendered = "\n".join(
                    f"    {q.get('question')} options={[o.get('label') for o in q.get('options', [])]} multi={q.get('multiSelect')}"
                    for q in questions
                )
                action = f"answer {n} <chosen label(s) or free text> | late-answer {n} <seconds> <answer>"
            else:
                rendered = f"    command={req.get('command')!r}"
                action = f"a {n} | d {n} | h {n} | late a {n} 45 | dup a {n} | wrong a {n}"
            log(f"REQUEST #{n} {rid}\n    session={req.get('session_id')} prompt={req.get('prompt_id')}\n"
                f"    tool_use_id={req.get('tool_use_id')} agent_id={req.get('agent_id')}\n{rendered}\n"
                f"    receipt={'written' if AUTO != 'none' else 'WITHHELD'}; type: {action}")
        time.sleep(0.2)


threading.Thread(target=watcher, daemon=True).start()
log(f"companion stand-in started run={RUN} mode={AUTO}")
if AUTO != "manual":
    while True:
        time.sleep(1)
while True:
    try:
        line = input("> ")
        parts = line.split()
    except EOFError:
        break
    if not parts:
        continue
    try:
        if parts[0] == "q":
            break
        if parts[0] in ("a", "d", "h"):
            decide(int(parts[1]), {"a": "allow", "d": "deny", "h": "no_decision"}[parts[0]])
        elif parts[0] == "late":
            threading.Thread(target=decide, args=(int(parts[2]), {"a": "allow", "d": "deny"}[parts[1]], float(parts[3])), daemon=True).start()
        elif parts[0] == "dup":
            decide(int(parts[2]), {"a": "allow", "d": "deny"}[parts[1]])
        elif parts[0] == "wrong":
            decide(int(parts[2]), {"a": "allow", "d": "deny"}[parts[1]], wrong=True)
        elif parts[0] == "answer":
            answer(int(parts[1]), line.split(maxsplit=2)[2])
        elif parts[0] == "late-answer":
            n, delay, value = line.split(maxsplit=3)[1:]
            threading.Thread(target=answer, args=(int(n), value, float(delay)), daemon=True).start()
        else:
            print("unknown command; see header of this script")
    except (IndexError, ValueError, KeyError) as e:
        print(f"bad command: {e}")
