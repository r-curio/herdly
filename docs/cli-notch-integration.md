# CLI notch integration — issue #3

This branch carries the existing desktop reminder integration as a separate baseline commit and adds CLI completions plus Ghostty navigation. The previous worktrees and their uncommitted files remain unchanged.

The selected events folder is read every two seconds. Session identity and source come from the matching Codex rollout metadata. Only CLI Stop records whose exact session/turn also has task_complete enter the CLI queue. Desktop reminders retain their desktop links. CLI reminders and completions route through the Ghostty adapter. Old completions restore silently; new completions expand for three seconds with the existing muteable sound. Explicit dismissals and verified visits persist completion-specific acknowledgments. Later turns are independent.

The app packages the native JXA adapter and includes the Automation usage description. Ghostty controls start disabled every launch. The user enables them in Steer controls; failed native access disables further queries and leaves notifications intact. Native calls happen off the UI thread with a five-second process deadline. Matching requires a live tracked session, the exact shortened UUID title, one unique terminal and no splits. The adapter revalidates immediately before selection and verifies the resulting foreground window/tab/terminal. Missing, ambiguous or changed targets are not acknowledged. A focus/navigation result acknowledges only completions captured before its asynchronous query.

Build: `sh scripts/build-app.sh`. Tests: `swift test` (six tests), including real file-reader/queue reconstruction and title matching. Native navigation remains unverified in Ghostty because the agent's computer-use restriction still applies. This is a lab integration, not installation of global hooks or proof that sessions outside the connected lab are monitored.

For human navigation testing, run Codex directly in two unsplit Ghostty tabs in the already trusted lab using `/opt/homebrew/bin/codex -m gpt-5.5 -s read-only -a on-request -c 'tui.terminal_title=["session-id"]'`. Connect the lab events directory in Steer if needed, then manually enable Ghostty controls and grant Automation permission if macOS asks. Send distinct no-tools completion prompts, switch to another app, then use each completion's Open in Codex button. Verify the correct tab is selected, and repeat across two windows. No saved Codex hooks, permission policies or terminal settings are modified by this build.

## Live Steer UI proof

The release build and strict code-sign verification passed. Replaced the running older Steer instance with this build, leaving its files intact. Computer use inspected only Steer: after reading the existing selected lab directory, controls reported one reminder and six CLI completions. Expanding the actual notch showed CLI completion rows, the CLI reminder, Dismiss actions and disabled Open buttons while Ghostty controls remained off. No Ghostty API, native selection or Automation permission prompt was invoked. The new build remains running from `output/Steer.app`.

## Reminder-only expansion fix

Reproduced a real one-item notch that would not expand. CLI reminders were counted and rendered as visible over Codex Desktop, but their shared presentation timer still applied desktop-only suppression. The presentation now uses the same visible-reminder list as the count and rows. Added a focused regression covering a CLI reminder with desktop foreground, plus its three-second collapse.

When Ghostty is disabled, CLI completion and reminder rows now expose Set up Ghostty rather than an unexplained disabled Open button. This opens Steer controls without enabling native access automatically. Setup guidance also covers reminder-only queues. Seven Swift tests, release build and strict signing verification passed. Live Steer UI confirmed the single reminder expands visibly and Set up Ghostty opens controls. Native Ghostty access remained off.

## Missing title configuration during navigation test

The user reported the generic navigation failure for reminder session 01a09139. Inspection found saved `terminal_title = []`; the earlier denial-test launch instructions omitted the session-title override. This explains why that test did not establish the required title binding; live inventory was not inspected, so other navigation failure causes remain possible. No saved settings were changed. Navigation feedback now distinguishes unreadable inventory, no unique matching live title (showing the expected title), rejected selection and unverified foreground state. Use a fresh session with the explicit per-launch title override for the next test.

## Human-verified Ghostty navigation

After launching a fresh CLI session with the explicit session-ID title override, the user confirmed that Open in Codex navigated correctly. The user then repeated the workflow with a second session in another Ghostty tab and confirmed that it worked. This is human-reported success for distinguishing two sessions and opening their corresponding tabs from another app, using the connected notch build. The agent did not control Ghostty. Separate-window navigation, direct-return acknowledgment and native failure-state behavior remain separate live checks; the prior hook status warnings are still unresolved.
