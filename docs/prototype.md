# Run the desktop prototype

This is a runnable shell for the accepted app-level visibility experiment in #1, not the real-session integration in #4. Requires macOS 14+ and Swift 6. It has one test completion, no Codex hooks, no real task monitoring, no approval buttons and no task navigation.

```sh
swift test
sh scripts/build-app.sh
open output/Steer.app
```

The build script produces an ad-hoc signed local app. It is not notarized or a distributable release. Quit Steer before rebuilding its bundle. No installation into Applications or login-item registration is performed.

## Try it

1. Click **Steer** in the macOS menu bar and select **Send test notification**.
2. While Codex is foreground, the notch panel stays hidden. Switch to Notes or another app: the test completion appears below the notch (top-center on other screens).
3. It expands for three seconds, then becomes **1 to check**. Hovering or keyboard interaction holds the expanded panel open. Click the compact panel to reopen it. Sound plays only on first presentation; **Mute sound** is in the menu.
4. Return to Codex: the panel hides. Leave again: the item remains, without replaying sound. Click **Dismiss**, in the panel or menu, to clear it.
5. Send another test, then use **Quit Steer** and relaunch: the pending item returns silently. Dismiss it, quit and relaunch: it stays cleared.

Sending another test replaces the single test item. This prototype does not implement a multi-item queue. Its pending flag and mute preference are stored under `dev.rcurio.steer.prototype`, separate from Codex settings.

Display selection follows the pointer's screen and stays on the current screen while hovered. This is a prototype placement rule; full-screen, multi-display and accessibility release checks remain outstanding. Automatic presentation does not activate Steer. The menu offers a keyboard-accessible dismissal path.

## Evidence

- `swift test`: one state scenario checks foreground suppression, delayed first presentation, hover retention, collapse without dismissal, app switching, silent restoration, explicit dismissal and a later completion.
- Release build, plist validation and ad-hoc signature verification pass.
- The process was observed running after launch. Computer-use inspection timed out; the visual walkthrough above is not recorded as passed.
- Only native app activation is observed through `NSWorkspace`; no Accessibility queries, Apple Events, task UI inspection, injected commands or Codex configuration changes.

Real Codex lifecycle events remain gated by #2. This prototype does not close the live integration tickets.
