# Zellij CLI: pane targeting, focus, input and client tty (#202)

Checked 2026-10-11 for [Research Zellij's CLI for pane targeting and client tty](https://github.com/r-curio/herdly/issues/202), a research child of [Support iTerm2, Terminal.app, WezTerm and multiplexers](https://github.com/r-curio/herdly/issues/197). This document records facts only. Decisions belong to the grilling tickets.

## Sources and versions

- **Zellij source:** tag `v0.45.1` (`efd8fd5a89a20c07a111d248ad7fce53848d2c18`, released 2026-08-28), the latest release when checked. `main` was at `333d789` (2026-10-09). Paths below are relative to [zellij-org/zellij](https://github.com/zellij-org/zellij) at `v0.45.1` unless a tag is named.
- **Older tags compared:** `v0.40.1`, `v0.41.2`, `v0.42.2`, `v0.43.1`, `v0.44.0`, `v0.44.1`, `v0.44.3`, `v0.45.0`. Files were fetched from each tag and diffed for the CLI surface.
- **Release notes:** `CHANGELOG.md` at `v0.45.1`, plus `gh release list -R zellij-org/zellij`.
- **Docs:** [CLI actions](https://zellij.dev/documentation/cli-actions.html) and [Controlling Zellij through the CLI](https://zellij.dev/documentation/controlling-zellij-through-cli.html), fetched 2026-10-11.
- **Binary:** the official `zellij-aarch64-apple-darwin.tar.gz` from release v0.45.1 was downloaded into a scratch directory. Its binary SHA-256 `ca5f9333…4a2c` matched the published `.sha256sum`. It was run only with `--version` (`zellij 0.45.1`) and `--help` for subcommands. Zellij is not installed on this machine. No session was started, attached to, listed or sent anything.
- **Open Island:** [Octane0411/open-vibe-island](https://github.com/Octane0411/open-vibe-island) at `b50f87a` (2026-09-15).

Nothing here was observed against a running Zellij session. Every behavioral claim comes from source or docs. **Live behavior is unverified throughout.**

## Answer in brief

1. **Identifiers.** Panes are `terminal_<n>` or `plugin_<n>`, and a bare number means `terminal_<n>`. Since 0.44.0, terminal pane IDs are not recycled within a session, and tabs have a stable `tab_id` separate from their position. `zellij action list-panes --json --all` (0.44.0+) returns every pane with its tab ID, tab position, tab name, title, focus/floating/exited state and foreground command.
2. **Clients.** `zellij action list-clients` returns only `CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND`. It exposes no client TTY, PID, host terminal or terminal size. `list-tabs --json` adds which client IDs have each tab active. Joining a Zellij client to a host terminal tab has to come from outside Zellij, for example the `zellij` client process's controlling TTY. Zellij gives no client-ID-to-PID mapping (unverified live).
3. **Title.** A pane's `title` in `list-panes` is the user-set pane name if there is one, otherwise the last OSC 0/2 title the program wrote. So a Codex title (ADR 0005) or a Claude Code title should be visible per pane (unverified live). Zellij also writes each client's host-terminal title as `<session> | <focused pane title>`.
4. **Focus.** `zellij action focus-pane-id <id>` (0.44.1+) switches to the pane's tab and focuses the pane. If the pane does not exist or is already focused, it prints an error to stderr and exits non-zero (2 by source reading). Before 0.44.1 there is no CLI pane focus; `go-to-tab <position>` (1-based) and `go-to-tab-name` exist in every compared version, and `go-to-tab-by-id` exists from 0.44.0.
5. **Which client acts.** A CLI action that needs a client (focus, tab switch, current-tab info) applies to the session's **last active client**, the last one that sent a keystroke. It is not the client in a particular host terminal tab. With exactly one attached client that is the same client, but only once that client has typed.
6. **Input.** `write-chars`, `write`, `paste` and `send-keys` take `--pane-id` from 0.44.0. Writes to an unknown pane ID are silently dropped and still exit 0. The CLI exit status confirms only that the server handled the request, not that the program read the bytes.
7. **Sockets.** On macOS the session socket is normally `$TMPDIR/zellij-<uid>/contract_version_1/<session>` (0.44.0+). Before 0.44.0 the last component was the Zellij version (for example `…/0.43.1/<session>`). `ZELLIJ_SOCKET_DIR` overrides the base directory. The socket is mode `1700`, and the server checks no peer credentials.
8. **Open Island** maps the hook's `ZELLIJ_PANE_ID` to a tab position with `list-panes --json --tab` and runs `go-to-tab <position+1>`. It then activates the first running terminal app from a fixed list, without any TTY join, and verifies nothing. It sends no input to Zellij panes.

## Version map

The CLI surface that matters changed at 0.44.0 and 0.44.1. The table comes from `zellij-utils/src/cli.rs`, `zellij-server/src/screen.rs` and `zellij-utils/src/consts.rs` at each tag.

| Capability | ≤ 0.43.1 | 0.44.0 | 0.44.1 – 0.45.1 |
| --- | --- | --- | --- |
| `list-clients` | yes (present at 0.40.1) | yes | yes |
| `query-tab-names`, `dump-layout`, `go-to-tab`, `go-to-tab-name`, `rename-session` | yes | yes | yes |
| `list-panes`, `list-tabs`, `current-tab-info`, `go-to-tab-by-id` | no | yes | yes |
| `--pane-id` on `write`/`write-chars`, plus `paste` and `send-keys` | no | yes | yes |
| `focus-pane-id` | no | no | yes |
| "already focused" error on `focus-pane-id` | n/a | n/a | yes |
| Socket subdirectory | Zellij version (`VERSION`) | `contract_version_1` | `contract_version_1` |
| Terminal pane IDs never recycled | no | yes (#4859) | yes |
| Stable `tab_id` (#4685) | no | yes | yes |

CHANGELOG entries behind these rows:

- **0.44.0:** `zellij action list-panes` (#4690), sending keys to other panes from the CLI (#4691), querying tab info (#4695), `--pane-id` and `--tab-id` on all relevant actions (#4846), tab ID vs position canonicalized (#4685), terminal pane IDs not recycled (#4859), sessions compatible across versions (#4439), and read-only attach (#4487).
- **0.44.1:** "add `focus-pane-with-id` … cli commands" (#4926). The shipped subcommand is named `focus-pane-id` in `cli.rs` and in `--help`.
- **0.45.0:** tabs may differ in size when clients focus different tabs (#5133), nested-session handling (#5417), and title-frames UI (#5318).

Because the socket directory depended on the exact version before 0.44.0, a pre-0.44 CLI only sees sessions started by the same Zellij version. From 0.44.0, any build with contract version 1 sees them. That follows from `ZELLIJ_SOCK_DIR` in `consts.rs` and is unverified live.

**Detecting version:** `zellij --version` prints `zellij <semver>` for the CLI binary that runs it. No CLI command reports the *running server's* version. The server process is `zellij --server <socket path>` (`zellij-client/src/lib.rs`, `spawn_server`), so its executable path is visible in the process table. The version of that executable is not, short of running it (unverified).

## Sessions

- `zellij list-sessions` (`ls`) reads `ZELLIJ_SOCK_DIR` and probes each socket by connecting and sending `ConnStatus` (`zellij-utils/src/sessions.rs`, `assert_socket`). **Side effect:** a socket that refuses the connection is deleted. Resurrectable (exited) sessions from the session-info cache are merged into the output.
- Output with `--no-formatting` is `<name> [Created <duration> ago] <suffix>`, where the suffix is `(current)`, `(EXITED - attach to resurrect)` or empty. With `--short` only the name is printed, **including exited sessions**, so `-s` alone cannot distinguish live from resurrectable sessions (`print_sessions`).
- **Choosing a session for `zellij action`** (`src/commands.rs`, `send_action_to_session`): with no live session the CLI prints "There is no active session!" and exits 1. With exactly one, the CLI uses it (and errors if `--session` names another). With several, it needs `--session <name>` or `ZELLIJ_SESSION_NAME` in the environment, and otherwise exits 1 with a list.
- **Session rename** (`zellij action rename-session`, `screen.rs`) renames the socket file and the server's own `ZELLIJ_SESSION_NAME`. Panes that already exist keep the old `ZELLIJ_SESSION_NAME` in their environment, and the server's `--server <path>` argv keeps the old path.

## Panes, tabs and IDs

- **Pane ID syntax:** `terminal_<n>`, `plugin_<n>`, or a bare integer meaning a terminal (`PaneId::from_str`, and the `--pane-id` help text).
- **Pane environment** (`zellij-server/src/os_input_output_unix.rs`, `spawn_terminal`): each terminal pane's command gets `ZELLIJ_PANE_ID=<n>`, plus the server's inherited environment. That includes `ZELLIJ=0` (`zellij-server/src/lib.rs`, `start_server_impl`) and `ZELLIJ_SESSION_NAME=<name>` (set by the client before spawning the server). The pane gets its own PTY through `login_tty`.
- **`list-panes`** (`route.rs`, `Action::ListPanes`; `screen.rs`, `collect_pane_list`): lists selectable panes in all tabs (all panes with `--all`), sorted by tab position, then terminals before plugins, then ID. `--json` serializes `PaneListEntry` (`zellij-utils/src/data.rs`), which includes:
  - `id`, `is_plugin`, `title`, `is_focused`, `is_floating`, `is_suppressed`, `is_fullscreen`, `exited`, `exit_status`, `is_held`, `is_selectable`, geometry, `terminal_command` (the command a command-pane was started with), `plugin_url`;
  - `tab_id`, `tab_position` (0-based), `tab_name`;
  - `pane_command` and `pane_cwd`, added when `--json`, `--command` or `--all` is given.
- **`is_focused`** is true when *any* client in that tab focuses the pane (`tiled_panes`, `pane_id_is_focused` over all clients). It does not identify a client.
- **Foreground process:** `pane_command` comes from the pane's PTY foreground process group (`tcgetpgrp`). It is the argv of that group-leader PID, joined with spaces, and is used only when it differs from the pane's shell. Otherwise it falls back to the shell's argv (`pty.rs`, `get_pane_running_command`; `os_input_output.rs`, `get_foreground_cmds`). Zellij does not expose the PID itself. Each pane's lookup has a 100 ms timeout, and an optional user `post_command_discovery_hook` can rewrite the result.
- **Pane TTY:** no CLI output names a pane's TTY device. A pane's processes have that PTY as their controlling terminal, so `ps`/`lsof` can see it. Mapping it back to a pane ID would need `ZELLIJ_PANE_ID` from the process environment (unverified on macOS) or another join.
- **`list-tabs --json`** serializes `TabInfo`: `position`, `name`, `tab_id`, `active` (true if *any* client has the tab active), `other_focused_clients` (every client ID whose active tab this is), `is_fullscreen_active`, `are_floating_panes_visible`, pane counts (`selectable_tiled_panes_count`, `selectable_floating_panes_count`, `panes_to_hide`), viewport sizes, swap-layout state and bell flags (`screen.rs`, `get_tab_info`). The `name` here is the tab's own name. In 0.45, plugins such as the tab bar may instead show a single-pane tab's pane title (`single_pane_tab_name`, title-frame mode only). The CLI `list-tabs` uses `tab.name`.
- **`current-tab-info [--json]`** reports the active tab of the client the action resolves to (see [Which client a CLI action acts for](#which-client-a-cli-action-acts-for)).
- **`query-tab-names`** prints tab names only. **`dump-layout`** prints the session as a KDL layout. Neither is needed once `list-panes`/`list-tabs` exist, and whether `dump-layout` carries pane IDs was not checked.

## Titles (OSC 0/2)

- **Pane title:** the VT parser treats OSC `0` and OSC `2` as "set window title". It trims the text and stores it as the grid title (`zellij-server/src/panes/grid.rs`). OSC 1 (icon name) is not stored as the title.
- **What `list-panes` shows:** `current_title()` returns the user-set pane name when non-empty, otherwise the grid title, otherwise the pane's initial title (`zellij-server/src/panes/terminal_pane.rs`). A user `rename-pane` therefore hides the program's title from `list-panes` until `undo-rename-pane`.
- **Codex and Claude titles:** a Codex TUI configured with `tui.terminal_title = ["session-id"]` (ADR 0005) or Claude Code writes its title with OSC 0/2. Under the rules above, that title should appear as the pane's `title`. **Not observed live.**
- **Host-terminal title:** for each client, Zellij writes OSC 0 to the host terminal with `<session> | <title of the pane that client focuses>`, or just `<session>` when the title is empty (`zellij-utils/src/shared.rs`, `make_terminal_title`; `zellij-server/src/ui/pane_contents_and_ui.rs`). It is written only for clients focusing that pane, and only when it changes. A host terminal tab running a Zellij client focused on a Codex pane would therefore be titled `<session> | <Codex short ID>…`, not the bare Codex title (unverified live). The session name comes from the server's environment, so after a rename it is the new name.

## Which client a CLI action acts for

- Every `zellij action` invocation connects to the session socket as a temporary client and sends `ClientToServerMsg::Action { …, is_cli_client: true }` (`zellij-client/src/cli_client.rs`). The CLI client also passes `terminal_id` from its own `ZELLIJ_PANE_ID` if that variable is set. A process outside Zellij, such as Herdly, has none.
- The server resolves the acting client in `route.rs`:

  ```rust
  // for cli clients, we want to default to the last active client
  // (i.e. the last client to have issued a keystroke) …
  session_state.read().unwrap().get_last_active_client().or(maybe_client_id).unwrap_or(client_id)
  ```

  `last_active_client` is set on each `ClientToServerMsg::Key` and cleared when that client leaves (`zellij-server/src/lib.rs`).
- So `focus-pane-id`, `go-to-tab*`, `current-tab-info`, and `write-chars` without `--pane-id` (which writes to that client's focused pane) act for whichever client typed last. If several clients are attached, that may not be the client in the host tab Herdly means to raise. Read-only watchers (`zellij watch`, 0.44.0) and web clients are clients too.
- **No keystroke yet:** if no client has typed since the session started, the acting client falls back to the CLI client itself. `go-to-tab` then uses the first client in `active_tab_ids` (`screen.rs`, `ScreenInstruction::GoToTab`). What `focus-pane-id` does in that state was not traced to a conclusion (unverified).

## Focus and verification

- **`focus-pane-id <id>`** (0.44.1+; `route.rs` → `ScreenInstruction::FocusPaneWithId`, `screen.rs`):
  - Pane not in any tab: the server sets exit status 1 and the error `Pane with id … not found`.
  - Pane already the acting client's active pane: the server sets exit status 1 and the error `Pane … is already focused`. A caller must not treat a non-zero exit alone as failure.
  - In both cases `route.rs` checks the error message before the exit status, so it sends `LogError`. The CLI then prints the message to stderr and exits **2**, not 1 (`cli_client.rs`, `individual_messages_client`). This comes from reading the source and is unverified live.
  - Otherwise: it switches the acting client to the pane's tab (`go_to_tab(position + 1)`) and focuses the pane. A hidden floating pane is shown (`should_float_if_hidden = true`). The pane's bell is cleared, and the session state is reported to plugins.
- **`go-to-tab <index>`** is 1-based on tab position (`go_to_tab(index)` → `switch_active_tab(index - 1)`). No not-found error path was found; an out-of-range index appears to be a silent no-op (unverified live). Positions change when tabs are moved or closed.
- **`go-to-tab-by-id <id>`** (0.44.0+) uses the stable tab ID. **`go-to-tab-name <name>`** matches by name, and `--create` makes the tab if it is missing, which a read-only caller must not pass.
- **Completion:** the CLI waits for the server to finish the action, up to a server-side 1-second `ACTION_COMPLETION_TIMEOUT` (`route.rs`, `wait_for_action_completion`). It then exits with the action's status: 0, a custom status, or 2 for an error message (`cli_client.rs`, `individual_messages_client`). A timeout is only logged server-side and is not reported as a failure.
- **Verifying focus afterwards:** re-read `list-panes --json` (`is_focused` on the pane), `list-tabs --json` (`other_focused_clients` containing the expected client ID), and `list-clients` (`ZELLIJ_PANE_ID` for that client). `list-clients` gives the per-client answer to "which pane has focus". Whether the host terminal tab is frontmost is outside Zellij.
- **`list-clients` caveat:** for each tab, it collects clients from the *floating* panes when floating panes are visible and from the tiled panes otherwise (`session_layout_metadata.rs`, `list_clients_metadata`). In a single-pane tab with no visible floating panes, this lists the client against the tiled pane.

## Input to one pane

- **`write-chars --pane-id <id> <chars>`** and **`write --pane-id <id> <bytes…>`** (0.44.0+) become `WriteCharsToPaneId`/`WriteToPaneId`. The server finds the tab holding the pane and writes the bytes to that pane's PTY, regardless of focus (`screen.rs`, `ScreenInstruction::WriteToPaneId`). It first sends `ClearScroll` for the acting client.
  - **Unknown pane ID:** the loop finds no tab and does nothing. No error is set, so the CLI exits 0.
  - **Without `--pane-id`:** `WriteChars` becomes `ScreenInstruction::WriteCharacter(…, client_id, …)`, so input goes to the acting client's focused pane (`route.rs`).
- **`send-keys "<key>" …`** (0.44.0+) parses named keys (`actions.rs`), and its two forms differ:
  - **With `--pane-id`,** each key is pre-encoded on the CLI side with `serialize_kitty()` (kitty keyboard protocol, `DISAMBIGUATE_ESCAPE_CODES`; `data.rs`). The bytes are then written raw through `WriteToPaneId`, whatever keyboard mode the pane's program has negotiated.
  - **Without `--pane-id`,** the key goes to the focused pane as `Action::Write { key_with_modifier, is_kitty_keyboard_protocol: true }`, which the server adapts to the pane.
  - Whether an unmodified digit encodes as the plain character was not checked (unverified). `write-chars --pane-id` sends the string's UTF-8 bytes unchanged.
- **`paste --pane-id`** (0.44.0+) wraps text in bracketed paste.
- **Delivery confirmation:** none beyond the exit status, which means the server queued the write. There is no acknowledgment that the program consumed it. `zellij subscribe --pane-id <id> --format json` (0.44.0+) streams a pane's rendered viewport and could show an on-screen change, but that is render output, not a delivery receipt.
- **Older versions:** before 0.44.0, `write-chars`/`write` have no `--pane-id` and always target the acting client's focused pane.

## Joining a client to its host terminal tab

- **Processes:** a Zellij client is the `zellij` process the user ran in the host terminal tab (`zellij`, `zellij attach <name>`, `zellij -s <name>`, …). Its controlling terminal is that tab's TTY. The server is a separate daemonized `zellij --server <socket path>` process with no controlling terminal (`zellij-client/src/lib.rs`; `zellij-server/src/lib.rs`, `daemonize`). The socket path's last component is the session name at the time the server started.
- **What Zellij exposes:** client IDs (small integers assigned by `SessionState::new_client`) with their focused pane, through `list-clients` and `list-tabs`. It exposes no client PID, TTY, host terminal or environment. The plugin API's `ListClients` returns `ClientInfo { client_id, pane_id, running_command, is_current_client }`, with no PID or TTY either (`data.rs`).
- **Possible external join (unverified):** the herdr precedent ([live proof](evidence/herdr-ghostty-live.md)) counted attached clients from `lsof -U` peers on the session socket and joined each to a host TTY. The same technique on Zellij's session socket would find client processes. It would also see transient connections from any `zellij action`, `zellij list-sessions` probe (including Herdly's own), `zellij watch`, and the web server. It would not yield Zellij's client IDs. Whether `lsof` on macOS shows usable peer pairs for Zellij's socket was not tested. A client's argv names the session only when the user typed it.
- **Single-client check:** `list-clients` counts clients that focus a pane, including watchers and web clients. The number of `zellij` client processes on the socket is a separate count, and the two can be compared (unverified).

## Socket location and permissions

- **Directory** (`zellij-utils/src/consts.rs`, Unix): `ZELLIJ_SOCK_DIR = ($ZELLIJ_SOCKET_DIR | runtime_dir | $TMPDIR/zellij-<uid>) / contract_version_1`. On macOS the `directories` crate's `ProjectDirs::runtime_dir()` has no macOS value (it is Linux-only), so the default is `std::env::temp_dir()/zellij-<uid>/contract_version_1`. That is normally the per-user `/var/folders/…/T/` directory (inferred from the crate's documented behavior, unverified live). Up to 0.43.1 the subdirectory was the Zellij version string.
- **Override:** a user who sets `ZELLIJ_SOCKET_DIR` in their shell moves the sockets. A process that does not share that environment, such as a GUI app, would look in the default place and not find them.
- **Permissions:** the CLI creates the directory with mode `0700`, and the server sets the socket to `0o1700` (sticky bit plus owner rwx; `zellij-server/src/lib.rs`, `start_server_impl`). No peer-credential check (`getpeereid`, `SO_PEERCRED`) exists in the Zellij source, so access control is the filesystem mode alone.
- **Path length:** the CLI exits 1 if the socket path is 104 bytes or longer on macOS (`check_ipc_pipe_length`), which suggests `ZELLIJ_SOCKET_DIR` for long `$TMPDIR` values.
- **Protocol:** the socket speaks Zellij's internal protobuf client/server contract (`zellij-utils/assets/prost_ipc/client_server_contract.rs`). It is not a documented public API. The CLI is the documented route.

## Required permissions and user configuration

- The CLI route needs no Zellij configuration change and no macOS permission. It runs as the same user and connects to the user's socket. `zellij action` loads the user's Zellij config (`Option<Config>` in `send_action_to_session`), which matters only for actions that create panes or tabs.
- **Side effects on the user's state:** `focus-pane-id` clears the pane's bell and moves the acting client's tab and focus. `go-to-tab-name --create` creates tabs. `list-sessions` deletes refused sockets. The read-only queries (`list-panes`, `list-tabs`, `list-clients`, `current-tab-info`, `query-tab-names`) change no session state, as far as the source shows.
- **Plugins and pipes:** the plugin API has richer events (`PaneUpdate`, `TabUpdate`, `ListClients` with `is_current_client`) and commands such as `focus_terminal_pane` and `write_chars_to_pane_id`. Using them requires loading a plugin (layout/config, `zellij plugin`, `zellij action launch-plugin`, or `zellij pipe --plugin`) and granting it permissions through Zellij's permission prompt. That changes the user's session and is not needed for the facts above. This route was not investigated further.

## How Open Island does it (`b50f87a`)

- **Capture** (`Sources/OpenIslandCore/ClaudeHooks.swift` ~L998, `CodexHooks.swift` ~L591, `GrokHooks.swift`): when the hook environment has `ZELLIJ` set (`inferTerminalApp`, checked before `TERM_PROGRAM`), the terminal app is `"Zellij"`. `terminalSessionID` becomes `"<ZELLIJ_PANE_ID>:<ZELLIJ_SESSION_NAME>"`. The AppleScript locator is skipped. Under Codex's shared daemon these variables are the daemon's inherited values (see [ADR 0012](adr/0012-bind-codex-herdr-panes-by-title-and-foreground-process.md)), which Open Island does not account for.
- **Discovery fallback** (`Sources/OpenIslandApp/ActiveAgentProcessDiscovery.swift`, `recognizedTerminalApp`): an ancestor process whose command ends in `/zellij` classifies the agent as running in Zellij.
- **Ghostty correction skipped** (`TerminalSessionAttachmentProbe.swift` ~L734): a Zellij jump target is never overwritten with Ghostty's terminal ID, "as it would break Zellij pane targeting".
- **Jump** (`Sources/OpenIslandApp/TerminalJumpService.swift`):
  1. `resolveZellijPath()` checks `~/.local/bin/zellij`, `/usr/local/bin/zellij`, `/opt/homebrew/bin/zellij`, then falls back to `/usr/bin/which zellij`.
  2. `zellijTabPosition` runs `zellij [--session <name>] action list-panes --json --tab`, decodes `[{id, tab_position}]`, and takes the first entry whose `id` equals the pane number. It does not check `is_plugin`, so `plugin_<n>` with the same number could match.
  3. `jumpToZellijPane` runs `zellij [--session <name>] action go-to-tab <tab_position + 1>`. It does not run `focus-pane-id`, so it relies on the tab having one pane, or accepts whichever pane in it is focused.
  4. It activates "the parent terminal" with `open -b <bundle id>`, choosing the **first running app** in the `knownApps` order (iTerm, cmux, Ghostty, Terminal, Warp, WezTerm, …). That is not necessarily the app hosting the client, and no tab within it is selected.
  5. It returns success when `go-to-tab` exits 0. There is no read-back, and `waitUntilExit` has no timeout.
  6. **On failure** (no pane ID, no binary, pane not found, or a non-zero exit) it still activates the first running known terminal and reports "Activated parent terminal".
- **Requirements:** `list-panes` makes Open Island's Zellij jump require Zellij 0.44.0 or later. On older versions the command fails and the fallback activation runs.
- **Input:** `TerminalTextSender.swift` has no Zellij case. Open Island sends no text or keys to Zellij panes.
- **Acting client:** because `go-to-tab` is a CLI action, it moves the last active client's tab (see [Which client a CLI action acts for](#which-client-a-cli-action-acts-for)), not necessarily the client in the terminal Open Island raises.

## Open questions (all unverified)

- Live confirmation that a Codex (ADR 0005 title) and a Claude Code pane show their titles in `list-panes`, and that the host terminal tab's title reads `<session> | <title>`.
- What `focus-pane-id` does before any client has typed (no `last_active_client`).
- Whether `lsof -U` on macOS pairs Zellij client processes with the session socket, as it did for herdr, and how transient CLI connections appear.
- Whether `ZELLIJ_PANE_ID` can be read from another same-user process's environment on macOS, to join a Claude or Codex process to its pane.
- The real-world exit status and timing of `write-chars --pane-id` and `focus-pane-id` against a running 0.44.x/0.45.x server, and the behavior of a pre-0.44 server reached by a 0.44+ CLI (different socket directories, so expected to be invisible).
- How `send-keys` digits are received by Codex's TUI under the kitty keyboard encoding, compared with `write-chars`.
