# iTerm2 acceptance

Recorded 2026-10-13 for [Accept iTerm2 live and turn its switch on](https://github.com/r-curio/steer/issues/243): the [MVP acceptance §3d](../mvp-acceptance.md#3d-terminal-host-acceptance) table run against packaged builds with iTerm2. The agent drove the run; the operator approved macOS prompts and confirmed card, Open and acknowledgment lines by looking. The operator accepted iTerm2 on 2026-10-13 with the results below, the lines marked not run included, and asked for its Settings card to be shown and for §3d's H4 and H6 wording to match the agreed rules. The earlier capability proof, with no Steer code path, is [iTerm2 live targeting proof](iterm2-live.md).

## Setup and versions

- iTerm2 3.7.4, Codex CLI 0.162.1, Claude Code 2.1.296, Ghostty 1.3.1.
- Builds, all unsigned development packages (`sh scripts/package-app.sh`):

| Build | Commit | `sha256` of the zip | Used for |
| --- | --- | --- | --- |
| 447 | d47ebb2 (main head when packaged with `scripts/package-app.sh` earlier in the session) | not recorded | First H2 decoy attempt. |
| 451 | 37bef81 (#266 merged) | `108b1227f4a6d3406b45dfeb9ed7fd3fa1843bbaa1749db9bf9a3d004c94fa3b` (`Steer-0.1.0+451-unsigned-dev.zip`) | H1, H2 first attempts, H3, H6 first attempt. |
| 456 | 0e2ee0e (#269 merged) | `58f59e58c24f0047cdffdb5986dbf9abfc860c2620bf05a174733f1ef1952269` (`Steer-0.1.0+456-unsigned-dev.zip`) | H6 rerun, H8, H9 Codex reply, H7 first attempt. |
| 464 | 638a31f (`fix/270`, on feb27a5; includes #268 and #271) | `9f8df666a36767823e848c74ef3f97f50c2701131a3fc60171d7d39d69ad9981` | H2 decoy rerun, H7, H9 Claude, #270 live checks. |

- Lab caveats:
  - Lab Codex sessions ran with `-m gpt-6-luna` for the session only, because the user's default model (gpt-6.1-sol) was rejected for the ChatGPT account. No Codex configuration was changed.
  - iTerm2 launched from the agent's shell inherited `CLAUDE_CODE_CHILD_SESSION`, so Claude there saved no transcript and the TANGO session never reached Steer. iTerm2 was relaunched with a clean environment, as the [earlier proof](iterm2-live.md#lab-hazards-found) warns.
  - The iTerm2 card was hidden in every build under test, so the switch was turned on and off through its stored preference (`iTerm2HostEnabled`), not from Settings.
  - Hovering expands the notch for Accessibility, but card text and buttons are not exposed to Accessibility and `screencapture` does not capture the expanded notch. Card lines therefore rest on the operator's reading.
  - Lab Codex and Claude sessions ended when iTerm2 quit (H7).

## Source inspection

- The iTerm2 card ([`ControlsView.swift`](../../Sources/SteerApp/ControlsView.swift) `ITerm2Controls`) has the switch, Automation permission badge (Allowed, Not allowed or Not verified, with Open Settings… on a denial), status badge (`ITerm2Presentation.settingsRow`: Off, Not in use, Ready or Needs attention), problem lines, Show diagnostics and the footer, as [product.md's card rules](../product.md#settings) require. This change adds the Version row and shows the card (`TerminalHost.showsCard`).
- What H6 shows depends on what finds the Automation denial. Steer's permission check (at start, when the switch is turned on, or when iTerm2 launches; `Companion+ITerm2.swift`) turns the switch back off, per product.md's Settings › Permission rule, so the card shows the switched-off line. A denial met by a scan while the switch is on marks iTerm2 unreadable, and one met by an Open maps to `.hostUnreadable(.iTerm2)` (`ITerm2.swift`, `ITerm2Navigation.swift`); both show "Steer can't read iTerm2. Check Settings › Terminals." This run reached only the first path (see H6).
- H4's results follow [ADR 0016](../adr/0016-open-and-acknowledge-visits-the-same-way-on-every-terminal-host.md)'s manual-visit rule: a switch to the tab acknowledges completions that arrived before it, however short. §3d's earlier H4 text ("the short visit acknowledges nothing") contradicted ADR 0016 and is corrected in the same change.

## Automated checks

Run 2026-10-13 on this change's head (`feat/243-accept-iterm2`): `swift test` passed 1023 tests; `sh scripts/build-app.sh` built `output/Steer.app`; `output/Steer.app/Contents/MacOS/Steer --smoke-test` passed ("Steer controls-window smoke check passed."); `git diff --check` against `origin/main` was clean. `TerminalHostsTests` now expects the Ghostty, iTerm2 and herdr cards shown and Terminal.app, WezTerm, tmux and Zellij hidden. The fixes below each carried their own tests.

## Live application proof

| Line | Build | Result | Observed |
| --- | --- | --- | --- |
| H1 | 451 | PASS with note | Switch turned on through its stored preference (card hidden). The Automation prompt was not observed; access was evidently granted, since Opens worked. The Settings badge was not checked (card hidden). |
| H2 | 464 | PASS with note | First attempts (447, 451): a decoy tab with the Codex title and no `codex` made Codex Open refuse silently (ADR 0013 uniqueness; ADR 0015's fallback cannot walk a decoy), and no line rendered. Fixed by #268 (decision A) and #267. Rerun on 464: decoy tab 3 with the Codex title and no `codex`; Open on OSCAR selected the Codex tab 1; operator: "works as expected". Claude's binding is shown by H3. Visits with the decoy present were not separately checked; iTerm2 has no typed input to test against it. |
| H3 | 451 | PASS with note | Fresh window 19965, no decoy: Codex Open selected the correct iTerm2 tab and Claude Open the correct tab; operator: "both works". `attention-snapshot` showed the ALPHA turn 01A133D6-668A acknowledged after Open. Note: an earlier Claude Open on the same build, with the older window, selected a Ghostty tab ("…: Steer"); which card was pressed is unconfirmed. |
| H4 | not recorded (run before the build 456 rerun) | PASS | Agent-driven through AppleScript, checked through `attention-snapshot` outcomes: Codex ~2 s visit acknowledged; Claude ~2 s visit acknowledged; Codex ~10 s visit acknowledged. A short visit acknowledging is ADR 0016's rule; §3d's earlier H4 text is superseded. Dwell (a completion arriving while the tab is in front) not run. |
| H5 | not recorded (run before the build 456 rerun) | PASS with note | Codex tab split, Claude tab showing, Finder in front: Open on HOTEL raised iTerm2 on the Claude tab and the card stayed; operator: "works as expected". GOLF, from an earlier H5 attempt, shows acknowledged; the cause is unconfirmed by the operator. The typed-input line was not checked. |
| H6 | 456 | PASS with note | First attempt (451) failed: with Steer → iTerm2 Automation turned off, the Codex card showed no line and Open did nothing visible (no view showed the navigation message since a20f994, and there was no scan-time line). Fixed by #267. Rerun on 456 with Automation denied: Steer turned iTerm2's switch off (`iTerm2HostEnabled` = 0), per product.md's "a denial turns the switch back off"; the Codex card replaced Open with "Steer can't tell which terminal this session is in." (the switched-off line, as in H8). The reply field stayed (daemon-held thread). The "Steer can't read iTerm2…" path (a denial met by a scan or an Open while the switch is on, or a scripting error) was not reached in this run. Settings half not run (card hidden). |
| H7 | 464 | PASS | First attempt (456) failed: quitting iTerm2 with Steer running relaunched it (pid 43611, "Tips of the Day"); with Steer stopped it stayed closed 45 s; starting Steer with iTerm2 closed did not launch it. Fixed by #270. Part 1 on 464: the quit lab kept iTerm2 closed for 120 s and for 30 s with Steer running, and the ROMEO card showed "iTerm2 isn't running." (operator). Part 2 on 464: after the agent reopened iTerm2 with `open -a iTerm` (Steer did not launch it) and the SIERRA Codex tab was closed, the card showed "This session has ended." (operator). |
| H8 Codex | 456 | PASS | Switch off: "Steer can't tell which terminal this session is in." |
| H8 Claude | 456 | PASS with note | Switch off: Open raised iTerm2 without changing tab (the Codex tab stayed). The card's offer to turn the host back on is not built (product.md puts it on the Settings card; owned by [#248](https://github.com/r-curio/steer/issues/248)): not run. |
| H9 Codex reply | 456 | PASS with note | With iTerm2 off, the card's reply "kilo" reached Codex through the daemon (the KILO turn ran 07:09:07–07:09:10Z), but the card said "Sent “kilo”, but Codex has not started a turn. Check Codex; Steer will not resend.", which was false. Fixed by #271. Not typed into iTerm2 (ADR 0017). |
| H9 Codex question | — | not run | No Codex question was available; the account's quota was low. |
| H9 Claude | 464 | open question | The UNIFORM card (Claude in iTerm2) showed Open Session and Dismiss, no reply field and no "Steer can't type into iTerm2. Reply in the session." line. `ClaudeReplyRouting` offers no field when no typed-reply host is on. See open questions. |
| iTerm2: no typed input | 464 | open question | No input was typed into iTerm2. The "Steer can't type into iTerm2…" line was not seen on any card; for Claude, see H9. For Codex, the line replaces question keys and the reply reason only while the daemon does not hold the session; the Codex sessions checked were daemon-held (for example the H6 rerun session, whose reply field stayed). |
| iTerm2: its own Claude Code integration on | — | not run | |
| Once, across hosts: same Codex title in two apps | — | not run | |
| #270 live checks | 464 | PASS | Ghostty Open from the notch (operator); iTerm2 Open past a decoy; quit lab three times. |

Observed, not a confirmed defect: the INDIA completion (01A13411) was acknowledged before the operator saw it. The frontmost log showed the operator switching apps, so the operator likely visited iTerm2.

## Not run

- H1's Settings badge and H6's Settings half (the card was hidden in every build under test).
- H4's dwell case.
- H5's typed-input line.
- H6's "Steer can't read iTerm2…" path: a denial met by a scan or an Open while the switch is on, or a scripting error.
- H8's offer to turn iTerm2 back on (not built; #248).
- H9 Codex question keys.
- iTerm2's own Claude Code integration turned on alongside Steer's hooks.
- The cross-host line (same Codex title in two apps).

## Defects found and fixed

| Issue | Pull request | Found in | Fix |
| --- | --- | --- | --- |
| [#265](https://github.com/r-curio/steer/issues/265) | [#266](https://github.com/r-curio/steer/pull/266) (37bef81) | Before H3 | Daemon Codex sessions in a host other than Ghostty were marked ended. |
| [#267](https://github.com/r-curio/steer/issues/267) | [#269](https://github.com/r-curio/steer/pull/269) (0e2ee0e) | H2, H6 | Open's unavailable reason had no view on terminal cards. |
| [#268](https://github.com/r-curio/steer/issues/268) | [#272](https://github.com/r-curio/steer/pull/272) (09852ff) | H2 | A title decoy with no `codex` blocked the Codex binding. The user chose option A: ignore such decoys. |
| [#270](https://github.com/r-curio/steer/issues/270) | [#275](https://github.com/r-curio/steer/pull/275) (87e5eb1) | H7 | Steer relaunched a terminal app that quit during a scan. |
| [#271](https://github.com/r-curio/steer/issues/271) | [#274](https://github.com/r-curio/steer/pull/274) (feb27a5) | H9 | A Codex reply whose turn finished between scans was reported as never started. |

Follow-up, open: [#273](https://github.com/r-curio/steer/issues/273) "Acknowledge and confirm replies from prompt records for every session".

## Open questions

- **H9 Claude line.** A Claude card in iTerm2 shows no reply field and no "Steer can't type into iTerm2. Reply in the session." line while no typed-reply host is on. product.md lists the line but not when it shows. Should it show there?
- **Confirmed-reply copy.** The new confirmation "Sent “X”. Codex started a turn after your reply." (#271) needs product sign-off.
- **H8 Claude offer.** The card's offer to turn a switched-off host back on belongs to [#248](https://github.com/r-curio/steer/issues/248).
