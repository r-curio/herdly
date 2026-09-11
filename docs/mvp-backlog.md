# macOS MVP backlog

[Milestone](https://github.com/r-curio/steer/milestone/1) · [All MVP issues](https://github.com/r-curio/steer/issues?q=is%3Aissue+label%3Amvp)

Start with desktop verification (#1 and #2), as requested. Ghostty verification (#3) is a separate prerequisite for CLI support. Feature tickets stay blocked until their prerequisite evidence exists. HITL requires live human verification; AFK can proceed independently once its blockers are resolved.

| Ticket | Type | Blocked by |
| --- | --- | --- |
| [#1 Prove Codex desktop conversation focus and exact jump-back](https://github.com/r-curio/steer/issues/1) | HITL | None |
| [#2 Prove desktop lifecycle events and safe approval handoff](https://github.com/r-curio/steer/issues/2) | HITL | None |
| [#3 Prove local Codex CLI tracking and exact Ghostty pane targeting](https://github.com/r-curio/steer/issues/3) | HITL | None |
| [#4 Show a live desktop task in a native macOS companion](https://github.com/r-curio/steer/issues/4) | AFK | [#1](https://github.com/r-curio/steer/issues/1), [#2](https://github.com/r-curio/steer/issues/2) |
| [#5 Connect and disconnect Codex safely from app settings](https://github.com/r-curio/steer/issues/5) | AFK | [#4](https://github.com/r-curio/steer/issues/4) |
| [#6 Show live Ghostty CLI sessions and jump to their exact panes](https://github.com/r-curio/steer/issues/6) | AFK | [#3](https://github.com/r-curio/steer/issues/3), [#4](https://github.com/r-curio/steer/issues/4), [#5](https://github.com/r-curio/steer/issues/5) |
| [#7 Present all sessions in one prioritized attention queue](https://github.com/r-curio/steer/issues/7) | AFK | [#4](https://github.com/r-curio/steer/issues/4), [#6](https://github.com/r-curio/steer/issues/6) |
| [#8 Notify on completion with a three-second popup and sound](https://github.com/r-curio/steer/issues/8) | AFK | [#7](https://github.com/r-curio/steer/issues/7) |
| [#9 Approve once or deny a live Codex request from the notch](https://github.com/r-curio/steer/issues/9) | AFK | [#2](https://github.com/r-curio/steer/issues/2), [#5](https://github.com/r-curio/steer/issues/5), [#6](https://github.com/r-curio/steer/issues/6), [#7](https://github.com/r-curio/steer/issues/7) |
| [#10 Reconcile approvals answered in Codex after handoff](https://github.com/r-curio/steer/issues/10) | AFK | [#9](https://github.com/r-curio/steer/issues/9) |
| [#11 Restore activity and acknowledgments safely after restart](https://github.com/r-curio/steer/issues/11) | AFK | [#8](https://github.com/r-curio/steer/issues/8), [#10](https://github.com/r-curio/steer/issues/10) |
| [#12 Keep the notch usable across displays and keyboard interaction](https://github.com/r-curio/steer/issues/12) | AFK | [#8](https://github.com/r-curio/steer/issues/8), [#9](https://github.com/r-curio/steer/issues/9) |
| [#13 Package and verify the first installable macOS MVP](https://github.com/r-curio/steer/issues/13) | HITL | [#5](https://github.com/r-curio/steer/issues/5), [#10](https://github.com/r-curio/steer/issues/10), [#11](https://github.com/r-curio/steer/issues/11), [#12](https://github.com/r-curio/steer/issues/12) |

## Delivery sequence

1. Prove desktop and Ghostty integrations on the installed runtimes. Source/schema inspection alone is insufficient.
2. Ship live desktop activity, reversible setup, then Ghostty activity in the native app.
3. Add the shared queue, three-second completion notifications and sound, and real bounded approvals.
4. Finish native handoff reconciliation, restart recovery, display/keyboard behavior, and packaging.

The MVP is not complete until the integrated live desktop and CLI checks in #13 pass. Issues with unresolved blockers must not be marked ready. These tickets do not authorize bypassing UI tool restrictions or altering real user configuration for tests.
