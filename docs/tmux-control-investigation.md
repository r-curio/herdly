# tmux control surface for pane targeting and client TTY (#201)

Checked 2026-10-11 for [Research tmux's control surface for pane targeting and client tty](https://github.com/r-curio/steer/issues/201), a child of the map [Support iTerm2, Terminal.app, WezTerm and multiplexers](https://github.com/r-curio/steer/issues/197). This document records facts only. Decisions belong to the grilling tickets.

## Method and versions

- **tmux 3.8**, the latest release (GitHub release published 2026-09-09; Homebrew `tmux` stable is also 3.8). Source read at tag `3.8`, commit `7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53` of [tmux/tmux](https://github.com/tmux/tmux). The manual is `tmux.1` at that tag, rendered with `mandoc`. When this document says "the manual", it means that file. "Since" versions come from the `CHANGES` file at the same tag.
- **No live tmux was run.** tmux is not installed on the research machine (`tmux -V` reports command not found), and the ticket forbids touching a running server. Every claim below comes from source or the manual. Behavior that needs a live check is marked **unverified**.
- **Codex CLI:** `codex-rs/tui/src/terminal_title.rs` read at `rust-v0.161.0` (the installed `codex-cli 0.161.0`) and on `main` at `cc7ba33601286a751477832b01de7b6f8de0dd9c`.
- **Open Island:** [open-vibe-island](https://github.com/Octane0411/open-vibe-island) at commit `b50f87aa7d58af1478837d48909eb68baa37f9b9` (2026-09-15).

## Answer in brief

1. **Identity.** tmux gives every session, window and pane a server-unique ID (`$N`, `@N`, `%N`) that never changes during the object's life in that server. `pane_tty`, `pane_title`, `pane_current_command`, `pane_pid` and `window_panes` are all formats that `list-panes -a -F` can print.
2. **Client and host tab.** `list-clients -F` lists only attached clients. It reports `client_tty`, `client_pid`, `client_session`, `client_flags`, and the client's current window and pane. `client_tty` is the TTY the tmux client process is running on, which is the host terminal tab's TTY. The client reports this value itself and the server does not check it.
3. **Selecting.** `select-window -t @W` and `select-pane -t %P` change a session's current window and active pane. `switch-client -c <client> -t %P` moves one client to the pane's session, window and pane in a single command. None of these raise the host terminal. tmux can confirm the result through a fresh `list-clients`. tmux has no notion of "frontmost".
4. **Focus.** The `focused` client flag is only meaningful when the user has turned on `focus-events` (off by default) and the outer terminal reports focus. Otherwise every client always shows `focused`.
5. **Input.** `send-keys -t %P -l <text>` delivers literal UTF-8 to one pane. A zero exit status confirms only that the target resolved. The keys can be swallowed without error: in copy mode they become mode commands, and with input disabled (`select-pane -d`) they are dropped.
6. **Titles.** Codex writes its title as plain `OSC 0`. tmux stores both `OSC 0` and `OSC 2` as `pane_title`, because `allow-set-title` defaults to on. The host terminal's own tab title shows nothing from tmux unless the user turns on `set-titles` (off by default).
7. **Socket.** The default socket is `$TMUX_TMPDIR/tmux-<uid>/default`, or `/tmp/tmux-<uid>/default` (which resolves to `/private/tmp/...` on macOS). tmux refuses to use the directory if it is not owned by the user or has any "other" permission bit. Steer never needs to change user configuration to read state.
8. **Version.** `tmux -V` reports the version of the binary. `#{version}` reports the version of the running server. The client and server must share protocol version 8, or the client prints `protocol version mismatch`.

## Identifiers and formats

The manual's FORMATS table lists all of the following, and `format.c` implements them.

| Format | Meaning (manual) | Source notes |
| --- | --- | --- |
| `session_id`, `window_id`, `pane_id` (`#D`) | Unique IDs | Prefixed `$`, `@`, `%`. "These are unique and are unchanged for the life of the session, window or pane in the tmux server" (COMMANDS section). They are reused after a server restart, so the IDs are not unique across restarts. |
| `pane_tty` | "Pseudo terminal of pane" | `wp->tty`, a device path such as `/dev/ttysNNN`. |
| `pane_title` (`#T`) | "Title of pane (can be set by application)" | See [Titles](#titles). |
| `pane_current_command` | "Current command if available" | On macOS (`osdep-darwin.c`) this is the short name (`pbsi_comm`, at most 16 characters) of the **process-group leader of the pane's foreground process group** (`tcgetpgrp`), passed through `parse_window_name`. If that name is unavailable, tmux falls back to the pane's start command and then the shell. |
| `pane_pid` | "PID of first process in pane" | The process tmux spawned, normally the shell. It is not the foreground process. |
| `pane_current_path`, `pane_start_command` | cwd and start command | Available. A cwd is not an identity (see AGENTS.md). |
| `pane_active`, `window_active` | Active pane in its window; current window in its session | |
| `window_panes` | "Number of panes in window" | Counts **floating panes too** (`window_count_panes(w, 1)`). Floating panes are new in 3.7. `pane_floating_flag` marks them. |
| `window_zoomed_flag` | Window zoomed | |
| `window_active_clients` | "Number of clients viewing this window" | Counts clients whose session's current window is this window. |
| `session_name` (`#S`), `session_attached` | Name; number of attached clients | Session names can be renamed. Only the `$N` ID is stable. |
| `client_tty`, `client_name`, `client_pid` | Client's pty, name, PID | `client_tty` is `ttyname(STDIN_FILENO)` of the client process. The client sends it in `MSG_IDENTIFY_TTYNAME`, and sends `client_pid` in `MSG_IDENTIFY_CLIENTPID`. The server stores both without checking. |
| `client_session` | Name of the client's session | A name, not an ID. Use `session_id` in a `list-clients` format for the ID. |
| `client_flags` | "List of client flags" | Comma-separated: `attached`, `focused`, `control-mode`, `read-only`, `suspended`, `UTF-8` and others (`server_client_get_flags`). Since 3.2; `focused` added in 3.2. |
| `version`, `pid`, `socket_path`, `start_time` | Server version, PID, socket path, start time | Read from the server process. `start_time` and `pid` can identify a server instance, which is useful for detecting a restart. |

**Commands that list.** The manual entries are as follows.

- `list-panes -a -F <fmt> [-f <filter>]` lists every pane on the server. It walks every session and every window in each session (`cmd-list-panes.c`). A window linked into two sessions therefore appears once for each session, with the same `pane_id`. Without `-a`, a target is needed. The `-f` filter is available since 3.2.
- `list-clients -F <fmt> [-f <filter>] [-t session]` lists only clients that have the `attached` flag and a session (`sort_get_clients`, `cmd-list-clients.c`). The short-lived client that runs `list-clients` is not listed. Each row's session, window and pane formats are that client's current session, its current window, and that window's active pane (`format_defaults`). So `list-clients -F '#{client_tty} #{session_id} #{window_id} #{pane_id}'` reports what each client is showing.
- `display-message -p [-c client] [-t target] <fmt>` prints one format for a client or target.
- `has-session -t <session>` exits with 1 if the session does not exist.

**Not starting a server.** Listing commands lack `CMD_STARTSERVER`, so they fail with "no server running" instead of starting one. Only commands such as `new-session`, `attach-session`, `start-server`, `list-keys` and `list-commands` start a server. The global `-N` flag (since 3.2) prevents a start in every case.

**Target syntax.** Pane IDs (`%N`) can be used directly as `-t` targets. The manual recommends IDs or fully qualified targets in scripts, because a bare `1` is resolved heuristically. Names accept prefix and glob matches unless prefixed with `=`.

## Matching one window, its one client, and the host tab

Facts relevant to the map's "single-pane window with exactly one attached client" layout:

- **Pane to window:** `list-panes -a -F '#{pane_id} #{pane_tty} #{window_id} #{window_panes} #{window_zoomed_flag} #{pane_floating_flag} #{session_id} #{session_attached}'` gives everything needed to check that a window has one pane and a session has N attached clients, all in one call.
- **Session to client:** `list-clients -F '#{client_tty} #{client_pid} #{session_id} #{window_id} #{pane_id} #{client_flags}'`. More than one client can be attached to the same session, and **session groups** (several sessions sharing windows) let two sessions show one window. `window_active_clients` counts every client currently viewing a window across all of them.
- **Client to host tab:** `client_tty` is the TTY of the terminal tab where the user ran `tmux attach` or `tmux new`. This is the same join ADR 0011 makes for herdr with `lsof`, except that tmux reports the TTY itself. Whether each host terminal exposes a tab's TTY is a question for the per-terminal research tickets. Because the client reports `client_tty` itself, a cross-check against the process table (`client_pid` owning that TTY) is possible but **unverified** in practice.
- **Nested tmux:** the server's `server_client_check_nested` treats a client as nested when its TTY equals some pane's TTY and `TMUX` is set. A client running inside another tmux pane has a `client_tty` that is a tmux pane TTY, not a terminal tab's TTY.
- **Control-mode clients** (`tmux -C` or `-CC`, used by iTerm2's integration, which the map lists as out of scope) are attached clients with the `control-mode` flag. They appear in `list-clients` and count toward `session_attached`.

## Selecting and verifying

From the manual:

- `select-window -t <target-window>` selects the window in **its session**. It changes the current window for every client attached to that session.
- `select-pane -t <target-pane>` makes the pane the active pane **in its window**. It has no client argument. `-Z` keeps a zoomed window zoomed. `-d` and `-e` disable and enable input to the pane. `-T` sets the pane title.
- `switch-client -c <target-client> -t <target>`: "As a special case, -t may refer to a pane (a target that contains ':', '.' or '%'), to change session, window and pane." This command needs a target client. Steer runs outside tmux with no `$TMUX`, so it has no current client and must pass `-c <client_tty>`. The manual says a target client is "typically the pty(4) file to which the client is connected".
- **Verification:** a fresh `list-clients -F '#{client_tty} #{pane_id} #{window_id}'` showing the target client on the target pane establishes what tmux is displaying to that client. tmux cannot tell whether the host terminal tab is selected or frontmost. That has to come from the host terminal.
- **Side effects:** selecting changes tmux's per-session "last window" and per-window "last pane" history, and can fire hooks the user has configured. Open Island's source records a further side effect: a redundant `switch-client` makes iTerm2's `-CC` integration re-attach and rebuild its windows (`TerminalJumpService.swift`, comment at "Step 1").

## Reporting focus (visit acknowledgment)

- **Which pane a client shows:** this is always known. It is the client's session's current window's active pane, from `list-clients` as described above.
- **Whether the user is looking at it:** the `CLIENT_FOCUSED` flag is set when the client is created (`server_client_create`) and when it changes session. It is cleared only by a focus-out event from the outer terminal (`tty-keys.c`). tmux asks the outer terminal for focus reports (`\E[?1004h`) only when the server option `focus-events` is on (`tty.c`). That option defaults to off (`options-table.c`). The terminal must also have the `focus` terminal feature. With the defaults, **every client reports `focused` permanently**, so the flag cannot distinguish a background tab from a foreground one. With `focus-events on`, the flag follows host-terminal focus, but turning it on is a user configuration change.
- **Events:** tmux has `client-focus-in` and `client-focus-out` hooks, and control-mode notifications such as `%window-pane-changed` and `%session-window-changed`. These need either a hook in user configuration or a long-lived control-mode client. Polling `list-clients` needs neither.

## Input to one pane

- `send-keys -t %P -l <text>`: "-l disables key name lookup and processes the keys as literal UTF-8 characters" (since 1.7). Without `-l`, an argument that names a key, such as `Enter` or `C-c`, is sent as that key. Open Island sends text with `-l` and then `Enter` as a separate command.
- **Delivery path** (`cmd-send-keys.c`, `window.c` `window_pane_key`):
  - If the pane is **in a mode** (copy mode, tree mode and so on), each key is looked up in the mode's key table and runs a mode command. If the key has no binding there, it does nothing. Nothing reaches the program.
  - If the pane's input is disabled (`PANE_INPUTOFF`, set by `select-pane -d`) or the pane is dead, keys are dropped silently, still with success.
  - Otherwise keys are encoded for the pane (`input_key_pane`) and written to the pane's pty. With `synchronize-panes` on, they are also copied to the window's other panes.
- **Confirmation:** the command returns success once the target resolves. A missing target is an error with exit status 1. tmux does not report whether the program read the bytes. A pre-check is possible with `#{pane_in_mode}`, `#{pane_dead}` and `#{pane_input_off}` (all in the FORMATS table), but there is still a window between the check and the send.
- `send-keys -K -c <client>` instead routes keys through a **client's** key table, as if the user typed them, including prefix bindings. It does not address a pane.

## Socket, permissions and environment

- **Location** (`tmux.c` `make_label`, `tmux.h`):
  - The search path is `TMUX_SOCK = "$TMUX_TMPDIR:" _PATH_TMP`. The first entry that resolves through `realpath` is used, so on macOS the default is `/private/tmp/tmux-<uid>/default`.
  - `-L <name>` replaces `default` with the given name in the same directory.
  - `-S <path>` is a full path and ignores `-L` and the directory.
  - With neither flag, a client inside tmux uses the path in `$TMUX`.
  - `TMUX_TMPDIR` has been honored since 1.9, and `TMPDIR` has been ignored since 2.2.
- **Permissions:**
  - tmux creates `tmux-<uid>` with `mkdir(..., S_IRWXU)`. It refuses to use the directory if it is not a directory, not owned by the current uid, or has any `o+rwx` bit (`TMUX_SOCK_PERM` = 7). Group bits are not checked.
  - The server binds a default or `-L` socket with mode `0660` and a `-S` socket with `0600` (`server.c` umasks). It then sets the socket's execute bits while any session is attached and clears them when none is (`server_update_socket`).
  - Since 3.3, the server also has an access list (`server-access`). Only the owner and root have access by default.
- **Finding non-default servers:** tmux has no registry. Servers started with `-L` sit as other names in the same directory. Servers started with `-S` can be anywhere and are found only through the server process's arguments, or through `$TMUX` in an environment Steer can read. The server process title is `tmux: server` on macOS (**unverified**).
- **Environment in panes** (`environ.c`, `spawn.c`):
  - `TMUX=<socket_path>,<server pid>,<session id number>`.
  - `TMUX_PANE=%<pane id>`.
  - Both are inherited by the pane's processes, including hooks run by the agent. They are subject to the same daemon taint ADR 0012 describes for Codex. Claude Code hooks presumably inherit them from the pane (**unverified**).

## Titles

- **Application to tmux** (`input.c`): `OSC 0` and `OSC 2` set the pane's title when the pane option `allow-set-title` is on. It is on by default, and the option exists since 3.5. Before 3.5, applications could always set the title.
  - `screen_set_title` stores the result of `clean_name(title, untrusted=1)`. That function rejects invalid UTF-8, replaces `#(` with `_(`, and escapes control characters, tabs and newlines in visible form.
  - A pane's initial title is the host name.
  - `select-pane -T` and `split-window -T` / `new-pane -T` also set the title.
  - An empty `OSC` payload sets an empty title.
- **Codex** (0.161.0 and `main`) writes `\x1b]0;<title>\x07` directly to stdout. It does not wrap the title in tmux DCS passthrough, which it does use for `OSC 9` notifications. tmux should therefore capture Codex's title, including ADR 0005's shortened session ID, as `pane_title` under default options. This follows from both sources but is **unverified live**.
- **Claude Code:** Steer's Claude setup emits `ESC ] 2 ; Steer Claude <id> BEL` through Claude's hook `terminalSequence` response (`docs/claude-setup.md`). Whether Claude writes that sequence as is to its pane TTY, or wraps it for tmux, is **unverified**. If it is wrapped in passthrough, tmux would forward it to the host terminal only with `allow-passthrough` on (default off), and `pane_title` would not change.
- **tmux to host terminal:** tmux sets the outer terminal's title only when `set-titles` is on (session option, default off), using `set-titles-string` (default `#S:#I:#W - "#T" #{session_alerts}`). With defaults, the host tab's title does not show the pane title. With `set-titles on` and the default string, the host title contains the Codex title only as a quoted substring.
- **Window names are separate:** `automatic-rename` is on by default and names the window after the active pane's current command. `allow-rename` (`\ek...\e\\`) is off by default.

## Control mode

`tmux -C` (`-CC` disables echo) starts a client that reads commands on stdin and wraps each reply in `%begin` ... `%end`/`%error`. It also emits asynchronous notifications such as `%output`, `%window-pane-changed`, `%session-window-changed`, `%client-session-changed`, `%sessions-changed` and `%subscription-changed`. `refresh-client -B` subscribes to format changes. Since 3.8, hooks can also monitor formats.

A control client is an attached client. It appears in `list-clients` with `control-mode`, counts toward `session_attached`, and receives the output of every pane in its session. Running `tmux -C` with no command creates a new session. Attaching one therefore changes the client counts that the "exactly one attached client" rule would read. Plain command invocations do not attach.

## Version and support detection

- `tmux -V` prints the binary's version string, such as `tmux 3.8`. It does not contact a server. A server started by an older binary can still be running.
- `tmux display-message -p '#{version}'` reports the **server's** version. It needs a server and a client that speaks the same protocol (`PROTOCOL_VERSION` 8 in `tmux-protocol.h`). On a mismatch the client prints `protocol version mismatch (client 8, server N)`.
- Minimum versions for the features above, from `CHANGES`:

| Feature | Since |
| --- | --- |
| `send-keys -l` | 1.7 |
| `pane_current_command` | 1.9 |
| `TMUX_TMPDIR` | 1.9 |
| `client_pid` | 2.1 |
| `client_flags` with `focused` | 3.2 |
| `-f` filters on list commands | 3.2 |
| `-N` | 3.2 |
| `server-access` | 3.3 |
| `allow-set-title` | 3.5 |
| Floating panes | 3.7 |

  `pane_id`, `pane_tty`, `client_tty`, `select-pane`, `select-window` and `switch-client -c` are older than all of these.
- Install locations Open Island probes are `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux` and `/usr/bin/tmux`. macOS does not ship tmux.

## How Open Island does it (b50f87a)

**Discovery** (`ActiveAgentProcessDiscovery.swift` `resolveTmuxInfo`):

- This runs only when the agent process has a TTY but its parent chain reaches no terminal app.
- It looks for a tmux server among processes whose command contains `tmux` and `server` or `new-session`. It takes the argument after `-S` **or `-L`** as a socket path and passes it as `-S`. A `-L` name is therefore treated as a path, which looks wrong by the manual.
- It runs `list-panes -a -F '#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}'` and takes the first row whose `pane_tty` equals the agent's TTY.
- It runs `list-clients -F '#{client_tty}'` and walks the parents of the first process on any client TTY until it finds a known terminal app. That app becomes the host.
- No pane count, client count, zoom or split check is made.

**Target refresh** (`TerminalJumpTargetResolver.swift`):

- This runs `list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}<|>#{pane_tty}<|>#{pane_title}'` without passing a socket.
- It matches sessions to panes by TTY, then by stored target, then by **substring** of the stored pane title.
- The target it keeps is the name and index form, not `%N`.

**Open** (`TerminalJumpService.swift` `jumpToTmuxPane`):

1. Run `list-clients -F '#{client_tty}\t#{client_session}'` and take the **first** client.
2. If that client's session differs from the target's session name, run `switch-client -c <tty> -t <session>`.
3. Run `select-window -t <session:window>`.
4. Run `select-pane -t <session:window.pane>`. Only this step's exit status is used.
5. Run the host terminal's own jump using the session's stored `terminalTTY`. That value is the **pane's** TTY, not the client's. For iTerm2 and Terminal.app, a TTY match against a tab is therefore not expected to hit, and it falls back to activating the app. This is inferred from source and **unverified**. The iTerm2 script calls `activate` before matching.

There is no read-back of the selected pane or of the host tab.

**Typed input** (`TerminalTextSender.swift` `sendViaTmux`):

- Any session with a tmux target can reply (`canReply`), and only after the session completed.
- It runs `send-keys -t <target> -l <text>`, then a separate `send-keys -t <target> Enter`, each a subprocess.
- Success means both exit statuses were 0. There is no pending-state check, mode check or read-back.

**Attachment** (`TerminalSessionAttachmentProbe.swift`) has no tmux-specific logic at this commit. tmux sessions go through its generic process and TTY matching.

## Open points (unverified)

- Live behavior of every command above on tmux 3.8 under macOS, in an isolated server (`-L` lab socket).
- `pane_title` for a Codex 0.161+ pane, including after Codex exits or crashes. A crash leaves the last title in place until something else sets it, by inference.
- How Claude Code's hook `terminalSequence` reaches tmux (plain or passthrough), and Claude Code's own title behavior.
- `pane_current_command` for a native Codex binary (expected `codex`), an npm-installed Codex (the group leader may be `node`), and Claude's native installer (a version-named binary, per ADR 0008's amendment). These are inferences from `tcgetpgrp` and the process-group leader's name.
- Whether `client_tty` always equals the TTY each host terminal reports for its tab, and how this behaves with `tmux attach` run through `ssh` or a login wrapper.
- `focused` flag behavior in each host terminal with `focus-events on`, if a grilling ticket considers requiring it.
