# macOS MVP backlog

[Milestone](https://github.com/r-curio/herdly/milestone/1) · [All MVP issues](https://github.com/r-curio/herdly/issues?q=is%3Aissue+label%3Amvp)

Start with desktop verification (#1 and #2), as requested. Ghostty verification (#3) is a separate prerequisite for CLI support. Feature tickets stay blocked until their prerequisite evidence exists. HITL requires live human verification; AFK can proceed independently once its blockers are resolved.

| Ticket | Type | Blocked by |
| --- | --- | --- |
| [#1 Prove Codex desktop app visibility and exact jump-back](https://github.com/r-curio/herdly/issues/1) | HITL | None |
| [#2 Prove desktop lifecycle events and safe approval handoff](https://github.com/r-curio/herdly/issues/2) | HITL | None |
| [#3 Prove local Codex CLI tracking and exact Ghostty pane targeting](https://github.com/r-curio/herdly/issues/3) | HITL | None |
| [#4 Show a live desktop task in a native macOS companion](https://github.com/r-curio/herdly/issues/4) | AFK | [#1](https://github.com/r-curio/herdly/issues/1), [#2](https://github.com/r-curio/herdly/issues/2) |
| [#5 Connect and disconnect Codex safely from app settings](https://github.com/r-curio/herdly/issues/5) | AFK | [#4](https://github.com/r-curio/herdly/issues/4) |
| [#6 Show live Ghostty CLI sessions and jump to their exact panes](https://github.com/r-curio/herdly/issues/6) | AFK | [#3](https://github.com/r-curio/herdly/issues/3), [#4](https://github.com/r-curio/herdly/issues/4), [#5](https://github.com/r-curio/herdly/issues/5) |
| [#7 Present all sessions in one prioritized attention queue](https://github.com/r-curio/herdly/issues/7) | AFK | [#4](https://github.com/r-curio/herdly/issues/4), [#6](https://github.com/r-curio/herdly/issues/6) |
| [#8 Notify on completion with a three-second popup and sound](https://github.com/r-curio/herdly/issues/8) | AFK | [#7](https://github.com/r-curio/herdly/issues/7) |
| [#9 Approve once or deny a live Codex request from the notch](https://github.com/r-curio/herdly/issues/9) | AFK | [#2](https://github.com/r-curio/herdly/issues/2), [#5](https://github.com/r-curio/herdly/issues/5), [#6](https://github.com/r-curio/herdly/issues/6), [#7](https://github.com/r-curio/herdly/issues/7) |
| [#10 Reconcile approvals answered in Codex after handoff](https://github.com/r-curio/herdly/issues/10) | AFK | [#9](https://github.com/r-curio/herdly/issues/9) |
| [#11 Restore activity and acknowledgments safely after restart](https://github.com/r-curio/herdly/issues/11) | AFK | [#8](https://github.com/r-curio/herdly/issues/8), [#10](https://github.com/r-curio/herdly/issues/10) |
| [#12 Keep the notch usable across displays and keyboard interaction](https://github.com/r-curio/herdly/issues/12) | AFK | [#8](https://github.com/r-curio/herdly/issues/8), [#9](https://github.com/r-curio/herdly/issues/9) |
| [#13 Package and verify the first installable macOS MVP](https://github.com/r-curio/herdly/issues/13) | HITL | [#5](https://github.com/r-curio/herdly/issues/5), [#10](https://github.com/r-curio/herdly/issues/10), [#11](https://github.com/r-curio/herdly/issues/11), [#12](https://github.com/r-curio/herdly/issues/12) |

Desktop MVP scope: hide the shared notch while Codex desktop is foreground; keep desktop completions until explicitly dismissed. Exact desktop task focus is deferred. Ghostty retains its pane-specific requirements. Direct approvals remain gated by their own integration proof.

## Delivery sequence

1. Prove desktop and Ghostty integrations on the installed runtimes. Source/schema inspection alone is insufficient.
2. Ship live desktop activity, reversible setup, then Ghostty activity in the native app.
3. Add the shared queue, three-second completion notifications and sound, and real bounded approvals.
4. Finish native handoff reconciliation, restart recovery, display/keyboard behavior, and packaging.

The MVP is not complete until the integrated live desktop and CLI checks in #13 pass. Issues with unresolved blockers must not be marked ready. These tickets do not authorize bypassing UI tool restrictions or altering real user configuration for tests.

## After the MVP

- **Answer Codex questions by call id through the app-server daemon.** Follow-up to ADR 0006. Codex's TUI attaches to a running local daemon (`~/.codex/app-server-control/app-server-control.sock`), and any client subscribed to a thread receives `item/tool/requestUserInput` and may answer it; the others get `serverRequest/resolved`. A Herdly JSON-RPC client on that socket would replace the Ghostty key relay with an exact per-call answer and would cover desktop threads if the desktop app ever attaches to the same daemon. Tracked as issue #42. Built as a draft integration on 2026-09-14 (`AppServerQuestions.swift`, `AppServerDaemonClient.swift`, fake-client tests and a fake-daemon lab); it stays inert until a daemon socket exists. Still blocked on: a daemon in the user's workflow (`codex app-server daemon start` refuses without the managed standalone install), proof on the installed CLI that a second client receives the pending request, ([ADR 0007](adr/0007-connect-to-the-codex-daemon-socket-as-the-same-user.md) on socket authentication was accepted on 2026-09-14, and the user chose to install the standalone package). Not a prerequisite for anything in the MVP.
