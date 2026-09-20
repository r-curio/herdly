# Claude setup live evidence

Date: 2026-09-21  
Scope: issue #80, isolated disposable roots only  
Artifact under test: packaged `SteerHook` from this branch

## Evidence boundary

This record separates source and helper checks from a real Claude process. The
commands below use placeholders so no account path, session identity, API key,
or conversation content is stored in the repository.

## Reproducible isolated startup

Run from a checkout containing a packaged helper:

```sh
ROOT="$(mktemp -d /private/tmp/steer-claude-setup.XXXXXX)"
CONFIG="$ROOT/config"
EVENTS="$ROOT/events"
INSTALLATION_ID="<uuid>"
SESSION_ID="<uuid>"
HELPER="<packaged-app>/Contents/Helpers/SteerHook"
mkdir -p "$CONFIG" "$EVENTS"

cat > "$CONFIG/settings.json" <<JSON
{
  "env": {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"},
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "${HELPER} --agent claude --events-dir ${EVENTS} --installation-id ${INSTALLATION_ID} --terminal-title", "timeout": 10}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "${HELPER} --agent claude --events-dir ${EVENTS} --installation-id ${INSTALLATION_ID} --terminal-title", "timeout": 10}] }]
  }
}
JSON

CLAUDE_CONFIG_DIR="$CONFIG" ANTHROPIC_API_KEY=invalid \
  claude --session-id "$SESSION_ID" --print "isolated setup smoke"
# Expected: nonzero status because the disposable API key is invalid.

CLAUDE_CONFIG_DIR="$CONFIG" claude agents --json
# Expected: [] for the disposable root.
```

Before starting Claude, the helper output was checked directly as well:

```sh
printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup"}' "$SESSION_ID" |
  "$HELPER" --agent claude --events-dir "$EVENTS" \
    --installation-id "$INSTALLATION_ID" --terminal-title > "$ROOT/session-start.json"
printf '{"hook_event_name":"SessionEnd","session_id":"%s"}' "$SESSION_ID" |
  "$HELPER" --agent claude --events-dir "$EVENTS" \
    --installation-id "$INSTALLATION_ID" --terminal-title > "$ROOT/session-end.json"
```

The first output was one JSON object with only `terminalSequence`; its value
contained the full session ID. The second output was one JSON object with the
empty-title reset sequence. Diagnostics stayed out of stdout.

The actual run used a fresh temporary root and fake credentials. Claude
started, delivered `SessionStart` before the request failed, and wrote a
matching metadata-only `SessionStart` record with these exact fields:

```text
hook_event_name=SessionStart
session_start_source=startup
source=steer-claude-hook-v1
installation_id=<configured lab installation id>
session_id=<configured lab session id>
received_at=<present ISO-8601 timestamp>
captured_at=<present timestamp>
```

The configured installation ID and session ID matched the received record.
`claude agents --json` returned a top-level empty array. The run changed no
real `~/.claude` file. A field allowlist inspection found no prompt, command,
path, reason, tool input, credential, or other event payload in the Claude
record. The process exited nonzero only because the API key was intentionally
invalid.

The helper self-test separately proved that `SessionStart` returns Claude's
JSON `terminalSequence` containing the full session ID and that `SessionEnd`
returns the reset sequence. It also proved that a Claude record keeps only the
setup metadata listed above.

## Restart evidence

No pre-existing live session was present in the disposable root, so this run
does not claim an observed old-session restart. The automated setup test covers
the boundary: a session record delivered before installation, a non-SessionStart
event, or a resume event does not make the root Connected. The status path also
requires the current installation ID. The root remains **Configured; restart
required** until a new exact-root `SessionStart` with `source=startup` and the
current installation ID arrives. A malformed,
disabled, failed, or timed-out `claude agents --json` probe is reported as
typed unavailable and is never treated as an empty root.

## Ghostty attempt

I attempted a disposable Ghostty launch with a temporary `--settings` file,
the same local hook, a local stub API, and no changes to the default Claude or
Ghostty configuration. The hook record proved the exact startup event. The
noninteractive `claude --print` route did not expose an observable Ghostty
title, and the isolated interactive process could not be given its initial
submit key through the available automation surface. Therefore this evidence
does not claim that Ghostty applied or retained the title, or that a clean
`SessionEnd` reset was visible in the terminal. No abrupt-exit restoration was
attempted or claimed.

The remaining operator checkpoint is to launch the packaged app against a
disposable Claude root in a real unsplit Ghostty tab, start a new session, and
observe the title `Steer Claude <full-session-id>` and the clean shutdown reset.
Project and command-line settings precedence remains an explicit product
boundary: this root-only evidence does not prove that higher-priority sources
are absent.
