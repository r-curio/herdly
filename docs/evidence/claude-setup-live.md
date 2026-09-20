# Claude setup live evidence

Date: 2026-09-21
Scope: issue #80, isolated disposable roots only
Tested Steer commit: `db84a9175959d51d2a53b567eccb90f46f8cdc55`
Packaged helper: `output/Steer.app/Contents/Helpers/SteerHook`
Helper SHA-256: `b29fc496ced6bcca953678b7801abd54392d00872b66ce220b6a57e3fc46bf1a`
Claude Code: `2.1.278`

## Evidence boundary

This is a sanitized run record, not a transcript. The run used a newly created
temporary `HOME`, `CLAUDE_CONFIG_DIR`, and events directory, plus a newly
generated fake API key value. Raw Claude stdout and stderr stayed in that
temporary root and were not committed. Session and installation IDs were
generated UUIDs; the record keeps only match booleans. The real `~/.claude`
root was outside the run's home and configuration roots.

## Reproducible isolated startup

Run from the repository root after building the packaged app with
`sh scripts/build-app.sh`:

```sh
set -eu
ROOT_RUN="$(mktemp -d /private/tmp/steer-claude-setup-run.XXXXXX)"
CONFIG="$ROOT_RUN/config"
EVENTS="$ROOT_RUN/events"
SELF_TEST_EVENTS="$ROOT_RUN/helper-self-test-events"
TEMP_HOME="$ROOT_RUN/home"
HELPER="$PWD/output/Steer.app/Contents/Helpers/SteerHook"
INSTALLATION_ID="$(uuidgen | tr '[:lower:]' '[:upper:]')"
SESSION_ID="$(uuidgen | tr '[:lower:]' '[:upper:]')"
SELF_TEST_INSTALLATION_ID="$(uuidgen | tr '[:lower:]' '[:upper:]')"
SELF_TEST_SESSION_ID="$(uuidgen | tr '[:lower:]' '[:upper:]')"
mkdir -p "$CONFIG" "$EVENTS" "$SELF_TEST_EVENTS" "$ROOT_RUN/helper-self-test" "$TEMP_HOME"

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
HOOK_COMMAND="$(shell_quote "$HELPER") --agent claude --events-dir $(shell_quote "$EVENTS") --installation-id $(shell_quote "$INSTALLATION_ID") --terminal-title"

python3 - "$CONFIG/settings.json" "$HOOK_COMMAND" <<'PY'
import json
import pathlib
import sys

path, command = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "env": {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"},
    "hooks": {
        "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 10}]}],
        "SessionEnd": [{"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 10}]}],
    },
}, indent=2) + "\n")
PY

PRE_COUNT="$(find "$EVENTS" -maxdepth 1 -type f | wc -l | tr -d ' ')"
set +e
HOME="$TEMP_HOME" CLAUDE_CONFIG_DIR="$CONFIG" ANTHROPIC_API_KEY=invalid \
  python3 - "$SESSION_ID" "$ROOT_RUN/claude.stdout" "$ROOT_RUN/claude.stderr" <<'PY'
import subprocess
import sys

session_id, stdout_path, stderr_path = sys.argv[1:]
with open(stdout_path, "w") as stdout, open(stderr_path, "w") as stderr:
    result = subprocess.run([
        "claude", "--no-session-persistence", "--session-id", session_id,
        "--output-format", "json", "--print", "isolated setup smoke",
    ], stdout=stdout, stderr=stderr, timeout=30, check=False)
raise SystemExit(result.returncode)
PY
CLAUDE_EXIT=$?
set -e
POST_COUNT="$(find "$EVENTS" -maxdepth 1 -type f | wc -l | tr -d ' ')"

set +e
HOME="$TEMP_HOME" CLAUDE_CONFIG_DIR="$CONFIG" claude agents --json >"$ROOT_RUN/agents.stdout" 2>"$ROOT_RUN/agents.stderr"
AGENTS_EXIT=$?
set -e

# Keep helper checks in a separate directory; these are never mixed with EVENTS.
set +e
"$HELPER" --self-test >"$ROOT_RUN/helper-self-test.stdout" 2>"$ROOT_RUN/helper-self-test.stderr"
HELPER_SELF_TEST_EXIT=$?
set -e
printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup"}' "$SELF_TEST_SESSION_ID" |
  "$HELPER" --agent claude --events-dir "$SELF_TEST_EVENTS" --installation-id "$SELF_TEST_INSTALLATION_ID" --terminal-title >"$ROOT_RUN/helper-self-test/session-start.json"
printf '{"hook_event_name":"SessionEnd","session_id":"%s"}' "$SELF_TEST_SESSION_ID" |
  "$HELPER" --agent claude --events-dir "$SELF_TEST_EVENTS" --installation-id "$SELF_TEST_INSTALLATION_ID" --terminal-title >"$ROOT_RUN/helper-self-test/session-end.json"

printf 'pre_files=%s post_files=%s claude_exit=%s agents_exit=%s helper_self_test_exit=%s isolated_home=true\n' \
  "$PRE_COUNT" "$POST_COUNT" "$CLAUDE_EXIT" "$AGENTS_EXIT" "$HELPER_SELF_TEST_EXIT"

python3 - "$EVENTS" "$INSTALLATION_ID" "$SESSION_ID" "$ROOT_RUN/agents.stdout" "$ROOT_RUN/helper-self-test/session-start.json" "$ROOT_RUN/helper-self-test/session-end.json" <<'PY'
import json
import pathlib
import sys

events, installation_id, session_id, agents_path, title_start, title_end = sys.argv[1:]
records = []
for path in sorted(pathlib.Path(events).glob("*.json")):
    record = json.loads(path.read_text())
    records.append({
        "hook_event_name": record.get("hook_event_name"),
        "session_start_source": record.get("session_start_source"),
        "source": record.get("source"),
        "installation_id_match": record.get("installation_id") == installation_id,
        "session_id_match": record.get("session_id") == session_id,
        "received_at": record.get("received_at"),
        "captured_at": record.get("captured_at"),
        "keys": sorted(record),
    })
for record in sorted(records, key=lambda item: (item["captured_at"] or 0, item["hook_event_name"] or "")):
    print(json.dumps(record, sort_keys=True, separators=(",", ":")))
agents = json.loads(pathlib.Path(agents_path).read_text())
start = json.loads(pathlib.Path(title_start).read_text())["terminalSequence"]
end = json.loads(pathlib.Path(title_end).read_text())["terminalSequence"]
print("agents_shape=%s agents_count=%s" % ("array" if isinstance(agents, list) else type(agents).__name__, len(agents) if isinstance(agents, list) else "n/a"))
print("title_start_json=%s title_end_json=%s" % (start.startswith("\033]2;Steer Claude ") and start.endswith("\007"), end == "\033]2;\007"))
PY
```

The direct helper calls above use the separate self-test directory. The real
Claude run never invokes the helper before startup; its first event file is
created by Claude's `SessionStart` delivery.

Observed run record:

```text
pre_files=0 post_files=2 claude_exit=1 agents_exit=0 helper_self_test_exit=0 isolated_home=true
{"captured_at":1789924593.599845,"hook_event_name":"SessionStart","installation_id_match":true,"keys":["captured_at","hook_event_name","installation_id","received_at","session_id","session_start_source","source"],"received_at":"2026-09-20T17:16:33Z","session_id_match":true,"session_start_source":"startup","source":"steer-claude-hook-v1"}
{"captured_at":1789924594.296905,"hook_event_name":"SessionEnd","installation_id_match":true,"keys":["captured_at","hook_event_name","installation_id","received_at","session_id","source"],"received_at":"2026-09-20T17:16:34Z","session_id_match":true,"session_start_source":null,"source":"steer-claude-hook-v1"}
agents_shape=array agents_count=0
title_start_json=True title_end_json=True
```

The Claude subprocess had a 30-second bound and exited with status `1` after
the fake API key was rejected.
The two records came from the process run itself and have distinct event names
and timestamps. The configured installation and session IDs matched both
records. The allowlist contains only setup metadata; no prompt, command, path,
reason, tool input, credential, or other event payload was stored.

## Ghostty checkpoint

This was not completed in the automated run. The available automation could
not operate a real Ghostty tab, so this section is an operator checkpoint and
makes no pass claim.

Paste this self-contained block into a real unsplit Ghostty tab from the
repository root after building the packaged app with `sh scripts/build-app.sh`.
It reads the default authenticated Claude root without editing its settings,
writes a disposable `--settings` file, and uses a temporary working directory:

```sh
(
  set -eu
  CHECKOUT="$(pwd -P)"
  HELPER="$CHECKOUT/output/Steer.app/Contents/Helpers/SteerHook"
  test -x "$HELPER"
  ROOT_RUN="$(mktemp -d /private/tmp/steer-claude-ghostty.XXXXXX)"
  CONFIG="$ROOT_RUN/config"
  EVENTS="$ROOT_RUN/events"
  INSTALLATION_ID="$(uuidgen | tr '[:lower:]' '[:upper:]')"
  SESSION_ID="$(uuidgen | tr '[:lower:]' '[:upper:]')"
  mkdir -p "$CONFIG" "$EVENTS"

  HOOK_COMMAND="$(python3 - "$HELPER" "$EVENTS" "$INSTALLATION_ID" <<'PY'
import shlex
import sys

helper, events, installation_id = sys.argv[1:]
print(" ".join([
    shlex.quote(helper),
    "--agent", "claude",
    "--events-dir", shlex.quote(events),
    "--installation-id", shlex.quote(installation_id),
    "--terminal-title",
]), end="")
PY
)"
  python3 - "$ROOT_RUN/helper's-dir/SteerHook" <<'PY'
import shlex
import sys

path = sys.argv[1]
assert shlex.split(shlex.quote(path)) == [path]
PY

  python3 - "$CONFIG/settings.json" "$HOOK_COMMAND" <<'PY'
import json
import pathlib
import sys

path, command = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "env": {"CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1"},
    "hooks": {
        "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 10}]}],
        "SessionEnd": [{"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 10}]}],
    },
}, indent=2) + "\n")
PY
  printf 'SESSION_ID=%s\nExpected Ghostty title: Steer Claude %s\n' "$SESSION_ID" "$SESSION_ID"
  cd "$ROOT_RUN"
  claude --settings "$CONFIG/settings.json" --setting-sources project --session-id "$SESSION_ID"
)
```

If the default root is authenticated, submit one harmless prompt. Before
launching Claude, the block prints the full `SESSION_ID` and expected title.
At the first checkpoint, while Claude remains open, report the exact title
shown in the tab and whether it matches `Steer Claude <full SESSION_ID>`. Stop
after that report; clean exit and title reset are a separate later checkpoint.
The `--setting-sources project` flag excludes the ordinary user and local
settings while retaining the default root's authentication.
If authentication or startup fails, report that result without retrying with a
real credential in the disposable root. Report the tested Steer commit, helper
SHA-256, whether the full title appeared, and any observed error. Record the
clean shutdown reset in the later checkpoint. Do not paste credentials or raw
conversation output into the evidence record.

This run does not claim that Ghostty applied or retained the title. Clean
shutdown reset and abrupt-exit restoration remain separate later checkpoints.
