# Terminal.app scripting surface for exact tab targeting (#199)

Checked 2026-10-11 for [Research Terminal.app's scripting surface for exact tab targeting](https://github.com/r-curio/steer/issues/199), a research ticket under the map [Support iTerm2, Terminal.app, WezTerm and multiplexers](https://github.com/r-curio/steer/issues/197). This doc records facts only. Decisions belong to the grilling tickets.

No Apple Events were sent to Terminal. No tab was scripted or typed into, and no configuration was changed. Every scripting fact below comes from the installed scripting dictionary, Apple documentation, or symbol names in the Terminal binary. Runtime behavior that only a live test can show is marked **unverified**.

## Answer

1. **Identity:** a Terminal `tab` has **no identifier property** and no `name`. The tab's stable handle is its **`tty`** (read-only text, for example `/dev/ttys012`). A `window` has a unique integer `id`, but tabs are addressed only by index within a window, and that index shifts when tabs are closed or reordered.
2. **One tab is one TTY:** the dictionary has no pane or split class. Terminal's "Split Pane" (⌘D) shows a second view of the same session, not a second shell (see [Splits](#splits)). So "unsplit tab" and "one tty per tab" coincide.
3. **Select and verify:** `selected` (tab) and `frontmost` (window) are writable. `selected tab` of a window, application `frontmost`, and window order (`front window`/`index`) can be read back to verify the result.
4. **Focus:** `tty of selected tab of front window`, combined with Terminal being the frontmost app, reports which tab has focus.
5. **Titles:** a tab exposes only `custom title`. Whether the title Codex sets with an escape sequence (OSC 0) or Steer's Claude title (OSC 2) appears in `custom title`, in the window's `name`, or nowhere readable for a background tab is **unverified**. Apple does not document it.
6. **Input:** the only tab-addressed input in the dictionary is **`do script <text> in <tab>`**. It needs no System Events keystrokes. Apple documents it only as "Runs a UNIX shell script or command" and returns the tab. Its delivery semantics are **unverified**, and it gives **no delivery confirmation**. If the target resolves to nothing, the dictionary's null case suggests the text is run in a **new window** instead (see [Input](#input-to-one-tab)).
7. **Open Island** binds Terminal sessions by tab `tty`, falling back to a substring match on `custom title`. It selects the first matching tab without verifying the result, and it sends no text to Terminal.app: reply input is offered only for tmux and Ghostty.

## Version checked

| Item | Value | Source |
| --- | --- | --- |
| macOS | 26.5 (25F71) | `sw_vers` |
| Terminal | 2.15, build 470.2 (`version.plist` BuildVersion 68, SourceVersion 470002000000000) | `/System/Applications/Utilities/Terminal.app/Contents/Info.plist`, `Contents/version.plist` |
| Bundle ID | `com.apple.Terminal` | `Info.plist` `CFBundleIdentifier` |
| Scripting | `NSAppleScriptEnabled = true`; `OSAScriptingDefinition = Terminal.sdef` | `Info.plist` |
| Dictionary | `Contents/Resources/Terminal.sdef`, SHA-256 `efc515ec…a92af`, byte-identical to `sdef /System/Applications/Utilities/Terminal.app` output (576 lines) | `shasum -a 256` of both |
| User guide | Terminal User Guide 2.15 for macOS 26 | [support.apple.com/guide/terminal](https://support.apple.com/guide/terminal/change-profiles-tab-settings-trmltab/2.15/mac/26) |

Terminal is a system app on the sealed system volume, so its version follows the macOS release. Apple's archived [Terminal 2 release notes](https://developer.apple.com/library/archive/releasenotes/DeveloperTools/RN-Terminal/index.html) (Leopard, 2007) introduce tabs but say nothing about scripting. The release that first exposed `tty`, `selected` or `do script … in` is **unverified**. Only this one installed version was inspected.

## The scripting dictionary

All entries below are from `Terminal.sdef` on Terminal 2.15. Cocoa keys are shown because they confirm which properties have setters. The binary's symbol table lists `scriptTTY`, `scriptSelected`/`setScriptSelected:`, `scriptFrontmost`/`setScriptFrontmost:`, `scriptCustomTitle`/`setScriptCustomTitle:`, `scriptProcesses`, `scriptBusy`, `TTDoScriptCommand` and `handleDoScriptCommand:` (`strings` of `Contents/MacOS/Terminal`). There is no `setScriptTTY`.

### `application` (`capp`, Cocoa `TTApplication`)

| Property / element | Code | Access | Meaning |
| --- | --- | --- | --- |
| `frontmost` | `pisf` | r | "Is this the frontmost (active) application?" (`isActive`) |
| `version` | `vers` | r | Application version |
| `window` elements | `cwin` | r | Cocoa key `orderedWindows`, so `window 1`/`front window` is Terminal's frontmost window |
| `settings set` elements, `default settings`, `startup settings` | | | Profiles (not needed for targeting) |

There is no `activate` entry in the dictionary. `activate` is the standard Apple Event every scriptable Cocoa app accepts. Open Island uses it, and `NSRunningApplication.activate` is an alternative that needs no Apple Event.

### `window` (`cwin`, Cocoa `TTWindow`)

| Property | Code | Access | Meaning |
| --- | --- | --- | --- |
| `id` | `ID  ` | r | "The unique identifier of the window." (`uniqueID`) |
| `name` | `pnam` | r | "The full title of the window." (`title`) |
| `index` | `pidx` | rw | "ordered front to back" |
| `frontmost` | `pisf` | rw | "Whether the window is currently the frontmost Terminal window." (`scriptFrontmost`) |
| `miniaturized`, `visible`, `zoomed` | `pmnd`, `pvis`, `pzum` | rw | Window state |
| `selected tab` | `tcnt` | (contents) | `selectedTabController` |
| `tab` elements | `ttab` | r | `tabControllers` |

### `tab` (`ttab`, Cocoa `TTTabController`)

| Property | Code | Access | Meaning |
| --- | --- | --- | --- |
| `tty` | `ttty` | **r** | "The tab's TTY device." (`scriptTTY`) |
| `selected` | `tbsl` | rw | "Whether the tab is selected." |
| `custom title` | `titl` | rw | "The tab's custom title." |
| `title displays custom title` | `tdct` | rw | Whether the title shows the custom title |
| `processes` | `prcs` | r | "The processes currently running in the tab." List of text (names only, no PIDs) |
| `busy` | `busy` | r | "Whether the tab is busy running a process." |
| `contents` | `pcnt` | r | "The currently visible contents of the tab." |
| `history` | `hist` | r | "The contents of the entire scrolling buffer of the tab." |
| `current settings` and colors, font, rows/columns, other `title displays …` flags | | rw | Appearance |

The tab has **no `id`, no `name`, no working directory and no PID**.

### `do script` (`coredosc`, Cocoa `TTDoScriptCommand`)

```xml
<command name="do script" code="coredosc" description="Runs a UNIX shell script or command.">
  <direct-parameter type="text" description="The command to execute." optional="yes"/>
  <parameter name="with command" ... code="cmnd" optional="yes" hidden="yes"> <!-- deprecated -->
  <parameter name="in" description="The tab in which to execute the command" code="kfil" optional="yes">
    <type type="tab" /> <type type="window" /> <type type="any" /> <!-- support null case -->
  </parameter>
  <result type="tab" description="The tab the command was executed in." />
</command>
```

There is no `write text`/`input text` command (iTerm2's and Ghostty's equivalents) and no key-sending command.

## Point by point

### Per-tab identifiers

- **Tab:** none in the dictionary. A script refers to a tab by position (`tab 2 of window id 4711`), and the position changes when tabs before it close or are reordered. A by-position reference taken during enumeration can point to a different tab by the time it is used. This race is inferred from the addressing model and has not been observed.
- **Window:** `id` is documented as unique. Its lifetime across Terminal relaunch or Resume is **unverified**.
- **`tty`:** the only per-tab value that names the tab's terminal. It is read-only and cannot be set by script. A `/dev/ttysNNN` path is reused by the system after its pty closes, so a remembered tty identifies a tab only while that tab is alive. Re-reading it next to the process check below catches reuse.
- **`TERM_SESSION_ID`:** Terminal gives every terminal session a unique identifier in this environment variable, for Resume support (`/etc/zshrc_Apple_Terminal`: "Terminal assigns each terminal session a unique identifier and communicates it via the TERM_SESSION_ID environment variable"). The scripting dictionary does not expose it, so it cannot be joined to a tab without Apple Events beyond those listed above. For Codex, hook environment variables are tainted by the shared daemon (ADR 0012), so a hook's `TERM_SESSION_ID`, `TERM_PROGRAM` or `tty` cannot identify a Codex tab.

### TTY, title and foreground process exposure

- **TTY:** `tty of tab` (see above).
- **Foreground process:** the dictionary gives only process *names* (`processes`) and `busy`. With the tab's tty, Steer can read the foreground process without another Apple Event: `ps -t ttysNNN -o pid,stat,comm`, where `+` in `stat` means "the process is in the foreground process group of its control terminal" (`man ps`, `-t` and `state` `+`). This mirrors ADR 0011's `lsof` TTY join and ADR 0012's foreground-process check. It has not been run against a Terminal tab here.
- **Titles:** see the next section.
- **Screen text:** `contents` and `history` expose the visible screen and full scrollback. These are readable but carry conversation content. Matching on them was not evaluated.

### Codex and Claude Code titles

- **What the agents write:** Codex's TUI writes its title as **OSC 0** (`ESC ] 0 ; title BEL`). Source: [`codex-rs/tui/src/terminal_title.rs`](https://github.com/openai/codex/blob/cc7ba33601286a751477832b01de7b6f8de0dd9c/codex-rs/tui/src/terminal_title.rs) at `cc7ba33` (2026-10-10), which writes `"\x1b]0;{}\x07"` and tests `writes_osc_title_with_bel_terminator`. With `tui.terminal_title = ["session-id"]`, the title is ADR 0005's 29-character prefix plus `...` (observed on Codex 0.145.0). Steer's Claude hook writes **OSC 2** `Steer Claude <full-session-id>` through Claude's `terminalSequence` (`Sources/SteerHook/main.swift:136-138`, [Claude setup](claude-setup.md)).
- **What Terminal shows:** Apple's guide lists the window-title items (working directory or document, active process name, shell command name, profile name, TTY name, dimensions, command key) and the tab-title items (working directory or document, path, active process name, arguments, TTY name, "Show other items when there is a custom title", activity indicator). Sources: [window title](https://support.apple.com/guide/terminal/trml15228/mac) and [Tab settings 2.15](https://support.apple.com/guide/terminal/change-profiles-tab-settings-trmltab/2.15/mac/26). Neither page mentions escape-sequence titles. The Inspector has separate "Window Title" and "Tab Title" fields.
- **Unverified, and needs a live check:**
  - whether OSC 0 or OSC 2 updates the tab's scriptable `custom title`;
  - whether it appears only in the window's `name` ("full title of the window"), which reflects only the selected tab;
  - whether it is readable at all for a background tab;
  - whether the profile's title options can hide it.

  Until this is checked, Codex's session-ID title and Steer's Claude title cannot be assumed visible through Terminal scripting. Note that `custom title` is writable, so a user, a script or another tool can set any value there.

### Selecting a tab and verifying it

The dictionary supports this sequence. It was not run here.

```applescript
tell application "Terminal"
    set selected of theTab to true      -- tab: tbsl, rw
    set frontmost of theWindow to true  -- window: pisf, rw (scriptFrontmost)
    activate                            -- standard event, or NSRunningApplication.activate
end tell
-- verify with a fresh read:
--   frontmost (application) is true
--   tty of selected tab of front window = expected tty
```

- These are **unverified** at runtime:
  - whether `set selected` on a tab in a background window also orders that window front;
  - how minimized windows (`miniaturized`), windows on another Space, and full-screen windows behave;
  - whether `frontmost` is true immediately after `activate` returns.

  Ghostty needed settle delays (Open Island's `ghosttyFocusSettleDelay`).
- Because tabs have no ID, a revalidating script must re-find the tab by `tty` in the same script that selects it. Then it must read back `tty of selected tab of front window`.

### Reporting the focused tab (visit acknowledgment)

`tty of selected tab of front window`, together with application `frontmost` (or `NSWorkspace.frontmostApplication` = `com.apple.Terminal`, which needs no Apple Event), names the tab the user is looking at. Each poll is one Apple Event round trip. Terminal posts no scriptable focus-change notification. Whether the selected tab of the front window is reliably the key window's tab when Terminal has several windows is **unverified**.

### Input to one tab

- **`do script "text" in theTab`** is the only dictionary route that addresses one tab without System Events. The dictionary says it "Runs a UNIX shell script or command" in "The tab in which to execute the command" and returns that tab. Apple publishes no further semantics for it.
- **Unverified delivery semantics:** widely reported, but not confirmed from a primary source:
  - the text is delivered to the tab's terminal as input followed by a newline, so it reaches whatever foreground process holds the tty (the Codex or Claude TUI, a pager, an editor, `ssh`) rather than "running a command";
  - whether a newline is always appended, and whether it can be suppressed;
  - whether the text arrives as one paste-like write or as keystrokes (a TUI may treat a burst differently);
  - how control characters are handled;
  - whether `do script` selects or raises the tab.
- **Risks visible from the dictionary itself:**
  - The `in` parameter accepts `any` "to support null case". A `do script` without a target creates a new window. So a target that resolves to `missing value` may run the text as a **shell command in a new window** rather than fail. This is inferred from the sdef comment and common usage, and is unverified.
  - The tab is addressed by position, so the race under [Per-tab identifiers](#per-tab-identifiers) applies between finding the tab and sending.
  - The text is named "script"/"command". Nothing checks which process receives it.
- **Delivery confirmation:** none. The result is a tab reference only. `busy`, `processes`, `contents` and `history` can be read afterwards, but they show screen or process state, not that the intended process consumed the input.
- **Other routes, not dictionary-based:**
  - System Events keystrokes into the frontmost window. The map rules these out for approvals, and they are not tab-addressed.
  - Writing to `/dev/ttysNNN` directly writes to the terminal's *output* side (it shows text on the screen), not to the program's input. On macOS, injecting input with `TIOCSTI` is restricted. That is general knowledge and was not verified here.
  - A multiplexer inside the tab (tmux `send-keys`) is tab-independent and belongs to the multiplexer tickets.

### Splits

The dictionary has no pane class. Apple's [keyboard shortcuts page](https://support.apple.com/guide/terminal/trmlshtcts/2.15/mac/26) lists "Split window into two panes" ⌘D and "Close split pane" ⇧⌘D. A secondary source ([O'Reilly, Mac OS X](https://www.oreilly.com/library/view/mac-os-x/9781449314828/ch17s06.html)) describes the split as two views of the same session that scroll independently. If that holds, a split tab still has one tty and one shell, and splits do not create a second target. This is **unverified** against current Terminal.

### Permissions and configuration

- **Automation (TCC Apple Events)** for `com.apple.Terminal`: the same mechanism Steer already uses for Ghostty. The pieces are `NSAppleEventsUsageDescription` in `scripts/build-app.sh` (its text currently names Ghostty only), the `com.apple.security.automation.apple-events` entitlement in `scripts/Steer.entitlements`, and a consent check through `AEDeterminePermissionToAutomateTarget`, which sends no event (`Sources/SteerApp/GhosttyAutomationPermission.swift`). Terminal needs its own per-target consent, because macOS grants Automation per controlling app and target app pair.
- **Terminal-side settings:** the dictionary and `Info.plist` show no in-app scripting toggle (unlike Ghostty's `NSApp.isAppleScriptEnabled` gate). `NSAppleScriptEnabled` is `true` in the bundle. Reading tabs needs no Terminal preference.
- **Things Steer would have to change to make titles work:** nothing is known to be needed if escape-sequence titles are readable (unverified). Setting a tab's `custom title` by script would modify Terminal state. The map says Steer never edits user configuration, and whether a scripted custom title counts as configuration is a decision for the grilling tickets.

### Detecting support and version

- **Presence:** `NSWorkspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal")` or a running `NSRunningApplication`. Terminal ships with macOS at `/System/Applications/Utilities/Terminal.app`, so it is always installed on supported macOS.
- **Version:** `CFBundleShortVersionString` (2.15 here) from `Info.plist`, read with no Apple Event. The application's `version` property also gives it, but costs an Apple Event.
- **Feature check without Apple Events**, following the Ghostty precedent in [Ghostty tty investigation](ghostty-tty-investigation.md#feature-check-for-steer): read `Info.plist` → `OSAScriptingDefinition`, parse `Contents/Resources/Terminal.sdef`, and require:
  - class `ttab` with property `ttty` (type `text`);
  - property `tbsl`;
  - window class `cwin` with property `pisf` and contents `tcnt`;
  - command `coredosc` with parameter `kfil`, if input is in scope.

  Matching on four-character codes rather than names is the same choice that check made.
- **Which tab a session is in:** a hook's `TERM_PROGRAM=Apple_Terminal` shows that a shell runs under Terminal (Open Island relies on it). For Codex this value is daemon-tainted (ADR 0012).

## How Open Island does it

Source: Open Island at commit `b50f87aa7d58af1478837d48909eb68baa37f9b9` (2026-09-15).

- **Locating the session (hook side):**
  - `ClaudeHooks.swift` and `CodexHooks.swift` classify the terminal from `TERM_PROGRAM` (`apple_terminal` → `"Terminal"`).
  - They record `terminal_tty` from `/usr/bin/tty`, or from the parent's `ps -o tty=` (`CodexHooks.currentTTY`, `parentProcessTTY`).
  - If the tty is still missing, they ask Terminal for `tty` and `custom title` of `selected tab of front window` (`CodexHooks.terminalLocator`). That is the *focused* tab at hook time, not necessarily the session's tab.
- **Inventory (`TerminalSessionAttachmentProbe.swift`):**
  - `terminalSnapshots()` lists `tty` and `custom title` of every tab of every window in one `osascript` run, with ASCII 31/30 separators.
  - A session matches a tab when the tab's tty equals the session's tty. Otherwise it matches when the tab's `custom title` **contains** the session's `paneTitle` (substring).
  - Each tab is assigned to one "preferred" session (`attachedTerminalSessions`), and the session's jump target is corrected to the tab's tty (`correctedTerminalJumpTarget`).
- **Jump (`TerminalJumpService.jumpToTerminalTab`, lines 958-981):**
  - In one AppleScript, it calls `activate`, then iterates windows and tabs.
  - On the first tab whose `tty` equals the target tty, or whose `custom title` contains `paneTitle`, it runs `set selected of aTab to true` and `set frontmost of aWindow to true` and returns `"matched"`.
  - It does not check for uniqueness and reads nothing back to verify.
  - On no match, `jump` falls back to `open -b com.apple.Terminal`, reported as "Exact pane targeting could not find the live terminal".
  - The tmux path calls the same function after `select-pane`.
- **Focus (`ForegroundTerminalSessionProbe.swift`):** if the frontmost app is `com.apple.Terminal`, it reads `tty of selected tab of front window` and compares the normalized tty with the session's.
- **Input (`TerminalTextSender.swift`):**
  - `canReply` returns true only for tmux targets and Ghostty, so Terminal.app gets **no** text input.
  - Ghostty uses `input text` plus `send key "enter"`. Open Island does not use `do script`.

Compared with Steer's rules, Open Island's Terminal route:

- accepts a substring title match;
- takes the first match rather than requiring a unique one;
- uses the hook's tty, which is the daemon's under Codex's shared daemon (ADR 0012);
- does not verify the result.

## Unverified and open points

All of these need a live Terminal test in a disposable lab. None was run, because this ticket forbids Apple Events to running terminals.

1. Where Codex's OSC 0 title and Steer's Claude OSC 2 title surface: tab `custom title`, window `name`, or neither, including for background tabs and under different profile title settings.
2. `do script … in tab`:
   - whether a newline is appended;
   - paste-versus-keystroke delivery;
   - control characters;
   - behavior when a TUI is in the foreground;
   - whether it selects or raises the tab;
   - what happens when the target is `missing value`.
3. Whether `set selected` plus `set frontmost` plus `activate` reliably raise a tab in a background, minimized, other-Space or full-screen window, and whether the read-back is immediately consistent.
4. Whether `window id` survives Terminal relaunch or Resume. Tab position stability under drag-reordering.
5. Split-pane semantics in Terminal 2.15 (one tty assumed).
6. The macOS release that first exposed `tab`'s `tty`, `selected`, and `do script … in`. Only 2.15 on macOS 26.5 was inspected.
7. `ps -t <tty>` foreground detection against a Terminal-hosted Codex and Claude, including npm-installed Codex process names (as ADR 0012 already notes).

## Sources

- Installed `/System/Applications/Utilities/Terminal.app` 2.15 (470.2) on macOS 26.5 (25F71): `Info.plist`, `version.plist`, `Contents/Resources/Terminal.sdef` (= `sdef` output), and `strings` of `Contents/MacOS/Terminal`.
- `/etc/zshrc_Apple_Terminal` (TERM_SESSION_ID and working-directory OSC 7 comments).
- `man ps` (`-t`, state `+`).
- Apple Terminal User Guide: [window title](https://support.apple.com/guide/terminal/trml15228/mac), [Tab settings 2.15 for macOS 26](https://support.apple.com/guide/terminal/change-profiles-tab-settings-trmltab/2.15/mac/26), [keyboard shortcuts 2.15](https://support.apple.com/guide/terminal/trmlshtcts/2.15/mac/26).
- Apple [Terminal 2 Release Notes](https://developer.apple.com/library/archive/releasenotes/DeveloperTools/RN-Terminal/index.html) (retired, Leopard).
- openai/codex [`terminal_title.rs`](https://github.com/openai/codex/blob/cc7ba33601286a751477832b01de7b6f8de0dd9c/codex-rs/tui/src/terminal_title.rs) at `cc7ba33`.
- Open Island `b50f87a`: `Sources/OpenIslandApp/TerminalJumpService.swift`, `TerminalSessionAttachmentProbe.swift`, `ForegroundTerminalSessionProbe.swift` and `TerminalTextSender.swift`, plus `Sources/OpenIslandCore/CodexHooks.swift` and `ClaudeHooks.swift`.
- Steer precedent: [ADR 0005](adr/0005-bind-ghostty-tabs-by-codex-title.md), [ADR 0011](adr/0011-open-herdr-panes-only-through-an-exact-ghostty-tty-join.md), [ADR 0012](adr/0012-bind-codex-herdr-panes-by-title-and-foreground-process.md), [Ghostty tty investigation](ghostty-tty-investigation.md).
