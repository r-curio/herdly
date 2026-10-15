# WezTerm acceptance

Recorded 2026-10-15 for [Accept WezTerm live and turn its switch on](https://github.com/r-curio/steer/issues/245): the [MVP acceptance §3d](../mvp-acceptance.md#3d-terminal-host-acceptance) table run against one packaged build with WezTerm. The agent ran it alone, at the operator's request, while the operator was away. It drove Settings and the notch through Accessibility and confirmed each Open and acknowledgment from the WezTerm CLI, macOS's frontmost app, the window title, screenshots and `attention-snapshot.json`. No operator looked at any line. The earlier capability proof, with no Steer code path, is [WezTerm live targeting proof](wezterm-live.md).

## Setup and versions

- WezTerm `20240203-110809-5046fc22` (its app bundle reports a placeholder `0.1.0`), macOS 26.5 (25F71), Codex CLI 0.162.1, Claude Code 2.1.299.
- Build: 484, commit e9962ee (this branch), `Steer-0.1.0+484-unsigned-dev.zip`, `sha256` `b0dff2b30f6e632658924a607db4546b84db7b72c0f5c28375566a60fd00319b`, unsigned development package (`sh scripts/package-app.sh`), run from `output/Steer.app` in place of the installed app, which was restored afterwards. The build shows the WezTerm card with a Version row from `wezterm --version`, has the question-digit gate on, and contains this branch's Terminal.app fix (below).
- Lab:
  - WezTerm was launched with a clean environment (`env -i HOME USER /usr/bin/open -a WezTerm`). A fresh WezTerm shell listed no `CLAUDE*`, `CODEX*`, `HERDR*` or `ITERM*` variables.
  - Sessions ran in disposable directories under the agent's scratchpad. Window A held tab 1 Codex, tab 2 Claude (`--model haiku`) and tab 3 a decoy carrying the Codex session's exact title (`printf` OSC 0) over `sleep`. A second window B (a shell) was added for H5's front-window line. Codex ran with `-m gpt-6-luna -s read-only` for the session only.
  - Codex ran with `--no-daemon` except for H9's question, because daemon-run sessions' hook records carried another terminal's identifiers and their completions never queued ([#284](https://github.com/r-curio/steer/issues/284)). `request_user_input` is offered only through the daemon, so H9's question used a daemon-run session.
  - Turns were driven by `wezterm cli send-text --no-paste` (Codex submitted after a separate CR). Chrome, fullscreen on the notch's display, was the "other app". The notch was expanded by hovering its display's top edge.
- Lab caveats:
  - Steer surfaced completions 5–30 s after their hook records, so each check waited for the card or the snapshot entry before acting.
  - Several card replacements reused one thread name, because Codex titles a thread from its first prompt ("Reply with only GOLF" carried later turns).
  - One Codex launch opened Codex's own hooks screen, and the next typed prompt went into it. Every hook event then showed Installed equal to Active, and no `enabled = false` appeared under `hooks.state`. `~/.codex/config.toml` was rewritten at that launch, and there was no earlier copy to compare. No Steer or Codex configuration was otherwise changed.
  - Agent clicks meant to expand the notch landed on fullscreen Chrome's tab strip a few times before hovering replaced them.

## Source inspection

- The WezTerm card ([`ControlsView.swift`](../../Sources/SteerApp/ControlsView.swift) `WezTermControls`) has the switch, Version (added in this change), the status badge (`WezTermPresentation.settingsRow`: Off, Not in use, Ready, Needs attention), problem lines, Show diagnostics and the footer. It has no Permission row: WezTerm needs no Automation access. This change shows it (`TerminalHost.showsCard`).
- WezTerm's binding read counted Terminal.app only once Terminal.app's Automation access was granted (`terminalAppActive`), unlike every other host (`terminalAppSwitchedOn`). With Terminal.app's switch on and Terminal.app not running, access can't be verified, so Terminal.app read as unreadable and every WezTerm binding failed closed (diagnostics: `hostUnreadable(terminalApp)`). This change counts it by its switch ([`Companion+WezTerm.swift`](../../Sources/SteerApp/Companion+WezTerm.swift) `wezTermOtherHosts`). A running but unverified Terminal.app still reads as unreadable.
- WezTerm's default GUI socket (`srwx-----T`, mode 1700) passes the owner-only trust check.

## Automated checks

Run 2026-10-15 on this change's head (`feat/245-accept-wezterm`): `swift test` passed 1035 tests; `sh scripts/package-app.sh` built and packaged build 484; `output/Steer.app/Contents/MacOS/Steer --smoke-test` passed ("Steer controls-window smoke check passed."); `git diff --check` was clean. `TerminalHostsTests` now expects the Ghostty, iTerm2, Terminal.app, WezTerm and herdr cards shown and tmux and Zellij hidden; `WezTermTests` expects the digit gate on and covers the version line.

## Live application proof

| Line | Result | Observed |
| --- | --- | --- |
| Digit proof (ADR 0017) | PASS | Before the gate changed: a daemon-run Codex `request_user_input` question (Red, Blue, Green) in a WezTerm pane, then `send-text --no-paste --pane-id 0 -- 2` alone. Codex recorded "answer: Blue" and replied `• Blue.`; no CR was sent. This is the route `WezTermInput` uses, run from the CLI rather than a Steer code path. |
| H1 | PASS | The agent turned the switch on from Settings on build 482 (an earlier commit of this branch); it stayed on across the relaunches to 483 and 484. The card showed Status "Not in use" with no problem lines, then on 484 "Ready" once sessions bound. Version read the bundle's `0.1.0` on 482 and `20240203-110809-5046fc22` from 483 on (fixed in this change). No permission prompt (WezTerm needs none); macOS asked once for Documents access because the build ran from `~/Documents`, and the agent allowed it. |
| H2 | PASS | Panes: Codex 0 (`/dev/ttys011`), Claude 1 (`/dev/ttys019`), decoy 6 with the Codex session's exact title over `sleep`. Diagnostics: Codex `bound(wezTerm, tabID "0", /dev/ttys011)`, Claude `bound(wezTerm, tabID "1", /dev/ttys019)`; nothing bound to the decoy. Opens, visits and H9's replies reached only panes 0 and 1. |
| H3 | PASS | Chrome in front, WezTerm's window showing the decoy tab (`[3/3]`). Codex Open (GOLF): WezTerm frontmost, window `[1/3]` (screenshot: the Codex pane, not the same-titled decoy); the turn was acknowledged in the snapshot afterwards. Claude Open (HOTEL): WezTerm frontmost on `[2/3]` (screenshot); the card cleared afterwards. |
| H4 | PASS | Codex JULIET queued, then a ~4 s switch to tab 1 (`activate-pane` plus raising WezTerm) and back to Chrome: acknowledged. Claude KILO, same with tab 2: cleared. Codex LIMA arriving with tab 1 already in front: queued at 00:42:29, still unacknowledged at 00:42:34, acknowledged at 00:42:35 (dwell). |
| H5 split | PASS | Codex MIKE queued, then tab 1 split (panes 0 and 7). Open: WezTerm raised, window stayed on `[3/3]`, MIKE not acknowledged. The card read "Steer can't reach this session's tab. Reply in the session." under the reply field. |
| WezTerm: tab in a window not in front | PASS | Window B (a shell) in front within WezTerm, the sessions' tabs in window A. Claude Open (NOVEMBER) and Codex Open (MIKE): WezTerm raised, window B stayed in front (no window switch), neither acknowledged. The Claude card kept its reply field: the unsplit tab is still bound, so only Open falls back. |
| H6 (socket not owner-only) | PASS | `chmod 750` on the GUI socket with the switch on. Codex and Claude cards: "Open Session unavailable. Steer can't read WezTerm. Check Settings › Terminals." and "Steer can't reach this session's tab. Reply in the session." Settings: Status Needs attention, "Steer can't read WezTerm: its socket in ~/.local/share/wezterm isn't private to you." Mode restored to 1700; Status back to Ready. |
| H7 quit | PASS | `quit_relaunch_lab.py wezterm` (SIGTERM; WezTerm added to the lab in this change): WezTerm stayed closed for 120 s with Steer running. Codex and Claude cards: "Open Session unavailable. WezTerm isn't running." The agent relaunched WezTerm; Steer did not. |
| H7 closed tab | DEVIATION | A new `--no-daemon` Codex session (SIERRA) in its own tab, completion queued, tab closed with `kill-pane`. No `SessionEnd` record arrived, and for 90 s the card read "Open Session unavailable. Steer can't tell which terminal this session is in." Sessions that exited with `/quit` read "Open Session unavailable. This session has ended." Follow-up: [#285](https://github.com/r-curio/steer/issues/285). |
| H8 Codex | PASS | Switch off: the card read "Open Session unavailable. Steer can't tell which terminal this session is in." (shown at scan time, so no Open button to press). |
| H8 Claude | PASS with note | Switch off: Open raised WezTerm without changing window or tab; nothing acknowledged. The card's offer to turn WezTerm back on is not built ([#248](https://github.com/r-curio/steer/issues/248)). |
| H9 replies | PASS | Claude card: "reply with only OSCAR" typed through the card; pane 1 showed the prompt and `⏺ OSCAR`. Codex card: "reply with only PAPA"; the card showed "Typing your reply into the session…", and pane 0 showed the prompt and `• PAPA` (the separate CR committed it). Neither word appeared in any other pane. |
| H9 Codex question | PASS with note | A daemon-run Codex question in pane 0 showed answer buttons labeled "Answers with this option through Codex's daemon.", because the daemon held it (ADR 0010's precedence). Answering Green from the card reached Codex (`• Green`). Steer's WezTerm digit route was not reached: the only Codex sessions that can ask are daemon-run, and Steer answers those through the daemon while connected. The digit itself is the proof above. |
| #270: no relaunch | PASS | H7's quit lab. |

## Not run

- An operator looking at any line; every check was the agent's.
- Steer's WezTerm digit route end to end (see H9). It applies only to a question the daemon does not hold.
- "Answer this in Codex." with the gate off (the gate is on in this build).
- H8's offer to turn WezTerm back on (not built; #248).
- The cross-host line (same Codex title in two apps).
- A Claude session's tab closed (H7's second half was run for Codex only).

## Decisions

None taken by the operator yet. Open for the operator:

- **H7 closed tab:** whether a CLI session whose process is gone without `SessionEnd` reads "This session has ended." ([#285](https://github.com/r-curio/steer/issues/285)).
- **Daemon-run sessions:** their hook records carry the daemon's terminal environment and their WezTerm completions did not queue ([#284](https://github.com/r-curio/steer/issues/284)). This affects every host, not only WezTerm.
- **Digit gate:** turned on from the CLI-level proof, as ADR 0017 requires ("a live run shows the digit alone commits there"). Turn `WezTermInput.questionDigitsProvenLive` back off if a Steer-driven digit run is required first.
