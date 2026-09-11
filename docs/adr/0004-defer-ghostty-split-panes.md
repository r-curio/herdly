# Defer Ghostty split-pane support

The initial Ghostty integration targets the correct tab and window, with one Codex session in an unsplit tab. Exact targeting among multiple panes within a tab is deferred. This reduces the interaction scope while preserving normal Codex launching and the stable Ghostty baseline.

Issue #3 must prove two sessions in separate tabs/windows, including the same project, and retain its independent CLI lifecycle/approval checks. Closed, ambiguous or split targets return unavailable/unknown; no input goes to an arbitrary terminal.

Deferring panes does not establish session-to-tab identity. Stable tab IDs are useful only after a reliable binding is proven. Do not assume cwd or the currently selected tab identifies the originating session. The prerelease PID/TTY path remains research, not an accepted runtime requirement.
