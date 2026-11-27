# Defer Ghostty split-pane support

Accepted (recorded 2026-09-12). Amended by ADR 0015 (below); tty binding accepted by ADR 0013.

The initial Ghostty integration targets the correct tab and window, with one Codex session in an unsplit tab. Exact targeting among multiple panes within a tab is deferred. This reduces the interaction scope while preserving normal Codex launching and the stable Ghostty baseline.

Issue #3 must prove two sessions in separate tabs/windows, including the same project, and retain its independent CLI lifecycle/approval checks. Closed, ambiguous or split targets return unavailable/unknown; no input goes to an arbitrary terminal.

Amended 2026-10-11 by [ADR 0015](0015-raise-the-terminal-app-when-open-cannot-reach-the-exact-target.md): Open on an ambiguous or split target raises Ghostty without selecting a tab or pane (an Open fallback). A closed target stays unavailable, and no input goes to a fallback target.

Deferring panes does not establish session-to-tab identity. Stable tab IDs are useful only after a reliable binding is proven. Do not assume cwd or the currently selected tab identifies the originating session. The prerelease PID/TTY path remains research, not an accepted runtime requirement.

Amended 2026-11-27: tty binding is no longer research. [ADR 0013](0013-bind-cli-sessions-to-terminal-tabs-by-tty.md) accepted it on 2026-10-11, and Herdly detects at runtime whether the installed Ghostty exposes a terminal's `tty` (`GhosttyTTYSupport`; see the [Ghostty tty investigation](../ghostty-tty-investigation.md)).
