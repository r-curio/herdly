# WezTerm live targeting proof

Recorded 2026-10-11 for [Prove WezTerm targeting live](https://github.com/r-curio/herdly/issues/206), the live check of [Research WezTerm's CLI for exact pane targeting](https://github.com/r-curio/herdly/issues/200) ([findings](https://github.com/r-curio/herdly/blob/docs/200-research-wezterm/docs/wezterm-cli-investigation.md)). This is evidence for later decisions, not a decision or an implemented Steer capability. Steer itself was not running; the lab scripts stood in for it.

## Setup

- WezTerm `20240203-110809-5046fc22` (Homebrew cask, latest stable, default configuration, no `wezterm.lua`), macOS 26.5 (25F71), Codex CLI 0.162.1, Claude Code 2.1.296. WezTerm was launched with a clean environment, and every `wezterm cli --no-auto-start` call ran with a minimal environment. No lab shell saw `CLAUDE*`/`CODEX*` variables.
- Main lab: [`scripts/terminal-lab/wezterm_lab.py`](../../scripts/terminal-lab/wezterm_lab.py). It covers window A with tabs A1 (Codex), A2 (Claude), A3 (decoy with Codex's title over `sleep`) and A4 (split into A4a and A4b), and window B with a shell (B1). Codex and Claude isolation was the same as the [iTerm2 proof](iterm2-live.md).
- Select probe: [`scripts/terminal-lab/wezterm_select_probe.py`](../../scripts/terminal-lab/wezterm_select_probe.py). Panes get unique OSC 2 titles, and the front WezTerm window's title is read from the window server ([`onscreen_windows.swift`](../../scripts/terminal-lab/onscreen_windows.swift)). That read relies on this host's Screen Recording permission and is a lab-only check, not a Steer route. It ran once with two windows and once with a single window.
- Sanitized output: [`wezterm-live.json`](wezterm-live.json).

## Results

| Check | Observed |
| --- | --- |
| Pane identity | `wezterm cli list --format json` gave integer `window_id`, `tab_id` and `pane_id`, plus `tty_name` (one tty per pane), `title`, `cwd` (`file://` URL), `is_active` and `is_zoomed` per pane. A split shows as two panes sharing a `tab_id`. Each shell's `WEZTERM_PANE` equalled its `pane_id`. Claude's hooks saw `WEZTERM_PANE`, `WEZTERM_UNIX_SOCKET` (the GUI socket), `TERM_PROGRAM=WezTerm` and the version. |
| Codex title | Codex's OSC 0 title `01a129bd-a3ec-7dc0-875a-4fac3...` (the first 29 characters of rollout id `01a129bd-a3ec-7dc0-875a-4fac39ec9eaa` plus `...`) was the pane `title` 6 s after launch. |
| Claude title | Steer's OSC 2 title `Steer Claude 729984f1-…` became the pane `title` right after Claude's `SessionStart` hook fired. Claude took 76 s to start in this run, and until then the title was the process name `2.1.296`. |
| Icon title wins | In the probe, a pane that set an OSC 1 icon title and then an OSC 2 title reported the icon title as its `title`. A shell that sets an icon title would therefore hide Steer's OSC 2 Claude title. Codex's OSC 0 sets both. |
| Duplicate titles | The decoy's pane `title` equalled Codex's exactly. A title alone does not identify the Codex pane. |
| Foreground process | `list` has no process field. `ps -t <tty_name>` showed `codex`, `claude` (plus `caffeinate`) and `sleep` as the foreground groups. |
| Open, single window | `activate-pane --pane-id N` switched the window to N's tab and focused N in 5 of 5 cases: another tab, back to a split tab, a split sibling, and two cases from Finder followed by `open -b com.github.wez.wezterm`. The window server's front WezTerm window title changed to `[k/n] <N's title>`, and `list-clients` `focused_pane_id` became N. |
| Open, two windows | When the target was in the window that was not focused, `activate-pane` still exited 0 and changed `is_active` within its tab. But the window in front and `focused_pane_id` stayed on the other window: 0 of 3 without an app raise, and 0 of 2 with `open -b` from Finder, which raised the previously focused window. The one case whose target was already in the focused window matched. No CLI command raises a specific window. |
| Read-back limits | `list-clients` `focused_pane_id` changes only for the focused window and stays at its last value when another app is in front. `window_title` in `list` did not change when tabs switched. `is_active` is per tab, and `list` does not say which tab a window shows. |
| `send-text` to a shell | `--no-paste "echo PROBE…\r"` to A4a appeared only in A4a. A default (paste) `send-text` to B1 typed the command without running it; a later `\r` ran it. No probe appeared in any other pane, including the launch window. `send-text` did not raise WezTerm: Finder stayed in front. |
| `send-text` to a TUI | Claude submitted `--no-paste "<text>\r"` from one call. Codex did not, and needed a separate `\r`, as in iTerm2 and Terminal.app. |
| Unknown pane | `send-text --pane-id 1006` exited 1 with "no such pane 1006", and nothing was written anywhere. |

## Not shown

- Nightly WezTerm builds, where `list`/`list-clients` may report more. The stable build is from 2024.
- A user `wezterm.lua`, workspaces other than `default`, mux-server domains, and multiple GUI instances.
- Socket permission checks: the socket was used, not audited.
- Raising a specific window through macOS APIs, such as Accessibility or the window server. That would need permissions Steer does not hold today.
- Bracketed-paste submit behavior for multi-line text.
- Any Steer code path.
