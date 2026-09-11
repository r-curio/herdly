# Codex companion behavior

## Platform

Build a fresh native macOS app with SwiftUI and AppKit. Keep session and queue rules separate from the platform interface. Other operating systems are outside the initial scope; see [the platform decision](adr/0003-use-native-macos-ui.md).

## Initial supported surfaces

Support the Codex desktop app and Codex CLI running directly in Ghostty first. A terminal multiplexer is not part of the user's stated workflow. Other terminal hosts are outside the initial scope.

Monitor only Codex sessions running locally on the user's Mac in the first version. Remote Codex sessions, including sessions reached through SSH, are outside the initial scope. No remote session connection layer is required.

For the initial Ghostty scope, support one Codex session in an unsplit tab and return to that exact tab in its window. Multiple panes within a tab are deferred. Split tabs are unsupported for exact targeting and must return unavailable rather than selecting an arbitrary pane. Stable Ghostty remains the baseline; a prerelease is not required merely to support splits. Session-to-tab binding still needs verification, including two tabs in the same project. See ADR 0004.

The user's reference to ChatGPT desktop means its Codex work, not regular ChatGPT conversations. The installed /Applications/ChatGPT.app bundle identifies as com.openai.codex; scope remains Codex only. Available runtime integration points still require verification rather than assuming all desktop hosts expose the same capabilities.

## Agreed visibility behavior

While the user works outside the relevant Codex session and Codex is working, show a compact status indicator in the notch. Expand it when Codex finishes or needs input. Hide that session's notch notification when the user returns to that specific session.

Focus is session-specific: using terminal tab B does not hide activity from Codex in tab A, and viewing another conversation in the Codex desktop app does not hide activity from the originating conversation. Bringing the hosting application to the foreground alone does not count as returning. Other sessions can keep the shared notch visible.

If the companion cannot reliably identify the focused session, retain the relevant notification without marking it acknowledged and leave approvals in Codex's normal flow. If a notch approval is already pending when focus becomes uncertain, hand it back without approving or denying it. The notch then offers only Open in Codex for that request.

Present one shared notch on the display the user is actively using. On a display without a physical notch, use a compact top-center panel. Do not duplicate the queue across displays. The exact active-display selection rule and behavior while the user is interacting with the panel still need to be defined and verified.

## Agreed queue experience

Use one shared notch for multiple Codex sessions. Its compact state shows separate counts, such as "3 working · 2 to check". Working counts tasks currently working; to check counts pending approval requests, including requests handed back to Codex, and unacknowledged completions. Clicking expands the queue with approval requests ahead of other activity. This is a queue for the user's attention; it does not serialize Codex execution.

Each approval request has its own 30-second handoff timer starting when the companion receives the request, including while it waits behind other requests. Opening the queue or reaching the request does not restart or extend its timer. Expired requests retain only Open in Codex while permission is still needed.

Queue priority is: actionable notch approvals, requests handed back to Codex that still need an answer, unacknowledged completions, then running tasks. Within each group, order by original arrival time, oldest first. Expiration moves a request into the handed-back group without restarting its timer.

## Agreed approval experience

Include direct approval and denial from the notch in the first version. Each approval request also offers an Open in Codex action so the user can return to the originating session and read more context before deciding.

An unanswered notch approval hands back to Codex after 30 seconds. Before handoff, offer Approve once, Deny, and Open in Codex. After handoff, continue indicating that permission is needed but offer only Open in Codex; the user then decides in Codex. Returning to the originating Codex session hands the decision back immediately. A timeout or handoff never approves the action automatically.

Approve once applies only to the current request. Persistent permission settings remain in Codex; the notch does not offer always-allow rules.

Approval cards show the task name, project, requested command or action, and Codex's reason when available, above Approve once, Deny, and Open in Codex. Long details can expand for inspection before deciding. Do not invent a missing reason or imply that a shortened command is the complete action.

The companion preserves the user's existing Codex approval settings and does not introduce approval requests for actions Codex already permits.

## Agreed completion experience

When Codex finishes while the user is outside that session, expand the notch for three seconds, then collapse it. Keep it open while the user is interacting with it. This completion display timer is separate from the 30-second approval handoff deadline; interaction must not extend an approval deadline. Keep the completion in the attention queue until the user opens the originating session or explicitly dismisses it. Collapsing the notch does not acknowledge or remove the completion.

Play a short completion sound when that notification first appears. Provide a mute control. Reopening the queue does not replay the sound. The specific sound is not yet selected.

Preserve unacknowledged completions locally across companion restarts. Revalidate pending approval state before offering any active approval controls; never restore an old button as an actionable request solely from saved data. Completion presentation must respect the agreed priority of approval requests.

The companion runs quietly in the background even while the notch is hidden. Acknowledgment must also work when the user navigates directly to the originating Codex session without opening the notch. Observe the exact focused session after completion and store acknowledgment for that completion rather than permanently for the entire session. Focus is a proxy for visiting a result, not proof that the user read its contents. The technical mechanism for exact session identification still requires verification.

If the companion was fully quit when the user visited the result, that visit may not be recoverable. Restored notifications must not be described as authoritatively unread without a verified Codex read-status signal. Retain uncertain completions without replaying their sound and let the user open or dismiss them. Fully quitting the companion stops its background observation.

## Integration findings

Codex's documented PermissionRequest hook runs before the normal approval prompt. It can return allow or deny, or leave the decision to Codex's normal approval flow. A hook-based notch approval therefore needs an explicit handoff policy; simultaneous actionable prompts in the notch and Codex are not established by this interface. Source: https://learn.chatgpt.com/docs/hooks#permissionrequest (checked 2026-09-11).

This is an integration finding, not a selected transport. Desktop app and CLI behavior still require separate verification.

The documented app-server thread/read method retrieves conversation data; it is not a user-view receipt. No authoritative user-view notification was established in the reviewed app-server reference. Exact desktop conversation and Ghostty pane focus detection still requires technical verification. Source: https://learn.chatgpt.com/docs/app-server (checked 2026-09-11).

The [first desktop investigation](codex-desktop-investigation.md) found private conversation-level read-state events in the installed app and confirmed lifecycle/approval protocol definitions with a runnable probe. Live focus, exact navigation, and approval handoff remain unverified; the computer-use tool blocked access to Codex's interface.

## Open decisions

- The technical mechanism for releasing a pending companion interaction and restoring normal approval behavior, including timeout and approval races.
- How to detect the specific focused terminal session or desktop conversation. The agreed experience is a requirement, not yet verified integration capability; the uncertainty fallback is settled above.
- How to identify the active display and keep panel interaction stable while display focus changes.
- Validate the proposed module boundaries and transport in [architecture.md](architecture.md) against the required integration checks.

## Selected Ghostty tab binding

Use Codex’s session-ID terminal title as the stable-version mapping candidate (ADR 0005). This changes the visible title while Codex runs. Match only one unsplit tab, reject ambiguity, and preserve normal launching. First verify using a temporary command-line override; no saved user setting has been changed.
