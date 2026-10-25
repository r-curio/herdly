# tmux acceptance

Run 2026-10-20 to 2026-10-25 and recorded 2026-10-25 for [Accept tmux live and turn its switch on](https://github.com/r-curio/herdly/issues/246). This is the [MVP acceptance §3d](../mvp-acceptance.md#3d-terminal-host-acceptance) table plus tmux's host-specific lines, run with a tmux client inside each of the three hosts that can raise a tmux client's tab: WezTerm, iTerm2 and Terminal.app. The agent ran it alone, at the operator's request, on the operator's own Mac while the operator's own Codex and Claude sessions kept running. It drove Settings and the notch through Accessibility. It confirmed each Open and acknowledgment from four sources: `tmux list-clients`, the host's window and tab (WezTerm CLI, AppleScript), macOS's frontmost app, and screenshots. No operator looked at any line.

## Setup and versions

- tmux 3.8 on its default socket (`/private/tmp/tmux-503/default`), started with `-f /dev/null` so no user configuration applied.
- Hosts:
  - WezTerm `20240203-110809-5046fc22`.
  - iTerm2 3.7.4.
  - Terminal.app 2.15.
- macOS 26.5 (25F71).
- Agents: Codex CLI 0.164.0 and Claude Code 2.1.304. Claude Code updated itself to 2.1.310 during the run.
- Build: 549, commit a138612 (this branch), `Herdly-0.1.0+549-unsigned-dev.zip`, `sha256` `65999a372e997639d9e400b51542d455bad532cc506c29829e8b8c16cd423e1d`, unsigned development package (`sh scripts/package-app.sh`), `dirty_worktree` false.
  - The live runs used build 549's commit plus temporary Open-step logging only (no behavior change). The logging was used to diagnose the raise fix below, then reverted.
  - The packaged zip itself was then unzipped outside `~/Documents` and run for a final check: Settings showed the tmux card Ready, and a Claude row's Open in WezTerm reached the exact tmux window and was acknowledged.
  - The build shows the tmux card and has tmux's question-digit gate on. Builds 507, 508 and 548 were superseded during the run.
- Lab:
  - One tmux session `lab`. Window 0 ran Codex (pane `%3`, `/dev/ttys017`), started in a scratchpad directory. Window 1 ran Claude (pane `%1`, `/dev/ttys031`, thread `bravo-reply`), also started in a scratchpad directory.
  - Each host held a tab with the tmux client, a decoy tab printing the Codex session's exact title (OSC 0) over `sleep`, and a spare shell.
  - Turns were driven by `tmux send-keys -l` (Codex submitted after a separate CR). Replies were typed through the notch card with Accessibility (`AXConfirm`).
  - "Another app" was Finder or Chrome.
- Lab caveats:
  - A pending macOS Keychain prompt ("Herdly wants to use … Herdly phone alert topic") stopped Herdly surfacing any new completion until it was answered. Every rebuilt ad-hoc build raised it again. The agent pressed Deny each time. One H3 attempt in WezTerm failed while the prompt was open, and passed once it was answered (follow-up below).
  - The clean build asked once for Documents access, and the agent pressed Don't Allow. The first Open pressed on the clean build's arrival card raised WezTerm without changing the tmux window. The row's Open pressed right after reached the window (`[1/3] tmux`, `%1`) and acknowledged the completion. Every earlier card Open in the run reached its window, so this single miss is recorded without a cause.
  - Codex titles a thread from its first prompt, so later turns carried earlier titles ("Reply with OSCAR").
  - iTerm2 answered the tmux client's XTVERSION query on attach, and the reply (`>|iTerm2 3.7.4`) landed in Codex's composer once. It was cleared with C-c before the next turn.

## Source inspection

- The tmux card (`TmuxHostRow` in [`ControlsView.swift`](../../Sources/HerdlyApp/ControlsView.swift)) is shown from this change (`TerminalHost.showsCard`), so H1 runs from Settings.
- Three changes made the run pass:
  - `TmuxRunner` and `ZellijRunner` read a command that printed nothing as failed. This covers `switch-client` and `select-pane`, so every Open fell back after a successful switch. A command with no output now counts as succeeded.
  - `runTmuxOpen` and `runZellijOpen` returned `self?.raiseHostTab(…) ?? .unavailable(.sessionEnded)` from the raise and host-verify steps. `nil` is a step that passed, so every successful raise read "This session has ended." Only a released companion now reads as ended ([`Companion+Tmux.swift`](../../Sources/HerdlyApp/Companion+Tmux.swift), [`Companion+Zellij.swift`](../../Sources/HerdlyApp/Companion+Zellij.swift)).
  - `TmuxInput.questionDigitsProvenLive` is on, after the digit proof below.
- Socket trust: the default socket's folder `/private/tmp/tmux-503` is mode 0700 and the socket is owner-only, which passes.
- iTerm2's shells descend from `iTermServer-3.7.4`, which is reparented to launchd. A tmux client's pids therefore never walk up to iTerm2, and ADR 0015's fallback can't name the app ([cli-notch-integration.md](../cli-notch-integration.md)). This drives iTerm2's H5, H7 and H8 results.

## Automated checks

Run 2026-10-25 on this branch's head (`feat/246-accept-tmux`, rebased onto main 3f7adee):
- `swift test` passed 1400 tests.
- `sh scripts/package-app.sh` built and packaged build 549.
- `git diff --check` was clean.

`TerminalHostsTests` now expects the tmux card shown, and `TmuxTests` expects the digit gate on.

## Live application proof

H1, the digit proof and H2 are shared by all three hosts. They are one tmux server and one pair of sessions, with the client moved between hosts.

| Line | Result | Observed |
| --- | --- | --- |
| Digit proof (ADR 0017) | PASS | 2026-10-20, before the gate changed: a Codex `request_user_input` question (Red, Blue, Green) in the tmux pane, then a lone `3` with `send-keys -l` and no Enter. Codex recorded "answer: Green" and replied `• Green`. This is the route `TmuxInput` uses, run from the CLI rather than a Herdly code path. |
| H1 | PASS | The agent turned the switch on from Settings › Terminals › Multiplexers. The card read Not in use with no problem lines, then Ready once sessions bound. No permission prompt for tmux itself. iTerm2 and Terminal.app had their Automation access already granted, or granted once (Terminal.app: Allow). |
| H2 | PASS | Codex bound to `%3`, Claude to `%1`. In every host the decoy tab carried the Codex title and bound nothing: Open, visits and replies reached only `%3` and `%1`. |

### WezTerm

| Line | Result | Observed |
| --- | --- | --- |
| H3 | PASS | Finder in front, WezTerm on the decoy tab, tmux on the other window. Claude Open: WezTerm frontmost, window `[1/3] tmux`, client on `%1`, then acknowledged after the visit. Codex Open: the tmux tab (not the same-titled decoy), client on `%3`, acknowledged. The arrival card's Open and a row click both run the same Open. |
| H4 | PASS | A switch to the tmux tab by hand acknowledged queued completions for both agents. A completion arriving with its pane in front cleared after the dwell. |
| H5 | PASS | A second tmux client attached. Open stopped at revalidation (`unsupportedLayout`): WezTerm raised, tab unchanged, nothing acknowledged. tmux types replies into the exact pane, not the tab (`TmuxInput`), so with two clients a reply still landed only in the bound pane (CHARLIE2). |
| H6 | PASS | `chmod 0705 /private/tmp/tmux-503`. Card: "Herdly can't read tmux. Check Settings › Terminals." Settings: Needs attention, "Herdly can't read tmux's default socket. Check that it runs as you." Mode restored to 0700; back to Ready. |
| tmux: socket other than the default | PASS with note | A Claude session in tmux on `-L alt-socket`. The card showed "Sessions seen on a socket other than the default can't be reached." The session's own reason line read "Open Session is unavailable until Herdly can verify the exact herdr pane.", which names the wrong multiplexer (follow-up below). Killing that server read "This session has ended." |
| H7 quit | DEVIATION | WezTerm quit with sessions running. Herdly did not relaunch it (closed for 20 s). With no tmux client attached, both rows read "Herdly can't tell which terminal this session is in." rather than "WezTerm isn't running.": the tmux pane has no client, so no host is known. |
| H7 closed pane | DEVIATION | `kill-window` on a Claude window (`ender`). No `SessionEnd` arrived, and the row read "Open is unavailable until Herdly can verify this Claude session is live." rather than "This session has ended." This matches WezTerm's own H7 ([#285](https://github.com/r-curio/herdly/issues/285)). |
| H8 Codex | PASS | WezTerm's switch off: "Herdly can't tell which terminal this session is in." |
| H8 Claude | DEVIATION | WezTerm's switch off: the row read "Herdly can't tell which terminal this session is in." rather than raising the app. Claude's process ancestry ends at the tmux server, not at WezTerm, so there is no app to raise silently (product.md's ancestry rule). The offer to turn the host back on is not built ([#248](https://github.com/r-curio/herdly/issues/248)). |
| H9 replies | PASS | Codex: INDIA2 typed through the card landed in `%3` and was committed by the separate CR. Claude: the reply landed in `%1` and Claude answered. Neither word reached the decoy or the other pane. |
| H9 Codex question | PASS with note | Herdly's own tmux digit route was not reached: Codex offers `request_user_input` only through its daemon, and the daemon answers first (ADR 0010), as in WezTerm's acceptance. The digit itself is the proof above. |

### iTerm2

The lab used one new iTerm2 window: tab 1 the tmux client (`/dev/ttys030`), tab 2 the decoy, tab 3 a shell. The operator's other iTerm2 windows were left alone, and iTerm2 was never quit.

| Line | Result | Observed |
| --- | --- | --- |
| H3 | PASS | Claude and Codex Open, from the row and from the arrival card's Open: iTerm2 frontmost on tab 1, client on the right pane, acknowledged after the visit. Slower than WezTerm: 4–9 s from click to the tab. |
| H4 | PASS | Manual switch and dwell, both agents. |
| H5 | DEVIATION | With two clients, the row read "Unreachable · Herdly can't tell which terminal this session is in." rather than raising iTerm2: the fallback can't find iTerm2 from the client pids (Source inspection). The reply with two clients still landed in the bound pane (PAPA3). |
| H6 | PASS | Same lines as WezTerm's H6. |
| H7 | Stood in | iTerm2 was not quit, because the operator's own sessions run there. Detaching the client stood in for it: "Herdly can't tell which terminal this session is in." |
| H8 | Same as WezTerm | Codex PASS, Claude DEVIATION. |
| H9 replies | PASS | Codex SIERRA3 landed in `%3` and was committed. Claude PASS. tmux types into the pane, so iTerm2's own no-typing rule does not apply. |

### Terminal.app

Terminal.app had windows for the tmux client (`/dev/ttys048`), the decoy, and a second client (`/dev/ttys050`) for H5.

| Line | Result | Observed |
| --- | --- | --- |
| H3 | PASS | Claude and Codex Open: Terminal frontmost on the client's window, client on the right pane, acknowledged. About 10 s from click to window. |
| H4 | PASS | Manual switch and dwell, both agents. |
| H5 | PASS | Second client attached: Terminal raised, front window unchanged, nothing acknowledged. The reply still landed in the bound pane (YANKEE3). |
| H6 | PASS | Same lines as WezTerm's H6. |
| H7 | PASS with note | Terminal quit and stayed closed with Herdly running. The rows read "Herdly can't tell which terminal this session is in." for the same reason as WezTerm's H7. |
| H8 | Same as WezTerm | Codex PASS, Claude DEVIATION. |
| H9 replies | PASS | Codex ALFA3 and the Claude reply each landed in their own pane and committed. |

## Not run

- No operator looked at any line; every check was the agent's.
- Herdly's own tmux digit route end to end (see H9). It applies only to a question the daemon does not hold.
- Quitting iTerm2 (H7), to keep the operator's sessions running.
- A Ghostty host.
- The cross-host line (same Codex title in two apps).

## Decisions

Taken by the operator on 2026-10-25, each as recommended:

- **H7 with no client:** accepted. With the host app quit or the client detached, a tmux pane has no client and reads "Herdly can't tell which terminal this session is in." This is tmux's expected line, not "<app> isn't running."
- **H8 Claude:** accepted for now. Ancestry stops at the tmux server, so a Claude session in tmux can't be raised silently with the host switch off.
- **iTerm2 fallback:** accepted. iTerm2's reparented server hides it from ADR 0015's walk, so H5 reads unreachable instead of raising iTerm2.
- **Closed pane without `SessionEnd`:** tracked with [#285](https://github.com/r-curio/herdly/issues/285).
- **Digit gate:** stays on from the CLI-level proof, as ADR 0017 allows.

Follow-ups to file:
- A pending Keychain prompt stops all event intake.
- The non-default socket's reason line names herdr.
- A tmux pane closed without `SessionEnd` ([#285](https://github.com/r-curio/herdly/issues/285)'s pattern).
