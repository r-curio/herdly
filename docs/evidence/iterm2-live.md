# iTerm2 live targeting proof

Recorded 2026-10-11 for [Prove iTerm2 targeting live](https://github.com/r-curio/steer/issues/204), the live check of [Research iTerm2's scripting surface for exact tab targeting](https://github.com/r-curio/steer/issues/198) ([findings](https://github.com/r-curio/steer/blob/docs/198-research-iterm2/docs/iterm2-scripting-investigation.md)). This is evidence for later decisions, not a decision or an implemented Steer capability. Steer itself was not running; the lab script stood in for it.

## Setup

- iTerm2 3.7.4 (Homebrew cask, fresh install, default profile), macOS 26.5 (25F71), Codex CLI 0.162.1 (it updated itself from 0.161.0 between the first and second run), Claude Code 2.1.296.
- Lab: [`scripts/terminal-lab/iterm2_lab.py`](../../scripts/terminal-lab/iterm2_lab.py) with the JXA driver [`iterm2.js`](../../scripts/terminal-lab/iterm2.js), run as `python3 -I scripts/terminal-lab/iterm2_lab.py --lab-root <checkout>/output/terminal-lab`. It creates two windows: window A with tabs A1 (Codex), A2 (Claude), A3 (a decoy carrying Codex's title over `sleep`) and A4 (split into A4a and A4b), and window B with one shell (B1). It drives everything through Apple Events from `osascript` and reads every result back.
- Codex ran read-only with approvals `never` in a disposable project. Claude ran with `--setting-sources project` in a disposable project whose only hooks are [`claude_title_hook.py`](../../scripts/terminal-lab/claude_title_hook.py), a stand-in that records the hook environment and emits SteerHook's `--terminal-title` sequence (`OSC 2 Steer Claude <session id>`) with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`, as Steer's Claude setup does. Nothing under `~/.codex` or `~/.claude` was written.
- Sanitized output of the third full run: [`iterm2-live.json`](iterm2-live.json). TUI screen text, which carried account and branch details, is omitted.

## Results

| Check | Observed |
| --- | --- |
| Pane identity | Each session's AppleScript `id` is a GUID equal to the part after `:` in the shell's `ITERM_SESSION_ID` (`w0t1p0:2EDA6BF5-…` for A2). The `termid` variable has the same value with `.` instead of `:`. Each session has its own `/dev/ttysNNN`. Tabs have no id; splits show as `count of sessions` = 2 (A4). |
| Codex title | Codex wrote its title as OSC 0: `terminalWindowName` and `terminalIconName` were both `01a12976-3c08-7733-990a-4d8a5...`, the first 29 characters of the session's rollout id `01a12976-3c08-7733-990a-4d8a574a90dc` plus `...` (ADR 0005's format). The tab name was the composite `<title> (<job>)`. It appeared 10–22 s after launch in every run. |
| Claude title | The hook's OSC 2 title `Steer Claude 1013bfc3-…` appeared only in `terminalWindowName`; `terminalIconName` stayed empty and the session `name` did not contain it. The id equals the hook payload's `session_id`. |
| Duplicate titles | A3 printed Codex's exact title over `sleep`: its `terminalWindowName` and `terminalIconName` were identical to A1's. A title alone does not identify the Codex tab. |
| Claude hook environment | Claude's hooks saw `ITERM_SESSION_ID`/`TERM_SESSION_ID` naming the A2 pane, `TERM_PROGRAM=iTerm.app`, `TERM_PROGRAM_VERSION=3.7.4`, and `claude` on the A2 tty as an ancestor. Codex hooks were not exercised (ADR 0012 already covers the daemon case). |
| Foreground job | iTerm2's `jobName`, `deepestJob` and `processTitle` read `login` for every lab tab that had never been displayed, both at 30 s and again 10 s later. They became correct only after the select checks had shown each tab: `codex`; `2.1.296` for Claude (the version-named binary; `processTitle` was `claude`); `sleep`. In the first run, jobName was already correct. `ps -o stat,comm -t <tty>` (the `+` foreground group) was correct every time: `login`, `codex` / `login`, `claude` (sometimes plus `caffeinate`) / `login`, `sleep`. |
| Select (full sequence) | `select` window, `select` tab, `select` session, then `activate`, followed by reading back `frontmost` and `current session of current tab of current window`, matched in 9 of 9 attempts across three runs, within 0.4–0.6 s. The attempts covered a background window with Finder in front, the other window, and a split pane. `lsappinfo front` agreed (`com.googlecode.iterm2`). |
| Select (partial) | `select` session alone, or tab then session, without selecting the window: it never moved to a tab in another window (0 of 6). In the same window it matched in run 2 and not in run 3. Only the full sequence is reliable. |
| Focus report | With Finder in front, iTerm2 reported `frontmost = false` but kept a `current window`/`current session` (the last-selected split pane). A focus answer needs both. |
| `write text` to a shell | `write text "echo PROBE-…"` to A4a appeared only in A4a. With `newline NO` to B1, the text was typed but not run, and a later `write text ""` ran it. A probe search across every iTerm2 session's `contents` found each probe only in its target: none in the other lab sessions, and none in sessions the run had not created. |
| `write text` to a TUI | Claude submitted a prompt sent as one `write text` (text + CR). Codex did not: in all three runs the text stayed in its composer. A separate `write text ""` (a lone CR) 1 s later submitted it. |
| Missing target | After a session was closed, addressing its GUID failed with "session not found". This was the lab driver's own lookup, which walks every session; iTerm2's behavior for a stale object specifier was not separately tested. |

## Lab hazards found

- **Inherited environment.** `open -a iTerm` from an agent session passed that session's environment to iTerm2, so every shell it started inherited `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_MESSAGING_SOCKET`/`_TOKEN` and similar. Results from the first run are not used here. iTerm2 was stopped and relaunched with `env -i HOME USER LOGNAME PATH /usr/bin/open -a iTerm`, and the lab now refuses to run if a lab shell sees `CLAUDE*`/`CODEX*` variables. Steer launching or activating a terminal must not hand down its own environment either.
- **Teardown.** `pkill -t ttysNNN` matches nothing on macOS, so teardown kills each tty's processes by PID. Killing a session's processes left tabs that AppleScript reported with no sessions and that window `close` did not remove. Quitting through AppleScript returned "User cancelled" (-128). iTerm2 was stopped with SIGTERM after the runs. Its session server kept two idle shells alive until they were killed.

## Not shown

- Broadcast Input (no AppleScript switch exists to set it up), the Python API, Automation consent attributed to Steer rather than `osascript`, a minimized or full-screen window, another Space, a hotkey window, session restoration across a relaunch, and tmux `-CC`.
- Whether a lone CR after a short delay reliably submits in Codex under load, and how embedded newlines in typed text are received.
- Any Steer code path: no Steer binding, Open, or relay was run.
