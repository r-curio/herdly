# iTerm2 scripting surface for exact tab targeting (#198)

Checked 2026-10-11 for [Research iTerm2's scripting surface for exact tab targeting](https://github.com/r-curio/steer/issues/198), a child of the map [Support iTerm2, Terminal.app, WezTerm and multiplexers](https://github.com/r-curio/steer/issues/197). Facts only. Decisions belong to the grilling tickets.

## Method and versions

- **Version checked:** iTerm2 **3.7.4**, the newest final release (Sparkle feed `https://iterm2.com/appcasts/final_modern.xml`, published 2026-10-08). The 3.6 line ends at 3.6.11. Source came from tag `v3.7.4` of [gnachman/iTerm2](https://github.com/gnachman/iTerm2/tree/v3.7.4). `master` (`5c60f132`, 2026-10-10) was compared where noted.
- **No installed app.** `/Applications` has no iTerm2, so no shipped bundle or `sdef` output was inspected. All dictionary facts come from `iTerm2.sdef` in the source tree. Whether a 3.7.4 build ships that file byte-for-byte is **unverified**. Ghostty's was identical (see [ghostty-tty-investigation.md](ghostty-tty-investigation.md)).
- **No live runs.** No Apple Events were sent and no iTerm2 or Python API calls were made. Every runtime behavior below comes from reading source or documentation. All of it is **unverified live**.
- **Open Island:** [Octane0411/open-vibe-island](https://github.com/Octane0411/open-vibe-island) at `b50f87aa7d58af1478837d48909eb68baa37f9b9`.
- **Official docs:** [AppleScript reference](https://iterm2.com/documentation-scripting.html) (the site's nav labels it "Scripting with AppleScript (Deprecated)") and [Scripting Variables](https://iterm2.com/documentation-variables.html). The [Python API docs](https://iterm2.com/python-api/) were not read. Python facts come from the library source in the same tag (`api/library/python/iterm2/iterm2/`).

Links below abbreviate `https://github.com/gnachman/iTerm2/blob/v3.7.4/` as **`iTerm2:`** and `https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/` as **`OI:`**.

## Summary

| Need | AppleScript (3.7.4) | Python API (3.7.4) |
| --- | --- | --- |
| Per-pane identifier | `session` `id` / `unique ID` (both the session GUID, text, read-only) | `Session.session_id` (same GUID) |
| Per-tab identifier | None. A tab has only `index`, `title` and `current session`. | Tab has `tab_id` (not examined in detail) |
| tty | `session` `tty` (text, read-only) | variable `tty` |
| Title | `session` `name` is a *composed* title. Exact OSC titles come from `variable named "terminalWindowName"` / `"terminalIconName"`. | same variables |
| Foreground process | `variable named "jobName"`, `"jobPid"`, `"commandLine"`, `"deepestJob"` | same variables |
| Split detection | `count of sessions of tab` | `Tab.sessions` |
| Select tab / pane | `select` on the window, tab and session. These are three separate effects, plus `activate` for the app. | `Session.async_activate(select_tab, order_window_front)` |
| Read focus | app `frontmost`, `current window`, window `current tab`, tab `current session` | the same, plus a push `FocusMonitor` |
| Input to one pane | `write text` / `write contents of file`. Fire-and-forget, no result. It **follows Broadcast Input**. | `async_send_text(text, suppress_broadcast=True)`. Returns OK or SessionNotFound. |
| Needs user config | None in iTerm2. macOS Automation consent for Steer → iTerm2 is required. | "Enable Python API" (default **off**), plus per-connection authorization |

## 1. Identifiers

From `iTerm2.sdef` ([iTerm2:iTerm2.sdef](https://github.com/gnachman/iTerm2/blob/v3.7.4/iTerm2.sdef)):

- **Application** (`capp`): `current window` (`Crwn`), `frontmost` (`pisf`, Cocoa key `isActive`), `version` (`vers`), element `window`.
- **Window** (`cwin`): `id` (integer, the window number, usable with `screencapture -l`), `alternate identifier` (text, `Twid`), `name` (title-bar text), `index`, `frontmost` (`pisf`, Cocoa key `scriptFrontmost`), `current tab` (`Crtb`), `current session` (`Wcsn`), `is hotkey window`, element `tab`, command `select`.
- **Tab** (`Trmt`): `current session` (`Wcsn`), `index` (`Indx`), `title` (`titl`), element `session`, commands `select` and `close`. **A tab has no `id` property in AppleScript.** A tab's object specifier is an *index* specifier into its window ([iTerm2:sources/Applescript/PTYTab+Scripting.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/Applescript/PTYTab%2BScripting.m)), so a held tab reference can point at a different tab after tabs are reordered or closed. A stable tab identity has to come from its session's `id`.
- **Session** (`Trms`): `id` (`ID  `, text, read-only, Cocoa key `guid`), `unique ID` (`Uniq`, text, read-only, also `guid`), `tty` (`Stty`, text, read-only), `name` (`pnam`, settable), `profile name`, `is processing`, `is at shell prompt` (requires shell integration), `contents`/`text`, `columns`, `rows`, commands `select`, `write`, `variable`, `set variable`, `close`, and the split commands.
- Sessions are addressed by a **unique-ID specifier**. `PTYSession -objectSpecifier` builds an `NSUniqueIDSpecifier` keyed on `guid`, and `PTYTab -valueInSessionsWithWithUniqueID:` resolves it ([iTerm2:sources/Applescript/PTYSession+Scripting.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/Applescript/PTYSession%2BScripting.m), PTYTab+Scripting.m). So `session id "<GUID>" of tab … of window …` resolves by GUID within its container. Whether `first session of every tab of every window whose id is "<GUID>"` style queries work was **not verified**.
- **`ITERM_SESSION_ID` / `TERM_SESSION_ID`:** iTerm2 sets both in the child environment to `w<window>t<tab>p<pane>:<GUID>` (`-[PTYSession sessionId]` and environment setup in [iTerm2:sources/PTYSession/PTYSession.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/PTYSession/PTYSession.m), around lines 3012 and 3189). It also sets `TERM_PROGRAM=iTerm.app` and `TERM_PROGRAM_VERSION`. The part after `:` equals AppleScript `id`. The `w/t/p` prefix is positional at launch time, and the variable `termid` carries it.
- These identifiers have not changed across versions. `tty`, `id`/`unique ID`, `write`, `select`, `variable`, `current tab`, `current session`, window `frontmost` and app `frontmost` all appear in `iTerm2.sdef` at `v3.0.0`, `v3.3.0`, `v3.5.0`, `v3.6.11`, `v3.7.4` and `master`. The only 3.6.11→3.7.4 dictionary change is two optional parameters on `request cookie`. `master` adds `create floating pane`, which is unreleased. Whether floating panes appear in a tab's `sessions` element was **not checked**.

## 2. tty, title and foreground process

### tty

`session` `tty` returns `[_shell tty]` ([PTYSession.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/PTYSession/PTYSession.m) `-tty`). The docs give the form `/dev/ttys01`. The value for an exited session and for tmux integration sessions was **not checked**.

### Titles: `name` is not the raw title

- `session` `name` returns the variable `name`, falling back to `profileName` and then `"Untitled"` (`-[PTYSession name]`). The variable `name` is "the formatted name as it appears in the tab bar… e.g. `My Profile (vim)`" ([variables doc](https://iterm2.com/documentation-variables.html)). It is computed by `iterm2.private.session_title` from the profile's **Title Components** ([iTerm2:sources/Language/BuiltInFunctions/iTermSessionTitleBuiltInFunction.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/Language/BuiltInFunctions/iTermSessionTitleBuiltInFunction.m)).
- The default Title Components for a profile with no saved value and no deprecated settings is **Job only** (`KEY_TITLE_COMPONENTS : @(iTermTitleComponentsJob)`, [iTerm2:sources/Settings/iTermProfilePreferences.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/Settings/iTermProfilePreferences.m) line 1175).
- **OSC 0 and OSC 1** (icon title) call `setUntrustedIconName:`. That sets `terminalIconName` and `autoNameFormat`, and then *temporarily* adds the Session Name component to the session's profile (`enableSessionNameTitleComponentIfPossible`, PTYSession.m around line 15652). With default components, `name` therefore becomes `<OSC title> (<job>)`, where job is the `processTitle` variable. That is a superstring of the title, not the title.
- **OSC 2** (window title only) sets only `terminalWindowName` (`setWindowTitle:`). It does **not** change `name` under default components. It does change the *window* title (`isWindowTitle` returns `windowName`).
- **Exact raw titles** are in variables: `terminalWindowName` ("as set by OSC 0 or OSC 2") and `terminalIconName` ("as set by OSC 0 or OSC 1") ([variables doc](https://iterm2.com/documentation-variables.html)). They are readable from AppleScript with `variable named "terminalWindowName"` on a session. The handler resolves the name in the session's variable scope, where session variables are unqualified (`iTermVariableScope+Session.m` adds them with `toScopeNamed:nil`). It returns a string, or `stringValue` for numbers ([PTYSession+Scripting.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/Applescript/PTYSession%2BScripting.m) line 122).
- Before setting, iTerm2 replaces `\(` in OSC titles with `\` + U+200B + `(`. Control characters become caret letters, and only the text before a newline is kept (`VT100Terminal.m` around line 2626, `screenSetWindowTitle:`).
- **Profile gate:** every OSC title change is dropped when the profile disables "Allow Title Setting" (`KEY_ALLOW_TITLE_SETTING`, default YES; `screenAllowTitleSetting`, checked in `VT100ScreenMutableState+TerminalDelegate.m`). This is user configuration that Steer cannot change.

### Codex and Claude titles specifically

- **Codex CLI** writes its title with **OSC 0** (`\x1b]0;{title}\x07`, [openai/codex `codex-rs/tui/src/terminal_title.rs`](https://github.com/openai/codex/blob/cc7ba33601286a751477832b01de7b6f8de0dd9c/codex-rs/tui/src/terminal_title.rs) at `main` `cc7ba336`). The shortened session ID from ADR 0005 should therefore appear exactly in both `terminalWindowName` and `terminalIconName`, and as `<title> (<job>)` in `name` under default components. This is inferred from source and **unverified live**, including what `processTitle` shows for Codex.
- **Claude Code under Steer** gets its title from Steer's `SessionStart` hook as **OSC 2** `Steer Claude <full-session-id>` (`Sources/SteerHook/main.swift` line 137). In iTerm2 that should set only `terminalWindowName`. Session `name` and tab `title` should **not** contain it under default components. Only `variable named "terminalWindowName"` (or the window `name` while that session is current) would show it. This is inferred from source and **unverified live**. Claude's own title (when `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` is unset) was not examined.

### Foreground process

These session variables are readable through `variable named "…"` ([variables doc](https://iterm2.com/documentation-variables.html), keys in [iTerm2:sources/Language/iTermVariables.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/Language/iTermVariables.m)):

- `jobName`: name of the foreground job. "As of version 3.7, jobName… reflects the job actually attached to the terminal, hiding helper subprocesses that run in the foreground process group but are piped to their parent (for example, an MCP server spawned by `claude`…)."
- `deepestJob`: the raw deepest foreground job, without that filtering.
- `jobPid`: PID of the current foreground job.
- `commandLine`: the foreground job with arguments.
- `processTitle`: the job's argv title, which may be modified by the process.
- `pid`: the session's root process (typically `login`).
- `foregroundJobAncestors` exists as a key. Its documentation was not found.

The dictionary has no direct foreground-process property. Earlier versions likely lacked the 3.7 `jobName` filtering. Exact first versions per variable were **not checked**.

## 3. Selecting a tab or pane and verifying it

The three `select` commands do different things ([iTerm2:sources/Applescript/](https://github.com/gnachman/iTerm2/tree/v3.7.4/sources/Applescript)):

| Target | Implementation | Effect |
| --- | --- | --- |
| `select` session | `[self.delegate setActiveSession:self]` | Makes it the active pane in its tab. The docs say it "Does not affect which tab is selected or which window has keyboard focus." |
| `select` tab | `[[parentWindow tabView] selectTabViewItemWithIdentifier:self]` | Selects the tab within its window |
| `select` window | `[[iTermController sharedInstance] setCurrentTerminal:…]` → `reallySetCurrentTerminal:` → `makeKeyAndOrderFront:` | Makes the window iTerm2's current terminal and key/front. It does **not** activate the app. A miniaturized window under "minimize to application icon" is deferred (`iTermSetCurrentTerminalHelper.m`). |
| `activate` (standard) | — | Activates iTerm2 |

All three handlers return nothing, so the command gives no success signal. Verification has to read state back:

- **App frontmost:** application `frontmost` (`isActive`). NSWorkspace's frontmost application gives the same fact without an Apple Event.
- **Window:** `current window` is `iTermController.currentTerminal`, documented as "the window that most recently had keyboard focus" ([iTerm2:sources/Applescript/iTermApplication+Scripting.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/Applescript/iTermApplication%2BScripting.m)). Window `frontmost` is `currentTerminal.window == self` (`scriptFrontmost`, `iTermWindowScriptingImpl.m` line 168). Both describe iTerm2's own notion of the current terminal. That notion is **not** cleared when another app comes to the front, so it is meaningful only together with app `frontmost`. The `windows` element is `NSApp.orderedWindows` filtered to terminal windows (`iTermApplication.m` `orderedScriptingWindows`), front to back.
- **Tab:** window `current tab`. Because tabs lack an `id`, compare `id of current session of current tab` against the target GUID. For an unsplit tab, `count of sessions` must be 1.
- **Pane:** tab `current session`, or window `current session`.

A hotkey window counts as a terminal window (`is hotkey window`). Buried sessions are not in any tab, so they are not reachable through `sessions of tab`. The Python API's send-text path explicitly includes buried sessions (`includeBuriedSessions:YES`).

**Python API:** `Session.async_activate(select_tab=True, order_window_front=True)` performs all three steps in one call ([session.py](https://github.com/gnachman/iTerm2/blob/v3.7.4/api/library/python/iterm2/iterm2/session.py)). Whether it also activates the app was **not checked**.

## 4. Reporting focus (visit acknowledgment)

- **AppleScript (poll):** one script can return `frontmost`, `id of current session of current tab of current window`, and `count of sessions of current tab of current window`. This is the same shape as Steer's Ghostty inventory. When no terminal window exists, `current window` is nil/missing. The exact error was **not checked**.
- **Python API (push):** `iterm2.FocusMonitor` delivers `FocusUpdate`s carrying one of `application_active`, `window_changed`, `selected_tab_changed` or `active_session_changed` ([focus.py](https://github.com/gnachman/iTerm2/blob/v3.7.4/api/library/python/iterm2/iterm2/focus.py)). It needs the Python API (see section 6).
- iTerm2 has no notion of whether the user actually looked. As with Ghostty, a selected tab in the frontmost app is the most either surface can report.

## 5. Input addressed to one pane

### AppleScript `write`

`write text "…" [newline NO]` and `write contents of file "…"` are sent to a session specifier ([PTYSession+Scripting.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/Applescript/PTYSession%2BScripting.m) line 69):

- `newline` defaults to YES and appends `\r`. Text and file together, or neither, raise script errors 1 and 2. Text goes to the pty as if typed (`writeTask:`). No bracketed-paste wrapping was seen on this path, so how a TUI receives embedded newlines is **unverified**.
- If the session's process has never produced output, the handler blocks in a `usleep(50000)` loop for up to about 1 s first (line 113).
- If the shell PID is not positive (an exited session), nothing is written and **no error** is raised. tmux integration clients go through `writeTask:` unconditionally.
- **The command returns no result.** There is no delivery confirmation beyond the absence of an Apple Event error, and nothing confirms that the receiving program read or acted on the bytes.
- **Broadcast Input applies.** `writeTask:` calls the broadcasting variant with `canBroadcast:YES`. If Broadcast Input is on for that session, the text goes to every session in the broadcast domain instead of only the addressed one (`writeTaskImpl:`, PTYSession.m around line 3969). AppleScript has no flag to suppress this, and the dictionary exposes no property that reports whether broadcast is on.

### Python API `async_send_text`

`Session.async_send_text(text, suppress_broadcast=False)` maps to `apiServerSendText:` ([iTerm2:sources/API/iTermAPIHelper.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/API/iTermAPIHelper.m) line 2443):

- It resolves the session by API identifier and returns `SessionNotFound` if the session is missing or exited, and `Ok` otherwise.
- `suppress_broadcast=True` uses `writeTaskNoBroadcast:`, so the text reaches only the addressed session.
- `Ok` means the bytes were queued to that session's pty. It is not an acknowledgment from the program.
- `async_inject` is different: it injects bytes as program *output*, not input.

## 6. Permissions and user configuration

- **AppleScript:** iTerm2's `Info.plist` sets `NSAppleScriptEnabled = YES` and `OSAScriptingDefinition = iTerm2.sdef` ([iTerm2:plists/release-iTerm2.plist](https://github.com/gnachman/iTerm2/blob/v3.7.4/plists/release-iTerm2.plist)). No source path was found that gates AppleScript behind an iTerm2 preference. macOS requires Automation (TCC) consent for the controlling app to send Apple Events to `com.googlecode.iterm2`. Steer's bundle has an `NSAppleEventsUsageDescription`, but its wording names Ghostty only (`scripts/build-app.sh` line 27). Whether consent is attributed to Steer or to `osascript` when Steer runs `osascript` as a child, as it does for Ghostty, was not checked for iTerm2.
- **Python API:** off by default (`kPreferenceKeyEnableAPIServer: @NO`, [iTerm2:sources/Settings/iTermPreferences.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/Settings/iTermPreferences.m) line 739). The user enables it in Settings ("Enable Python API"). The server is a websocket over the Unix socket `~/Library/Application Support/iTerm2/private/socket` ([iTermAPIServer.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/API/iTermAPIServer.m)), speaking protobuf (`api_pb2`).
- **Python API authorization:** an external client needs a cookie. The library reads `ITERM2_COOKIE`/`ITERM2_KEY`, or obtains one by sending the AppleScript `request cookie and key for app named "…"` ([auth.py](https://github.com/gnachman/iTerm2/blob/v3.7.4/api/library/python/iterm2/iterm2/auth.py)). That command fails with "The Python API is not enabled." while the API is off. A reusable cookie triggers an in-terminal announcement offering "24 Hours", "Forever", "Always Allow All Apps" or "Deny" ([iTermRequestCookieCommand.m](https://github.com/gnachman/iTerm2/blob/v3.7.4/sources/Applescript/iTermRequestCookieCommand.m)). Automation-auth can be disabled only by a root-owned `disable-automation-auth` file in iTerm2's Application Support (`iTermAPIHelper noauthPath`). Using the Python API therefore requires user configuration, which Steer never edits, plus Apple Events for the cookie.
- **iTerm2's own Claude Code integration (3.7):** iTerm2 3.7 ships a Claude Code onboarding (`sources/ClaudeCode/`). It enables the Python API, installs a `cc-status` hook into `~/.claude/settings.json`, and shows a Session Status toolbelt. Users of it will have the Python API on and an extra Claude hook. This is noted only as context and was not investigated further.

## 7. Detecting support and version without Apple Events

- **Bundle:** identifier `com.googlecode.iterm2`. Read `CFBundleShortVersionString` and `CFBundleVersion` from the running app's `NSRunningApplication.bundleURL` (or `NSWorkspace.urlForApplication(withBundleIdentifier:)`) `Contents/Info.plist`. In source both are the placeholder `unknown`, filled at build time, so the shipped value format is **unverified**.
- **Dictionary:** `Contents/Resources/iTerm2.sdef`, named by `OSAScriptingDefinition`. Section 1 lists the four-character codes. Every one needed for identify/select/write/focus has been present since 3.0.0, so a version floor matters less than for Ghostty's `tty`. A dictionary check like Ghostty's would test, for example, class `Trms` with properties `Stty` and `ID  `, command `Itrmsntx`, and command `Itrmvarb`.
- **Behavior differences not visible in the dictionary:** the 3.7 `jobName` filtering, and title semantics that depend on profile settings. A dictionary check cannot detect these.
- **Python API enabled?** The preference key is `EnableAPIServer` in iTerm2's defaults domain. Reading it is read-only, but iTerm2 can load preferences from a custom folder, so the defaults domain may not be authoritative. **Unverified.**
- AppleScript `version` of the application returns the version over Apple Events.

## 8. How Open Island does it (`b50f87a`)

### Capture (hook time)

- **Terminal detection** uses `TERM_PROGRAM` `iterm.app`/`iterm2`, falling back to `ITERM_SESSION_ID` or `LC_TERMINAL == "iTerm2"` ([OI:Sources/OpenIslandCore/CodexHooks.swift](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandCore/CodexHooks.swift) lines 699–734; ClaudeHooks.swift has the same at 1203–1258).
- **The value of `ITERM_SESSION_ID` is never used.** The session ID, tty and title come from a *focused-session locator*. The hook runs `osascript` with `tell current session of current window` → `id`, `tty`, `name` (CodexHooks.swift lines 785–802). It therefore records whichever iTerm2 session is focused when the hook runs, not necessarily the agent's own.
- **tty** comes first from the hook process's `/usr/bin/tty`, otherwise from the parent process's `ps -o tty=` (lines 762–783). The locator's tty is used only if those yield nothing (lines 624–635).

### Correction (polling)

`TerminalSessionAttachmentProbe` lists every session with `id`, `tty`, `name` in one AppleScript ([OI:…/TerminalSessionAttachmentProbe.swift](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandApp/TerminalSessionAttachmentProbe.swift) lines 1261–1310). It matches a snapshot to an agent session by equal `id`, else equal `tty`, else `name` **contains** the recorded pane title (lines 822–842). It then rewrites the jump target to the snapshot's values (lines 844–873). No uniqueness check was seen. `preferredSession` picks one session per snapshot.

### Jump (`jumpToITermSession`)

[OI:…/TerminalJumpService.swift](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandApp/TerminalJumpService.swift) lines 445–474:

1. `activate` iTerm.
2. Walk windows → tabs → sessions and take the first session whose `id` equals the stored ID, or else whose `tty` equals the stored tty.
3. `select aWindow`, `tell aWindow to select aTab`, `select aSession`, and return `"matched"`.

The selection is not read back. Splits are not checked. If nothing matches and the app is running with a precise locator, the code falls back to `open -b com.googlecode.iterm2` and reports "Exact pane targeting could not find the live terminal" (lines 422–425). For tmux, it selects the tmux pane first and then runs the same iTerm jump (lines 283–286).

### Focus check

`ForegroundTerminalSessionProbe` requires NSWorkspace's frontmost bundle to be `com.googlecode.iterm2`. It then reads `id` and `tty` of `current session of current window` and matches by ID, else by tty ([OI:…/ForegroundTerminalSessionProbe.swift](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandApp/ForegroundTerminalSessionProbe.swift) lines 92–107, 136–159).

### Text input

`TerminalTextSender` has **no iTerm2 path**. `canReply` is true only for tmux targets and Ghostty, and `send` handles only tmux `send-keys` and Ghostty `input text` ([OI:…/TerminalTextSender.swift](https://github.com/Octane0411/open-vibe-island/blob/b50f87aa7d58af1478837d48909eb68baa37f9b9/Sources/OpenIslandApp/TerminalTextSender.swift) lines 16–29). The phrase `write text` appears nowhere in Open Island's sources. iTerm2 replies work there only when the agent runs inside tmux. This differs from the map's note, which lists iTerm2 `write text` as Open Island's input route.

Open Island never uses the Python API.

## Open points (unverified)

- All runtime behavior is unverified live: the values of `tty`, `name`, `terminalWindowName` and `jobName` for real Codex and Claude sessions, `select`/`activate` results, and `write text` delivery into Codex's and Claude's TUIs, including newline and `\r` handling.
- Whether the shipped 3.7.4 bundle's `iTerm2.sdef` matches the source file.
- Under Codex's shared daemon (ADR 0012), a hook's `/usr/bin/tty`, parent tty and "focused session at hook time" describe the daemon's context or whatever pane has focus, not necessarily the Codex pane. This follows from Open Island's code and ADR 0012. It was not observed in iTerm2.
- Whether `session` `id` survives an iTerm2 restart with session restoration, or "Restore windows" arrangements, was not checked.
- How `tty` and the title variables behave for tmux integration (`-CC`) sessions. These are out of scope per the map.
- Whether `async_activate` activates the app, and the Python API's tab identifier semantics.
