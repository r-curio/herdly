# Terminal.app acceptance

Recorded 2026-10-14 for [Accept Terminal.app live and turn its switch on](https://github.com/r-curio/steer/issues/244): the [MVP acceptance §3d](../mvp-acceptance.md#3d-terminal-host-acceptance) table run against one packaged build with Terminal.app. The agent drove the run, including Settings clicks, the Automation toggle in System Settings and reading the notch through Accessibility; the operator pressed the notch's Open buttons, typed the card replies and confirmed what Terminal.app showed. The earlier capability proof, with no Steer code path, is [Terminal.app live targeting proof](terminal-app-live.md).

## Setup and versions

- Terminal 2.15 (build 470.2), macOS 26.5 (25F71), Codex CLI 0.162.1, Claude Code 2.1.299.
- Build: 473, commit facc155 (this branch: the Terminal.app card shown, with a Version row), `Steer-0.1.0+473-unsigned-dev.zip`, `sha256` `56c88c6f98d58681438998dfd6f75fd0c84e8db35a9aa67c32efc0407ac7f1c7`, unsigned development package (`sh scripts/package-app.sh`), run from `output/Steer.app`.
- Unlike the iTerm2 run, the card was shown in the build under test, so H1 and H6's Settings half were done from Settings.
- Lab:
  - Terminal.app was launched with a clean environment (`env -i HOME USER PATH /usr/bin/open -a Terminal`), as the [earlier proof](terminal-app-live.md) requires.
  - Sessions ran in disposable directories under the agent's scratchpad. Each tab was its own single-tab window, created with `do script`. Codex ran with `-m gpt-6-luna` for the session only; no Codex configuration was changed. The status line showed "monthly 0% left", but turns still ran.
  - The decoy was a window titled with the Codex session's exact title (`printf` OSC 0) over `sleep`.
  - Turns were driven by `do script` (Codex submitted after a separate empty `do script`).
  - Front-app changes were logged every 0.5 s with `lsappinfo`; acknowledgments were read from `attention-snapshot.json`.
- Lab caveats:
  - The first lab windows were closed during the run (before H2/H3), ending those sessions; the lab was rebuilt with new sessions. Several early completions were acknowledged by brief visits: the agent's own activation of Terminal.app to reorder windows (ADR 0016's manual visit), and probably the operator's. H2/H3 were run on the rebuilt lab.
  - The expanded notch is readable through Accessibility while hovered (card text, lines and buttons), unlike the iTerm2 run's note. H6, H7 and H9's question card were read that way; the operator confirmed the rest by looking.

## Source inspection

- The Terminal.app card ([`ControlsView.swift`](../../Sources/SteerApp/ControlsView.swift) `TerminalAppControls`) has the switch, Version (added in this change, as for iTerm2), the Automation permission badge with Open Settings… on a denial, the status badge (`TerminalAppPresentation.settingsRow`: Off, Not in use, Ready, Needs attention), problem lines, Show diagnostics and the footer, per [product.md's card rules](../product.md#settings). This change shows it (`TerminalHost.showsCard`).
- `TerminalAppSnapshot.inventory` gives every tab one pane, and each tab of a native tab group is a separate scripting window with one tab ([earlier proof](terminal-app-live.md)). So Steer can see neither Terminal's split view nor a tab group, and the "tab inside a window of several tabs" and split fallbacks in [CLI integration](../cli-notch-integration.md#terminalapp-open-and-replies-239) cannot fire. H5 shows what happens instead.
- The Permission badge comes from the latest permission check (`terminalApp.access`). A denial met by a scan sets `readable = false`, not `access`, so the badge keeps its last answer while the problem line shows. While the switch is off, `settingsRow` returns no problem lines.

## Automated checks

Run 2026-10-14 on this change's head (`feat/244-accept-terminal-app`): `swift test` passed 1028 tests; `sh scripts/build-app.sh` built `output/Steer.app`; `output/Steer.app/Contents/MacOS/Steer --smoke-test` passed ("Steer controls-window smoke check passed."). `TerminalHostsTests` now expects the Ghostty, iTerm2, Terminal.app and herdr cards shown and WezTerm, tmux and Zellij hidden.

## Live application proof

| Line | Result | Observed |
| --- | --- | --- |
| H1 | PASS with note | The operator turned the switch on in Settings. The card showed Version 2.15, Automation permission Allowed, Status Ready "Terminal.app is readable.", no problem lines (operator's screenshot). No Automation prompt was reported; Steer › Terminal was already listed and allowed in System Settings › Automation, so access was evidently granted before this run. |
| H2 | PASS | Windows: Codex 25095, Claude 25096, decoy 25100 with Codex's exact title over `sleep`. Codex Open selected the Codex window, not the decoy (operator: "ok"); `attention-snapshot` showed the INDIA turn acknowledged. H9's replies landed only in the Codex and Claude windows; the decoy got nothing. |
| H3 | PASS | From Chrome, Claude Open (JULIET) and Codex Open (INDIA) each showed the exact window (operator: "ok ok"); both completions were acknowledged after the Opens. |
| H4 | PASS | Agent-driven: a ~3 s switch to the Codex window acknowledged KILO; a ~3 s switch to the Claude window acknowledged LIMA; MIKE arriving while the Codex window was in front was not acknowledged after ~2 s and was after ~8 s (dwell). |
| H5 | PASS with deviation (product call) | Split: ⌘D split the Claude window (screenshot: two views of one session; Terminal's scripting reports nothing). Tab group: ⌘T added a shell tab to the Codex window, which then showed. Codex Open (OSCAR) and Claude Open (PAPA) both reached the exact session and acknowledged; afterwards the Codex tab was in front. §3d expects a fallback, but Steer cannot see either layout, and a split view shows the same session, so the exact session was reached each time. The typed-input line was not reached. |
| H6 scan path | PASS with note | With the switch on, the agent unticked Steer › Terminal in System Settings › Automation. Settings: Status Needs attention, "Steer can't read Terminal.app. Allow Steer under System Settings › Privacy & Security › Automation › Terminal." Both cards: "Steer can't read Terminal.app. Check Settings › Terminals." (operator: "same"). Note: the Permission badge still read Allowed. |
| H6 permission-check path | PASS with note | Switch turned off and on while denied: the check turned the switch back off; Permission Not allowed with Open Settings…; Status Off. Note: no problem line shows while the switch is off, though §3d mentions "the denial's problem line". The card's switched-off line is H8's, seen there. Access was then restored and the switch turned back on (Allowed, Ready). |
| H7 | PASS with note | `quit_relaunch_lab.py terminal` (SIGTERM): Terminal.app stayed closed for 120 s with Steer running. Codex card: "Open Session unavailable. Terminal.app isn't running." Claude card: "Open is unavailable until Steer can verify this Claude session is live." (its process ended with Terminal.app). The agent relaunched Terminal.app (`open -a`; Steer did not). A new Codex session (XRAY) in its own window: once that window closed, the card read "Open Session unavailable. This session has ended." While the window stayed open after its process ended (Terminal keeps it, titled with Codex's title), the card read "Steer can't tell which terminal this session is in." |
| H8 Codex | PASS | Switch off (agent, from Settings): "Steer can't tell which terminal this session is in." (operator). |
| H8 Claude | PASS with note | Switch off: Open raised Terminal.app without changing window (operator). The card's offer to turn the host back on is not built ([#248](https://github.com/r-curio/steer/issues/248)). |
| H9 replies | PASS with note | The operator typed "reply with only SIERRA" on the Codex card and "reply with only TANGO" on the Claude card ("it works"). Terminal contents: each text in its own window only, each session answered (`• SIERRA`, `⏺ TANGO`); nothing in the decoy. The cards' wording after sending was not recorded. |
| H9 Codex question | PASS with note | A Codex `request_user_input` question in Terminal.app (plan mode) showed answer buttons, not "Answer this in Codex.", because the daemon held the request; ADR 0010's precedence puts the daemon first. Answering Blue from the card reached Codex (`• Blue.`). The "Answer this in Codex." line, for a session the daemon does not hold, was not reached. |
| Terminal.app: replies only | PASS with note | Replies typed (H9). No key was sent to Terminal.app for the question; the daemon answered it. |
| #270: no relaunch | PASS | H7's quit lab. |

## Not run

- The Automation prompt at H1 (access was already granted).
- H5's typed-input line ("Steer can't reach this session's tab…"): no Terminal.app layout made Steer fall back.
- "Answer this in Codex." for a Codex question the daemon does not hold.
- H8's offer to turn Terminal.app back on (not built; #248).
- The cross-host line (same Codex title in two apps).

## Decisions

The operator decided the run's open questions on 2026-10-14:

- **H5 (accepted as is).** Terminal's split view and tab groups are invisible to its scripting, and a split shows one session twice, so Open reaching the exact session is Terminal.app's H5 result. §3d's Terminal.app line and CLI integration's fallback note say so.
- **H6 Permission badge (change).** A denial met by a scan should turn the badge to Not allowed, not leave it at Allowed. Follow-up: [#279](https://github.com/r-curio/steer/issues/279).
- **H6 problem line while off (accepted as is).** Once the permission check turns the switch off, Settings shows Not allowed with Open Settings… and no problem line: the Off rule governs for Terminal.app. §3d H6 says so. iTerm2's card still lists its denial line while off.
- **H7 Claude line (change).** When Terminal.app quits, the Claude card should say "Terminal.app isn't running." like the Codex card. Follow-up: [#280](https://github.com/r-curio/steer/issues/280).
