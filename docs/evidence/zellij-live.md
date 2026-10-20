# Zellij live targeting proof

Recorded 2026-10-11 for [Prove Zellij targeting live](https://github.com/r-curio/herdly/issues/208), the live check of [Research Zellij's CLI for pane targeting and client tty](https://github.com/r-curio/herdly/issues/202) ([findings](https://github.com/r-curio/herdly/blob/docs/202-research-zellij/docs/zellij-cli-investigation.md)). This is evidence for later decisions, not a decision or an implemented Steer capability. Steer itself was not running; the lab script stood in for it.

## Setup

- Zellij 0.45.1 (Homebrew), hosted in WezTerm `20240203-110809-5046fc22` (launched with a clean environment), macOS 26.5 (25F71), Codex CLI 0.162.1, Claude Code 2.1.296.
- Lab: [`scripts/terminal-lab/zellij_lab.py`](../../scripts/terminal-lab/zellij_lab.py). It ran an isolated session `lab` with its own `ZELLIJ_SOCKET_DIR` under the lab root, a lab config (startup tips, release notes and session serialization off) and a minimal environment. The session had tabs codex (`terminal_1`), claude (`terminal_2`), decoy (`terminal_3`, Codex's title over `sleep`) and split (`terminal_4` and `terminal_5`), plus the default first tab (`terminal_0`). One client was attached from a WezTerm pane (H1), and for part of the run a second client attached from another WezTerm tab (H2). Codex and Claude isolation was the same as the [iTerm2 proof](iterm2-live.md). No user Zellij session existed or was touched.
- Results come from the second full run, which added a keystroke from H1 before the focus cases. Sanitized output: [`zellij-live.json`](zellij-live.json).

## Results

| Check | Observed |
| --- | --- |
| Pane identity | `action list-panes --json --all` gave each pane's `id`, `is_plugin`, `title`, `tab_id`, `tab_position`, `tab_name`, `is_focused`, `exited` and geometry. Plugin and terminal panes reuse the same numbers (`id` 0 exists as both), so `is_plugin` must be checked. Each shell's `ZELLIJ_PANE_ID` equalled its terminal pane id. Claude's hooks saw `ZELLIJ=0`, `ZELLIJ_PANE_ID=2` and `ZELLIJ_SESSION_NAME=lab`. There is no tty or pid per pane. |
| Titles | Codex's OSC 0 title (`01a129cf-1a27-77a1-b68e-081c7...`, the ADR 0005 format) and Steer's OSC 2 Claude title (`Steer Claude d6a5e88b-…`) were each pane's `title`, within 12 s of launch. The decoy's `title` equalled Codex's exactly. Panes without a title read `Pane #n`. |
| Clients and host join | `action list-clients` gave `CLIENT_ID`, the client's current pane (`terminal_N`) and its running command. It gave no tty or pid. Each attached client was a `zellij` process whose controlling tty equalled its WezTerm host pane's `tty_name` (`ps`). `lsof -U` matched the session socket path only on the server's own descriptors, not on the clients, so the socket path alone does not tie a client process to the session. |
| Focus before any keystroke | `focus-pane-id terminal_2` exited 0, but the attached client stayed on `terminal_5` and the host title did not change. |
| Focus after the client typed | After one keystroke from H1, `focus-pane-id` moved H1's client to the target 4 of 4 times (another tab, each split pane, and back), with `list-clients` showing the new pane. The host pane's title followed as `lab \| <pane title>` (e.g. `lab \| Steer Claude d6a5e88b-…`). Refocusing the focused pane exited 2 with "Pane Terminal(5) is already focused". `is_focused` in `list-panes` marks each tab's focused pane, not the client's. |
| Two clients | With H2 attached but not yet typing, focus moved H1 (the last client to type) and left H2 alone. After one keystroke from H2, focus moved H2 and left H1 alone. A CLI focus cannot choose its client. |
| `write-chars --pane-id` to a shell | `write-chars` plus `write 13` to `terminal_4` ran only there. `dump-screen` of every pane found the probe nowhere else. |
| Unknown pane | `write-chars --pane-id terminal_999` exited 0 with no error, and nothing appeared in any pane. |
| TUI prompt | Claude submitted `write-chars "<text>\r"` from one call. Codex did not, and needed a separate `write 13`, as in every other host tested. |

## Not shown

- Zellij hosted in iTerm2, Terminal.app or Ghostty.
- User configuration, layouts, renamed panes (a user pane name replaces the program title), floating panes, web clients, and Zellij versions before 0.44.1.
- Whether the acting client can be identified from outside before a focus is sent.
- Any Steer code path.
