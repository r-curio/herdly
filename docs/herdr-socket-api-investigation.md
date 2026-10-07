# herdr local socket API (#101)

Checked 2026-10-07 against herdr 0.9.3 (protocol 22) installed at `~/.local/bin/herdr`. Research ticket [#101](https://github.com/r-curio/steer/issues/101) under map [#100](https://github.com/r-curio/steer/issues/100). Nothing here is proof that Steer can drive herdr end to end; live mutating checks belong to #102.

## Evidence labels

Each claim carries one label:

- **[schema]** comes from the bundled schema, `herdr api schema --json` (`protocol: 22`, `schema_version: 1`, 102 request methods).
- **[source]** comes from herdr's Rust source at tag [`v0.9.3`](https://github.com/herdrdev/herdr/tree/v0.9.3), which matches the installed version. File paths below are relative to that tree.
- **[docs]** comes from the v0.9.3 documentation that [herdr.dev/llms.txt](https://herdr.dev/llms.txt) points to, mainly [`socket-api.mdx`](https://raw.githubusercontent.com/herdrdev/herdr/v0.9.3/docs/next/website/src/content/docs/socket-api.mdx), or from `herdr --skill`.
- **[live]** is a read-only observation on the user's machine: `herdr status --json`, `herdr api snapshot`, `herdr agent list`, `herdr pane list`, `herdr pane process-info`, `herdr integration status`, `ps`, `lsof` and `netstat`. No herdr command that changes state was run.
- **[inferred]** is a conclusion drawn from the evidence above that has not been observed.
- **[#102]** marks a question that needs the live probe.

In the observed session the herdr server had 4 workspaces, 8 tabs, 8 panes and 4 detected agents. All 4 agents were Claude Code, so nothing about Codex was observed live.

## Transport, schema and compatibility

- **Wire format [docs][source]:** newline-delimited JSON over a Unix domain socket. A request is `{"id","method","params"}` on one line, and the reply echoes the same `id` with `result` (which carries a `type` discriminator) or `error {code, message}`. Bad JSON gets an empty `id`. An unknown method returns `unknown_method` and a malformed request returns `invalid_request` (`src/api/server.rs`). Invalid UTF-8 can close the connection without any response.
- **Schema [schema]:** `herdr api schema --json` prints a JSON Schema 2020-12 document containing `request`, `success_response`, `error_response`, `event` and `subscription_event`. It is bundled with the binary, so it describes the client binary, not necessarily the running server.
- **Version check [schema][live]:** `ping` returns `pong {version, protocol, capabilities}`. `herdr status --json` shows client and server version, `protocol`, `endpoint_protocol_generation` (1), the capabilities (`live_handoff`, `detached_server_daemon`, `surface_interest`, `health_check`, `ssh_agent_registration`), `compatible`, `endpoint_compatible`, `socket`, `restart_needed` and `server_binary_stale`. `session.snapshot` also carries `version` and `protocol`.
- **Compatibility promise [docs]:** "JSON API clients should ignore unknown fields and handle unsupported methods as normal errors." Client and server builds do not need to match for the UI endpoint. The numbered binary protocol (22) is for same-install operations such as direct attach and handoff, and the docs say to check `ping` or `herdr status` before using those operations across builds.
- **Breaking changes [source]:** `CHANGELOG.md` shows breaking changes in patch and minor releases. 0.9.2 removed the `pane.graphics.*` methods, which now return `unknown_method`. 0.7.5 restricted agent targets to a unique live name or a pane ID and renamed `agent send` to `send-keys`. Pre-1.0 herdr makes no semver promise [inferred].
- **What this means for Steer [inferred]:** fail closed. Before each herdr feature is used, Steer should check `ping` (protocol, plus `version` against a tested allowlist) and treat `unknown_method`, `protocol_mismatch` or a missing field as unavailable. The decoder should be tolerant of additions but strict about the fields it relies on.

## Socket location, ownership and permissions

- **Default paths [docs][live]:** `~/.config/herdr/herdr.sock` for the JSON API and `~/.config/herdr/herdr-client.sock` for the TUI client protocol. Named sessions use `~/.config/herdr/sessions/<name>/herdr.sock`. `herdr session list` shows a name, status and socket for each session. Only `default` was running.
- **Resolution order [docs][source]:** CLI `--session <name>`, then `HERDR_SOCKET_PATH`, then `HERDR_SESSION=<name>`, then the default. The client socket path is derived from `HERDR_SOCKET_PATH` by inserting `-client` (`src/server/socket_paths.rs`).
- **Permissions [source][live]:** both sockets are created with mode `0600` (`SOCKET_PERMISSION_MODE` in `src/api/server.rs` and `src/server/socket_paths.rs`). The observed socket was `srw------- <user> staff` inside a `0755` config directory. herdr does no peer-credential check (no `getpeereid` or `SO_PEERCRED` in the source). File mode is the only access control, so any process running as the same user has full control.
- **Pane environment [docs][live]:** herdr injects `HERDR_ENV=1`, `HERDR_SOCKET_PATH`, `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID` and `HERDR_BIN_PATH` into every managed pane, and sets `TERM_PROGRAM=herdr` and `TERM_PROGRAM_VERSION`. The docs say herdr-managed values win over caller-supplied env. This research agent ran inside pane `w4:p1` and saw exactly those variables.
- **Consequence for Steer [inferred]:** Steer's own hook helper runs as a child of the Claude or Codex process, so it inherits `HERDR_PANE_ID` and `HERDR_SOCKET_PATH`. That gives Steer a first-hand pane binding alongside herdr's `agent_session`; see the binding section below.

## Agent and pane records

The fields come from the schema; the observations are live.

| Record | Required fields | Optional fields of interest |
| --- | --- | --- |
| `AgentInfo` (`agent.list`, `agent.get`, snapshot `agents`) | `terminal_id`, `workspace_id`, `tab_id`, `pane_id`, `focused`, `agent_status`, `revision` | `agent`, `agent_session`, `name`, `title`, `display_agent`, `terminal_title`, `terminal_title_stripped`, `cwd`, `foreground_cwd`, `state_change_seq`, `completion_seq`, `interactive_ready`, `launch_pending`, `screen_detection_skipped`, `state_labels`, `tokens` |
| `PaneInfo` (`pane.list`, `pane.get`, snapshot `panes`) | `pane_id`, `terminal_id`, `workspace_id`, `tab_id`, `focused`, `agent_status`, `revision` | `agent`, `agent_session`, `label`, `terminal_title`, `terminal_title_stripped`, `cwd`, `foreground_cwd`, `scroll`, `restore_error`, and the same metadata fields |
| `TabInfo` | `tab_id`, `workspace_id`, `number`, `label`, `focused`, `pane_count`, `agent_status` | none |
| `AgentSessionInfo` | `source`, `agent`, `kind` (`id` or `path`), `value` | none |
| `PaneProcessInfo` (`pane.process_info`) | `pane_id` | `shell_pid`, `foreground_process_group_id`, `tty`, `foreground_processes[] {pid, name, argv, argv0, cmdline, cwd}` |

- **ID format [docs][live]:** workspace `w4`, tab `w4:t1`, pane `w4:p1`, terminal `term_65d3…`. The docs call these "opaque stable handles", and closed tab and pane IDs are not reused. When a pane moves to another workspace its pane ID changes and the old ID is returned as `previous_pane_id`, but the terminal stays alive. `terminal_id` survives a move, but agent commands do not accept terminal IDs.
- **`agent_status` [docs]:** one of `idle`, `working`, `blocked`, `done` or `unknown`. For Claude Code and Codex, herdr's integrations report only session identity, and state comes from screen-manifest detection ("Claude Code state comes from Herdr's screen manifest detection"). So `blocked` means herdr recognized a dialog on screen. It is not a hook fact and must not drive Steer's approval or question state. `done` means idle and not yet seen; an explicit `agent focus` or `pane focus` marks the agent seen.
- **`focused` [source][inferred]:** this is the server's default focus target. With one client it equals what that client shows. With several clients it is session-wide state and does not describe any particular client.
- **`terminal_title` [docs][live]:** OSC 0/2 titles written inside a pane stop at herdr and do not reach Ghostty (`configuration.mdx`, "Outer terminal window title"). Steer's existing `--terminal-title` marker therefore shows up as the herdr pane's `terminal_title` (observed as `Steer Claude <uuid>`), not as a Ghostty tab title. In 2 of 4 live panes the UUID in the title matched `agent_session.value`. The other 2 panes had no title. No mismatch was seen.
- **Single-pane check [schema][live]:** `TabInfo.pane_count` reports how many panes a tab holds, and `pane.layout` returns the split tree and `zoomed`. All 8 observed tabs had `pane_count: 1`.
- **`pane.process_info` on macOS [live]:** it returned `shell_pid`, `foreground_process_group_id` and the process list, but `tty` was `null` even though the pane's processes were on `ttys007`. On macOS, Steer cannot rely on `tty`. `shell_pid` and the process group can be joined to the hook's ancestry instead [inferred].

## Where `agent_session` comes from

- **Claude Code [source: `~/.claude/hooks/herdr-agent-state.sh`, integration v10]:** the hook is registered on `SessionStart` with matcher `^(startup|resume|clear|compact|fork)$`. It exits unless `HERDR_ENV=1`, `HERDR_SOCKET_PATH` and `HERDR_PANE_ID` are all set. It skips subagent events (where `agent_id` is present) and Cursor. It sends one `pane.report_agent_session` with `pane_id=$HERDR_PANE_ID`, `source="herdr:claude"`, `agent="claude"`, `seq=time_ns`, `agent_session_id=<hook session_id>` and, when present, `agent_session_path=<transcript_path>` and `session_start_source`. It waits at most 0.5 s and ignores every failure.
- **Codex [source: `~/.codex/herdr-agent-state.sh`, integration v8]:** the same mechanism with `source="herdr:codex"` and `agent="codex"`. It requires `transcript_path` and skips the report when `CODEX_THREAD_ID` is set and differs from the hook's `session_id`. It sends no `agent_session_path`. The hook is registered under `SessionStart` in `~/.codex/hooks.json`.
- **Server side [source]:** `src/app/api/panes.rs` calls `handle_pane_report_agent_session`, and `src/terminal/state.rs` calls `set_agent_session_ref_for_session_start`. A report applies only when its `seq` is newer for that source. Full-lifecycle sources face more gates: the detected agent must match the reported label and no recent process exit may be pending. The value is never checked against the agent's real session. herdr trusts whoever can write to the socket.
- **Lifecycle [source][inferred]:** the session is cleared when the agent process exits, is replaced or the pane respawns (several `persisted_agent_session = None` paths in `state.rs`). `terminal_agent_session_info` falls back to `persisted_agent_session`, the reference restored from `session.json`, when no live hook authority holds one. After a herdr server restart, `agent_session` can therefore show a restored reference before the resumed agent reports again [#102].
- **For Steer [inferred]:** `agent_session.value` is the agent's own session UUID reported from inside the pane, which is the same `session_id` that Steer's hook receives. It is a strong candidate for the exact binding the map requires, but Steer should also confirm the following:
  - `agent_session.source` is `herdr:claude` or `herdr:codex` and `agent` matches;
  - `agent` (the detected agent) is present and agrees;
  - exactly one live pane carries that value;
  - the tab's `pane_count` is 1 and the pane is not zoomed out of a split;
  - ideally, Steer's own hook recorded the same `HERDR_PANE_ID` and socket path for that session.

  If `HERDR_PANE_ID` is captured in Steer's hook, binding no longer depends on herdr's integration, which remains needed only for herdr's restore features [#102: decide whether Steer's hook may record those variables].

## Focus: does `agent focus` / `tab focus` change what the client shows?

- **Yes, for every attached client [source].** In `src/server/headless/client_views.rs`, a public socket request runs through `handle_api_request_with_shutdown_check` ("Applies a public socket request, including its session-wide focus projection"). When `agent.focus`, `tab.focus`, `pane.focus` or `workspace.focus` succeeds, it calls `focus_all_shell_clients_on_default_target()`, which moves every attached shell client's location to the target tab. Requests that come from a client's own UI move only that client.
- **`agent.focus` details [source]:** `focus_agent_target` resolves the target (a live agent name, or a pane ID that currently hosts an agent), focuses that pane in its workspace, calls `mark_active_tab_seen()` and switches to terminal mode. The response is the `AgentInfo`. The side effect matters: it clears herdr's `done` state for that agent.
- **`pane.focused` events [docs]:** "also reports manual pane selection changes from any client attached to this server. It does not move other clients' views, and its payload does not identify the client."
- **Implication [inferred]:** with exactly one attached client, an API focus is what that client displays, and a `pane.focused` event reflects that client's navigation. With two or more clients, focus moves all of them, and events cannot say which client acted. That is consistent with the map's rule that multiple clients are unavailable.
- **Outer focus [source]:** the server tracks each client's `outer_terminal_focus` (focus reports from the outer terminal) and a `foreground_client_id`, but neither is exposed through the JSON API. Steer still needs its own frontmost-Ghostty-tab check.
- **Needs #102:** observe that `agent focus` moves the visible pane in the single Ghostty-hosted client; that a zoomed or split tab behaves as expected; and how quickly `pane.focused` and `tab.focused` events arrive.

## `agent send-keys` semantics

- **Request [schema]:** `agent.send_keys {target, keys: [string]}`. On the CLI it is `herdr agent send-keys <TARGET> <KEY>...`. `pane.send_keys {pane_id, keys}` is the raw pane equivalent.
- **Addressing [docs][source]:** `target` must be a unique live agent name or the pane ID currently hosting that agent. Terminal IDs and agent kinds are rejected. The server resolves the target, requires an effective known agent in that terminal and checks `runtime_hosts_agent` (otherwise `agent_not_ready` or `agent_not_found`). There is no session parameter, so the server cannot check that the pane still holds the intended `agent_session` (`src/app/api/agents.rs`, `handle_agent_send_keys`). It also does not refuse when the agent is not `blocked`; only `agent.prompt` refuses a blocked agent.
- **Encoding [source][docs]:** each string is parsed by `config::parse_key_combo`: a single printable character, named keys (`enter`, `esc`, `tab`, arrows, `space`, `minus`, `plus` and others), modifier chords (`ctrl+c`, `alt+x`, `shift+tab`) or function keys. Multi-character strings such as `12` are not keys. All keys are validated before any byte is written (`invalid_key`). Each key is encoded by herdr's libghostty-based encoder using the pane's current keyboard protocol (`runtime.encode_terminal_key(key, keyboard_protocol())`). So `"1"` becomes the same bytes a real `1` keypress would produce for that application, including under the kitty keyboard protocol.
- **Delivery [source]:** the encoded bytes are queued with `try_send_bytes`, a non-blocking enqueue to the pane's PTY actor. An `ok` result means the bytes were accepted into the queue, not that they were written or consumed. A full queue returns `agent_send_keys_failed`. There is no acknowledgment from the application, no deduplication and no idempotency key, and a retry sends again [inferred].
- **For ADR 0006 [inferred]:** herdr can deliver exactly one digit key to an exact pane. Everything ADR 0006 requires around the key has to be done by Steer: the fresh pending-request check from the session rollout, re-resolving the pane by `agent_session` immediately before sending, the single-pane check, never retrying and never sending Enter unless it is proven necessary. A small race remains between Steer's check and herdr's enqueue [#102: confirm that a single digit commits the option in Codex CLI under herdr's key encoding].

## Events vs polling

- **Subscription [schema][docs]:** `events.subscribe {subscriptions: [...]}` keeps the connection open, and the first reply is `subscription_started`. The types are `workspace.*`, `worktree.*`, `tab.created`, `closed`, `focused`, `renamed` and `moved`, `pane.created`, `updated` (carrying the full `PaneInfo`, so it includes `agent_session` and title changes), `closed`, `focused`, `moved`, `exited` and `agent_detected`, `pane.agent_status_changed` (optionally filtered by `pane_id` and `agent_status`), `pane.output_matched`, `pane.scroll_changed` and `layout.updated`. No event names a client. There is no dedicated event for a session change; such changes arrive as `pane.updated` [inferred from `EventData`].
- **Guarantees [docs]:** there is no replay before acceptance, and ordering holds only within each subscription entry. Event history is bounded and shared: a slow reader gets `events_lost` and the connection closes. Events and snapshots share no sequence boundary. The documented recovery is to resubscribe, wait for `subscription_started`, then fetch `session.snapshot` on a second connection and treat events as signals to invalidate cached state. If any referenced pane does not exist, the whole subscribe request is rejected and the connection closes. After a live handoff, subscriptions must reconnect.
- **One-shot waits [schema]:** `events.wait {match_event, timeout_ms}` and `agent.wait` (run by the server, pinned to the resolved pane occupant).
- **Recommendation [inferred]:** subscribe as an invalidation signal and run authoritative `agent.list`, `pane.get` or `session.snapshot` reads before any action, together with a bounded polling fallback. Target revalidation must always be a fresh read immediately before focus or send-keys. A cached event is never enough.

## Multiple clients and named sessions

- **Named sessions [docs][live]:** each named session is its own server with its own socket. `herdr session list [--json]` enumerates them along with their status. Panes inherit the socket of the server that created them, which is the `HERDR_SOCKET_PATH` in the hook's environment. A Steer binding should store the socket path with the pane ID, because IDs such as `w1:p1` are unique only within one server [docs].
- **Attached clients [source][live]:** the JSON API has no method to list or count clients. The server keeps a client table (`src/server/clients.rs`, `app_client_count`), but it is not exposed. The read-only process inspection below works:
  - `netstat -f unix -an` shows the listening `herdr-client.sock` (the entry with a vnode) and one connected server-side socket for each client.
  - `lsof -nP -U` maps each connected socket's peer to a client PID. Observed: server PID 3789 had one connected `herdr-client.sock` socket whose peer was PID 70502, the `herdr` client.

  Direct `herdr agent attach` clients and remote bridges also use the client socket [inferred]. They would need to be told apart [#102].
- **For the map's multi-client rule [inferred]:** count client-socket peers. More than one client, or an unexplained peer, means unavailable. This depends on lsof and netstat output formats and is less authoritative than an API would be.

## Outer terminal hosting the client

- **Process chain [live]:** herdr client PID 70502 (`herdr`, `ttys002`) is the child of `-/bin/zsh` (70461, `ttys002`), whose parent is `/usr/bin/login` (70460), whose parent is `/Applications/Ghostty.app/Contents/MacOS/ghostty` (828). The server (`herdr server`, PID 3789) has its parent set to `launchd`, no TTY, and stdio on `/dev/null`. Its pane PTYs are `/dev/ptmx` masters.
- **What is known [live][source]:** the client's TTY (`ttys002`) and its Ghostty ancestor. herdr itself does not report the client PID or TTY.
- **Gap [inferred, from `docs/ghostty-investigation.md`]:** Ghostty 1.3.1's AppleScript terminal object exposes neither TTY nor PID, so mapping `ttys002` to a Ghostty window, tab or terminal ID is unresolved, the same gap as #3 and ADR 0005. A candidate is a title beacon. herdr writes the outer terminal title from `ui.window_title`, whose tokens include `{workspace}`, `{tab}` and `{terminal_title}`, and `client.window_title.set` overrides it for the foreground client. Matching that title in Ghostty's scripting dictionary could identify the herdr tab. Calling `client.window_title.set` changes state, though, and Steer's rule is never to edit herdr configuration [#102 and a decision ticket].
- **`GHOSTTY_*` variables in panes [live]:** they are inherited from whichever environment started the server. They identify no Ghostty surface.

## Questions for #102

1. With one Ghostty-hosted client, does `agent focus <pane>` visibly switch that client to the exact pane? Does `tab focus` do the same, including from another Space or a zoomed tab? Are `pane.focused` and `tab.focused` events emitted?
2. Does a single `agent send-keys <pane> 1` commit option 1 in a disposable Codex CLI `request_user_input` pane under herdr's encoder (kitty protocol or legacy)? Is Enter ever needed?
3. After `herdr server stop` (in an isolated named session) and resume, how long does `agent_session` show the restored reference before the agent reports again? Can the restored value be distinguished from a live report?
4. With two attached clients on one server, do the lsof and netstat peer counts match? How do `herdr agent attach` and remote-bridge connections look?
5. Can the Ghostty terminal hosting the herdr client be identified without changing state, for example from the default `ui.window_title` value showing in Ghostty's terminal `name`?
6. Confirm that Steer's hook helper sees `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` for both Claude Code and Codex CLI, and that the value equals the pane where herdr's `agent_session` appears.

Run these probes in a disposable named session (`herdr --session steer-probe`) with disposable agents, never against the user's default session.
