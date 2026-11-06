# Codex companion

A companion that keeps the user aware of Codex work while they use other applications.

## Language

**Companion**:
The product being designed, used alongside the existing Codex desktop app and CLI.
_Avoid_: Codex replacement

**Codex surface**:
The existing Codex desktop app or CLI through which the user works with Codex.

**Notch**:
The companion's compact display at the top of the screen, intended to show Codex activity while the user works outside the relevant session.

**Codex session**:
An individual Codex conversation in the desktop app or CLI, distinct from its hosting application.

**Terminal host**:
The terminal environment that contains a CLI session's terminal: an unsplit tab of a supported terminal (Ghostty, iTerm2, Terminal.app, WezTerm) that the user switched on in Herdly, or a single-pane tmux window, Zellij tab or herdr tab whose one client runs in such a tab.
_Avoid_: Terminal app, window

**Multiplexer**:
A program that runs terminal panes inside one client in a terminal tab: tmux, Zellij or herdr. A session in a multiplexer has two layers, its pane and the terminal host tab running the client.
_Avoid_: Terminal host (for the multiplexer alone), session manager

**Tab binding**:
The association between a CLI session and the one unsplit terminal tab running it. For Claude Code it follows the session's own process to its tab. For Codex it holds only while exactly one tab runs a Codex process in its foreground and shows the session's shortened identifier as its title. It is void once the tab closes, its foreground process changes, the session ends, or, for Codex, the title changes.
_Avoid_: Tab match, tab mapping

**Pane binding**:
The association between a CLI session and the one multiplexer pane (tmux, Zellij or herdr) running it. For Codex it holds only while exactly one pane runs a Codex process in its foreground and shows the session's shortened identifier as its title. For Claude Code it follows the session's own process to its pane, or, where the multiplexer cannot show which pane a process runs in, holds only while the companion's own record of the pane agrees with an independent signal (the multiplexer's report of the pane's session, or the session's process running under that multiplexer). It is void once the session ends or any of these stops holding. The tab running the multiplexer's client is found separately, by that client's terminal.
_Avoid_: Pane mapping, pane match

**Thread name**:
The name Codex desktop gives a Codex session and shows in its sidebar. The companion displays it when Codex has recorded one and never invents a substitute; a session without one is labelled by its shortened identifier.

**Weekly limit**:
Codex's own figure for how much of its weekly usage window is used, read from the newest session rollout. The companion shows it on the strip while the window has not reset and never estimates it itself.

**Five-hour limit**:
Codex's own figure for how much of its five-hour usage window is used, reported together with the weekly limit. The companion shows it beside the weekly limit only while Codex reports one that has not reset; a plan without a short window shows nothing in its place.

**Claude subscription window**:
Claude's own five-hour or seven-day subscription window from a status-line payload, qualified by one configuration root and session. The companion shows each independently while it remains current on Herdly's clock, ignores gateway spend limits, and reports missing or unproved windows as unavailable.

**Discovered session**:
A Codex session the companion shows as working before it has observed any of that session's own activity, because Codex's own record shows an unfinished turn and its surface is still alive. Discovery adds only a working indication; it never creates a completion, request, question, or sound.

**Approval request**:
A request from Codex for the user's permission to perform an action. Before handoff, the user can approve it once, deny it, or return to Codex for more context.

**Question request**:
A request from Codex for the user's answer to one or more questions, posed in the Codex surface. The companion surfaces it, relays the option the user chose in the notch to a CLI session, and otherwise returns the user to Codex; it never chooses an answer itself.

**Session reply**:
A follow-up prompt the user types on a completion card and sends to that finished session, which starts its next turn. The companion sends one reply per card, only to the session the card is about, and only through a transport that reaches that exact session; it never resends and never treats sending as having acknowledged the completion; the turn start the reply causes acknowledges it like any prompt in that session.

**Typed input**:
A question option's digit or a session reply that the companion types into the one terminal pane a session is bound to, after the user chose or wrote it in the notch. It reaches only that pane, is sent at most once, and is never an approval.
_Avoid_: Keystrokes, injection

**Clicked card**:
An approval request or question request the user opened from the attention queue by clicking its row, shown alone in place of the queue with a way back to it. It has no timed close, moves an approval's deadline only for the hover pause (ADR 0020), and ends on Escape, the way back, an action, the end of interaction, or its request leaving the queue; it never shows a different item.
_Avoid_: Spotlight (that is the automatic card that closes after the card-open time, 3 seconds by default), detail view

**Row note**:
The short delivery line a queue row carries after the user approved, denied, or answered it in the notch: sending, sent but unconfirmed, not delivered, or waiting for Codex. It belongs to one exact request, says only what Herdly observed about delivery, and clears with that request's resolution evidence, never returning afterwards. A one-time approval Claude's helper confirms has no note: its row leaves the queue.
_Avoid_: Status message, toast, navigation message

**Open in Codex**:
The action that returns the user to the originating Codex session of a notch notification; Claude's equivalent is Open in Claude. These are the action's names; its button labels are product presentation and live in the product and design docs.

**Attention queue**:
The ordered collection of Codex activity presented in the shared notch, with approval requests ahead of other activity. Its order determines presentation, not when Codex sessions execute. The user may sort the remaining rows "Newest first" instead of "By need"; live approvals (soonest deadline first) and waiting questions stay first either way. Ungrouped, its rows that need the user sit under kind sections (see **Queue section**).

**Queue section**:
One of the open queue's kind headings when it is not grouped: Approve (live approvals), Answer (waiting questions), or Check (everything else that needs the user), each with its count; working rows stay in the "N working" fold, or, when nothing needs the user, sit under Working with their count (#319, F1, agreed 2026-10-21). A later section may fold its extra rows behind "+N more", which opens in place; live approvals never fold. Presentation only: a section or fold never changes counts, the strip, acknowledgment, or a deadline (D13, agreed 2026-10-21, #314).
_Avoid_: Group (that is the user's Group by choice), "Needs you" (the retired heading)

**Exception word**:
The single word a queue row carries when it is off its normal path: Failed, Handed back, Waiting, Status unknown, or Unreachable. Approve, answer, check, and stopped have none, because the section says the kind; a live approval shows its seconds left instead (D17, agreed 2026-10-21, #314). Unreachable marks a result row whose session Herdly cannot open and takes the slot ahead of any other word (#322).
_Avoid_: Tag, kind pill

**Result row**:
An open-queue row for a recent or Earlier result, a Claude session waiting, or one whose status is unknown. It is one line; clicking it, or Return on it, opens its session through the usual Open, and its Dismiss (or Remove) sits on the line. An unreachable result row shows why under its name and cannot be clicked. Opening it acknowledges nothing (D20, agreed 2026-10-21, #322).
_Avoid_: Completion card (the spotlight card), Earlier fold

**Open fallback**:
An Open that raises the session's terminal app, without selecting a tab or pane, because the exact tab or pane cannot be reached. It is navigation only: it never counts as a visit, acknowledges nothing, and is never an input target.
_Avoid_: Partial open, best-effort open

**Acknowledged completion**:
A particular completion cleared by explicit dismissal; for a supported CLI surface, also by a verified visit after completion; when it arrives while its terminal tab or pane is already in front, by that tab or pane staying visible for five seconds after it arrived; or by a later prompt submitted in the same session. Desktop app visibility never acknowledges a completion; the desktop app's own cleared unread flag, read from its state file after the completion, does (see [desktop read state](docs/desktop-read-state.md). This does not mean every result in the session has been read.

**Uncertain completion**:
A completion that arrived while the companion was not observing. The user may have viewed it unobserved, so it is retained without a sound and offered for opening or dismissal; it is never described as unread.

**Resolution evidence**:
A recorded sign that a handed-back approval request or a question request is no longer pending in Codex: Codex's recorded answer to that exact request or call, the end of that exact turn, or the end of its session. A prompt that merely disappeared is not evidence.
