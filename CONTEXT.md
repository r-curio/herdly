# Agent companion

A companion that keeps the user aware of supported local coding-agent work while they use other applications.

## Language

**Companion**:
The product being designed, used alongside the existing Codex desktop app and CLI.
_Avoid_: Codex replacement

**Codex surface**:
The existing Codex desktop app or CLI through which the user works with Codex.

**Agent source**:
The upstream coding agent a session belongs to, currently Codex or Claude Code.

**Agent surface**:
The existing app or CLI through which the user works with an agent source.

**Agent session**:
An individual conversation or unit of agent work, distinct from its hosting application and qualified by its agent source.

**Notch**:
The companion's compact display at the top of the screen, intended to show supported agent activity while the user works outside the relevant session.

**Codex session**:
An individual Codex conversation in the desktop app or CLI, distinct from its hosting application.

**Session name**:
The name an agent source gives an agent session. The companion displays it without claiming whether the user or agent created it and falls back to the shortened session identifier.
_Avoid_: Thread name

**Weekly limit**:
Codex's own figure for how much of its weekly usage window is used, read from the newest session rollout. The companion shows it on the strip while the window has not reset and never estimates it itself.

**Five-hour limit**:
Codex's own figure for how much of its five-hour usage window is used, reported together with the weekly limit. The companion shows it beside the weekly limit only while Codex reports one that has not reset; a plan without a short window shows nothing in its place.

**Discovered session**:
An agent session the companion shows as working before it has observed any of that session's own activity, because the agent source reports current work and its surface is still alive. Discovery adds only a working indication; it never creates an outcome, request, question, or sound.

**Session outcome**:
A verified terminal result of agent work: Finished for success, Failed for failure, or Stopped for interruption. When the result cannot be classified, the session has Status unavailable rather than an invented outcome.

**Earlier outcome**:
An unacknowledged session outcome whose presentation has moved below current work after its decay period. It remains available to open or dismiss and is not considered read.

**Approval request**:
A request from an agent source for the user's permission to perform an action. Before handoff, the user can approve it once, deny it, or return to the source for more context when a verified direct-decision route exists.

**Question request**:
A request from an agent source for the user's answer to one or more questions. The companion surfaces it, relays only the answer the user chose through a verified route, and otherwise returns the user to the source; it never chooses an answer itself.

**Session reply**:
A follow-up prompt the user types on a completion card and sends to that finished session, which starts its next turn. The companion sends one reply per card, only to the session the card is about, and only through a transport that reaches that exact session; it never resends and never treats the reply as having acknowledged the completion.

**Open in Codex**:
The action that returns the user to the Codex session associated with a notch notification.

**Open in Claude**:
The action that returns the user to the exact Claude Code session associated with a notch notification, or reports that the target is unavailable.

**Attention queue**:
The ordered collection of supported agent activity presented in the shared notch, with approval requests ahead of other activity. Its order determines presentation, not when agent sessions execute.

**Acknowledged completion**:
A particular completion cleared by explicit dismissal; for a supported CLI surface, also by a verified visit after completion. Desktop app visibility never acknowledges a completion; the desktop app's own cleared unread flag, read from its state file after the completion, does (see [desktop read state](docs/desktop-read-state.md). This does not mean every result in the session has been read.

**Acknowledged outcome**:
A particular session outcome cleared by explicit dismissal or source-specific evidence defined by the product contract. Acknowledgment does not claim that every result in the session was read.

**Uncertain completion**:
A completion that arrived while the companion was not observing. The user may have viewed it unobserved, so it is retained without a sound and offered for opening or dismissal; it is never described as unread.

**Uncertain outcome**:
A session outcome restored without continuous observation. It is retained without a repeated sound and offered for opening or dismissal; it is never described as unread.

**Resolution evidence**:
A recorded sign that a handed-back approval request or a question request is no longer pending in Codex: Codex's recorded answer to that exact request or call, the end of that exact turn, or the end of its session. A prompt that merely disappeared is not evidence.
