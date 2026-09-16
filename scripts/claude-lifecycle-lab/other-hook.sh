#!/bin/bash
# Unrelated coexisting hook: logs the event to its own file and never decides anything.
p=$(cat)
d="${STEER_LAB_RUN:-.}"
printf '%s %s\n' "$(date -u +%FT%T.%NZ)" "$(printf '%s' "$p" | python3 -c 'import json,sys; o=json.load(sys.stdin); i=o.get("tool_input") or {}; print(o.get("hook_event_name"), o.get("session_id"), o.get("tool_use_id"), i.get("command") or [q.get("question") for q in i.get("questions", [])])')" >> "$d/other-hook.log"
exit 0
