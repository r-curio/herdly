# Notch placement and keyboard interaction — issue #12

Status: implemented and checked in the built app on a single built-in notch display. Agreed behavior is in [product.md](product.md); the pure rules live in `Sources/SteerCore/NotchPlacement.swift`. The two-display and display-disconnect cases are covered by focused tests and by the operator walkthrough below, which has not yet been recorded on a second display.

Revision (hover-expand notch): the panel is one black shape with concave ears at its top corners. On a display with a camera housing the collapsed strip is the housing row itself: exactly the housing height, anchored to the top edge of the screen, with a 112-point wing left of the housing for one sprite per session (at most three, in priority order, each in a color that stays with the session, stepping while that session works; the unlit sprite while no session is listed) followed by a "+N" mark for further sessions and the to-check count, and a 60-point wing right of it for the Codex weekly limit readout, 112 points while Codex also reports a five-hour window and its readout sits ahead of the weekly one (see [Codex usage limits](codex-usage.md)), and 62 points more for each current Claude five-hour or seven-day readout ahead of those, plus 4 points between the two groups (see [Claude usage](claude-usage.md); `UsageStripReadouts.wingWidth`); the name is read in the open queue, not the strip (`NotchPlacement.strip`); on any other display the strip is inline with the menu bar row that is actually showing there (as tall as the bar, anchored to the top edge, centered where the bar is empty), or 40 points tall at the top edge when that display has no menu bar (a full-screen app, or an auto-hidden bar); the menu bar height comes from the window server's menu bar window on that display (`NotchDisplay.shownMenuBarHeight`), not from `visibleFrame`, which reserves the strip whether or not the bar is showing. The collapsed strip shows the sprites, the to-check badge (`StripSummary`), and the usage limits (`CodexUsageReading`, then the newest current `ClaudeUsageReading`). Hover expands it (`HoverHold` keeps it open for 0.3 s after the pointer leaves); a new completion or request opens only its own card for three seconds (`Spotlight`), and the open panel is exactly as tall as its measured content, capped at 480 points, and 60 points wider than the collapsed strip, half on each side, never narrower than 380 points, so hovering visibly widens it whatever usage readouts are shown (`NotchPlacement.expandedGrowth`); the per-profile Wide and Extra wide panel widths grow it by 160 or 260 points instead, never narrower than 480 or 580 points, and never past 16 points from either side of the display (`PanelWidth`). Older statements below about a margin below the housing, a 210-point collapsed width, a 380-point expanded width, click-to-expand, or whole-queue popups are superseded by this revision; the display-selection, freeze-while-interacting, Escape, and accessibility-label rules stand.

## One panel, one queue

Steer creates exactly one `NotchPanel` and one `AttentionQueue`. Every display change re-runs placement of that same panel; nothing is duplicated per display, and no queue state is keyed by display. The panel is configured to join all Spaces as a full-screen auxiliary window at status-bar level; the probe records those flags, and whether it actually appears over full-screen apps and on every Space is walkthrough step 7, not yet verified live.

## Active-display rule

`NotchDisplaySelection.choose(displays:pointer:current:interacting:preference:)` decides where the panel goes on every refresh (five times a second and on app activation or screen-parameter changes):

1. **Interacting → freeze.** While the pointer is over the panel or the panel has keyboard focus, keep the display the panel is already on. Controls never move to another display mid-click or mid-Tab; expanding or collapsing still resizes the panel in place. The app confirms the hover flag against the real pointer location, so a panel re-placed out from under the pointer does not stay frozen.
2. **Pinned → the pinned display.** With a pin (see [Pinned display](#pinned-display-2026-10-08)), the pinned display wherever the pointer is; while it is not attached, the built-in display. With neither attached, the steps below apply.
3. **Otherwise the display under the pointer.** This is the display the user is actively using.
4. **Pointer on no display → keep the current display.**
5. **No current display → the first attached display.**

A display that has disconnected is never chosen, even while interacting: the rule falls through to the pointer, then the first display. `NSApplication.didChangeScreenParametersNotification` triggers a refresh, so connect, disconnect, and rearrangement re-place the panel within one refresh.

## Geometry

`NotchPlacement.frame(on:expanded:rows:extraRows:)` is pure. On a display with a physical camera housing (`safeAreaInsets.top` > 0) the panel's top edge sits 6 pt below the housing; on a display without one it sits 12 pt below the top edge as a compact top-center panel. Width is 210 pt collapsed and 380 pt expanded; expanded height grows 65 pt per row from 150 pt and is capped at 380 pt, with the row list scrolling beyond that.

## Pinned display (2026-10-08)

The user can keep the notch on one display instead of following the pointer. The default is Follow pointer, so nothing changes until a display is chosen.

- **Choosing.** The General page of the controls window has a Notch display picker, and the S menu bar item has a Show notch on submenu. Both list Follow pointer, then each attached display by its macOS name, left to right (`NotchDisplayChoices`). Two displays with the same name are numbered in that order. Choosing an option re-places the panel at once; the queue, presentations, and approval deadlines are untouched.
- **Identity.** A pin is the display's UUID (`CGDisplayCreateUUIDFromDisplayID`), which survives reboots and reconnects where the display number does not, plus the label shown when it was chosen. Both are stored in UserDefaults as `notchDisplayPinID` and `notchDisplayPinName`; a missing or empty identifier means Follow pointer. A display the system reports no UUID for is not offered.
- **Pinned display not connected.** The notch shows on the built-in display, or follows the pointer when there is no built-in display (a closed lid). The pin is kept: the pickers list it as "*name* (not connected)", and the notch returns to it when it reconnects. The setting's detail line says which of these applies, naming the display as the picker does.
- **Unchanged rules.** Interaction still freezes placement first, so a pinned display that reconnects mid-click does not pull the panel away until the interaction ends. A pinned external monitor showing no menu bar still tucks the strip, and only the pointer at that display's top edge reveals it; a new item's spotlight still slides it in.
- **Probe.** `--placement-probe` records each display's `persistent_id`, `name`, and `built_in`, and the `display_preference`. Launch arguments `-notchDisplayPinID <uuid> -notchDisplayPinName <name>` set a pin for that launch only through the UserDefaults argument domain, without saving anything.

## Interaction and timers

`NotchInteraction.isActive(pointerInside:keyboardFocus:)` is the single definition of "the user is interacting". It freezes placement and keeps the active single-item spotlight open; passive hover does not replace that spotlight with the full queue. Header activation explicitly opens the queue. Interaction does not touch `AttentionRequest.expiresAt`: the approval handoff deadline is absolute from companion receipt and `AttentionQueue.expire(at:)` ignores presentation entirely. `interactionKeepsACompletionOpenButNeverExtendsAnApprovalDeadline` holds a popup open through 35 s of alternating pointer and keyboard interaction while the request hands back at exactly 30 s. Outside interaction, the completion popup collapses three seconds after it last expanded.

## Keyboard and accessibility

- **Automatic notifications never take input.** Presentation uses `orderFrontRegardless`, which shows the panel without making it key; the panel is a non-activating panel, so Steer itself never activates. The probe below records `is_key_after_presentation: false` with the panel visible.
- **Deliberate focus.** Clicking the panel gives it key status without activating Steer; Tab from another app cannot reach a non-activating panel of another process, so keyboard-only entry needs a hotkey, which is deferred. Once the panel is key, Tab and Shift-Tab move between the header button, Approve once, Deny, Open in Codex, Dismiss, and Show full request; the expanded list is a focus section. Buttons use the standard bordered style so macOS draws its focus ring; the plain-style header button draws its own visible ring while focused.
- **Escape.** `NotchPanel.cancelOperation` collapses every presentation (`Attention.collapse()`, which never dismisses) and, if the panel was key, orders it out and re-activates the frontmost app so keyboard input returns to it. The next refresh shows the collapsed panel again.
- **Labels.** Each row is an accessibility container labeled with its kind and subject (task name when Codex provided one, otherwise the shortened session ID). Every button's label names its action and subject, for example "Approve once: deploy, session 01a0916c-337b". The header reads the working and to-check counts and says whether the queue is expanded.
- **No running commentary.** The panel shows no navigation result line and no keyboard hint (removed 2026-09-14 at the user's request); navigation results remain in the controls window, and the card's own status sentence reports what Steer did for a question.
- **Long details.** Task, project, action, command, and reason wrap in full with no line limit; the full request stays behind Show full request. A shortened command is never presented as the complete action.

## Automated checks

`swift test`. New in `Tests/SteerCoreTests/NotchPlacementTests.swift`: pointer display chosen when idle; placement frozen on the current display while interacting; a disconnected current display falling back even while interacting; pointer off every display keeping the current display, then the first, then nil with no displays; collapsed frame below the physical housing and centered; the compact top-center panel on a non-notch display; the expanded height cap; pointer or keyboard focus counting as interaction; interaction holding a completion open without extending the approval deadline; and Escape collapsing without dismissing. Pinned display: the pinned display chosen wherever the pointer is; a missing pin falling back to the built-in display and returning on reconnect; a missing pin with no built-in display following the pointer; the interaction freeze holding over a reconnecting pin; stored values without an identifier meaning Follow pointer; picker options numbering same-named displays and listing a disconnected pin; the checked entry and detail line naming the pinned display by its current label after a rename or a swap of same-named displays; and the detail line for each case.

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

## Empty notch (2026-10-08)

Reported: with no session the strip still drew a green sprite, which read as a session. The strip now draws the unlit sprite (well gray, eyes shut, still) when no session is listed, and the open queue says why it is empty in one row (`EmptyQueueReading`): "Nothing running", naming the sources whose setup is connected, or "Not connected" with Open Controls once both setup checks have landed and neither source is connected. While either check is pending, the row names no source and claims no missing connection. `emptyQueueNamesConnectedSourcesAndClaimsNoGapBeforeBothSetupsAreChecked` covers the reading. `--preview-queue empty-collapsed|empty-expanded|empty-not-connected` renders the three states; pass `--attention-snapshot` with a scratch path so the preview does not load the real snapshot.

## Operator walkthrough (to record before release)

Not performed by the agent: it needs a second display, Mission Control, and the keyboard, which are outside the permitted automation. Run it with Steer connected to an isolated lab as in [restart recovery](restart-recovery.md) and record each line as pass, fail, or uncertain.

1. **Two displays.** Attach an external monitor. Send a test notification. Move the pointer between displays: the panel follows the pointer and appears exactly once, below the housing on the built-in display and top-center on the external one.
2. **Freeze during interaction.** Expand the panel on the external display, hover over a button, and move the pointer's display by dragging past the edge while staying over the panel: it does not jump. Click the panel on the built-in display so it has keyboard focus, then move the pointer to the other display: it stays put until Escape returns focus.
3. **Disconnect and reconnect.** With the panel on the external display, unplug it. The panel appears once on the built-in display with the same queue and no new sound. Reconnect: the panel follows the pointer again; nothing is duplicated or replayed.
4. **Deadline independence.** Trigger a CLI approval in the lab, hover over the panel, and keep the pointer there past 30 s: the row changes to Continue in Codex on time while the popup stays open.
5. **Keyboard.** With another app active, wait for a completion: the other app keeps keyboard focus. Click the panel, press Tab repeatedly: the focus ring moves through the controls and is visible on each. Press Escape: the panel collapses and typing goes to the previous app.
6. **VoiceOver.** Turn VoiceOver on and navigate the expanded panel: each row announces its kind and subject, each button its action and subject, and a long command reads in full.
7. **Spaces and full screen.** Open a full-screen app and switch Spaces: the panel shows over the full-screen app and on each Space, once.
8. **Pinned display.** Choose the external monitor under Show notch on. Move the pointer to the built-in display: the panel stays on the external one. Unplug it: the panel appears once on the built-in display and Notch display reads "*name* (not connected)". Reconnect it: the panel returns to the external monitor. Choose Follow pointer: the panel follows the pointer again.

## Boundaries

- "Actively using" means the display under the pointer, or the pinned display when the user has chosen one. Keyboard-only users on a multi-display setup get the pointer's display; a rule based on the key window's display is deferred until it is needed.
- Escape is the only keyboard collapse; there is no global hotkey to open or focus the panel, so keyboard-only users must click it once.
- `--assume-codex-away` and `--placement-probe` are lab flags compiled into the app like `--restart-report`; they change nothing unless passed.
- Focus rings depend on macOS Full Keyboard Access for Tab to reach buttons, as in any macOS app.
- The probe proves geometry and key status on this machine; it cannot attach or detach a display.
