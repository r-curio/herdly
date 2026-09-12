"""Race checks against the real release SteerHook, without Codex.

Each case feeds one synthetic PermissionRequest payload to the helper on stdin, plays the companion
(receipt, then a decision at a chosen moment) and records the helper's stdout decision and the
rewritten .approval outcome. Cases run concurrently in separate event directories.

  deadline-before   decision written 27 s after receipt   -> helper must emit allow
  deadline-after    decision written 31 s after receipt   -> helper already handed back; nothing emitted
  disconnect        receipt, then the companion vanishes  -> helper hands back at 30 s; a late click at 40 s is
                    written for the OLD request id and a NEWER request in the same session must ignore it
  simultaneous      two requests in one session/turn      -> deny A and allow B land on their own ids
"""
import json, os, subprocess, sys, threading, time, uuid, shutil

S = os.path.dirname(os.path.abspath(__file__))
HOOK = os.environ.get("STEER_HOOK", os.path.abspath(os.path.join(S, "..", "..", ".build", "arm64-apple-macosx", "release", "SteerHook")))
ROOT = os.path.join(S, "events-helper-race")
shutil.rmtree(ROOT, ignore_errors=True); os.makedirs(ROOT)

def atomic(path, obj):
    tmp = path + ".tmp-" + uuid.uuid4().hex
    with open(tmp, "w") as f: json.dump(obj, f)
    os.link(tmp, path); os.unlink(tmp)

def payload(session, turn, command):
    return json.dumps({"hook_event_name": "PermissionRequest", "session_id": session, "turn_id": turn,
                       "tool_name": "Bash", "cwd": "/tmp/steer-race", "tool_input": {"command": command}})

def run_helper(events, session, turn, command):
    started = time.time()
    proc = subprocess.run([HOOK, "--events-dir", events, "--installation-id", str(uuid.uuid4()).upper()],
                          input=payload(session, turn, command).encode(), capture_output=True)
    return {"started": started, "finished": time.time(), "stdout": proc.stdout.decode(), "exit": proc.returncode}

def wait_request(events, command, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        for name in os.listdir(events):
            if name.endswith(".approval"):
                try: req = json.load(open(os.path.join(events, name)))
                except Exception: continue
                if req.get("details", {}).get("command") == command and req.get("outcome") == "pending":
                    return name[:-9]
        time.sleep(0.05)
    raise RuntimeError("request not published")

def receipt(events, rid):
    now = time.time()
    atomic(os.path.join(events, rid + ".receipt"), {"request_id": rid, "received_at": now, "expires_at": now + 30})
    return now

def decide(events, rid, decision):
    now = time.time()
    atomic(os.path.join(events, rid + ".decision"), {"request_id": rid, "decision": decision, "decided_at": now})
    return now

def outcome(events, rid):
    return json.load(open(os.path.join(events, rid + ".approval"))).get("outcome")

results = {}

def deadline_case(name, delay):
    events = os.path.join(ROOT, name); os.makedirs(events)
    session, turn = str(uuid.uuid4()), str(uuid.uuid4())
    box = {}
    t = threading.Thread(target=lambda: box.update(run_helper(events, session, turn, f"touch {name}")))
    t.start()
    rid = wait_request(events, f"touch {name}")
    received = receipt(events, rid)
    time.sleep(delay)
    decided = decide(events, rid, "allow")
    t.join()
    results[name] = {"request_id": rid, "received_at": received, "decision_written_at": decided,
                     "decision_after_receipt_seconds": round(decided - received, 3),
                     "helper_stdout": box["stdout"], "helper_seconds": round(box["finished"] - box["started"], 3),
                     "approval_outcome": outcome(events, rid)}

def disconnect_case():
    name = "disconnect"
    events = os.path.join(ROOT, name); os.makedirs(events)
    session, turn = str(uuid.uuid4()), str(uuid.uuid4())
    old = {}
    t = threading.Thread(target=lambda: old.update(run_helper(events, session, turn, "touch OLD")))
    t.start()
    old_id = wait_request(events, "touch OLD")
    received = receipt(events, old_id)
    t.join()  # the companion is gone: no decision ever arrives; helper hands back on its own
    handed_back_after = time.time() - received
    old_outcome = outcome(events, old_id)
    # A newer request in the same session and turn starts while the user "returns" and clicks the old row.
    new = {}
    t2 = threading.Thread(target=lambda: new.update(run_helper(events, session, turn, "touch NEW")))
    t2.start()
    new_id = wait_request(events, "touch NEW")
    receipt(events, new_id)
    late_click_written = False
    try:
        decide(events, old_id, "allow"); late_click_written = True
    except FileExistsError:
        late_click_written = False  # the helper's own no_decision record already occupies the slot
    time.sleep(2)
    decide(events, new_id, "deny")
    t2.join()
    results[name] = {"old_request_id": old_id, "old_helper_stdout": old["stdout"], "old_outcome": old_outcome,
                     "old_handed_back_after_seconds": round(handed_back_after, 3),
                     "late_allow_for_old_request_accepted_by_store": late_click_written,
                     "old_decision_record": json.load(open(os.path.join(events, old_id + ".decision"))),
                     "new_request_id": new_id, "new_helper_stdout": new["stdout"], "new_outcome": outcome(events, new_id)}

def simultaneous_case():
    name = "simultaneous"
    events = os.path.join(ROOT, name); os.makedirs(events)
    session, turn = str(uuid.uuid4()), str(uuid.uuid4())
    a, b = {}, {}
    ta = threading.Thread(target=lambda: a.update(run_helper(events, session, turn, "touch A")))
    tb = threading.Thread(target=lambda: b.update(run_helper(events, session, turn, "touch B")))
    ta.start(); tb.start()
    a_id = wait_request(events, "touch A"); b_id = wait_request(events, "touch B")
    receipt(events, a_id); receipt(events, b_id)
    time.sleep(1)
    decide(events, a_id, "deny")
    time.sleep(1)
    decide(events, b_id, "allow")
    ta.join(); tb.join()
    results[name] = {"a_request_id": a_id, "a_helper_stdout": a["stdout"], "a_outcome": outcome(events, a_id),
                     "b_request_id": b_id, "b_helper_stdout": b["stdout"], "b_outcome": outcome(events, b_id),
                     "same_session": session, "same_turn": turn}

threads = [threading.Thread(target=deadline_case, args=("deadline-before", 27)),
           threading.Thread(target=deadline_case, args=("deadline-after", 31)),
           threading.Thread(target=disconnect_case), threading.Thread(target=simultaneous_case)]
for t in threads: t.start()
for t in threads: t.join()
report = {"recorded": time.strftime("%Y-%m-%d"), "helper": HOOK, "cases": results}
os.makedirs(os.path.join(S, "runs"), exist_ok=True)
json.dump(report, open(os.path.join(S, "runs", "helper-race.json"), "w"), indent=2)
print(json.dumps(report, indent=2))
