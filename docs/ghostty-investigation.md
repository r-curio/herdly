# Direct CLI and Ghostty gate (#3)

Checked 2026-09-11. Status: blocked; exact live session-to-pane binding is not proven. [Issue #3](https://github.com/r-curio/steer/issues/3).

## Installed evidence

```sh
python3 scripts/probe_ghostty.py --self-test
python3 scripts/probe_ghostty.py
```

Both passed. This probe reads the app's plist and scripting dictionary plus four allowlisted variables from its own environment and its stdin TTY. It sends no Apple Events, controls no UI and changes no settings. Running it inside the Codex tool runner yielded no terminal context; that is not evidence about a direct Ghostty shell.

Installed Ghostty is `1.3.1`. Its scripting dictionary provides:

| Object | Relevant properties/actions |
| --- | --- |
| Application | Frontmost flag and front window |
| Window | Stable ID and selected tab |
| Tab | Stable ID and focused terminal |
| Terminal | Stable ID, title, working directory, focus action |

The installed terminal object does **not** expose TTY or process ID. A read-only string check of the installed binary found `GHOSTTY_RESOURCES_DIR` but neither `GHOSTTY_SURFACE_ID` nor `GHOSTTY_SESSION_ID`; the bundled shell integrations also had no matching ID/TTY variable assignments. This is static evidence, not a complete runtime environment test.

The [official AppleScript documentation](https://ghostty.org/docs/features/applescript) establishes the candidate focus/navigation API. A stable pane ID is useful only after it is reliably bound to the originating Codex session. Two sessions in the same directory cannot be distinguished by directory. Titles and whichever pane is frontmost when a hook arrives are also unsafe identifiers. Process ancestry/TTY alone cannot join to a dictionary that exposes neither.

Do not substitute one of those heuristics to pass the gate. A future runtime exposing a verifiable inherited pane identifier or a supported process/TTY mapping could resolve this gap; that would need its own installed-version test. No Ghostty upgrade or shell-launch wrapper was installed.

The independent CLI contract check in #2 ran against `/opt/homebrew/bin/codex`, version `0.145.0`. It confirmed lifecycle and approval schema definitions, not hook invocation or native terminal prompt behavior. Desktop uses `0.153.4`; do not inherit desktop approval results for this CLI.

## Live test blocker and remaining exercise

The computer-use tool rejected `/Applications/Ghostty.app` (`com.mitchellh.ghostty`) for safety reasons. No alternate UI-control route was attempted. No new tab, split, CLI session or approval prompt was created. macOS Automation permission availability is untested; the tool rejection does not prove a macOS permission denial.

In a permitted environment, run two disposable, normally launched Codex sessions in the same project: first in splits, then separate tabs/windows. Capture each session ID and authoritative pane binding from within the session; the probe above can record candidate terminal context without dumping other environment variables. Collect the frontmost app, selected tab, focused pane, requested target and independently observed result while moving between both sessions and another app.

Pass requires exact return to the originating pane, including from background, and no acknowledgment of A when only B is viewed. Close the target and revoke/unavailable observation in the test environment: the result must become unknown/unavailable without targeting another pane or typing keys. An accepted focus command alone is not proof of the final selected pane.

Separately exercise actual CLI lifecycle hooks and explicit allow once, deny, 30-second no-decision, disconnect, manual return and late-reply cases using disposable actions and isolated configuration. Capture request correlation and native resolution. Neither these approval cases nor same-directory focus/navigation cases have run. #6 remains blocked.
