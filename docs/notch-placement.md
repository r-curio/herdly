# Notch placement and keyboard interaction — issue #12

Status: implemented and checked in the built app on a single built-in notch display. Agreed behavior is in [product.md](product.md); the pure rules live in `Sources/SteerCore/NotchPlacement.swift`. The two-display and display-disconnect cases are covered by focused tests and by the operator walkthrough below, which has not yet been recorded on a second display.

Revision (hover-expand notch): the panel is one black shape with concave ears at its top corners. On a display with a camera housing the collapsed strip is the housing row itself: exactly the housing height, anchored to the top edge of the screen, with a 112-point wing left of the housing for one sprite per session (at most three, in priority order, each in a color that stays with the session, stepping while that session works) followed by a "+N" mark for further sessions and the to-check count, and a 60-point wing right of it for the Codex weekly limit readout (see [Codex weekly limit](codex-usage.md)); the name is read in the open queue, not the strip (`NotchPlacement.strip`); on any other display the strip is inline with the menu bar row that is actually showing there (as tall as the bar, anchored to the top edge, centered where the bar is empty), or 40 points tall at the top edge when that display has no menu bar (a full-screen app, or an auto-hidden bar); the menu bar height comes from the window server's menu bar window on that display (`NotchDisplay.shownMenuBarHeight`), not from `visibleFrame`, which reserves the strip whether or not the bar is showing. The collapsed strip shows the sprites, the to-check badge (`StripSummary`), and the weekly limit (`CodexWeeklyLimit`). Hover expands it (`HoverHold` keeps it open for 0.3 s after the pointer leaves); a new completion or request opens only its own card for three seconds (`Spotlight`), and the open panel is exactly as tall as its measured content, capped at 380 points. Older statements below about a margin below the housing, a 210-point collapsed width, click-to-expand, or whole-queue popups are superseded by this revision; the display-selection, freeze-while-interacting, Escape, and accessibility-label rules stand.

## One panel, one queue

Steer creates exactly one `NotchPanel` and one `AttentionQueue`. Every display change re-runs placement of that same panel; nothing is duplicated per display, and no queue state is keyed by display. The panel is configured to join all Spaces as a full-screen auxiliary window at status-bar level; the probe records those flags, and whether it actually appears over full-screen apps and on every Space is walkthrough step 7, not yet verified live.

## Active-display rule

`NotchDisplaySelection.choose(displays:pointer:current:interacting:)` decides where the panel goes on every refresh (five times a second and on app activation or screen-parameter changes):

1. **Interacting → freeze.** While the pointer is over the panel or the panel has keyboard focus, keep the display the panel is already on. Controls never move to another display mid-click or mid-Tab; expanding or collapsing still resizes the panel in place. The app confirms the hover flag against the real pointer location, so a panel re-placed out from under the pointer does not stay frozen.
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
- **Deliberate focus.** Clicking the panel gives it key status without activating Steer; Tab from another app cannot reach a non-activating panel of another process, so keyboard-only entry needs a hotkey, which is deferred. Once the panel is key, Tab and Shift-Tab move between the header button, Approve once, Deny, Open in Codex, Dismiss, and Show full request; the expanded list is a focus section. Buttons use the standard bordered style so macOS draws its focus ring; the plain-style header button draws its own visible ring while focused.
- **Escape.** `NotchPanel.cancelOperation` collapses every presentation (`Attention.collapse()`, which never dismisses) and, if the panel was key, orders it out and re-activates the frontmost app so keyboard input returns to it. The next refresh shows the collapsed panel again.
- **Labels.** Each row is an accessibility container labeled with its kind and subject (task name when Codex provided one, otherwise the shortened session ID). Every button's label names its action and subject, for example "Approve once: deploy, session 01a0916c-337b". The header reads the working and to-check counts and says whether the queue is expanded.
- **Long details.** Task, project, action, command, and reason wrap in full with no line limit; the full request stays behind Show full request. A shortened command is never presented as the complete action.

## Automated checks

`swift test` (97 tests). New in `Tests/SteerCoreTests/NotchPlacementTests.swift`: pointer display chosen when idle; placement frozen on the current display while interacting; a disconnected current display falling back even while interacting; pointer off every display keeping the current display, then the first, then nil with no displays; collapsed frame below the physical housing and centered; the compact top-center panel on a non-notch display; the expanded height cap; pointer or keyboard focus counting as interaction; interaction holding a completion open without extending the approval deadline; and Escape collapsing without dismissing.

## Hidden menu bar (2026-09-14)

Reported on an external 3440 × 1440 display with Chrome in full screen: the strip floated 30 pt below the top edge, over Chrome's tab bar, with its ears fused to nothing. `visibleFrame` still reserved the menu bar strip although no menu bar was showing. Fixed by reading the menu bar height from the window server's menu bar windows (owner Window Server at the main-menu level, on screen), which exist only on displays currently showing a bar. First checked live with the strip fused under the bar; the user then asked for it inline with the bar, so the strip is now the menu bar row itself on an external display, as it is the housing row on the built-in one. `displayWithoutAShownMenuBarPutsTheStripAtTheTopEdge` and `shownMenuBarHeightComesFromTheMenuBarWindowOnThatDisplay` cover the rule.

## Key status at launch (2026-09-14)

Launching the app (Finder, `open`, a login item) activates it and AppKit makes the panel key, which counted as keyboard interaction: placement froze, the spotlight never closed, and the tucked strip never tucked. `NotchPanel.hasDeliberateKeyboardFocus` now counts key status only after the user has clicked in the panel (`clickedForKey`, cleared when the panel resigns key). Escape and the collapse path are unchanged.

## Tucked strip on a full-screen display (2026-09-14)

Follow-up to the report above: even at the top edge the strip covered the tab row of a full-screen browser. On an external monitor that shows no menu bar the strip now rests entirely above the screen edge (`NotchTuck`), like the hidden menu bar, and slides in (the usual 0.18 s ease-out) while the pointer is within 3 pt of the top edge or over the panel, while the panel has keyboard focus, or while the panel is open, so a new completion, request, or question still shows itself for its three-second spotlight and then tucks away. External monitors with a menu bar and the built-in display (notch or not) are unchanged; `NotchDisplay.isBuiltIn` comes from `CGDisplayIsBuiltin`. `stripTucksAboveAFullScreenDisplayUntilThePointerTouchesTheTopEdgeOrThePanelOpens` covers the rule.



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
2. **Freeze during interaction.** Expand the panel on the external display, hover over a button, and move the pointer's display by dragging past the edge while staying over the panel: it does not jump. Click the panel on the built-in display so it has keyboard focus, then move the pointer to the other display: it stays put until Escape returns focus.
3. **Disconnect and reconnect.** With the panel on the external display, unplug it. The panel appears once on the built-in display with the same queue and no new sound. Reconnect: the panel follows the pointer again; nothing is duplicated or replayed.
4. **Deadline independence.** Trigger a CLI approval in the lab, hover over the panel, and keep the pointer there past 30 s: the row changes to Continue in Codex on time while the popup stays open.
5. **Keyboard.** With another app active, wait for a completion: the other app keeps keyboard focus. Click the panel, press Tab repeatedly: the focus ring moves through the controls and is visible on each. Press Escape: the panel collapses and typing goes to the previous app.
6. **VoiceOver.** Turn VoiceOver on and navigate the expanded panel: each row announces its kind and subject, each button its action and subject, and a long command reads in full.
7. **Spaces and full screen.** Open a full-screen app and switch Spaces: the panel shows over the full-screen app and on each Space, once.

## Boundaries

- "Actively using" means the display under the pointer. Keyboard-only users on a multi-display setup get the pointer's display; a rule based on the key window's display is deferred until it is needed.
- Escape is the only keyboard collapse; there is no global hotkey to open or focus the panel, so keyboard-only users must click it once.
- `--assume-codex-away` and `--placement-probe` are lab flags compiled into the app like `--restart-report`; they change nothing unless passed.
- Focus rings depend on macOS Full Keyboard Access for Tab to reach buttons, as in any macOS app.
- The probe proves geometry and key status on this machine; it cannot attach or detach a display.
