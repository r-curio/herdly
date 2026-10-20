# Terminal.app live targeting proof

Recorded 2026-10-11 for [Prove Terminal.app targeting live](https://github.com/r-curio/herdly/issues/205), the live check of [Research Terminal.app's scripting surface for exact tab targeting](https://github.com/r-curio/herdly/issues/199) ([findings](https://github.com/r-curio/herdly/blob/docs/199-research-terminal-app/docs/terminal-app-scripting-investigation.md)). This is evidence for later decisions, not a decision or an implemented Steer capability. Steer itself was not running; the lab script stood in for it.

## Setup

- Terminal 2.15 (build 470.2), macOS 26.5 (25F71), Codex CLI 0.162.1, Claude Code 2.1.296. Terminal was launched with a clean environment (`env -i … /usr/bin/open -a Terminal`), and the lab confirmed that no lab shell saw `CLAUDE*`/`CODEX*` variables.
- Lab: [`scripts/terminal-lab/terminal_lab.py`](../../scripts/terminal-lab/terminal_lab.py) with the JXA driver [`terminal.js`](../../scripts/terminal-lab/terminal.js) and the window-server helper [`onscreen_windows.swift`](../../scripts/terminal-lab/onscreen_windows.swift). Codex and Claude isolation was the same as the [iTerm2 proof](iterm2-live.md), including the [`claude_title_hook.py`](../../scripts/terminal-lab/claude_title_hook.py) stand-in for SteerHook's OSC 2 title.
- Tabs: Terminal's dictionary cannot create a tab (`make new tab` → "AppleEvent handler failed"), and System Events needs Accessibility, which was not granted. The user pressed ⌘T twice in a lab window, and the lab adopted that three-tab group (`--adopt-window`) as T1 (Codex), T2 (Claude) and T3 (decoy with Codex's title over `sleep`). B1 is a shell in a separate window. Terminal was on a different Space from the user's other windows.
- A supplemental check, [`terminal_codex_submit.py`](../../scripts/terminal-lab/terminal_codex_submit.py), retried Codex's submit in a standalone window.
- Sanitized output: [`terminal-app-live.json`](terminal-app-live.json).

## Results

| Check | Observed |
| --- | --- |
| Tabs are windows | Each tab in the ⌘T group was its own scripting `window` with one `tab`, a distinct window `id` and identical `bounds`. Every tab reported `selected = true`, so `selected` does not say which tab of a group is showing. The window `id`s equal the window server's CGWindowIDs. Two earlier ⌘T attempts produced separate windows, not tabs, while Terminal was running with a launch argument (`-AppleWindowTabbingMode always`) left over from a lab experiment. |
| Identity | One tty per tab. Claude's hooks saw `TERM_PROGRAM=Apple_Terminal`, `TERM_PROGRAM_VERSION=470.2` and a per-tab `TERM_SESSION_ID` UUID. That UUID is not readable through Terminal's scripting dictionary. `claude` was on T2's tty as an ancestor. |
| Codex title | Codex's OSC 0 title `01a129b8-e8dd-7821-babb-cdc0e...` (the first 29 characters of rollout id `01a129b8-e8dd-7821-babb-cdc0efb2cef6` plus `...`) appeared exactly in the tab's `custom title`, and inside the window `name` (`<user> — <title> — <command> — 120×30`). It did so whether or not the tab was the one showing. |
| Claude title | Steer's OSC 2 title `Steer Claude 12e2faa8-…` appeared exactly in `custom title` and in the window `name`, for showing and background tabs alike. A plain shell's `custom title` was the default `Terminal`. |
| Duplicate titles | T3's `custom title` became Codex's exact title over `sleep`. A title alone does not identify the Codex tab. |
| Foreground process | `processes` listed the tab's whole process tree: `login, codex`, `login, claude, caffeinate`, plus Claude's `git` plugin-fetch children during one read. `ps -t <tty>` (the `+` foreground group) agreed. `busy` was true for Claude and `sleep` and false for Codex while it was idle. |
| Select | `selected = true` on a tab did nothing (0 of 1). Setting the tab-window's `frontmost = true` or `index = 1` switched the group to that tab, with or without `activate`, in 0.3–0.37 s (6 of 6). Coming from Finder, `activate` brought Terminal's Space and the target to the front. Each match was verified three ways: front window = target, `frontmost`, and the window server listing the target's window on screen with no other group member on screen. |
| Focus report | With Finder in front, Terminal reported `frontmost = false`. Its front window stayed the last-selected tab, and that tab was still listed on screen (the Space did not change). |
| `do script` to a shell | `do script "echo PROBE-…" in <B1>` appeared only in B1, and in no other tab. It did not bring Terminal to the front: Finder stayed frontmost. |
| `do script` to a TUI | Claude submitted text sent with one `do script` (text + newline). Codex showed the text in its composer but did not submit. In the supplemental check, a separate `do script ""` submitted it. |
| Stale target | After the target tab's window was closed, `do script … in <held tab reference>` failed with "Can't get object". No new window or tab appeared, and the `printf` probe file was not written. The research's suspected fallback to running the text in a new window did not happen in this case. |

## Not shown

- `TERM_SESSION_ID` as an identifier Steer could read from outside the hook.
- Profiles with title options changed, minimized or full-screen windows, a tab group spread across displays, and Spaces behavior beyond one Space switch.
- `do script` against a tab reference held across a Terminal relaunch, or one that resolves to `missing value` in another way.
- Embedded newlines, control characters, and Automation consent attributed to Steer rather than `osascript`.
- Any Steer code path.
