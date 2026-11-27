# Build a fresh Codex companion

Build a fresh app, using Open Island as an architectural reference rather than forking its codebase. This keeps the implementation focused on the user's Codex workflow instead of inheriting a broad agent and terminal support matrix, at the cost of implementing and verifying the required integrations ourselves.

The choice of implementation technology and internal module boundaries remains open. Future flexibility does not require building support for other agents now.

Amended 2026-09-20 ([issue #80](https://github.com/r-curio/herdly/issues/80)): Claude Code is now supported alongside Codex, and terminal hosts beyond Ghostty followed under ADRs [0013](0013-bind-cli-sessions-to-terminal-tabs-by-tty.md) and [0014](0014-bind-multiplexer-panes-and-join-their-client-to-a-host-tab.md). Each was added for a concrete request and verified on its own; the decision not to inherit a broad agent and terminal matrix wholesale still stands.
