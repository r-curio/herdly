# Run the desktop prototype

This is a runnable shell for the accepted app-level visibility experiment in #1, not the real-session integration in #4. Requires macOS 14+ and Swift 6. It has one test completion, no Codex hooks, no real task monitoring, no approval buttons and no task navigation.

```sh
swift test
sh scripts/build-app.sh
open output/Steer.app
```

The build script produces an ad-hoc signed local app. It is not notarized or a distributable release. Quit Steer before rebuilding its bundle. No installation into Applications or login-item registration is performed.

## Try it

1. Launch Steer and click **Send test** in its controls window. The menu-bar shortcut is **S**; it also offers **Send test notification**. Closing the controls window keeps Steer running; reopening the app shows the controls again.
2. While Codex is foreground, the notch panel stays hidden. Switch to Notes or another app: the test completion appears below the notch (top-center on other screens).
3. It expands for three seconds, then becomes **1 to check**. Hovering or keyboard interaction holds the expanded panel open. Click the compact panel to reopen it. Sound plays only on first presentation; **Mute sound** is in the menu.
4. Return to Codex: the panel hides. Leave again: the item remains, without replaying sound. Click **Dismiss**, in the panel or menu, to clear it.
5. Send another test, then use **Quit Steer** and relaunch: the pending item returns silently. Dismiss it, quit and relaunch: it stays cleared.

Sending another test replaces the single test item. This prototype does not implement a multi-item queue. Its pending flag and mute preference are stored under `dev.rcurio.steer.prototype`, separate from Codex settings.

Display selection follows the pointer's screen and stays on the current screen while hovered. This is a prototype placement rule; full-screen, multi-display and accessibility release checks remain outstanding. Automatic presentation does not activate Steer. The menu offers a keyboard-accessible dismissal path.

## Evidence

- `swift test`: one state scenario checks foreground suppression, delayed first presentation, hover retention, collapse without dismissal, app switching, silent restoration, explicit dismissal and a later completion.
- Release build, plist validation and ad-hoc signature verification pass.
- Initial menu-only inspection timed out. Diagnosis found the status item at x=767–820 while the MacBook usable right menu area started at x=848: the physical notch obscured it. A smaller S item reduces space usage; a controls window on launch/reopen provides access regardless of menu-bar crowding.
- The controls window and its Send test, Dismiss and Quit buttons were verified through computer-use inspection. Full notification/foreground walkthrough remains pending.
- `output/Steer.app/Contents/MacOS/Steer --smoke-test` verifies that the controls window is visible and the menu is configured, then exits. Quit the normal instance before running this check; it does not prove the menu item is outside the notch.
- Only native app activation is observed through `NSWorkspace`; no Accessibility queries, Apple Events, task UI inspection, injected commands or Codex configuration changes.

Real Codex lifecycle events remain gated by #2. This prototype does not close the live integration tickets.

## Computer-use walkthrough

Verified through Steer's own accessibility interface and screenshots:

- Send test changed the controls from no notifications to one queued item.
- Closing the controls left a compact `1 to check` panel.
- Clicking the compact panel displayed the test details and Dismiss button.
- Dismiss in the controls changed the queue to empty and disabled Dismiss.
- Sending another test, quitting through the UI and reopening restored one queued item.
- After the earlier panel dismissal and a process restart, the controls showed no queued notifications.

The controls were left open with one test queued. Inspection brings Steer's panel into focus, so these observations do not independently measure the three-second timer or prove passive collapse while another app is active. Sound/mute and Codex foreground suppression were not verified by computer use; Codex UI access remains restricted. The state test covers timing separately. A temporary missing-window selection error was resolved by restarting the prototype; its process was still running, so it was not recorded as a crash.
