# Enter the notch by a Carbon hotkey and hand the keyboard back to the remembered app

Accepted on 2026-11-13 (#427). Before this, the only way to give the notch panel keyboard focus was a click: automatic presentation never makes the panel key, and Tab cannot reach a non-activating panel in another process. The user agreed one system-wide entry key, ⌃⌥Space by default, changeable or switched off in Settings › Notch, with plain digits never taken from other apps.

## Decision

- **Registration.** `NotchHotkeyRegistrar` registers the one shortcut with Carbon `RegisterEventHotKey` and `kEventHotKeyExclusive`. It needs no Accessibility permission and sees only that key combination. Herdly installs no event tap and no global `NSEvent` monitor. `eventHotKeyExistsErr` is shown under the Settings row and the notch stays click-only; a recorded shortcut must hold Control, Option, or Command (`NotchHotkey`), so ordinary typing can never be claimed.
- **Entry without activation.** On a press, Herdly remembers the frontmost app and makes the panel key the way a click does (`hasDeliberateKeyboardFocus`), without activating Herdly. Herdly activates itself only when the window server refuses key status to an inactive app. `NotchKeyboardEntry.target` sends the keyboard to the card on screen, or opens the queue with its top row selected.
- **One hand-back path.** The hotkey again, Escape at the top level, and the panel folding for any reason go through `Companion.handBackKeyboard()`, and `NotchKeyboardReturn.handBack` (HerdlyCore) picks what to activate:
  - the remembered app, matched by process identifier and bundle identifier, while it still runs;
  - nothing, when it has quit, so macOS chooses; Herdly never activates a terminal it guessed;
  - nothing, when a third app came forward meanwhile (for example an Open from the notch), so that app keeps the keyboard;
  - nothing later, once the panel lost key status to another app, because the remembered app is forgotten then.
- **Hold and placement.** The queue the hotkey opened stays open while it holds the keyboard and does not move displays. Focus from a click still holds nothing (#376), and keyboard focus still pauses no countdown (ADR 0020).

## Considered options

- **Event tap (`CGEventTap`) or global `NSEvent` monitor.** Rejected: both need Accessibility or Input Monitoring permission and observe every keystroke, far more than one shortcut needs. The issue forbids an event-tap fallback.
- **Activate Herdly on every press.** Rejected: every hand-back would then depend on re-activating the other app correctly, and a failed or raced activation would leave the user typing into nothing. Taking key status like a click keeps the user's app frontmost.
- **Always re-activate the remembered app.** Rejected: after Return opened a session in another app from the notch, folding would pull the original app back over the one the user just asked for.
- **Non-exclusive registration.** Rejected: Carbon then accepts a shortcut another process already holds, so Settings could not report it as taken.

## Not yet shown live

- ⌃⌥Space from Ghostty mid-line, then again, with the next keystroke landing at the same cursor.
- A shortcut held by another app reported as taken in Settings.
- A shortcut claimed through System Settings, which Carbon cannot see; it may register without error and never fire (recorded under Boundaries in docs/notch-placement.md).
