# tmux live targeting proof

Recorded 2026-10-11 for [Prove tmux targeting live](https://github.com/r-curio/herdly/issues/207), the live check of [Research tmux's control surface for pane targeting and client tty](https://github.com/r-curio/herdly/issues/201) (findings on the unmerged branch `docs/201-research-tmux`; their lasting facts are in [ADR 0014](../adr/0014-bind-multiplexer-panes-and-join-their-client-to-a-host-tab.md) and the tmux section of [CLI notch integration](../cli-notch-integration.md#tmux-pane-binding-two-layer-open-and-typed-input-241)). This is evidence for later decisions, not a decision or an implemented Steer capability. Steer itself was not running; the lab script stood in for it.

## Setup

- tmux 3.8 (Homebrew), hosted in WezTerm `20240203-110809-5046fc22` (launched with a clean environment), macOS 26.5 (25F71), Codex CLI 0.162.1, Claude Code 2.1.296.
- Lab: [`scripts/terminal-lab/tmux_lab.py`](../../scripts/terminal-lab/tmux_lab.py). It started an isolated server (`tmux -L steerlab -f /dev/null`, minimal environment, socket `/private/tmp/tmux-503/steerlab`) with one session `lab` and windows codex (`%0`), claude (`%1`), decoy (`%2`, Codex's title over `sleep`) and split (`%3` and `%4`). One client was attached from a WezTerm pane (H1), and for part of the run a second client attached from another WezTerm tab (H2). Codex and Claude isolation was the same as the [iTerm2 proof](iterm2-live.md). No user tmux server existed or was touched.
- Sanitized output: `tmux-live.json` (raw lab record not kept in the repo). It includes a note on one manual passthrough check made before the final run.

## Results

| Check | Observed |
| --- | --- |
| Pane identity | `list-panes -a -F` gave `pane_id` (`%0`–`%4`), `pane_tty` (one tty per pane), `pane_title`, `pane_current_command`, `window_panes` (2 for the split), `session_attached` and `pane_in_mode`. Claude's hooks saw `TMUX` (socket path, server pid, session index) and `TMUX_PANE=%1`, plus `TERM_PROGRAM=tmux`. |
| Host join | `list-clients -F` gave the client's `client_tty`, `/dev/ttys022`. That equalled the WezTerm host pane's `tty_name`, so the client joins to exactly one host pane by tty. The second client reported its own tab's tty, `/dev/ttys023`. |
| Codex title | Codex's OSC 0 title `01a129c8-a7db-7782-94ad-741ab...` (the ADR 0005 format) was `pane_title` 6 s after launch. The host pane's title stayed `tmux` (`set-titles` is off by default). |
| Claude title | Steer's OSC 2 title never reached tmux. `pane_title` stayed the default hostname (`Mac`), and the host title stayed `tmux`. A raw OSC 2 printed from a shell pane did set `pane_title`. A passthrough-wrapped OSC 2 did not, so Claude Code emits the hook's `terminalSequence` wrapped for tmux passthrough, which tmux drops with `allow-passthrough` off (the default). With `allow-passthrough on`: when the client was displaying the Claude window (manual check), the title went to the **outer host pane** (`Steer Claude e9ca0f71-…`) and `pane_title` still stayed `Mac`. When the window was created detached and not displayed (lab run), nothing arrived anywhere. |
| Duplicate titles | The decoy's `pane_title` equalled Codex's exactly. |
| Foreground command | `pane_current_command` was `codex`, `sleep` and `zsh` as expected, and `2.1.296` for Claude (the version-named binary). `ps -t <pane_tty>` showed `claude`. |
| Switch | `switch-client -c <client_tty> -t %pane` moved the client to the target pane 5 of 5 times: another window, each pane of the split, and back. The new `pane_id` was confirmed by `list-clients` within 0.03–0.04 s. With two clients on the same session, switching H1 also moved H2 to the same pane, because the current window belongs to the session, not the client. |
| Focused flag | `client_flags` read `attached,focused,UTF-8` in every state: WezTerm in front or Finder in front, with `focus-events` off and also after `set -g focus-events on`. The flag did not track focus in this setup. |
| `send-keys` to a shell | `send-keys -t %3 -l "echo PROBE…"` then `Enter` ran only in `%3`. `capture-pane` of every pane found the probe nowhere else. |
| Copy mode | With `%4` in copy mode, `send-keys -l` got no reply within the timeout in both lab runs (20 s, then 8 s). The pane stayed in copy mode and the text was neither typed nor run. Eight manual retries of the same command into a copy-mode pane each returned in under 0.1 s. Why it hung is unknown. |
| `send-keys` to a TUI | Claude submitted `-l "<text>\r"` from one call. Codex did not, and needed a separate `send-keys Enter`, as in iTerm2, Terminal.app and WezTerm. |
| Unknown pane | `send-keys -t %999` exited 1 with "can't find pane: %999", and nothing was written. |

## Not shown

- tmux hosted in iTerm2, Terminal.app or Ghostty; the client-tty join was shown only for WezTerm hosts.
- A user `.tmux.conf`, `set-titles on`, named sockets other than the lab's, grouped sessions, and iTerm2's `-CC` mode.
- Focus reporting with a host known to send focus events to tmux.
- The cause of the copy-mode hang.
- Any Steer code path.
