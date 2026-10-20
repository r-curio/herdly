"""Lab-only Claude Code hook for issue #71. Mirrors HerdlyHook's Claude approval file protocol for any tool.

Invoked by the lab project's .claude/settings.json only. Every hook event is logged as identifiers and
keys (no prompt or file content). A PermissionRequest publishes <rid>.request plus a <rid>.live heartbeat,
waits up to 5 s for <rid>.receipt, then until the receipt's expires_at for <rid>.decision. Only an
explicit allow/deny decision produces stdout; no_decision, missing receipt, deadline, or any error exits 0
silently so Claude's native prompt stays the authority. After emitting, it writes <rid>.delivery.

Usage: python3 -I lab_helper.py <events dir>
"""
import json, os, sys, time, uuid

EVENTS = sys.argv[1]
os.makedirs(EVENTS, exist_ok=True)


def atomic(path, obj):
    tmp = os.path.join(EVENTS, ".tmp-" + uuid.uuid4().hex)
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.link(tmp, path)  # fails if the target exists: never replace a record
    os.unlink(tmp)


def log(entry):
    entry["t"] = time.time()
    entry["pid"] = os.getpid()
    with open(os.path.join(EVENTS, "hooks.jsonl"), "a") as f:
        f.write(json.dumps(entry) + "\n")


def read(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


try:
    payload = json.loads(sys.stdin.read(64 * 1024))
except Exception:
    sys.exit(0)

event = payload.get("hook_event_name")
tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
summary = {
    "event": event, "keys": sorted(payload.keys()),
    "session_id": payload.get("session_id"), "prompt_id": payload.get("prompt_id"),
    "tool_name": payload.get("tool_name"), "tool_use_id": payload.get("tool_use_id"),
    "file_path": tool_input.get("file_path"), "permission_mode": payload.get("permission_mode"),
    "notification_type": payload.get("notification_type"),
    "transcript_path": payload.get("transcript_path"),
    # Key -> type (and length for strings), so a family proof can state the display fields without content.
    "tool_input_shape": {k: (f"str[{len(v)}]" if isinstance(v, str) else type(v).__name__)
                         for k, v in tool_input.items()} or None,
    # Path-like targets only; lab paths are disposable.
    "targets": {k: tool_input[k] for k in ("file_path", "notebook_path", "path", "pattern", "cell_id", "edit_mode",
                                           "cell_type", "replace_all", "offset", "limit", "url", "query", "mode")
                if k in tool_input} or None,
}
if event != "PermissionRequest":
    log(summary)
    sys.exit(0)

rid = str(uuid.uuid4())
published = time.time()
summary["request_id"] = rid
log(summary)
request = {"request_id": rid, "published_at": published, **{k: v for k, v in summary.items() if k != "keys"}}
atomic(os.path.join(EVENTS, rid + ".request"), request)
live_path = os.path.join(EVENTS, rid + ".live")


def heartbeat():
    with open(live_path + ".tmp", "w") as f:
        json.dump({"request_id": rid, "heartbeat_at": time.time()}, f)
    os.replace(live_path + ".tmp", live_path)


def finish(outcome, **extra):
    log({"event": "helper_exit", "request_id": rid, "outcome": outcome, **extra})
    try:
        os.unlink(live_path)
    except FileNotFoundError:
        pass
    sys.exit(0)


receipt = None
while time.time() - published < 5:
    heartbeat()
    receipt = read(os.path.join(EVENTS, rid + ".receipt"))
    if receipt and receipt.get("request_id") == rid:
        break
    receipt = None
    time.sleep(0.1)
if receipt is None:
    finish("no_receipt")

while time.time() < receipt["expires_at"]:
    heartbeat()
    decision = read(os.path.join(EVENTS, rid + ".decision"))
    if decision and decision.get("request_id") == rid and decision.get("decided_at", 1e18) < receipt["expires_at"]:
        kind = decision.get("decision")
        if kind not in ("allow", "deny"):
            finish("handed_back", decision=kind)
        out = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": kind}}}
        sys.stdout.write(json.dumps(out))
        sys.stdout.flush()
        atomic(os.path.join(EVENTS, rid + ".delivery"),
               {"request_id": rid, "decision": kind, "decided_at": decision["decided_at"], "delivered_at": time.time()})
        finish("emitted", decision=kind)
    time.sleep(0.1)
finish("deadline")
