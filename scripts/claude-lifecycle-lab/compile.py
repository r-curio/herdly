#!/usr/bin/env python3
"""Summarize lab runs: event order, identity fields, request/decision correlation.

Usage: compile.py [runs-dir] [--json out.json]

Prints, per run: metadata, the ordered event trace (event, prompt_id, tool_use_id,
agent_id, key fields), helper outcomes, companion actions, and a correlation table
joining each PermissionRequest to its PreToolUse / PostToolUse / PostToolUseFailure /
PermissionDenied / PostToolBatch records by tool_use_id. With --json it also writes a
sanitized evidence file suitable for docs/evidence.
"""
import glob, json, os, sys

runs_dir = next((a for a in sys.argv[1:] if not a.startswith("--") and os.path.isdir(a)), os.path.join(os.path.dirname(__file__), "runs"))
out = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
summary = []

SHORT = {
    "UserPromptSubmit": lambda p: repr((p.get("prompt") or p.get("prompt_text") or "")[:60]),
    "PreToolUse": lambda p: f"{p.get('tool_name')} {((p.get('tool_input') or {}).get('command') or '')[:50]!r}",
    "PermissionRequest": lambda p: f"{p.get('tool_name')} {((p.get('tool_input') or {}).get('command') or '')[:50]!r} timeout={p.get('timeout')}",
    "PostToolUse": lambda p: f"{p.get('tool_name')} keys={sorted(k for k in p if k not in ('session_id','transcript_path','cwd','hook_event_name','permission_mode','prompt_id','tool_input'))}",
    "PostToolUseFailure": lambda p: f"{p.get('tool_name')} error={str(p.get('error'))[:80]!r}",
    "PermissionDenied": lambda p: f"{p.get('tool_name')} reason={str(p.get('denial_reason'))[:80]!r}",
    "PostToolBatch": lambda p: f"calls={[c.get('tool_use_id') for c in p.get('tool_calls', [])]} outputs={[(o.get('tool_use_id'), (o.get('error') or '')[:40]) for o in p.get('tool_outputs', [])]}",
    "Notification": lambda p: f"{p.get('notification_type')} {str(p.get('message'))[:60]!r}",
    "Stop": lambda p: f"stop_hook_active={p.get('stop_hook_active')} last={str(p.get('last_assistant_message'))[:40]!r}",
    "SessionEnd": lambda p: f"reason={p.get('reason')}",
    "SessionStart": lambda p: f"source={p.get('source')}",
    "SubagentStart": lambda p: f"agent_type={p.get('agent_type')}",
    "SubagentStop": lambda p: f"agent_type={p.get('agent_type')} last={str(p.get('last_assistant_message'))[:40]!r}",
    "StopFailure": lambda p: f"{ {k: str(v)[:60] for k, v in p.items() if k not in ('session_id','transcript_path','cwd','hook_event_name','permission_mode','prompt_id')} }",
}

for run in sorted(glob.glob(os.path.join(runs_dir, "*"))):
    meta = {}
    try:
        meta = json.load(open(os.path.join(run, "meta.json")))
    except Exception:
        pass
    events = []
    for f in glob.glob(os.path.join(run, "events", "*.jsonl")):
        for line in open(f):
            try:
                events.append(json.loads(line))
            except Exception:
                events.append({"unparseable": line[:100]})
    events.sort(key=lambda e: e.get("received_at", 0))
    if not events:
        continue
    print(f"\n=== {os.path.basename(run)}  claude={meta.get('claude_version')} session={meta.get('session_id')}")
    t0 = events[0].get("received_at", 0)
    trace, helper, by_tool = [], [], {}
    for e in events:
        dt = round(e.get("received_at", 0) - t0, 3)
        if "probe_note" in e:
            helper.append(e)
            print(f"  +{dt:8.3f}  [helper] {e['probe_note']} outcome={e.get('outcome')} req={e.get('request_id')} tool_use_id={e.get('tool_use_id')} after={e.get('seconds_since_publish')}s")
            continue
        p = e.get("payload", {})
        ev = p.get("hook_event_name", "?")
        ids = f"prompt={p.get('prompt_id')} tool_use={p.get('tool_use_id')} agent={p.get('agent_id')}"
        detail = SHORT.get(ev, lambda p: "")(p)
        print(f"  +{dt:8.3f}  {ev:<20} {ids}  {detail}  [pid {e.get('hook_pid')} env_session={e.get('env', {}).get('CLAUDE_CODE_SESSION_ID')}]")
        trace.append({"t": dt, "event": ev, "prompt_id": p.get("prompt_id"), "tool_use_id": p.get("tool_use_id"), "agent_id": p.get("agent_id"), "detail": detail})
        tid = p.get("tool_use_id")
        if tid:
            by_tool.setdefault(tid, []).append(ev)
        for o in p.get("tool_outputs", []) if ev == "PostToolBatch" else []:
            by_tool.setdefault(o.get("tool_use_id"), []).append("PostToolBatch")
    if by_tool:
        print("  correlation by tool_use_id:")
        for tid, evs in by_tool.items():
            print(f"    {tid}: {' -> '.join(evs)}")
    comp = os.path.join(run, "companion.log")
    if os.path.exists(comp):
        print("  companion actions:")
        for line in open(comp):
            if "wrote decision" in line or "REQUEST" in line or "scheduled" in line or "refused" in line:
                print("    " + line.rstrip().splitlines()[0])
    other = os.path.join(run, "other-hook.log")
    if os.path.exists(other):
        print("  coexisting hook saw:")
        for line in open(other):
            print("    " + line.rstrip())
    summary.append({"run": os.path.basename(run), "meta": meta, "trace": trace, "helper": helper, "correlation": by_tool})

if out:
    json.dump({"probe": "steer-claude-lifecycle-lab/1", "runs": summary}, open(out, "w"), indent=1, sort_keys=True)
    print(f"\nwrote {out}")
