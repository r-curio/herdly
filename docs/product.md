# Codex companion behavior

## Current handed-back reminder behavior

Keep Continue in Codex after no-decision handoff, with only Open in Codex. Remove reminders on structured completion of their exact session and turn; other turns remain queued. Presence does not prove approval is still pending. Accessibility cleanup is deferred. This supersedes older permission-still-needed wording below. The current integration reads the isolated approval lab; it does not install general hooks.


## Platform

Build a fresh native macOS app with SwiftUI and AppKit. Keep session and queue rules separate from the platform interface. Other operating systems are outside the initial scope; see [the platform decision](adr/0003-use-native-macos-ui.md).

## Initial supported surfaces

Support the Codex desktop app and Codex CLI running directly in Ghostty first. A terminal multiplexer is not part of the user's stated workflow. Other terminal hosts are outside the initial scope.

Monitor only Codex sessions running locally on the user's Mac in the first version. Remote Codex sessions, including sessions reached through SSH, are outside the initial scope. No remote session connection layer is required.

The user uses Ghostty tabs/windows and split panes. Session focus detection and Open in Codex must target the individual pane within the appropriate tab and window. Exact targeting remains a capability to verify, not an assumed implementation guarantee.

The user's reference to ChatGPT desktop means its Codex work, not regular ChatGPT conversations. The installed /Applications/ChatGPT.app bundle identifies as com.openai.codex; scope remains Codex only. Available runtime integration points still require verification rather than assuming all desktop hosts expose the same capabilities.

## Agreed visibility behavior

For the desktop MVP, hide the notch whenever the Codex desktop app is foreground. When the user is in another app, show the notch if there is running activity or an attention item. This applies even when the user is viewing a different Codex conversation: viewing B also hides A's notification. Exact desktop conversation focus is deferred.

Hiding changes presentation only. Keep desktop completions queued until explicitly dismissed, including after Open in Codex, manual navigation, or foreground/background changes. No app activation or navigation result marks a completion read.

Ghostty support retains its separate exact-pane requirement: using terminal pane B does not acknowledge activity from pane A. The desktop foreground rule hides the shared notch while Codex desktop is active; it does not clear Ghostty items either.

If app activation or the required Ghostty pane identity is unknown, retain queue items without acknowledgment and leave approvals in Codex's normal flow. Unknown desktop activation retains the indicator rather than guessing it was viewed. Release any pending approval interaction with no decision on uncertainty; only Open in Codex remains. App-level visibility alone does not establish safe direct desktop approval support.

Present one shared notch on the display the user is actively using. On a display without a physical notch, use a compact top-center panel. Do not duplicate the queue across displays. The exact active-display selection rule and behavior while the user is interacting with the panel still need to be defined and verified.

## Agreed queue experience

Use one shared notch for multiple Codex sessions. Its compact state shows separate counts, such as "3 working · 2 to check". Working counts tasks currently working; to check counts pending approval requests, including requests handed back to Codex, and unacknowledged completions. Clicking expands the queue with approval requests ahead of other activity. This is a queue for the user's attention; it does not serialize Codex execution.

Each approval request has its own 30-second handoff timer starting when the companion receives the request, including while it waits behind other requests. Opening the queue or reaching the request does not restart or extend its timer. Expired requests retain only Open in Codex while permission is still needed.

Queue priority is: actionable notch approvals, requests handed back to Codex that still need an answer, unacknowledged completions, then running tasks. Within each group, order by original arrival time, oldest first. Expiration moves a request into the handed-back group without restarting its timer.

## Agreed approval experience

Direct approval and denial remain a separately gated feature: keep desktop approvals native until the approval transport and an applicable handoff policy are verified. The app-level visibility change does not enable approval buttons. Each approval request also offers an Open in Codex action so the user can return to the originating session and read more context before deciding.

An unanswered notch approval hands back to Codex after 30 seconds. Before handoff, offer Approve once, Deny, and Open in Codex. After handoff, continue indicating that permission is needed but offer only Open in Codex; the user then decides in Codex. For any future verified desktop approval interaction, foregrounding Codex must hand the decision back immediately; Ghostty uses return to the originating pane. This handoff does not dismiss completion notifications. A timeout or handoff never approves the action automatically.

Approve once applies only to the current request. Persistent permission settings remain in Codex; the notch does not offer always-allow rules.

Approval cards show the task name, project, requested command or action, and Codex's reason when available, above Approve once, Deny, and Open in Codex. Long details can expand for inspection before deciding. Do not invent a missing reason or imply that a shortened command is the complete action.

The companion preserves the user's existing Codex approval settings and does not introduce approval requests for actions Codex already permits.

## Agreed completion experience

For desktop completions, present the notification while outside the Codex app; for Ghostty, while outside the originating pane. Expand for three seconds, then collapse it. Keep it open while the user is interacting with it. This completion display timer is separate from the 30-second approval handoff deadline; interaction must not extend an approval deadline. Keep desktop completions in the attention queue until explicitly dismissed. Ghostty completions may also be acknowledged by a verified visit to their originating pane. Collapsing the notch does not acknowledge or remove the completion.

Play a short completion sound when that notification first appears. Provide a mute control. Reopening the queue does not replay the sound. The specific sound is not yet selected.

Preserve unacknowledged completions locally across companion restarts. Revalidate pending approval state before offering any active approval controls; never restore an old button as an actionable request solely from saved data. Completion presentation must respect the agreed priority of approval requests.

The companion runs quietly in the background even while the notch is hidden. For desktop, completion acknowledgment requires explicit dismissal; observing a visit is outside this MVP. Store dismissal per completion, not permanently for the session. A completion received while Codex is foreground remains queued for presentation when away. Once presented, foreground/background changes must not replay its sound. Ghostty's verified per-pane acknowledgment remains a separate integration requirement.

If the companion was fully quit when the user visited the result, that visit may not be recoverable. Restored notifications must not be described as authoritatively unread without a verified Codex read-status signal. Retain uncertain completions without replaying their sound and let the user open or dismiss them. Fully quitting the companion stops its background observation.

## Integration findings

Codex's documented PermissionRequest hook runs before the normal approval prompt. It can return allow or deny, or leave the decision to Codex's normal approval flow. A hook-based notch approval therefore needs an explicit handoff policy; simultaneous actionable prompts in the notch and Codex are not established by this interface. Source: https://learn.chatgpt.com/docs/hooks#permissionrequest (checked 2026-09-11).

This is an integration finding, not a selected transport. Desktop app and CLI behavior still require separate verification.

The documented app-server thread/read method retrieves conversation data; it is not a user-view receipt. No authoritative user-view notification was established in the reviewed app-server reference. Exact desktop focus is deferred; Ghostty pane focus still requires technical verification. Source: https://learn.chatgpt.com/docs/app-server (checked 2026-09-11).

The [first desktop investigation](codex-desktop-investigation.md) found private conversation-level read-state events in the installed app and confirmed lifecycle/approval protocol definitions with a runnable probe. The user subsequently verified task-link navigation from Codex and Apple Notes. App-level visibility still needs live implementation verification, and approval handoff remains unverified; computer-use access to Codex was blocked.

## Open decisions

- The technical mechanism for releasing a pending companion interaction and restoring normal approval behavior, including timeout and approval races.
- Verify native desktop app-activation observation and exact Ghostty pane identity. Exact desktop conversation focus is deferred, not an MVP gate.
- How to identify the active display and keep panel interaction stable while display focus changes.
- Validate the proposed module boundaries and transport in [architecture.md](architecture.md) against the required integration checks.


CLI lab completions now enter the shared notch after matching session/turn completion evidence. Ghostty navigation is opt-in per app launch during this investigation; uncertain targeting retains the notification. See [CLI integration](cli-notch-integration.md).
