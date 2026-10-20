"""Stand-in for the Herdly companion's receipt and decision writes. Same JSON shapes as ApprovalStore.

Modes:
  allow | deny        receipt, then that decision after <delay> seconds
  timeout | receipt   receipt only; the helper hands back at its own 30-second deadline
  handoff             receipt, then a no_decision record after <delay> seconds (Open in Codex / focus handoff)
"""
import json, os, sys, time, uuid
events, mode, delay = sys.argv[1], sys.argv[2], float(sys.argv[3])
seen = {}
log = open(os.path.join(events, f"standin-{mode}.log"), "a")
def atomic(path, obj):
    tmp = os.path.join(events, ".standin-" + uuid.uuid4().hex)
    with open(tmp, "w") as f: json.dump(obj, f)
    os.link(tmp, path); os.unlink(tmp)   # link fails if a file already exists: never replace
while True:
    for name in os.listdir(events):
        if not name.endswith(".approval"): continue
        rid = name[:-9]
        if rid in seen: continue
        try: req = json.load(open(os.path.join(events, name)))
        except Exception: continue
        if req.get("outcome") != "pending": continue
        now = time.time()
        atomic(os.path.join(events, rid + ".receipt"), {"request_id": rid, "received_at": now, "expires_at": now + 30})
        log.write(f"{now:.6f} receipt {rid} command={req.get('details',{}).get('command')!r}\n"); log.flush()
        seen[rid] = now
        if mode in ("allow", "deny", "handoff"):
            time.sleep(delay)
            decided = time.time()
            decision = "no_decision" if mode == "handoff" else mode
            atomic(os.path.join(events, rid + ".decision"), {"request_id": rid, "decision": decision, "decided_at": decided})
            log.write(f"{decided:.6f} decision {decision} {rid}\n"); log.flush()
    time.sleep(0.2)
