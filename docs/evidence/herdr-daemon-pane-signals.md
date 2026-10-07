# Pane signals for Codex sessions under a shared daemon (#144)

Gathered on 2026-10-07 for [Decide herdr pane binding when Codex hooks run in a shared daemon](https://github.com/r-curio/steer/issues/144), which follows the [daemon hook environment run](herdr-daemon-hook-env.md) from #116. These findings inform the decision; they do not make it. Everything below came from read-only observation of the user's live default herdr session and Codex daemon, plus the Codex and herdr CLIs' own help and schemas. No hook, herdr state, Codex configuration or session was changed, and no key or focus request was sent. Project directories and full session IDs are omitted.

## Setup

| Component | Version |
| --- | --- |
| macOS | Darwin 25.5.0 |
| herdr | 0.9.3, protocol 22 |
| Codex CLI | 0.160.1 (standalone package) |
| Claude Code | 2.1.292 |

Live at the time: one managed Codex daemon, two Codex CLIs in herdr panes `w1:p8` and `w1:p9`, and four Claude Code sessions in workspaces `w3` and `w4`.

## Findings

### 1. The daemon outlives the pane it inherited

- The daemon `codex app-server --listen unix:// --managed-daemon` (started 10:52) and its `pid-update-loop` helper had parent PID 1. Both carried `HERDR_PANE_ID=w1:p2` and `HERDR_TAB_ID=w1:t2`.
- herdr answered `pane_not_found` for `w1:p2`. The CLI that started the daemon was gone, but its pane ID lived on in every hook the daemon ran.
- The two live CLIs carried their own correct `HERDR_PANE_ID` (`w1:p8` started 14:46, `w1:p9` started 14:58). Hooks for their sessions would carry `w1:p2`.
- Only the daemon held the sessions' rollout files open. The CLIs held SQLite logs and Unix sockets, but no rollout. Open files therefore cannot tie a CLI process to a session.

The #116 run showed the stale pane can belong to the user's real Codex. This run adds that it can also name a pane that no longer exists. If herdr later reuses a pane ID, it could name an unrelated pane. ADR 0008's server-identity check covers a server restart, but not ID reuse within one server lifetime.

### 2. herdr's `agent_session` for daemon-hosted Codex is useless as a signal

Both live Codex panes reported `agent: codex`, `agent_status: working` and `agent_session: null`. herdr's own Codex integration reports from inside the daemon, so its session report went to the departed `w1:p2`.

### 3. herdr reports each pane's real foreground process

`herdr pane process-info --pane <id>` (socket method `pane.process_info`, in the protocol 22 schema) returned `shell_pid`, `foreground_process_group_id` and `foreground_processes` (`pid`, `argv`, `cwd`, `name`). herdr reads these from the pane's own terminal, not from any agent report.

| Pane | Foreground process group | Foreground process | Matches CLI with that `HERDR_PANE_ID` |
| --- | --- | --- | --- |
| `w1:p8` | 60859 | `codex`, PID 60859 | yes |
| `w1:p9` | 73257 | `codex`, PID 73257 | yes |
| `w3:pC` | 83378 | `claude`, PID 83378, plus its MCP children | yes |

The daemon PID never appears in a pane's foreground processes.

### 4. The pane title carries the Codex session ID from inside the pane

With `tui.terminal_title = ["session-id"]` (ADR 0005), herdr's `terminal_title_stripped` held the shortened session ID that each CLI rendered itself:

| Pane | Title | Rollout the daemon held |
| --- | --- | --- |
| `w1:p8` | `01a1151d-4e9d-7e53-a0b0-10d6e...` | `rollout-2026-10-07T14-46-44-01a1151d-4e9d-7e53-a0b0-10d6e…` |
| `w1:p9` | `01a1152a-0089-7bf2-89ea-0ded8...` | `rollout-2026-10-07T15-00-36-01a1152a-0089-7bf2-89ea-0ded8…` |

The title is the only observed pane-local signal that names a Codex session under the daemon. It is written by the CLI in the pane, so the daemon's environment cannot affect it. It is still a shortened 29-character prefix, written by whatever process holds the terminal, and it depends on a user setting. ADR 0008 currently allows titles to veto a binding but never to make one.

### 5. Codex exposes no client identity for a thread

The generated app-server protocol schema for 0.160.1 (`codex app-server generate-json-schema`) has `InitializeParams.clientInfo` (`name`, `title`, `version`) and connection-scoped `processId`s for `command/exec`. None of these ties a thread to a client process or terminal. No Codex-reported client identity was found.

### 6. The daemon is the default, but can be turned off

- `codex features list` reports `daemon_auto_start  stable  true`.
- `codex --help` offers `--no-daemon`: "Run without the shared background server, even if it is already running."
- With the daemon off, hooks run under the CLI and inherit the pane's environment. This was not observed live in this run.

Steer must not change the user's Codex configuration (AGENTS.md). Turning the daemon off is a user choice that Steer can only describe.

### 7. Claude Code showed no shared process

- Every Claude Code process was a direct child of its pane's shell, carried its own pane's `HERDR_PANE_ID`, and appeared as that pane's foreground process.
- herdr's `agent_session` for all four Claude panes held the correct session ID. One of them was this investigation's own session: the shell under it reported `HERDR_PANE_ID=w4:p4`, and herdr's `w4:p4` held the same session ID.
- Claude hooks were not observed directly. That they run as children of the Claude process is inferred from the process spawning this session's tool commands.

## A hook can tell whether it ran in its pane

The daemon run and the direct run differ in the hook's process ancestry, not in its environment:

- **In the CLI:** the ancestry of a hook run by the CLI reaches the CLI process. herdr reports that process as the foreground process of the pane named by `HERDR_PANE_ID`.
- **In the daemon:** the ancestry of a hook run by the daemon reaches the daemon and then launchd (PID 1), never a pane's foreground process.

If the hook recorded its ancestor PIDs (with process start times, to guard against PID reuse), Steer could require that one of them is the recorded pane's current foreground process. That would reject the daemon case without recognizing the daemon by name. It would also reject a pane that has since closed or been reused. This is a proposal: no Steer hook records ancestry yet, and a hook's ancestry under each mode has not been captured live.

## Answers to the issue's questions, as far as evidence goes

| Question | What the evidence shows | Still open |
| --- | --- | --- |
| Independent signal for the pane | `pane.process_info` proves which pane runs a Codex CLI process. Under the daemon, only the pane title ties that pane to a session. Codex exposes no client identity. | Whether a title, with a foreground Codex process and uniqueness checks, may bind (today it only vetoes). |
| Detecting daemon-run hooks | Hook ancestry versus herdr's foreground process for the pane is a candidate. The daemon is on by default, and `--no-daemon` or `daemon_auto_start = false` turns it off. | Live capture of hook ancestry in both modes. Whether to describe `--no-daemon` to users. |
| Claude Code | No shared process. Per-pane environment and `agent_session` were correct for four sessions. | Live hook ancestry for Claude. |
| ADRs and code | ADR 0008's agreement rule is not independent under the daemon and needs superseding for Codex. ADRs 0010 and 0011 consume ADR 0008's binding, so they change only through their fresh checks. | The replacement rule. The code then changes in `SteerHook` (record ancestry), `HerdrClient` (`pane.process_info`), `HerdrBindingRules` (#123), the relay fresh check (#126), and the Companion wiring, where `withholdingUnverifiedCodex` is removed (#135). |
