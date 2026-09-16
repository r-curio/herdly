#!/bin/bash
# Launch one isolated, disposable Claude Code session for a named lab scenario.
#
#   run.sh <scenario> [extra claude args...]
#
# Scenarios select the hook configuration and injected conditions:
#   lifecycle | approval-* | interrupt-tool | parallel | identical | coexist
#                         -> base settings (all observers + permission helper)
#   stop-continue         -> base + Stop hook that asks Claude to continue once
#   api-failure           -> base + ANTHROPIC_BASE_URL pointed at a closed port
#   helper-crash / helper-hang -> base + helper-mode file set before launch
#
# Isolation: --setting-sources "" drops user/project/local settings; only the
# generated lab settings (and any managed policy) apply. The real ~/.claude
# settings, hooks, and permission rules are never modified. Each run gets a
# fresh session id and its own evidence directory under runs/<scenario>-<time>.
set -euo pipefail
LAB="$(cd "$(dirname "$0")" && pwd)"
SCENARIO="${1:?scenario name}"; shift || true
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN="$LAB/runs/$SCENARIO-$STAMP"
PROJECT="$RUN/project"
mkdir -p "$RUN/events" "$PROJECT"
[ -d "$PROJECT/.git" ] || (cd "$PROJECT" && git init -q && echo "# disposable lab project ($SCENARIO)" > README.md && git add -A && git -c user.email=lab@example.invalid -c user.name=lab commit -qm init)
SESSION="$(uuidgen | tr 'A-Z' 'a-z')"
PROBE="python3 $LAB/probe.py"

observers=(SessionStart UserPromptSubmit PostToolUse PostToolUseFailure PostToolBatch PermissionDenied Notification SubagentStart SubagentStop StopFailure SessionEnd PreCompact PostCompact Elicitation ElicitationResult)
STOP_MODE="observe"; [ "$SCENARIO" = "stop-continue" ] && STOP_MODE="stop-continue" && touch "$RUN/stop-continue-armed"
case "$SCENARIO" in helper-crash|question-helper-crash) echo crash > "$RUN/helper-mode";; helper-hang|question-helper-hang) echo hang > "$RUN/helper-mode";; esac

hooks="{"
for ev in "${observers[@]}"; do
  hooks+="\"$ev\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$PROBE observe\",\"timeout\":10}]}],"
done
hooks+="\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$PROBE observe\",\"timeout\":10}]}"
if [[ "$SCENARIO" == question-* ]]; then
  hooks+=",{\"matcher\":\"AskUserQuestion\",\"hooks\":[{\"type\":\"command\",\"command\":\"$PROBE question\",\"timeout\":135}]}"
fi
if [ "$SCENARIO" = "question-coexist" ]; then
  hooks+=",{\"matcher\":\"AskUserQuestion\",\"hooks\":[{\"type\":\"command\",\"command\":\"$LAB/other-hook.sh\",\"timeout\":10}]}"
fi
if [ "$SCENARIO" = "coexist" ]; then
  hooks+=",{\"hooks\":[{\"type\":\"command\",\"command\":\"$LAB/other-hook.sh\",\"timeout\":10}]}"
fi
hooks+="],"
hooks+="\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"$PROBE $STOP_MODE\",\"timeout\":10}]}],"
hooks+="\"PermissionRequest\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$PROBE permission\",\"timeout\":45}]}"
if [ "$SCENARIO" = "coexist" ]; then
  # A second, unrelated handler on the same events: an observer that logs to its own file and never decides.
  OTHER="$LAB/other-hook.sh"
  hooks+=",{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$OTHER\",\"timeout\":10}]}"
fi
hooks+="]}"
printf '{"hooks":%s}' "$hooks" | python3 -m json.tool > "$RUN/settings.json"

{
  echo "{\"scenario\":\"$SCENARIO\",\"session_id\":\"$SESSION\",\"started_utc\":\"$STAMP\","
  echo " \"claude_version\":\"$(command claude --version 2>/dev/null | tr -d '\n')\","
  echo " \"ghostty_version\":\"$(defaults read /Applications/Ghostty.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)\","
  echo " \"macos\":\"$(sw_vers -productVersion)\", \"term_program\":\"${TERM_PROGRAM:-}\", \"ghostty_resources\":\"${GHOSTTY_RESOURCES_DIR:-}\","
  echo " \"setting_sources\":\"\", \"settings_file\":\"$RUN/settings.json\", \"permission_mode\":\"default\", \"model\":\"${LAB_MODEL:-sonnet}\"}"
} > "$RUN/meta.json"

echo "== Steer Claude lifecycle lab: $SCENARIO"
echo "   run dir : $RUN"
echo "   session : $SESSION"
echo "   companion (second tab): python3 $LAB/companion.py $RUN"
echo "   evidence: $RUN/events/$SESSION.jsonl"
echo

export STEER_LAB_RUN="$RUN"
unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
[ "$SCENARIO" = "api-failure" ] && export ANTHROPIC_BASE_URL="http://127.0.0.1:9" && echo "   API failure injected: ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"
cd "$PROJECT"
exec claude --setting-sources "" --settings "$RUN/settings.json" --permission-mode default \
  --session-id "$SESSION" --model "${LAB_MODEL:-sonnet}" --debug-file "$RUN/debug.log" "$@"
