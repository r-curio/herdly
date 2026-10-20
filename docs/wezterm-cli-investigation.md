# WezTerm CLI: exact pane targeting (#200)

Checked 2026-10-11 for [Research WezTerm's CLI for exact pane targeting](https://github.com/r-curio/herdly/issues/200), a child of [Support iTerm2, Terminal.app, WezTerm and multiplexers](https://github.com/r-curio/herdly/issues/197). This note records facts only. Choices about binding, Open, acknowledgment and input belong to the decision tickets.

No WezTerm is installed on the research machine. Nothing here was run against a live WezTerm. Every claim comes from WezTerm's source and its official docs, unless it is marked **inference** or **unverified**.

## Versions and sources

| Item | Value | Source |
| --- | --- | --- |
| Latest stable release | `20240203-110809-5046fc22` (2024-02-03). There has been no newer stable release. | `gh release list -R wezterm/wezterm`; Homebrew cask `wezterm` reports `20240203-110809,5046fc22` |
| Nightly | The `nightly` pre-release; its macOS zip was rebuilt 2026-10-11. Homebrew cask `wezterm@nightly` tracks it. | `gh api repos/wezterm/wezterm/releases/tags/nightly` |
| Source read | `main` at [`e2a98e1b`](https://github.com/wezterm/wezterm/tree/e2a98e1b8af156988ad0ac778658ac27b60a55fb) (2026-10-10), compared with tag `20240203-110809-5046fc22` | shallow clone of `github.com/wezterm/wezterm` |
| Official docs | [wezterm.org/cli/cli](https://wezterm.org/cli/cli/index.html) (generated from `docs/` in the same repository) | |
| Open Island | [`b50f87a`](https://github.com/Octane0411/open-vibe-island/tree/b50f87aa7d58af1478837d48909eb68baa37f9b9) (2026-09-15) | local clone |

Between the stable tag and `main`, the only changes under `wezterm/src/cli/` are to `list-clients` (it gained `ssh_auth_sock`) and `proxy`. `list`, `activate-pane`, `activate-tab` and `send-text` are identical. The mux wire protocol version (`CODEC_VERSION`) is 42 at the stable tag and 46 on `main`.

Below, "source" links point to `main` at `e2a98e1b`.

## Answer in brief

1. **Identifiers.** `wezterm cli list --format json` returns one object per pane with integer `window_id`, `tab_id` and `pane_id`, plus `title`, `cwd`, `tty_name`, `is_active`, `is_zoomed`, `workspace`, `tab_title`, `window_title`, size and cursor fields. IDs are scoped to one WezTerm mux, normally one GUI process.
2. **TTY: yes. Foreground process: not from the CLI.** `tty_name` is the pane's pty device path, available since `20230408-112425-69ae8472`. The CLI has no foreground-process field. The pane `title` falls back to the foreground process's basename only while the title is the literal default `wezterm`.
3. **Titles.** The pane `title` is the terminal's OSC title. If an OSC 1 icon title is set, it is used instead. Codex writes OSC 0, which clears the icon title, so Codex's session-ID title should appear as `title`. Herdly's Claude title hook writes OSC 2, which leaves an earlier icon title in place, so a shell that sets OSC 1 (oh-my-zsh does) would hide it. Both points are **inferred from source and unverified live**.
4. **Selecting.** `wezterm cli activate-pane --pane-id N` sets that pane's tab active in its window and makes the pane the tab's active pane. Neither it nor any other `wezterm cli` subcommand raises a GUI window or activates the app. Raising has to happen separately through macOS. With several WezTerm windows, the CLI cannot choose which OS window comes to the front.
5. **Focus.** `wezterm cli list-clients --format json` reports `focused_pane_id` for each connected client, including the GUI itself. The GUI updates it only while painting an OS-focused window, and the value is not cleared when WezTerm loses focus. It does not say whether WezTerm is frontmost.
6. **Input.** `wezterm cli send-text --pane-id N [--no-paste] TEXT` writes to exactly that pane. Without `--no-paste` the text is sent as a paste, wrapped in bracketed-paste markers when the pane has enabled them. With `--no-paste` it writes raw bytes. Success means the bytes were written to the pty master and nothing more. An unknown pane ID fails with "no such pane".
7. **Trust and configuration.** The GUI serves the mux protocol on `~/.local/share/wezterm/gui-sock-<pid>` and publishes a symlink `~/.local/share/wezterm/default-org.wezfurlong.wezterm` pointing at it. The server has no authentication and no peer-credential check. Protection relies on directory and socket permissions. The CLI needs no WezTerm configuration change and no macOS Automation permission.
8. **Splits.** A tab is split when more than one `list` entry shares its `tab_id`. Zoomed tabs still list every pane, and `is_zoomed` marks the zoomed one.
9. **Version.** `wezterm --version` prints the build tag. The app bundle's `Info.plist` version is a static `0.1.0`, so it is not usable. Panes spawned by WezTerm carry `TERM_PROGRAM=WezTerm` and `TERM_PROGRAM_VERSION=<tag>`.
10. **Open Island** activates by pane ID, then `tty_name`, then cwd, then a title substring, and calls `open -b` afterward. It never verifies the result and does not send text to WezTerm.

## `wezterm cli list`

Source: [`wezterm/src/cli/list.rs`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm/src/cli/list.rs#L119). Docs: [list](https://wezterm.org/cli/cli/list.html). The struct is commented as "intended to be a stable output format".

The JSON output is a flat array with one object per pane, in pre-order of each tab's split tree. Fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `window_id`, `tab_id`, `pane_id` | integer | Mux IDs. They are allocated per process and not reused within it (**inference** from the counters in `mux`). They are not stable across WezTerm restarts. |
| `workspace` | string | Workspace of the window. |
| `size` | `{rows, cols, pixel_width, pixel_height, dpi}` | Pane size. |
| `title` | string | Pane title (see [Titles](#titles)). |
| `cwd` | string | A `file://host/path` URL from OSC 7, or `""`. Open Island strips the scheme. |
| `cursor_x`, `cursor_y`, `cursor_shape`, `cursor_visibility` | | Cursor state. |
| `left_col`, `top_row` | integer | Pane offset inside the tab. Both are 0 for an unsplit tab. |
| `tab_title` | string | The tab's explicit title (`set-tab-title` or Lua), otherwise `""`. |
| `window_title` | string | The mux window's title. |
| `is_active` | bool | This pane is its **tab's** active pane. It does not mean the tab is selected or the window is focused. |
| `is_zoomed` | bool | This pane is zoomed in its tab. |
| `tty_name` | string or null | The pty slave path from `ttyname_r`, for example `/dev/ttys012`. It is null where the pane is not a local pty. |

`tty_name`, `is_active` and `is_zoomed` arrived in commits `0ca050e0` and `96f1585b` (2023-04-05/06). Both are contained in `20230408-112425-69ae8472` and every later release.

The server answers `ListPanes` by walking every mux window and every tab ([`sessionhandler.rs` L397](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-mux-server-impl/src/sessionhandler.rs#L397)). The output therefore includes windows in workspaces the GUI is not currently showing. Whether `activate-pane` on a pane in an inactive workspace switches the GUI's workspace is **unverified**. The handlers read show no workspace switch.

The output has no field for which tab is selected in its window. `activate-tab` reads `is_active` only to choose a tab's pane, not to find the selected tab.

## Titles

- The pane title comes from `LocalPane::get_title` ([`mux/src/localpane.rs` L449](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/mux/src/localpane.rs#L449)). That returns the terminal's title. When the title is exactly `wezterm` (the default), it returns the basename of the foreground process instead.
- The terminal title is `icon_title` if one is set, otherwise `title` ([`term/src/terminalstate/mod.rs` L655](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/term/src/terminalstate/mod.rs#L655)). OSC 1 sets `icon_title`. OSC 0 clears `icon_title` and sets `title`. OSC 2 sets only `title` ([`performer.rs` L740–771](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/term/src/terminalstate/performer.rs#L740)).
- **Codex CLI:** `codex-rs/tui/src/terminal_title.rs` writes `ESC ] 0 ; title BEL`, which is OSC 0 (openai/codex `main` at `cc7ba336`, 2026-10-10). Under `tui.terminal_title = ["session-id"]` (ADR 0005), `title` should therefore show the shortened session ID even if the shell set an icon title earlier. **Inference; unverified live and unchecked against the installed Codex version.**
- **Claude Code:** Herdly's `SessionStart` hook sets `ESC ] 2 ; Herdly Claude <id> BEL`, which is OSC 2 ([claude-setup](claude-setup.md), [live evidence](evidence/claude-setup-live.md)). oh-my-zsh's `title` function sends both OSC 2 and OSC 1 when `TERM` matches `xterm*` ([`lib/termsupport.zsh`](https://github.com/ohmyzsh/ohmyzsh/blob/42a4ccb1b14dbeffe81259105a5243b4f4cb618e/lib/termsupport.zsh)), and WezTerm's default `TERM` is `xterm-256color`. Under such a shell, `wezterm cli list` would likely report the shell's icon title (for example the command line) instead of `Herdly Claude <id>`. **Inference; unverified live.**
- The hook environment of a Claude session started in WezTerm carries `WEZTERM_PANE` (see [Environment](#environment-variables)). This gives a pane ID without relying on a title. Under Codex's shared daemon, the same variable is tainted in the way ADR 0012 describes for `HERDR_PANE_ID`.

## Foreground process and TTY

- The CLI exposes no foreground process or PID. Lua has `pane:get_foreground_process_name()` and `get_foreground_process_info()`, which use the pty's process-group leader via `tcgetpgrp` ([docs](https://wezterm.org/config/lua/pane/get_foreground_process_info.html)). Lua is reachable only through the user's `wezterm.lua`, which Herdly does not edit.
- `tty_name` lets a caller read the foreground process from outside WezTerm with standard tools (for example `ps -t <tty> -o pid,pgid,tpgid,comm`). This is the same kind of join ADR 0011 uses with `lsof`. **Not tried here.**

## Selecting a pane or tab

Source: [`activate_pane.rs`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm/src/cli/activate_pane.rs), [`activate_tab.rs`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm/src/cli/activate_tab.rs), server [`SetFocusedPane` handler](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-mux-server-impl/src/sessionhandler.rs#L339). Both commands exist since `20230326-111934-3666303c`.

- `activate-pane --pane-id N` sends `SetFocusedPane{N}`. The server looks up the pane, window and tab, sets the window's active tab, sets the tab's active pane, and notifies `PaneFocused`. The GUI frontend repeats the same tab and pane activation on its side ([`frontend.rs` L80](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-gui/src/frontend.rs#L80), [`Mux::focus_pane_and_containing_tab`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/mux/src/lib.rs#L545)). A missing pane returns an error, and the CLI exits non-zero.
- `activate-tab --tab-id T` also ends in `SetFocusedPane` for that tab's current active pane. `--tab-index` and `--tab-relative` resolve relative to the "current" pane, which comes from `WEZTERM_PANE` or the most recent client.
- **No window raise.** None of these paths call the OS window's `focus()`. Only key-assignment actions such as `ActivateWindow` and the Lua `window:focus()` call it ([`termwindow/mod.rs` L2139](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-gui/src/termwindow/mod.rs#L2139), [docs](https://wezterm.org/config/lua/window/focus.html)). The CLI has no window-focus subcommand. Bringing WezTerm forward therefore takes a separate macOS activation, such as Open Island's `open -b com.github.wez.wezterm` or `NSRunningApplication.activate`. Which WezTerm window macOS brings forward then is up to macOS. When the target tab is in a non-key window, that window may not come to the front. **Unverified live.**
- WezTerm has no AppleScript dictionary. Its `Info.plist` has no `OSAScriptingDefinition`, only an `NSAppleEventsUsageDescription` for programs launched inside it ([`assets/macos/WezTerm.app/Contents/Info.plist`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/assets/macos/WezTerm.app/Contents/Info.plist)). So Automation cannot pick a window either.
- **Omitting `--pane-id` is unsafe.** Every pane-addressed subcommand that is not given `--pane-id` uses `WEZTERM_PANE` from the caller's environment. Without that variable, it uses the focused pane of the client with the most recent input ([`client.rs` L1314](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-client/src/client.rs#L1314)).

## Reporting focus (for visit acknowledgment)

Source: [`list_clients.rs`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm/src/cli/list_clients.rs#L122). Docs: [list-clients](https://wezterm.org/cli/cli/list-clients.html).

- JSON fields: `username`, `hostname`, `pid`, `connection_elapsed`, `idle_time` (both `{secs, nanos}`), `workspace`, `focused_pane_id` (integer or null). `main` also has `ssh_auth_sock`, which is not in `20240203`.
- The GUI registers itself as a client ([`wezterm-gui/src/main.rs` `setup_mux`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-gui/src/main.rs#L676)), so its `pid` is the `wezterm-gui` process. It records focus during paint, only when `self.focused` is set, meaning the OS window has focus ([`render/paint.rs` L252–258](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-gui/src/termwindow/render/paint.rs#L252)). Nothing clears it when the window loses focus.
- **Consequences, inferred from source:** a changed `focused_pane_id` for the GUI client means that pane was painted as active in a focused WezTerm window after the previous reading. An unchanged value says nothing about whether WezTerm is still frontmost, which needs a separate macOS frontmost-app check. The CLI does not send `SetClientId` (only `verify_version_compat` does, and the CLI path never calls it), so short-lived `wezterm cli` invocations should not appear as clients and should not change `focused_pane_id`. **Unverified live.**
- Because the GUI reports `focused_pane_id` for its own client, it does not reflect panes selected from another GUI process or another mux.

## Sending input

Source: [`send_text.rs`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm/src/cli/send_text.rs), server [`WriteToPane`/`SendPaste`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-mux-server-impl/src/sessionhandler.rs#L443). Docs: [send-text](https://wezterm.org/cli/cli/send-text.html). `--no-paste` exists since `20220624-141144-bd1b7c5d`.

- The target is exactly `--pane-id`. Text comes from the argument, or from stdin if no argument is given.
- **Default (paste):** `Terminal::send_paste` ([`terminalstate/mod.rs` L943](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/term/src/terminalstate/mod.rs#L943)) wraps the text in `ESC[200~ … ESC[201~` when the pane's application has enabled bracketed paste, and strips any embedded paste markers. Without bracketed paste, newlines are canonicalized per `canonicalize_pasted_newlines`. **Inference:** inside a TUI that enables bracketed paste, a newline in pasted text is pasted and does not submit. A separate `--no-paste` carriage return would be needed to submit. Whether Codex's and Claude's TUIs enable bracketed paste in WezTerm is **unverified**.
- **`--no-paste`:** the raw bytes go to the pane's pty writer (`pane.writer().write_all`).
- **Confirmation:** the server replies `UnitResponse` after the bytes are written to the pty master, and the CLI exits 0. That shows delivery to the pty, not that the application read, accepted or acted on the input. An unknown pane ID returns `no such pane N`, and the CLI exits non-zero.
- A pane belonging to a tmux control-mode domain silently drops pastes and still returns success (`LocalPane::send_paste`). That case is out of scope for the map.
- `send-text` does not focus or raise anything.

## Socket location, discovery and trust

- **GUI socket:** each GUI process listens on `RUNTIME_DIR/gui-sock-<pid>` and exports `WEZTERM_UNIX_SOCKET` with that path to its children ([`wezterm-gui/src/main.rs` L413–415](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-gui/src/main.rs#L413)). On macOS, `RUNTIME_DIR` is `~/.local/share/wezterm`. `compute_runtime_dir` uses `dirs_next::runtime_dir()`, which returns `None` on macOS for dirs-next 2.0.0, and then falls back to `HOME/.local/share/wezterm` ([`config/src/config.rs` L1775](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/config/src/config.rs#L1775)). The macOS behavior of dirs-next comes from that crate and was **not checked live**.
- **Published name:** a GUI that should publish creates the symlink `RUNTIME_DIR/default-<class>`, with `org.wezfurlong.wezterm` as the default class, pointing to its socket ([`discovery.rs` L272](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-client/src/discovery.rs#L272)). The code comments that the link carries "NO guarantee that the returned path references a running instance". A GUI started with `--always-new-process`, with an overriding config file, or for an SSH or serial domain does not publish. `discover_gui_socks()` lists every live `gui-sock-*`.
- **CLI resolution order** ([`client.rs` L1222](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-client/src/client.rs#L1222)):
  1. a non-empty `WEZTERM_UNIX_SOCKET`;
  2. otherwise, unless `--prefer-mux` is given, the published GUI symlink for `--class`, or the default class;
  3. otherwise the first `unix_domains` entry from configuration, whose default socket is `RUNTIME_DIR/sock`.

  The [docs](https://wezterm.org/cli/cli/index.html) list `--prefer-mux` before the environment variable, but the code checks `WEZTERM_UNIX_SOCKET` first.
- **Auto-start:** when step 3 cannot connect, the CLI spawns `wezterm-mux-server --daemonize` unless `--no-auto-start` is passed ([`client.rs` `unix_connect`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-client/src/client.rs#L731)). The GUI-socket route sets `no_serve_automatically` and never spawns. A caller that does not want a background server started passes `--no-auto-start`.
- **Permissions:** the listener creates its directory with mode `0700` (`create_user_owned_dirs`). It refuses to listen if the directory is group- or other-writable (mode `& 0o22`), unless `skip_permissions_check` is set for a configured unix domain. It removes any stale file, binds, and sets the sticky bit on the socket ([`local.rs` L45](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-mux-server-impl/src/local.rs#L45)). The socket's own mode depends on the process umask. **Unverified live.**
- **No authentication:** the server performs no peer-credential check, no token check and no handshake before it serves requests. No `getpeereid` or `SO_PEERCRED` appears anywhere in the tree. Any process that can connect can list panes, send text and spawn commands. Codec-version agreement is checked only by the GUI's own client domains (`verify_version_compat`), not by `wezterm cli`.
- **Version skew:** the CLI talks the codec of its own build (42 for `20240203`, 46 on `main`). A CLI from a different build than the running GUI may fail to decode replies. **Unverified.** Open Island's bundle-path preference (below) sidesteps most of this.
- **Configuration:** `wezterm cli list`, `list-clients`, `activate-pane`, `activate-tab` and `send-text` do not call `init_config` (`wezterm/src/main.rs`). Only `spawn` and `proxy` load `wezterm.lua`. In step 3, the CLI reads `configuration()` for `unix_domains`. Whether that evaluates the user's Lua file without `common_init` is **unverified**. `wezterm -n` (`--skip-config`) is available.
- **macOS permissions:** none. The CLI is a Unix-socket client, so it needs no Apple Events or Automation consent. A separate app activation through `NSRunningApplication` needs none either.

## Environment variables

- `WEZTERM_PANE=<pane_id>` is set on every command a local domain spawns in a pane. `WEZTERM_UNIX_SOCKET` is passed through as well ([`mux/src/domain.rs` L479–482](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/mux/src/domain.rs#L479)). Processes inside a pane, including hook helpers, inherit both unless something clears them.
- `TERM_PROGRAM=WezTerm` and `TERM_PROGRAM_VERSION=<build tag>` are set on panes ([`config/src/config.rs` L1621](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/config/src/config.rs#L1621)).
- For Codex under the shared app-server daemon, these values describe whichever pane started the daemon (ADR 0012). For Claude Code hooks they describe the hook's own pane, but that is **unverified live**.

## Detecting splits

- One `list` entry per pane: a tab is unsplit exactly when one entry has its `tab_id`. The pane tree is walked in full even while a pane is zoomed, because `codec_pane_tree` iterates the tree, not the visible panes. `is_zoomed` marks the zoomed pane.
- `left_col` and `top_row` are both 0 for an unsplit tab's only pane. That alone does not prove the tab is unsplit, because the first pane of a split also sits at 0,0.

## Detecting support and version

- **Executable:** the bundle ships `Contents/MacOS/wezterm` (CLI), `wezterm-gui`, `wezterm-mux-server` and `strip-ansi-escapes` ([`ci/deploy.sh`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/ci/deploy.sh)). The bundle identifier is `com.github.wez.wezterm`.
- **Version:** `wezterm --version` prints `wezterm <tag>`, for example `wezterm 20240203-110809-5046fc22`. The tag comes from `.tag` or `git show --format=%cd-%h` at build time ([`wezterm-version/build.rs`](https://github.com/wezterm/wezterm/blob/e2a98e1b8af156988ad0ac778658ac27b60a55fb/wezterm-version/build.rs)). The command does not contact the GUI. The tag is a date-commit string, not semver. `CFBundleShortVersionString` in the source `Info.plist` is the constant `0.1.0`, and `deploy.sh` does not rewrite it, so the bundle version cannot identify a build. **Unverified on a released bundle.**
- **Features this research depends on:** `list --format json` with `tty_name`, `is_active` and `is_zoomed` since `20230408-112425-69ae8472`; `activate-pane` and `activate-tab` since `20230326-111934-3666303c`; `send-text --no-paste` and JSON `list-clients` since `20220624-141144-bd1b7c5d`. The stable `20240203` has all of them.
- **Probing alternative:** call `wezterm cli list --format json` and check the keys. This needs a running GUI and is read-only. Its exit status is non-zero when no instance is reachable.
- **Running instance:** match `NSRunningApplication` for `com.github.wez.wezterm` to the `<pid>` in `gui-sock-<pid>`. This is an option, not tested.

## Open Island (b50f87a)

Files: `Sources/OpenIslandApp/TerminalJumpService.swift` (L984–1147), `TerminalJumpTargetResolver.swift` (L469–676), `TerminalSessionAttachmentProbe.swift` (L157), `TerminalTextSender.swift`, and `Sources/OpenIslandCore/{Claude,Codex}Hooks.swift`. WezTerm and Kaku are handled as one "WezTerm family". Kaku (`fun.tw93.kaku`, CLI `kaku`) is a WezTerm-based macOS terminal ([tw93/Kaku](https://github.com/tw93/Kaku)). Its CLI compatibility was not checked here.

- **Detection:** hooks map `TERM_PROGRAM=WezTerm` to the terminal app "WezTerm". They record the hook's tty (from `/usr/bin/tty`, falling back to the parent process's tty from `ps`) and the cwd. They do **not** read `WEZTERM_PANE`, and WezTerm is on the list of apps the focused-terminal locator skips.
- **CLI path:** `/Applications/WezTerm.app/Contents/MacOS/wezterm`, then `~/Applications/...`, then `which wezterm` (a `PATH` lookup).
- **Resolver (background):** while the app is running, it runs `wezterm cli list --format json` with a 3-second timeout and decodes `pane_id`, `title`, `cwd` and `tty_name`. It assigns sessions to panes in passes: stored pane ID, then exact `tty_name`, then normalized cwd, then title **substring**. It then writes the pane ID, tty, cwd and title back into the session's jump target. No uniqueness checks are made, so the first match wins in each pass.
- **Jump:** it re-runs `list` (no timeout on this path), then calls `activate-pane --pane-id` for the first pane that matches by pane ID, then `tty_name`, then cwd, then title substring. On exit status 0 it runs `open -b <bundle id>` and reports "Focused the matching WezTerm pane." It does not check that the pane is selected, which window is in front, or whether WezTerm is frontmost. When nothing matches or the CLI fails, the generic path activates the app.
- **tmux in WezTerm:** after selecting the tmux pane, the WezTerm case falls through to `open -b`. No WezTerm tab is selected.
- **Text input:** `TerminalTextSender` supports only tmux `send-keys` and Ghostty AppleScript. `canReply` returns false for WezTerm, so Open Island never calls `send-text`.
- **Attachment probe:** WezTerm sessions are excluded from the "ambiguous" set that the Ghostty, Terminal and iTerm probes inspect. Liveness for WezTerm comes from the resolver and process discovery only.
- **Socket trust:** none of its own. It relies on the CLI's default resolution, including `WEZTERM_UNIX_SOCKET` inherited from Open Island's environment, and passes neither `--no-auto-start` nor `--class`.

## Unverified and open

- Nothing was run against a live WezTerm. That includes JSON shapes, `tty_name` values, and the socket and directory modes on macOS.
- Whether a Codex TUI's OSC 0 title shows as `title` in `wezterm cli list` for the installed Codex version, and whether Herdly's OSC 2 Claude title is hidden by a shell icon title.
- Which OS window comes forward when WezTerm is activated while the target tab is in a non-key window, and whether `activate-pane` into an inactive workspace switches the GUI's workspace.
- Whether `focused_pane_id` of the GUI client updates promptly enough after an Open to serve as verification, and whether short-lived CLI connections ever appear in `list-clients`.
- Behavior when the CLI and GUI builds differ (codec 42 vs 46).
- Whether `configuration()` in the CLI's fallback path evaluates `wezterm.lua`.
- Bracketed-paste state of Codex and Claude TUIs in WezTerm, and the bytes needed to submit after a paste.
- `WEZTERM_PANE` as seen by a Claude Code hook, and as seen by the shared Codex daemon.
- Kaku's CLI parity with WezTerm.
