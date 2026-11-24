# Claude Desktop Code sessions through Herdly's Claude hooks

Recorded 2026-11-24 against Claude.app 5.11492.5, which bundles Claude Code 2.1.325, and the user's
running Herdly built from `main` at `4906906`. This was an investigation, not a feature: Herdly's code is
unchanged. Lab scripts: [scripts/claude-desktop-lab](../../scripts/claude-desktop-lab).

## Question

Can Herdly follow, answer and decide for Claude Code sessions started in Claude Desktop's Code tab, and
return to one exactly? Regular Claude chats are out of scope (user decision, 2026-11-24): they have no
hooks or session registry.

## Setup and limits

- **Sessions:** six throwaway local sessions in `~/tmp/herdly-probe`, an empty git repository, started
  through Claude Desktop's own `claude://code/new?folder=<path>&q=<prompt>` link. The prompt was submitted
  by a scripted Return keystroke, which sometimes needed a second press.
- **Hooks:** the user's real Herdly hooks in `~/.claude/settings.json`, unchanged. Claude Desktop starts
  Claude Code with `--setting-sources=user,project,local`, so user hooks load.
- **Permission mode:** Claude Desktop ran every session with `--permission-mode=auto`, and the link has
  no mode parameter. To get a prompt, the probe folder alone got `.claude/settings.local.json` with
  `{"permissions": {"ask": ["Bash(date:*)"]}}`. The user's Claude Desktop settings were not changed.
- **Decisions:** at the user's direction ("answer for me", "do everything"), the agent wrote the answer and
  decision records the notch would write ([answer_question.py](../../scripts/claude-desktop-lab/answer_question.py),
  [decide_approval.py](../../scripts/claude-desktop-lab/decide_approval.py)), only for probe-folder desktop
  sessions and only after the running Herdly had issued its receipt. Nobody clicked the notch, and the
  agent had no screen access, so **what the cards looked like was not observed**.
- **Observation:** [watch.py](../../scripts/claude-desktop-lab/watch.py) logged metadata only: event and
  tool names, record key names, and registry fields. No transcript was read. The only response read was
  the one-word reply to the colour question.

## Results

| Case | What happened | Result |
| --- | --- | --- |
| Lifecycle | `SessionStart`, `UserPromptSubmit`, `PreToolUse`/`PostToolUse` Bash, `PostToolBatch`, `Stop`, `SubagentStop`, all with Herdly's `source` and installation id | Pass |
| Terminal | No record carries `hc_terminal_id`. The process has no tty, and its parent is Claude.app's `disclaimer` helper | Expected: no terminal |
| Registry | `~/.claude/sessions/<pid>.json` has `entrypoint: "claude-desktop"`, `kind: "interactive"`, and the usual `status`/`waitingFor` | Pass |
| Question answered | `AskUserQuestion` (Red, Blue): Herdly issued a receipt, the stand-in wrote `Red`, the helper wrote its delivery acknowledgment, and `PostToolUse` followed. Claude's final reply was `Red` | Pass |
| Question unanswered | No answer within the 30 s window. The helper emitted nothing, and a `Notification` followed when Claude Desktop showed its own question | Pass: native fallback |
| Approval allow | Bash `date > stamp.txt`: `PermissionRequest` → receipt → `allow` → delivery acknowledgment → `PostToolUse`. `stamp.txt` was created | Pass |
| Approval deny | Same command → `deny` → delivery acknowledgment. No `PostToolUse` and no file | Pass |
| Approval no decision | Receipt and no decision. `Notification` at +6 s, as in the CLI ([transport proof](claude-permission-transport.md) item 7). The registry then read `waiting` / `permission prompt` and Claude Desktop kept its native prompt | Pass: native fallback |
| Exact Open | `claude://code/continue?session=local_<id>` brought that session forward. Its `lastFocusedAt` updated within 4 s, and another session's did not | Pass |

## Identity join

Claude Desktop writes one file per Code session at
`~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<uuid>.json`, holding
`sessionId` (`local_<uuid>`, the desktop's id), `cliSessionId` (the hook `session_id`), `cwd`,
`isArchived`, `permissionMode`, `lastActivityAt` and `lastFocusedAt`. Joining `cliSessionId` to the hook
session gives the exact `local_` id the continue link takes. The link accepts only
`^local_[A-Za-z0-9-]{1,64}$` or `last`. It is ignored when Claude Desktop's OS entry points setting is
off.

These are Claude Desktop internals, not a documented interface. The file layout, the link, and the link's
validation could change in any update.

## What this does not establish

- How the current Herdly notch presents a desktop row, and what its Open does today. Rows arrive as Claude
  sessions with no terminal, so the terminal Open rules presumably make Open unavailable, but nobody looked.
- Whether answering in Claude Desktop's own prompt clears the Herdly card as fast as in the CLI. The
  registry fields are the same, but no native click was made.
- Remote, SSH and cloud desktop sessions, worktree sessions, and Claude Desktop with its OS entry points
  setting off.
- `lastFocusedAt` as read evidence. It shows focus, not that a result was read. Decided in
  [#474](https://github.com/r-curio/herdly/issues/474): it counts as a terminal tab being in front (below).

## Focus probe (#474)

Recorded 2026-11-24, same Claude.app. Two existing Code sessions, A and B, were switched by
`osascript` activation and the continue link while a watcher logged only each file's `lastFocusedAt` and
modification time.

| Step | `lastFocusedAt` |
| --- | --- |
| Activate Claude Desktop, A selected | A set to the activation time, file written about 1.0 s later |
| Stay in front 8 s | No write |
| Continue link to B | B set |
| Leave, then the link to B again (already selected) | B set |
| Leave, then activate Claude Desktop (B selected) | B set |
| Leave to another app | No write, either session |

Not probed: selecting a session from Claude Desktop's sidebar, and switching to its Chat tab.

### Live run, PR build of #474

| Case | Observed | Result |
| --- | --- | --- |
| Result arrives while another app is in front | Queued for 28 s with Finder frontmost | Pass |
| Claude Desktop activated with the session selected | Cleared within 1.5 s | Pass |
| Claude Desktop brought forward by a new-session link | Writes the previously selected session's `lastFocusedAt`, then shows the new-session page; that session's real queued result cleared within 6 s although it was never shown | Accepted gap (ADR 0026) |
| Dwell | Not run: the scripted prompt was typed while another app was in front | Not shown |

In one earlier away run a result cleared after 6 s; the frontmost app was not logged then, and the rerun
with logging held. Keystroke-driven lab steps are unsafe while the user is working: they type into
whichever app is in front.
