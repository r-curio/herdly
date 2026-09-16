#!/usr/bin/env python3
"""Disposable Claude Code hook probe for the lifecycle/approval proof.

Modes (argv[1]):
  observe        record the hook payload and exit 0 with no output (default)
  permission     record, then act as a stand-in for Steer's approval helper:
                 publish one fresh request, wait <=5 s for a companion receipt,
                 then <=30 s (31 s bound) for a decision bound to that exact
                 request. No receipt, no decision, expiry, malformed, mismatched
                 or late records all hand back to Claude's native prompt.
  stop-continue  record; if <run>/stop-continue-armed exists and this is the
                 first Stop for the prompt, consume the marker and ask Claude to
                 continue once.
  question       record an AskUserQuestion call, wait for one exact human answer,
                 then return the original questions plus that answer as updatedInput.

Failure injection for the helper (file <run>/helper-mode, one word):
  crash   exit 1 with stderr before publishing anything
  hang    sleep past the hook timeout after publishing

Evidence goes to $STEER_LAB_RUN/events/<session_id>.jsonl (fallback argv[2]).
Nothing here approves on error or timeout, synthesizes keystrokes, or answers
for the human. Only the companion stand-in (driven by the human) writes decisions.
"""
import json, os, sys, time, uuid

MODE = sys.argv[1] if len(sys.argv) > 1 else "observe"
RUN = os.environ.get("STEER_LAB_RUN") or (sys.argv[2] if len(sys.argv) > 2 else os.getcwd())
HOME = os.path.expanduser("~")
CONNECTION_TIMEOUT = float(os.environ.get("STEER_LAB_CONNECTION_TIMEOUT", "5"))
HANDOFF_TIMEOUT = float(os.environ.get("STEER_LAB_HANDOFF_TIMEOUT", "30"))
WAIT_BOUND = 31.0
POLL = 0.02
TRUNCATE = 400


def sanitize(value):
    if isinstance(value, str):
        value = value.replace(HOME, "~")
        return value if len(value) <= TRUNCATE else value[:TRUNCATE] + f"…[+{len(value) - TRUNCATE} chars]"
    if isinstance(value, list):
        return [sanitize(v) for v in value]
    if isinstance(value, dict):
        return {k: sanitize(v) for k, v in value.items()}
    return value


def atomic_write(path, obj):
    tmp = path + "." + uuid.uuid4().hex
    with open(tmp, "w") as f:
        json.dump(obj, f, sort_keys=True)
    os.link(tmp, path)  # never replace an existing record
    os.unlink(tmp)


def read_json(path, limit=4096):
    try:
        if os.path.islink(path) or not os.path.isfile(path) or os.path.getsize(path) > limit:
            return None
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def record(session, obj):
    d = os.path.join(RUN, "events")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"{session or 'unknown'}.jsonl"), "a") as f:
        f.write(json.dumps(sanitize(obj), sort_keys=True) + "\n")


raw = sys.stdin.read()
try:
    payload = json.loads(raw) if raw.strip() else {}
except Exception:
    payload = {"unparseable_stdin": raw[:TRUNCATE]}
session = payload.get("session_id")
now = time.time()
base = {
    "probe": "steer-claude-lifecycle-lab/1",
    "received_at": now,
    "received_iso": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + f".{int((now % 1) * 1e6):06d}Z",
    "monotonic": time.monotonic(),
    "hook_pid": os.getpid(),
    "hook_ppid": os.getppid(),
    "mode": MODE,
    "env": {k: os.environ.get(k) for k in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_EFFORT", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE") if k in os.environ},
    "payload": payload,
}
record(session, base)

if MODE == "stop-continue" and payload.get("hook_event_name") == "Stop":
    marker = os.path.join(RUN, "stop-continue-armed")
    if os.path.exists(marker) and not payload.get("stop_hook_active"):
        os.unlink(marker)
        record(session, {"probe_note": "stop-continue: asked Claude to continue once", "prompt_id": payload.get("prompt_id"), "received_at": time.time()})
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "Stop", "continueConversation": True,
                                                 "additionalContext": "Lab continuation: reply with exactly the word continued."}}))
    sys.exit(0)

is_question = MODE == "question" and payload.get("hook_event_name") == "PreToolUse" \
    and payload.get("tool_name") == "AskUserQuestion"
is_permission = MODE == "permission" and payload.get("hook_event_name") == "PermissionRequest"
if not is_question and not is_permission:
    sys.exit(0)

helper_mode = ""
try:
    with open(os.path.join(RUN, "helper-mode")) as f:
        helper_mode = f.read().strip()
except Exception:
    pass

if helper_mode == "crash":
    record(session, {"probe_note": "helper crash injected (exit 1, nothing published)", "received_at": time.time()})
    print("steer-lab helper: injected crash", file=sys.stderr)
    sys.exit(1)

req_dir = os.path.join(RUN, "requests")
rcpt_dir = os.path.join(RUN, "receipts")
dec_dir = os.path.join(RUN, "decisions")
for d in (req_dir, rcpt_dir, dec_dir):
    os.makedirs(d, exist_ok=True)

rid = str(uuid.uuid4()).upper()
published = time.time()
tool_input = payload.get("tool_input") or {}
request = {
    "kind": "question" if is_question else "permission",
    "request_id": rid,
    "session_id": session,
    "prompt_id": payload.get("prompt_id"),
    "tool_use_id": payload.get("tool_use_id"),
    "agent_id": payload.get("agent_id"),
    "tool_name": payload.get("tool_name"),
    "command": tool_input.get("command"),
    "description": tool_input.get("description"),
    "cwd": payload.get("cwd"),
    "upstream_timeout": payload.get("timeout"),
    "published_at": published,
    "expires_at": published + HANDOFF_TIMEOUT,
    "outcome": "pending",
}
if is_question:
    request["tool_input"] = tool_input
atomic_write(os.path.join(req_dir, rid + ".json"), sanitize(request))


def finish(outcome, extra=None):
    rec = {"probe_note": "helper outcome", "request_id": rid, "tool_use_id": request["tool_use_id"],
           "prompt_id": request["prompt_id"], "outcome": outcome, "received_at": time.time(),
           "seconds_since_publish": round(time.time() - published, 3)}
    if extra:
        rec.update(extra)
    record(session, rec)
    if outcome == "answered":
        return
    if outcome in ("allow", "deny"):
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                                 "decision": {"behavior": outcome}}}))
    sys.exit(0)


if helper_mode == "hang":
    record(session, {"probe_note": "helper hang injected after publish (sleeping 90 s)", "request_id": rid, "received_at": time.time()})
    time.sleep(90)
    finish("hang-returned-without-decision")

# Receipt: the companion must acknowledge this exact request within the connection timeout.
start = time.monotonic()
receipt = None
while time.monotonic() - start < CONNECTION_TIMEOUT:
    r = read_json(os.path.join(rcpt_dir, rid + ".json"))
    if r and r.get("request_id") == rid and isinstance(r.get("received_at"), (int, float)) \
            and published <= r["received_at"] <= time.time():
        receipt = r
        break
    time.sleep(POLL)
if receipt is None:
    finish("no_receipt_question_handoff" if is_question else "no_receipt_handoff")

# Decision: the 30 s clock starts at the receipt, as in Steer's helper. A decision bound to this
# request, decided after the receipt and before expiry, counts; anything else is no decision.
got = time.monotonic()
expiry = got + HANDOFF_TIMEOUT
hard = min(expiry + 1, got + WAIT_BOUND)
seen = None
while time.monotonic() < hard:
    d = read_json(os.path.join(dec_dir, rid + ".json"))
    if d is not None:
        seen = d
        if is_question:
            answer = d.get("answer")
            exact = d.get("session_id") == session and d.get("prompt_id") == request["prompt_id"] \
                and d.get("tool_use_id") == request["tool_use_id"]
            ok = d.get("request_id") == rid and exact and isinstance(answer, str) and answer.strip() \
                and isinstance(d.get("decided_at"), (int, float)) \
                and receipt["received_at"] <= d["decided_at"] <= time.time()
            if not ok:
                finish("malformed_or_mismatched_question_handoff", {"decision_record": d})
            if time.monotonic() < expiry:
                questions = tool_input.get("questions")
                if not isinstance(questions, list) or len(questions) != 1 \
                        or not isinstance(questions[0].get("question"), str):
                    finish("unsupported_question_shape_handoff")
                updated = dict(tool_input)
                updated["answers"] = {questions[0]["question"]: answer.strip()}
                finish("answered", {"decision_record": d, "receipt": receipt})
                print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                    "permissionDecision": "allow", "updatedInput": updated}}))
                sys.exit(0)
        ok = d.get("request_id") == rid and d.get("decision") in ("allow", "deny", "no_decision") \
            and isinstance(d.get("decided_at"), (int, float)) and receipt["received_at"] <= d["decided_at"] <= time.time()
        if ok and d["decision"] == "no_decision":
            finish("companion_handoff", {"decision_record": d})
        if ok and time.monotonic() < expiry:
            finish(d["decision"], {"decision_record": d, "receipt": receipt})
        if not ok:
            finish("malformed_or_mismatched_decision_handoff", {"decision_record": d})
    if time.monotonic() >= expiry:
        break
    time.sleep(POLL)
finish("expired_question_handoff" if is_question else "expired_handoff",
       {"decision_record": seen, "receipt": receipt})
