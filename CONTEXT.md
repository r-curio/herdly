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

**Thread name**:
The name Codex desktop gives a Codex session and shows in its sidebar. The companion displays it when Codex has recorded one and never invents a substitute; a session without one is labelled by its shortened identifier.

**Weekly limit**:
Codex's own figure for how much of its weekly usage window is used, read from the newest session rollout. The companion shows it on the strip while the window has not reset and never estimates it itself.

**Discovered session**:
A Codex session the companion shows as working before it has observed any of that session's own activity, because Codex's own record shows an unfinished turn and its surface is still alive. Discovery adds only a working indication; it never creates a completion, request, question, or sound.

**Approval request**:
A request from Codex for the user's permission to perform an action. Before handoff, the user can approve it once, deny it, or return to Codex for more context.

**Question request**:
A request from Codex for the user's answer to one or more questions, posed in the Codex surface. The companion surfaces it, relays the option the user chose in the notch to a CLI session, and otherwise returns the user to Codex; it never chooses an answer itself.

**Open in Codex**:
The action that returns the user to the Codex session associated with a notch notification.

**Attention queue**:
The ordered collection of Codex activity presented in the shared notch, with approval requests ahead of other activity. Its order determines presentation, not when Codex sessions execute.

**Acknowledged completion**:
A particular completion cleared by explicit dismissal; for a supported CLI surface, also by a verified visit after completion. Desktop app visibility never acknowledges a completion; the desktop app's own cleared unread flag, read from its state file after the completion, does (see [desktop read state](docs/desktop-read-state.md). This does not mean every result in the session has been read.

**Uncertain completion**:
A completion that arrived while the companion was not observing. The user may have viewed it unobserved, so it is retained without a sound and offered for opening or dismissal; it is never described as unread.

**Resolution evidence**:
A recorded sign that a handed-back approval request or a question request is no longer pending in Codex: Codex's recorded answer to that exact request or call, the end of that exact turn, or the end of its session. A prompt that merely disappeared is not evidence.
