# Notch placement and keyboard interaction — issue #12

Status: implemented and checked in the built app on a single built-in notch display. Agreed behavior is in [product.md](product.md); the pure rules live in `Sources/SteerCore/NotchPlacement.swift`. The two-display and display-disconnect cases are covered by focused tests and by the operator walkthrough below, which has not yet been recorded on a second display.

## One panel, one queue

Steer creates exactly one `NotchPanel` and one `AttentionQueue`. Every display change re-runs placement of that same panel; nothing is duplicated per display, and no queue state is keyed by display. The panel joins all Spaces and is a full-screen auxiliary window at status-bar level, so it appears over full-screen apps and on every Space without being copied.

## Active-display rule

`NotchDisplaySelection.choose(displays:pointer:current:interacting:)` decides where the panel goes on every refresh (five times a second and on app activation or screen-parameter changes):

1. **Interacting → freeze.** While the pointer is over the panel or the panel has keyboard focus, keep the display the panel is already on. Controls never move away mid-click or mid-Tab.
2. **Otherwise the display under the pointer.** This is the display the user is actively using.
3. **Pointer on no display → keep the current display.**
4. **No current display → the first attached display.**

A display that has disconnected is never chosen, even while interacting: the rule falls through to the pointer, then the first display. `NSApplication.didChangeScreenParametersNotification` triggers a refresh, so connect, disconnect, and rearrangement re-place the panel within one refresh.

## Geometry

`NotchPlacement.frame(on:expanded:rows:extraRows:)` is pure. On a display with a physical camera housing (`safeAreaInsets.top` > 0) the panel's top edge sits 6 pt below the housing; on a display without one it sits 12 pt below the top edge as a compact top-center panel. Width is 210 pt collapsed and 380 pt expanded; expanded height grows 65 pt per row from 150 pt and is capped at 380 pt, with the row list scrolling beyond that.

## Interaction and timers

`NotchInteraction.isActive(pointerInside:keyboardFocus:)` is the single definition of "the user is interacting". It freezes placement and keeps a completion popup open. It does not touch `AttentionRequest.expiresAt`: the approval handoff deadline is absolute from companion receipt and `AttentionQueue.expire(at:)` ignores presentation entirely. `interactionKeepsACompletionOpenButNeverExtendsAnApprovalDeadline` holds a popup open through 35 s of alternating pointer and keyboard interaction while the request hands back at exactly 30 s. Outside interaction, the completion popup collapses three seconds after it last expanded.

## Keyboard and accessibility

- **Automatic notifications never take input.** Presentation uses `orderFrontRegardless`, which shows the panel without making it key; the panel is a non-activating panel, so Steer itself never activates. The probe below records `is_key_after_presentation: false` with the panel visible.
- **Deliberate focus.** Clicking a control or Tabbing into the panel gives it key status without activating Steer. Tab and Shift-Tab move between the header button, Approve once, Deny, Open in Codex, Dismiss, and Show full request; the expanded list is a focus section. Buttons use the standard bordered style so macOS draws its focus ring; the plain-style header button draws its own visible ring while focused.
- **Escape.** `NotchPanel.cancelOperation` collapses every presentation (`Attention.collapse()`, which never dismisses) and, if the panel was key, orders it out and re-activates the frontmost app so keyboard input returns to it. The next refresh shows the collapsed panel again.
- **Labels.** Each row is an accessibility container labeled with its kind and subject (task name when Codex provided one, otherwise the shortened session ID). Every button's label names its action and subject, for example "Approve once: deploy, session 01a0916c-337b". The header reads the working and to-check counts and says whether the queue is expanded.
- **Long details.** Task, project, action, command, and reason wrap in full with no line limit; the full request stays behind Show full request. A shortened command is never presented as the complete action.

## Automated checks

`swift test` (97 tests). New in `Tests/SteerCoreTests/NotchPlacementTests.swift`: pointer display chosen when idle; placement frozen on the current display while interacting; a disconnected current display falling back even while interacting; pointer off every display keeping the current display, then the first, then nil with no displays; collapsed frame below the physical housing and centered; the compact top-center panel on a non-notch display; the expanded height cap; pointer or keyboard focus counting as interaction; interaction holding a completion open without extending the approval deadline; and Escape collapsing without dismissing.

## Placement probe (2026-09-13)

`Steer --placement-probe <path>` enqueues an in-memory test item, refreshes once, records the attached displays, the chosen display, the frames the rules would use, the panel's actual frame and key status, and quits. `--assume-codex-away` is a lab override for a machine where Codex desktop is foreground; `--attention-snapshot` isolates the snapshot. Nothing is written to UserDefaults or Codex configuration. Result: [evidence/notch-placement.json](evidence/notch-placement.json).

| Check | Result |
| --- | --- |
| Displays attached | One, built-in, 1512 × 982 pt, housing inset 32 pt |
| Collapsed top edge | 944 pt = 982 − 32 − 6, below the housing, centered at x 651–861 |
| Presented panel | Visible, expanded to 230 pt for the test item, top edge 944 pt |
| Key after automatic presentation | No |
| Panel flags | Non-activating, joins all Spaces, full-screen auxiliary, status-bar level |
| Smoke check | `--smoke-test` controls-window check passed on the same build |

## Operator walkthrough (to record before release)

Not performed by the agent: it needs a second display, Mission Control, and the keyboard, which are outside the permitted automation. Run it with Steer connected to an isolated lab as in [restart recovery](restart-recovery.md) and record each line as pass, fail, or uncertain.

1. **Two displays.** Attach an external monitor. Send a test notification. Move the pointer between displays: the panel follows the pointer and appears exactly once, below the housing on the built-in display and top-center on the external one.
2. **Freeze during interaction.** Expand the panel on the external display, hover over a button, and move the pointer's display by dragging past the edge while staying over the panel: it does not jump. Tab into the panel from the built-in display and move the pointer to the other display: it stays put until focus leaves.
3. **Disconnect and reconnect.** With the panel on the external display, unplug it. The panel appears once on the built-in display with the same queue and no new sound. Reconnect: the panel follows the pointer again; nothing is duplicated or replayed.
4. **Deadline independence.** Trigger a CLI approval in the lab, hover over the panel, and keep the pointer there past 30 s: the row changes to Continue in Codex on time while the popup stays open.
5. **Keyboard.** With another app active, wait for a completion: the other app keeps keyboard focus. Click the panel, press Tab repeatedly: the focus ring moves through the controls and is visible on each. Press Escape: the panel collapses and typing goes to the previous app.
6. **VoiceOver.** Turn VoiceOver on and navigate the expanded panel: each row announces its kind and subject, each button its action and subject, and a long command reads in full.
7. **Spaces and full screen.** Open a full-screen app and switch Spaces: the panel shows over the full-screen app and on each Space, once.

## Boundaries

- "Actively using" means the display under the pointer. Keyboard-only users on a multi-display setup get the pointer's display; a rule based on the key window's display is deferred until it is needed.
- Escape is the only keyboard collapse; there is no global hotkey to open the panel.
- Focus rings depend on macOS Full Keyboard Access for Tab to reach buttons, as in any macOS app.
- The probe proves geometry and key status on this machine; it cannot attach or detach a display.
