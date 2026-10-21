# Run the desktop prototype

This is a runnable shell for the accepted app-level visibility experiment in #1. Desktop lifecycle replay for #4 is documented separately in [desktop-live-integration.md](desktop-live-integration.md). Requires macOS 14+ and Swift 6. It has one test completion, no Codex hooks, no approval buttons, and an optional task-ID field for testing guarded link requests.

```sh
swift test
sh scripts/build-app.sh
open output/Herdly.app
```

The build script produces an ad-hoc signed local app. It is not notarized or a distributable release. Quit Herdly before rebuilding its bundle. No installation into Applications or login-item registration is performed.

## Try it

1. Launch Herdly and click **Send test** in its controls window. The menu-bar shortcut is **S**; it also offers **Send test notification**. Closing the controls window keeps Herdly running; reopening the app shows the controls again.
2. While Codex is foreground, the notch panel stays hidden. Switch to Notes or another app: the test completion appears below the notch (top-center on other screens).
3. It expands to the test card for three seconds, then collapses to the strip with a **1** badge. Hovering or keyboard interaction holds the panel open; hover the strip to reopen it, or click it for keyboard focus. Sound plays only on first presentation; **Mute sound** is in the menu.
4. Return to Codex: the panel hides. Leave again: the item remains, without replaying sound. Click **Dismiss**, in the panel or menu, to clear it.
5. Send another test, then use **Quit Herdly** and relaunch: the pending item returns silently. Dismiss it, quit and relaunch: it stays cleared.

Sending another test replaces the single test item. This prototype does not implement a multi-item queue. Its pending flag and mute preference are stored under `dev.rcurio.herdly.prototype`, separate from Codex settings.

Display selection follows the pointer's screen and stays on the current screen while hovered. `--preview-queue <collapsed|spotlight|spotlight-approval|spotlight-handed-back|spotlight-question|spotlight-claude-question|expanded>` seeds in-memory sample items for screenshots (the two approval modes show a live and a handed-back request in the spotlight; the two question modes show a Codex question card and a read-only Claude question card), and `empty-collapsed`, `empty-expanded`, and `empty-not-connected` show the empty notch; `clicked-approval` shows the approval sample as a clicked card (`clicked-approval-long` with a command past the six-line cap, `clicked-claude-approval` a Claude request with no command) and `row-note` the queue with that row selected and carrying a note; it ignores Codex activation, never scans events, and never saves. This is a prototype placement rule; full-screen, multi-display and accessibility release checks remain outstanding. Automatic presentation does not activate Herdly. The menu offers a keyboard-accessible dismissal path.

## Evidence

- `swift test`: one state scenario checks foreground suppression, delayed first presentation, hover retention, collapse without dismissal, app switching, silent restoration, explicit dismissal and a later completion.
- Release build, plist validation and ad-hoc signature verification pass.
- Initial menu-only inspection timed out. Diagnosis found the status item at x=767–820 while the MacBook usable right menu area started at x=848: the physical notch obscured it. A smaller S item reduces space usage; a controls window on launch/reopen provides access regardless of menu-bar crowding.
- The controls window and its Send test, Dismiss and Quit buttons were verified through computer-use inspection. The subsequent user walkthrough below verifies Codex foreground suppression and dismissal retention.
- `output/Herdly.app/Contents/MacOS/Herdly --smoke-test` verifies that the controls window is visible and the menu is configured, then exits. Quit the normal instance before running this check; it does not prove the menu item is outside the notch.
- Only native app activation is observed through `NSWorkspace`; no Accessibility queries, Apple Events, task UI inspection, injected commands or Codex configuration changes.

Real Codex lifecycle events remain gated by #2. This prototype does not close the live integration tickets.

## Computer-use walkthrough

Verified through Herdly's own accessibility interface and screenshots:

- Send test changed the controls from no notifications to one queued item.
- Closing the controls left a compact `1 to check` panel.
- Clicking the compact panel displayed the test details and Dismiss button.
- Dismiss in the controls changed the queue to empty and disabled Dismiss.
- Sending another test, quitting through the UI and reopening restored one queued item.
- After the earlier panel dismissal and a process restart, the controls showed no queued notifications.

The controls were left open with one test queued. Inspection brings Herdly's panel into focus, so these observations do not independently measure the three-second timer or prove passive collapse while another app is active. Sound/mute and Codex foreground suppression were not verified by computer use; Codex UI access remains restricted. The state test covers timing separately. A temporary missing-window selection error was resolved by restarting the prototype; its process was still running, so it was not recorded as a crash.

## User-confirmed foreground walkthrough

The user reported **all pass** for these five checks:

1. With a test queued, opening Codex hides the notch.
2. Switching between Codex tasks keeps it hidden.
3. Switching to Notes restores `1 to check`.
4. Repeating the switches twice retains the item without repeating its sound.
5. Dismissing clears it, and it stays cleared after restarting Herdly.

This is user-reported live evidence, separate from computer-use and state tests. It does not cover ambiguous installations, unavailable task links, or an unavailable app-activation signal. Those remaining #1 criteria must not be checked off based on this report. The subsequent failure-handling checks below complete the remaining bounded verification.

## Navigation failure boundary

The optional task-ID field validates UUIDs, requires one identifiable running Codex instance, and opens the link against that exact bundle URL. With no identifiable instance it requests that the user open their preferred Codex app; with multiple instances it refuses to guess. If the app exits during opening, a native error is reported. A successful callback says only that the link was sent; it never claims the task was selected or dismisses a notification. A nonexistent task can therefore remain safely unverified even if Codex accepts the URL.

Three Swift tests pass: completion lifecycle, unknown activation retention, and navigation boundaries. The navigation test injects the native opener to verify invalid IDs, no instance, missing bundle identity, multiple instances, exact bundle selection, native error, and successful delivery without verification (including a nonexistent UUID). These are deterministic boundary tests; no second Codex instance was launched for them.

Computer use verified `Enter a valid task ID` while `1 test notification queued` remained visible. The initial capture failed; reconnecting to Herdly confirmed the result. The test item was then dismissed. The user's live foreground, app-switch, restart, nonexistent-link and existing-window reports complement these automated checks. Approval behavior and real session events remain #2; this evidence completes the reduced #1 feasibility scope, not the full MVP or production routing guarantees.
