# Zellij acceptance

Run and recorded 2026-10-25 for [Accept Zellij live and turn its switch on](https://github.com/r-curio/herdly/issues/247). This is the [MVP acceptance §3d](../mvp-acceptance.md#3d-terminal-host-acceptance) table plus Zellij's host-specific lines, run with a Zellij client inside each of the three hosts that can raise a Zellij client's tab: WezTerm, iTerm2 and Terminal.app. The agent ran it alone, at the operator's request, on the operator's own Mac while the operator's own Codex and Claude sessions kept running. It drove Settings and the notch through Accessibility. It confirmed each Open and acknowledgment from four sources: `zellij action list-clients`, the host's window and tab (WezTerm CLI, AppleScript), macOS's frontmost app, and Herdly's attention snapshot, with screenshots. No operator looked at any line.

## Setup and versions

- Zellij 0.45.1, one session `lab` under the default socket directory (`$(getconf DARWIN_USER_TEMP_DIR)zellij-503/contract_version_1`, mode 0700, owner-only sockets). It was started with a minimal environment (`env -i` plus `HOME`, `USER`, `PATH`, `TMPDIR`, `LANG` and `TERM`) and a lab config, so no user configuration applied.
- Hosts:
  - WezTerm `20240203-110809-5046fc22`.
  - iTerm2 3.7.4.
  - Terminal.app 2.15.
- macOS 26.5 (25F71).
- Agents: Codex CLI 0.164.0 (`--no-daemon`) and Claude Code 2.1.310 (`--model haiku`).
- Builds, both unsigned development packages (`sh scripts/package-app.sh`) with `dirty_worktree` false:
  - 549, commit 9da9030 (the card shown, the digit gate still off). Used for the WezTerm lines and the digit proof.
  - 550, commit 2eb5da1 (this branch's head: the card shown and the digit gate on), `Herdly-0.1.0+550-unsigned-dev.zip`, `sha256` `890c5fd720d4727fd1bb59afc3743c008e88da47606c8f3b3ff75d32695152b2`. Unzipped outside `~/Documents` and used for H9's Codex question and every iTerm2 and Terminal.app line.
- Lab:
  - Tab `codex` ran Codex (`terminal_1`, thread "Reply with only BRAVO"). Tab `claude` ran Claude (`terminal_2`, thread `reply-alpha`). Tab `home` ran `/bin/sh` (`terminal_4`).
  - Each host held a tab or window with the Zellij client, a decoy printing the Codex session's exact title (OSC 0) over `sleep`, and a spare shell.
  - Turns were driven by `zellij action write-chars` (Codex submitted after a separate `write 13`). Replies were typed through the notch card with Accessibility (`AXConfirm`).
  - "Another app" was Finder.
- Lab caveats:
  - Every new build raised the macOS Keychain prompt ("Herdly wants to use … Herdly phone alert topic"). The agent pressed Deny each time ([#367](https://github.com/r-curio/herdly/issues/367)). One Documents-access prompt was answered Don't Allow.
  - A Zellij client writes `<session> | <title>` to its host only when the focused pane sends a title, so after an attach the host tab reads just `lab` (or `zellij`) and every Open falls back on the title veto (Findings). The lab set the host title by printing an OSC 0 title in the focused `home` pane before each host's Open lines.
  - WezTerm closed once while the operator was at the Mac. The client was reattached, and the `home` tab was created then.

## Source inspection

- The Zellij card (`ZellijHostRow` in [`ControlsView.swift`](../../Sources/HerdlyApp/ControlsView.swift)) is shown from this change (`TerminalHost.showsCard`), so H1 runs from Settings.
- `ZellijInput.questionDigitsProvenLive` is on, after the digit proof below.
- Open's plan (`ZellijOpen.plan` in [`ZellijTargeting.swift`](../../Sources/HerdlyCore/ZellijTargeting.swift)) joins the one client's tty to one host tab across the enabled terminal inventories (`MultiplexerHostTab.join`). When no enabled host lists the tty and a Ghostty tab lists none, the join answers `.ghostty`, and Open sends `focus-pane-id` before the Ghostty raise fails. This is the likely cause of H8 in iTerm2 and Terminal.app; it was read from the source, not confirmed with logging.

## Automated checks

Run 2026-10-25 on this branch's head (`feat/247-accept-zellij`, from main 7547555):
- `swift test` passed 1401 tests.
- `sh scripts/package-app.sh` built and packaged build 550.
- `git diff --check` was clean.

`TerminalHostsTests` now expects the Zellij card shown, `ZellijTests` expects the digit gate on, and `HerdrQuestionRelayTests` expects a Zellij question to route to `terminalRelay`.

## Live application proof

H1, the digit proof, H2, H6 and H9's Codex question are shared by all three hosts. They are one Zellij server and one pair of sessions, with the client moved between hosts.

| Line | Result | Observed |
| --- | --- | --- |
| Digit proof (ADR 0017) | PASS | Build 549, before the gate changed: a Codex `request_user_input` question (Red, Blue, Green) in Plan mode, then a lone `write-chars --pane-id terminal_1 -- 3` with no carriage return. Codex recorded "answer: Green". Herdly's card showed "Answer this in Codex." while the gate was off. |
| H1 | PASS | The agent turned the switch on from Settings › Terminals › Multiplexers. The card read Not in use with no problem lines, then Ready once sessions bound. No version is shown on the row, as for tmux. No permission prompt for Zellij itself. |
| H2 | PASS | Diagnostics: Codex bound to `ZellijPaneTarget(session: "lab", paneID: 1)`, Claude to `paneID: 2`. The decoy carried the Codex title and bound nothing in every host: Open, visits and replies reached only `terminal_1` and `terminal_2`. |
| H6 | PASS | `chmod 0750` on `contract_version_1`. Rows: "Unreachable · Herdly can't read Zellij. Check Settings › Terminals." Settings showed the same line. Mode restored to 0700; back to Ready. Run in WezTerm and iTerm2; the socket check is host-independent, so it was not repeated in Terminal.app. |
| H9 Codex question | PASS | Build 550, in WezTerm. A Plan-mode question; the card offered its options ("Selects this answer. Nothing is sent until Send."). Picking Banana and pressing Send recorded "answer: Banana" within 1 s, and no digit reached another pane. This is the first host acceptance where Herdly's own digit route ran end to end. |

### WezTerm

| Line | Result | Observed |
| --- | --- | --- |
| H3 | PASS | Finder in front, WezTerm on the decoy tab, the client on `home`. Claude Open: WezTerm frontmost on `[1/3]`, client on `terminal_2`, acknowledged after the visit. Codex Open: the client tab (not the same-titled decoy), client on `terminal_1`, acknowledged. The first attempts fell back on the title veto before the lab set the host title. |
| H4 | PASS | A switch to each pane by hand (about 4 s) acknowledged the queued completion for both agents. A completion arriving with its pane in front (HOTEL) cleared after the dwell, within 7 s. |
| H5 split | PASS | A second pane in the Codex tab. Open raised WezTerm without changing the tab or the pane; nothing acknowledged. The arrival card hid the reply field with no reason line (#323's rule). |
| H5 second client | PASS | Card: "More than one zellij client process is running." Open raised WezTerm, nothing changed, nothing acknowledged. A reply (LIMA) still landed only in `terminal_1`. |
| H7 quit | PASS with note | WezTerm quit with sessions running and stayed closed for 30 s; Herdly did not relaunch it. With no client left, both rows read "Herdly can't tell which terminal this session is in.", as tmux's accepted H7. |
| H8 Claude | PASS with note | WezTerm's switch off: WezTerm raised silently, tab unchanged. The offer to turn the host back on is not built ([#248](https://github.com/r-curio/herdly/issues/248)). |
| H8 Codex | DEVIATION | WezTerm's switch off: Open from the card and from the row raised nothing, and no line was shown. The Zellij focus was not checked; iTerm2's and Terminal.app's H8 show Open moving it (Findings). |
| H9 replies | PASS | Codex LIMA and Claude OSCAR each landed only in their own pane and committed. |

### iTerm2

The lab used one new iTerm2 window: tab 1 the Zellij client (`/dev/ttys012`), tab 2 the decoy, tab 3 a shell. The operator's other iTerm2 windows were left alone, and iTerm2 was never quit. Automation was already granted.

| Line | Result | Observed |
| --- | --- | --- |
| H3 | PASS | Claude and Codex Open: iTerm2 frontmost on tab 1, client on the right pane, acknowledged after the visit. About 6 s from click to tab. |
| H4 | PASS with note | Codex's 4 s manual visit was acknowledged. Claude's 4 s visit was missed twice; held 9 s, it was acknowledged. iTerm2's scans are slow enough to miss a short visit. |
| H5 split | PASS | iTerm2 raised on the same tab, Zellij did not move, nothing acknowledged. |
| H6 | PASS | Same lines as WezTerm's. |
| H7 closed pane | DEVIATION | `close-pane` on a throwaway Claude pane (`ender-03`). No `SessionEnd` arrived, and the row read "Open is unavailable until Herdly can verify this Claude session is live." rather than "This session has ended.", as WezTerm's and tmux's ([#285](https://github.com/r-curio/herdly/issues/285)). |
| H7 quit | Not run | iTerm2 was not quit, because the operator's own sessions run there. |
| H8 | DEVIATION | iTerm2's switch off. Claude: Open moved the client to `terminal_2`, then raised iTerm2 on the decoy tab; not acknowledged. Codex: Open moved the client to `terminal_1` and raised nothing. Zellij's focus changed without the pane being shown (Findings). |
| H9 replies | PASS | Codex CHARLIE3 landed only in `terminal_1`. Zellij types into the pane, so iTerm2's own no-typing rule does not apply. |

### Terminal.app

Terminal.app had windows for the Zellij client (`/dev/ttys050`) and the decoy (`/dev/ttys051`). Terminal also restored four earlier windows when it launched, two carrying old Codex titles; they were left alone.

| Line | Result | Observed |
| --- | --- | --- |
| H3 | PASS | Finder in front, Terminal's decoy window in front of the client's. Claude and Codex Open: Terminal frontmost on the client's window, client on the right pane, acknowledged. 6–7 s from click to window with iTerm2's switch also on, and quicker with it off. Two earlier checks taken at 4 s looked like fallbacks; both Opens completed later. |
| H4 | PASS | Manual 9 s visits to each pane, with Terminal in front on the client's window, acknowledged both queued completions. |
| H5 split | PASS | A second pane in the Codex tab: Terminal raised, Zellij did not move, nothing acknowledged. |
| H7 quit | PASS with note | Terminal quit (its "terminate running processes" alert answered Terminate Processes, for the lab's two windows) and stayed closed for 30 s with Herdly running. Both rows read "Herdly can't tell which terminal this session is in.", as in WezTerm. |
| H8 | DEVIATION | Terminal's switch off: the same result as iTerm2's H8 for both agents. |
| H9 replies | PASS | Codex LIMA3 typed through the card landed only in `terminal_1` and committed. The Claude reply field did not appear on the arrival card during the run; Claude's reply passed in WezTerm. |

## Findings

1. **The host-title veto is met only after a focused pane sets a title.** Zellij writes `<session> | <title>` to its host when the focused pane sends a title. After an attach, and after a new pane opened, the host read the session name alone (`lab`), and switching tabs did not set it. Claude panes carry no title ("Pane #1"), and Codex does not resend its title. So in ordinary use an Open falls back (raises the host app, nothing moved) until some focused pane prints a title. The fallback is safe, but Open rarely reaches the exact pane.
2. **With the host switch off, Open can move Zellij's focus without showing it.** When no enabled terminal lists the client's tty and Ghostty lists tabs without a tty, the join answers Ghostty, so `focus-pane-id` likely runs before the Ghostty raise fails (Source inspection). Seen in iTerm2 and Terminal.app for both agents; WezTerm's Codex H8 is likely the same.
3. **Open is slow with several hosts on.** With iTerm2 and Terminal.app both switched on, Open took 6–7 s from click to window, and iTerm2's slow scans can miss a manual visit under about 9 s.
4. **Notch:** once, the notch stayed open with no rows until its header was clicked.
5. **Keychain prompt:** every build raised it ([#367](https://github.com/r-curio/herdly/issues/367)).

## Not run

- No operator looked at any line; every check was the agent's.
- Quitting iTerm2 (H7), to keep the operator's sessions running.
- A Ghostty host (no Ghostty with `tty` on this Mac).
- The cross-host line (same Codex title in two apps).
- A Zellij older than 0.44.1, for the version line.

## Decisions

Open for the operator, each with a recommendation:

- **H7 with no client:** accept, as for tmux. With the host app quit, the pane has no client and reads "Herdly can't tell which terminal this session is in."
- **Title veto (Finding 1):** accept for now; follow-up [#369](https://github.com/r-curio/herdly/issues/369). Open falls back safely; the follow-up should find a way to meet ADR 0014's title check without the user printing a title.
- **H8 focus move (Finding 2):** accept for now; follow-up [#370](https://github.com/r-curio/herdly/issues/370). The join should not answer Ghostty for a client tty that belongs to a switched-off host's app.
- **Short visits in iTerm2 (Finding 3):** accept. Same pattern as tmux's iTerm2 run.
- **Closed pane without `SessionEnd`:** tracked with [#285](https://github.com/r-curio/herdly/issues/285).
- **Digit gate:** on, from the CLI-level proof and Herdly's own route (H9).
