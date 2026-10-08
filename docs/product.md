# Codex companion behavior

<!-- impeccable:product-schema 1 -->

## Current handed-back reminder behavior

Keep Continue in Codex after no-decision handoff, with only Open in Codex. Remove a reminder on evidence that its exact request was resolved: Codex's recorded output for that turn and command (allowed, rejected, or interrupted), structured completion or cancellation of its exact session and turn, or the end of its session. Other turns and other requests remain queued. Presence does not prove approval is still pending, and the row says so: it was handed back with no decision and Steer has not seen an answer yet. Open in Codex on an actionable CLI request hands back at once so Codex's own prompt appears immediately. Accessibility labels and keyboard interaction are covered by [notch placement](notch-placement.md). This supersedes older permission-still-needed wording below. See [approval reconciliation](approval-reconciliation.md).


## Platform

macos

Steer is a native macOS app rendering the macOS design language (SwiftUI content inside AppKit panels and windows). Design tooling that only recognizes web, iOS, or Android must not treat this project as web; when guidance is needed, adapt Apple's macOS Human Interface Guidelines, not iOS. See [the platform decision](adr/0003-use-native-macos-ui.md).

## Users

The primary user is the project owner: a developer who runs several Codex sessions at once in the Codex desktop app and in Codex CLI inside Ghostty, and who works in other applications while those sessions run. The job is to know, at a glance and without leaving the current app, which sessions are working, which need an answer, and which have finished, and to get back to the exact session when they choose to.

Other Mac developers with the same setup are a secondary audience once the MVP is proven. Future work should not yet assume unfamiliar users, marketing, or a public first-run flow.

## Product Purpose

Steer keeps the user aware of Codex work while they use other applications. It shows activity and requests for attention in a compact notch panel and lets the user return to the originating session. It exists because Codex's own surfaces only inform the user while they are looking at them.

Success is that the user keeps using Codex exactly as before, never misses an approval or completion while away, and never has Steer approve, dismiss, or mark anything read on their behalf without evidence.

## Positioning

Steer is a safe, exact companion. It never approves automatically, never claims a result was read without a verified signal, and returns the user to the exact session or Ghostty tab rather than to an app. Trustworthiness outranks feature breadth. A general agent dashboard, Codex's own notifications, or Notification Center could not truthfully make the same claim about handoff, acknowledgment, and exact targeting.

## Operating Context

- macOS 14 or later on a Mac, typically with a built-in notch display, sometimes with a second display.
- Codex desktop app (installed bundle identifies as com.openai.codex) and Codex CLI running directly in Ghostty, one session per unsplit tab.
- Steer runs as a background menu-bar app (LSUIElement) with a status item, a controls window, and the notch panel. It observes native app activation, Steer-owned Codex lifecycle hooks, and Ghostty tab titles carrying Codex's session ID.
- Launch at login is off until the user explicitly opts in. Its setting reflects macOS's ServiceManagement registration, including approval-required and unavailable states, rather than a saved Steer preference. A registered login launch is quiet: it does not open the controls window, while the menu-bar item and notch retain their normal behavior.
- Verification rituals: `swift test`, the ad-hoc build script, isolated hook labs and probe scripts under `scripts/`, and human walkthroughs recorded as evidence. Agreed behavior in this file is authoritative; a draft integration is not a proven capability.

## Capabilities and Constraints

Build a fresh native macOS app with SwiftUI and AppKit. Keep session and queue rules (SteerCore) separate from the platform interface (SteerApp). Other operating systems are outside the initial scope.

Confirmed capabilities and rules are detailed in the sections below and in the [domain glossary](../CONTEXT.md): one shared notch on the active display, separate working and to-check counts, a prioritized attention queue, 30-second approval handoff, three-second completion popups with a mutable sound, local persistence across restarts, and exact return to a desktop task or unsplit Ghostty tab.

Terminology is fixed by the glossary: companion, Codex surface, notch, Codex session, approval request, Open in Codex, attention queue, acknowledged completion, uncertain completion, resolution evidence.

Undecided product facts: the completion sound; a global hotkey for keyboard-only entry to the panel; exact desktop conversation focus; Ghostty split panes; the items listed under Open decisions below.

## Brand Commitments

- The name is Steer and is final.
- No icon, logo, wordmark, or completion sound exists yet. Future work must produce them rather than assume assets.
- Distribution is a personal ad-hoc signed build from `scripts/build-app.sh`. No App Store, notarization, or public download is planned.

## Evidence on Hand

- Recorded runtime evidence in `docs/evidence/`: CLI approval runtime and resolution, desktop turn start and completion, a desktop user-input question and its answer, notch placement, restart recovery.
- Human-verified walkthroughs recorded in [prototype.md](prototype.md), [notch-placement.md](notch-placement.md), and the investigation documents.
- Automated coverage: the SteerCore test suite (97 tests at the time of writing).
- No testimonials, customers, benchmarks, or screenshots for external audiences exist. Future work must not fabricate them.

## Product Principles

1. Preserve the Codex workflow: Codex stays fully usable when Steer is closed, and Steer never alters the user's real hook or permission configuration to test itself.
2. Fail closed: a timeout, error, or uncertainty never approves, never dismisses, and never marks anything read.
3. Say only what is known: the interface distinguishes verified state from uncertain state and never invents a missing reason, name, or read status.
4. Exact or unavailable: return the user to the precise session or tab, or say it is unavailable, never to an arbitrary target.
5. Attention, not control: the queue orders what the user sees; it never serializes or supervises Codex execution.

## Accessibility & Inclusion

Keyboard and VoiceOver operation of the notch panel are in scope: every row and button carries a label naming its action and subject, Tab moves through controls once the panel is key, Escape collapses without dismissing, and long commands read in full. Keyboard-only entry currently requires one click; a global hotkey is deferred. Placement follows the pointer's display unless the user has pinned a display.

## Initial supported surfaces

Support the Codex desktop app and Codex CLI running directly in Ghostty first. A terminal multiplexer is not part of the user's stated workflow. Other terminal hosts are outside the initial scope.

Monitor only Codex sessions running locally on the user's Mac in the first version. Remote Codex sessions, including sessions reached through SSH, are outside the initial scope. No remote session connection layer is required.

For the initial Ghostty scope, support one Codex session in an unsplit tab and return to that exact tab in its window. Multiple panes within a tab are deferred. Split tabs are unsupported for exact targeting and must return unavailable rather than selecting an arbitrary pane. Stable Ghostty remains the baseline; a prerelease is not required merely to support splits. Session-to-tab binding still needs verification, including two tabs in the same project. See ADR 0004.

The user's reference to ChatGPT desktop means its Codex work, not regular ChatGPT conversations. The installed /Applications/ChatGPT.app bundle identifies as com.openai.codex; scope remains Codex only. Available runtime integration points still require verification rather than assuming all desktop hosts expose the same capabilities.

## Agreed visibility behavior

Keep the Steer notch visible in every app, including Codex desktop and Codex CLI, even when there is no running activity or attention item. Foreground changes do not hide the strip or its queue. Notification popup and sound eligibility remain separate from notch visibility. Exact desktop conversation focus is deferred.

Keep desktop completions queued until explicitly dismissed or the desktop app records them read, as described below. No app activation or navigation result by itself marks a completion read.

Ghostty support retains its separate exact-pane requirement: using terminal pane B does not acknowledge activity from pane A. The shared notch remains visible while either Codex surface is active; visibility does not clear Ghostty items.

If app activation or the required Ghostty pane identity is unknown, retain queue items without acknowledgment and leave approvals in Codex's normal flow. Unknown desktop activation retains the indicator rather than guessing it was viewed. Release any pending approval interaction with no decision on uncertainty; only Open in Codex remains. App-level visibility alone does not establish safe direct desktop approval support.

Present one shared notch on the display the user is actively using. On a display without a physical notch, use a compact top-center panel. Do not duplicate the queue across displays. The active display is the one under the pointer, unless the user has pinned the notch to one display in the controls window or the menu bar item. A pinned display is used wherever the pointer is; while it is not connected the notch shows on the built-in display (or follows the pointer when there is no built-in display) and returns to the pinned display when it reconnects, with the pin kept. While the user is interacting with the panel (pointer over it or keyboard focus in it) placement stays on the panel's current display, and a display that disconnects is never chosen. Display changes and interaction never change the queue, replay a notification, or extend an approval deadline. See [notch placement and keyboard interaction](notch-placement.md).

## Agreed queue experience

Use one shared notch for multiple Codex sessions. Its compact state is a black strip fused to the bottom of the menu bar, a little wider than the camera housing, showing three readings on one line: a green pixel sprite that steps while any session is working and stands still otherwise, the task name of the top-priority item (Codex's task name when it provided one, otherwise the shortened session identifier), and a badge counting items to check, hidden at zero. To check counts pending approval requests, including requests handed back to Codex, unknown Claude waiting sessions, and unacknowledged completions. Hovering the strip expands the queue with approval requests ahead of other activity, and it collapses shortly after the pointer leaves; clicking gives the panel keyboard focus and keeps it open while focused. This is a queue for the user's attention; it does not serialize Codex execution.

Each approval request has its own 30-second handoff timer starting when the companion receives the request, including while it waits behind other requests. Opening the queue or reaching the request does not restart or extend its timer. Expired requests retain only Open in Codex while permission is still needed.

Queue priority is: actionable notch approvals, question requests waiting for the user's answer, requests handed back to Codex that still need an answer, unknown Claude waiting sessions, unacknowledged completions, then running tasks. Within each group, order by original arrival time, oldest first. A concrete approval or question for a Claude session replaces its generic waiting row so the same session is not counted twice. Expiration moves a request into the handed-back group without restarting its timer.

A session already working when the companion launches, or before its first hook event arrives, is shown as working from its rollout when there is liveness evidence for it: the desktop app running for a desktop session, its tab in Ghostty or a Codex CLI process for a CLI session, and no session end recorded since the turn began. Discovery only ever adds a running row; a completion, request, question, or sound still needs its own evidence. See [session discovery](session-discovery.md).

Codex's own background jobs are not the user's work and get no working row or completion. Agreed with the user on 2026-10-08 for memory consolidation, which Codex runs as a session of its own and was seen ending without a turn or session end. Steer recognises it by the prompt Codex itself submits; an approval or question from such a session still appears. See [desktop activity integration](desktop-live-integration.md#codex-background-jobs-2026-10-08).

A working row shows the latest readable `PreToolUse` action until its matching `PostToolUse`, then the last submitted prompt. Shell commands are always labelled as shortened in the row and remain available in full behind the row's disclosure. Missing or malformed tool data adds no action. Tool activity changes presentation only: it never changes attention priority, acknowledgment, or an approval deadline. Actions are not restored across a companion restart; a new tool event must arrive first. The installed payload shapes are recorded in [tool activity evidence](evidence/tool-activity.json).

Claude Code intake follows the same source-scoped attention model. For each configured Claude root,
Steer accepts only normalized helper records with the matching source marker and installation id.
Session and prompt observations identify the CLI session and turn; exact tool-use post events clear
only their matching action, while a bounded fresh `PreToolUse` may supply the current action. Missing
denial or interruption cleanup drops tool specificity without inventing a terminal result. `Stop` is
provisional and never creates Finished; `StopFailure` may report Failed. Claude question and approval
observations remain bounded, source-scoped state. For one live `AskUserQuestion` helper invocation,
Steer may retain one bounded ephemeral question request with its prompt and option labels while the
exact helper is waiting; it is bound to the installation, normalized Claude root, event directory,
session, prompt, tool-use, and request identities. A human-selected single choice, multi-select, or
typed answer can be returned once through Claude's supported `updatedInput` response. The request
does not become an answer capability after restart, and Steer stores no transcript or tool response.
One exact live Bash permission may be approved once or denied through the source-scoped helper
handshake. Ambiguous, expired, disconnected, interrupted, handed-back, and non-Bash permissions
keep only Claude's native controls. Interactive inventory status can add Working or Waiting rows;
background inventory alone does not create a queue row. A background done, failed, or stopped state
never creates a user-facing outcome without matching hook evidence. Per-root inventory reconciliation
is issue #82; mixed source presentation and counts in the existing notch are issue #83.

## Agreed mixed-source notch behavior

The notch presents Codex and Claude observations in one priority queue. Every row names its
source explicitly. Open in Codex and Open in Claude share one button label, "Open Session" (agreed 2026-10-08); the row already names the source. Claude cards explain when returning to the exact
tab is unavailable and show Open in Claude only after Ghostty controls, a complete live Claude
inventory, and one exact unsplit target are verified. Claude
uses its supplied session name for display when available and otherwise shows a shortened session
identifier, with the source prefix retained in both cases. The name is presentation metadata and does
not identify a target or claim who supplied it. Live rows read Working or Waiting. A finished, failed,
or stopped turn keeps that terminal label; when the current or terminal state cannot be classified,
the row says Status unavailable.

Claude questions use that live helper route only while exact identity and freshness checks succeed;
otherwise they show Waiting and explain that the answer belongs in Claude. Expiry, malformed or
mismatched records, helper loss, uncertainty, and a companion restart send nothing and leave Claude's
native question authoritative. Generic Claude Waiting rows still count as to-check attention, while
their exact tab return is unavailable until targeting is verified. Automated checks and the isolated
helper trace cover the response shape; integrated Steer behavior for each answer
kind and native fallback after timeout has not yet been observed in use. Claude completion
cards retain Dismiss and explain the unavailable return action without rendering an unsupported Open
control.
Claude follow-up prompts and direct approval decisions beyond Bash stay unavailable until their
transports are separately proven; the card explains that limitation instead of guessing a target.
Codex cards keep their existing answer, approval, detail, and reply actions.

Mixed-source release checks require reviewed source, automated tests, package
build, helper self-test, and packaged smoke check. Integrated live behavior is
unverified until observed during use; a scripted operator pass is optional.

Each fresh Claude question or outcome can sound and spotlight once for three seconds. Repeated
observations, discovery, and restart recovery do not replay either presentation. An outcome that
arrived before Steer restarted is uncertain and silent. After five minutes, an unacknowledged
outcome moves into Earlier while retaining its to-check count and Dismiss action; Codex retains Open
in Codex, while Claude keeps the unavailable return explanation. This is
presentation decay, not deletion or acknowledgment. Claude has no trustworthy read receipt; only
explicit dismissal, a later verified exact-tab visit, or a reply can acknowledge its outcome. Agreed
on 2026-10-08: a prompt submitted in a Claude session (its `UserPromptSubmit`) acknowledges that
session's outcomes from other turns that arrived strictly before the prompt. An outcome arriving at
or after the prompt, and outcomes of other sessions or roots, stay queued. Steer cannot tell a typed
prompt from one injected by a script (for example `herdr agent prompt`), so such a prompt also
acknowledges; the user accepted that.

## Agreed approval experience

Direct approval and denial remain a separately gated feature: keep desktop approvals native until the approval transport and an applicable handoff policy are verified. The app-level visibility change does not enable approval buttons. Each approval request also offers an Open in Codex action so the user can return to the originating session and read more context before deciding.

An unanswered notch approval hands back to Codex after 30 seconds. Before handoff, offer Approve once, Deny, and Open in Codex. After handoff, continue indicating that permission is needed but offer only Open in Codex; the user then decides in Codex. For any future verified desktop approval interaction, foregrounding Codex must hand the decision back immediately; Ghostty uses return to the originating pane. This handoff does not dismiss completion notifications. A timeout or handoff never approves the action automatically.

Approve once applies only to the current request. Persistent permission settings remain in Codex; the notch does not offer always-allow rules.

Approval cards show the task name, project, requested command or action, and Codex's reason when available, above Approve once, Deny, and Open in Codex. Long details can expand for inspection before deciding. Do not invent a missing reason or imply that a shortened command is the complete action.

The companion preserves the user's existing Codex approval settings and does not introduce approval requests for actions Codex already permits.

## Agreed question experience

When Codex asks the user a question (its request-user-input panel, in the desktop app or CLI), show a "Codex needs an answer" item while the user is away from that Codex surface. The card shows what Codex's own panel shows: the current question's header, its position when there are several ("1 of 2"), the question text, and the numbered option labels; the remaining questions open on request. Option descriptions and the free-text field stay in Codex, and shortened text says so. For a CLI session in Ghostty with Ghostty controls enabled, the options are controls: a click relays that one option to the session's own tab as its digit, and the card says what was sent and that Steer is waiting for Codex to record the answer. For a desktop session the options are a pick that opens the thread and stays highlighted on the card. A question Steer cannot number exactly (typed answers, more options than it shows, unreadable text) offers only Open in Codex. Offer Open in Codex and Dismiss always; the companion never chooses for the user, never sends on a timeout or error, and never resends.

Agreed on 2026-09-14, live proof partly recorded (issue #42): when a Codex app-server daemon is running and holds the question, the card's options and a typed-answer field answer exactly through it, by call id, for CLI and desktop threads alike; the card says which path it uses, and the Ghostty relay and the desktop pick remain the fallback when no daemon holds the question. Source: [answering through the app-server daemon](user-input-requests.md#answering-through-the-app-server-daemon); socket access per [ADR 0007](adr/0007-connect-to-the-codex-daemon-socket-as-the-same-user.md); the capability is claimed only once the notch-side live proof is recorded. Because a session attached to the daemon is recorded like a desktop one and outlives its terminal, a CLI session is also recognised by its session-id Ghostty tab title, and closing that tab ends the session in the notch (agreed with the user on 2026-09-14).

A fresh question opens its own card for three seconds with the completion sound, under the same rules as a completion; a question already waiting when the companion started is listed without a sound. The item clears on resolution evidence: Codex's recorded answer to that call, the end of its turn, or the end of its session. Dismissal is not remembered across restarts, so an unanswered question returns. While a session waits on a question it is not shown as working. Source: [user-input requests](user-input-requests.md).

## Agreed completion experience

For desktop completions, present the notification while outside the Codex app; for Ghostty, while outside the originating pane. Expand the panel to that completion's card alone for three seconds, then collapse it; a new question or approval request opens its own card the same way. Hover and keyboard focus keep that one spotlight card visible instead of replacing it with the whole queue. Clicking the header explicitly opens the whole queue; after the spotlight ends, ordinary hover does too. Keep a card open while the user is interacting with it. This completion display timer is separate from the 30-second approval handoff deadline; interaction must not extend an approval deadline. Keep desktop completions in the attention queue until explicitly dismissed. Ghostty completions may also be acknowledged by a verified visit to their originating pane. For herdr panes on a Ghostty without `tty`, an interim rule accepts a weaker visit until a Ghostty with `tty` ships (ADR 0011, [#155](https://github.com/r-curio/steer/issues/155)). Collapsing the notch does not acknowledge or remove the completion.

Agreed on 2026-09-14 (issue #46): a completion card carries a single-line reply field with a Send action, so the user can read a result and send a follow-up prompt to that session without switching applications. Enter sends; Escape still collapses the panel without dismissing the completion. The prompt starts a new turn on that exact thread through the app-server daemon, on the same socket as question answers; the Ghostty relay carries one key and nothing more (ADR 0006), so a session the daemon does not hold has no reply path and the field is disabled with the reason on the card. A session Codex is mid-turn for, including one blocked on a question, is refused the same way: the target is ambiguous. The socket is proven, `turn/start` is not — the capability is claimed only once a live run records a reply Codex took. One card sends one reply: after sending, the card says what was sent and that Steer is waiting for Codex to record the turn, and Steer never sends on a timeout or error and never resends. Sending does not acknowledge the completion; the next turn start shows the session as working. Source: [session replies](session-replies.md).

Play a short completion sound as that card opens. Provide a mute control. With Reduce Motion on, the sprite breathes instead of stepping and the panel resizes without animation. Reopening the queue does not replay the sound. The specific sound is not yet selected.

The spotlight is intentionally distilled for quick understanding and action. The existing title and session label identify what happened and where; the body adds only useful context that is not already visible: task, working directory, action, command, reason, full request, and an approval deadline when present. It shows the notification's prompt or question, current user-facing status, and every valid action, but omits technical identifiers, transport routes, and duplicate state or source labels. A fresh completion also shows the exact turn's original prompt when recorded and a plain-text final-response preview capped at five lines or 600 characters. These conversation excerpts exist only in process memory; they are not written to Steer's snapshot. A restored completion says that its preview is unavailable after restart. The full queue remains compact.

Preserve unacknowledged completions locally across companion restarts. Revalidate pending approval state before offering any active approval controls; never restore an old button as an actionable request solely from saved data. Completion presentation must respect the agreed priority of approval requests.

The companion runs quietly in the background even while the notch is hidden. For desktop, completion acknowledgment happens by explicit dismissal or when the desktop app's own unread flag for that thread is cleared after the completion ([desktop read state](desktop-read-state.md)); Steer never marks anything read itself. Store dismissal per completion, not permanently for the session. A completion received while Codex is foreground remains queued for presentation when away. Once presented, foreground/background changes must not replay its sound. Ghostty's verified per-pane acknowledgment remains a separate integration requirement.

If the companion was fully quit when the user visited the result, that visit may not be recoverable. Restored notifications must not be described as authoritatively unread without a verified Codex read-status signal. Retain uncertain completions without replaying their sound and let the user open or dismiss them. Fully quitting the companion stops its background observation.

## Agreed herdr presentation

Agreed with the user on 2026-10-07 (issue #114). This covers how herdr readiness and unavailable reasons appear for Claude Code and Codex CLI sessions in a herdr tab hosted by Ghostty. Binding, transport, question relay and Open follow ADRs [0008](adr/0008-bind-herdr-panes-when-steer-and-herdr-agree.md) (Claude), [0012](adr/0012-bind-codex-herdr-panes-by-title-and-foreground-process.md) (Codex, issue #144), [0009](adr/0009-talk-to-herdr-over-its-socket-and-poll-snapshots.md), [0010](adr/0010-relay-codex-question-options-as-herdr-pane-keys.md) and [0011](adr/0011-open-herdr-panes-only-through-an-exact-ghostty-tty-join.md). The settings row and the notch reason lines are implemented (#127), and failed Opens (#125) and unrelayable questions (#126) route through the same groups (#141).

**Settings.** The Terminals page shows a read-only herdr row under Ghostty, with no switch of its own. herdr works only while Ghostty controls are on. Until ADR 0009's gate opens (a Claude session has reported running in herdr, or a Codex session is live while herdr's default socket passes ADR 0009's trust check), the row says "No herdr sessions seen", Steer does not contact herdr, and the badge reads Not in use. The row says the same when herdr's server is not running and no Claude session reported a pane. Otherwise the badge reads Ready or Needs attention, and the row lists every problem that applies, one per line, because they are independent fixes:

- herdr's Claude integration missing or not current while Steer has seen Claude in herdr: the exact `herdr integration install claude` command with a Copy button. Steer never runs it or edits herdr's configuration.
- Ghostty cannot identify herdr's tab: update Ghostty. Steer decides this by checking that Ghostty exposes each terminal's `tty`, not by comparing version numbers. The message names a Ghostty version only once a release has been verified to provide it.
- herdr unavailable (not found in the fixed locations, not running, unsupported protocol, untrusted socket, and similar): generic wording.

**Notch.** Rows never label a session as running in herdr. When Open in Codex or Open in Claude is unavailable for a herdr session, the card replaces Open with one reason line and shows no disabled button, as Claude cards do. The internal reasons fall into four groups the user can act on:

- Ghostty too old: "Update Ghostty to return to herdr panes."
- Integration missing or not current (Claude only; Codex needs no herdr integration): run `herdr integration install claude`.
- Layout not supported (a split, several herdr clients, a named herdr session, a Ghostty tab in another window): "Steer returns only to a single-pane herdr tab in one Ghostty window."
- Everything else: "Open Session is unavailable until Steer can verify the exact herdr pane."

The exact internal reason goes to diagnostics, not to the card. Every action whose own route still works stays on the card while Open is unavailable: Dismiss, details, CLI approve or deny through the hook, and question options when ADR 0010's checks pass. If Open passes the scan but fails its recheck at click time, the same grouped reason appears in the navigation message, the item is retained, and the card swaps Open for the reason line on the next scan. When a Codex question cannot be relayed and Open is also unavailable, the card shows one line: "Answer this in Codex." followed by Open's grouped reason. Why the relay failed goes to diagnostics.

## Integration findings

Codex's documented PermissionRequest hook runs before the normal approval prompt. It can return allow or deny, or leave the decision to Codex's normal approval flow. A hook-based notch approval therefore needs an explicit handoff policy; simultaneous actionable prompts in the notch and Codex are not established by this interface. Source: https://learn.chatgpt.com/docs/hooks#permissionrequest (checked 2026-09-11).

This is an integration finding, not a selected transport. Desktop app and CLI behavior still require separate verification.

Codex runs hooks only when `features.hooks = true` is set in config.toml, and runs a non-managed hook only after its exact definition is trusted; trust is recorded per handler in config.toml as `[hooks.state."<hooks.json path>:<event>:<group>:<handler>"] trusted_hash = "sha256:…"`, a SHA-256 of the canonical JSON of the normalized handler (SessionEnd timeouts clamp to 3 s before hashing). Configure Codex sets the feature flag and records trust for exactly the handlers it installs, since the user approved them in the preview; a hook Codex marks as changed reads as repair-required. Verified against seven entries recorded by CLI 0.145.0 and the desktop app's bundled 0.153.4 (checked 2026-09-14). Codex desktop also rewrites config.toml on its own, so Steer owns only its lines and hook entries: status checks their presence, reinstall re-baselines on the current files, and undo removes exactly Steer's additions, restoring the original files verbatim only when they are still byte-identical to the install.

The documented app-server thread/read method retrieves conversation data; it is not a user-view receipt. No authoritative user-view notification was established in the reviewed app-server reference. Exact desktop focus is deferred; Ghostty pane focus still requires technical verification. Source: https://learn.chatgpt.com/docs/app-server (checked 2026-09-11).

The [first desktop investigation](codex-desktop-investigation.md) found private conversation-level read-state events in the installed app and confirmed lifecycle/approval protocol definitions with a runnable probe. The user subsequently verified task-link navigation from Codex and Apple Notes. App-level visibility still needs live implementation verification, and approval handoff remains unverified; computer-use access to Codex was blocked.

## Open decisions

- The technical mechanism for releasing a pending companion interaction and restoring normal approval behavior, including timeout and approval races.
- Verify native desktop app-activation observation and exact Ghostty pane identity. Exact desktop conversation focus is deferred, not an MVP gate.
- Multi-display, Spaces, and full-screen behavior are implemented under the documented rule; the operator walkthrough in [notch placement](notch-placement.md) is still to be recorded on a second display.
- Validate the proposed module boundaries and transport in [architecture.md](architecture.md) against the required integration checks.


CLI lab completions now enter the shared notch after matching session/turn completion evidence. Ghostty navigation is opt-in once and remembered across launches; the first launch offers it before macOS asks for Automation access; uncertain targeting retains the notification. See [CLI integration](cli-notch-integration.md).


A handed-back approval reminder clears when the exact originating session/turn completes or is explicitly canceled. Cancellation does not create a successful-completion notification. Missing logs and application focus alone do not clear approval reminders.

## Selected Ghostty tab binding

Use Codex’s session-ID terminal title as the stable-version mapping candidate (ADR 0005). This changes the visible title while Codex runs. Match only one unsplit tab, reject ambiguity, and preserve normal launching. First verify using a temporary command-line override; no saved user setting has been changed.
