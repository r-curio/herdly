# Bind unsplit Ghostty tabs through Codex's session title

Use Codex's built-in `tui.terminal_title = ["session-id"]` setting as the selected stable-Ghostty mapping candidate. It changes the displayed terminal title but does not replace the Codex launcher or require a terminal upgrade. Multiple panes per tab remain deferred by ADR 0004.

Codex CLI 0.145.0 renders this item as the first 29 characters of the canonical session UUID followed by three ASCII dots. Match the entire terminal name against that rendered value, then resolve its containing tab and window. Never use cwd, the currently focused terminal, a generic task title or substring matching as fallback. Require a unique title among tracked live sessions and exactly one matching terminal in the complete fresh inventory. Missing, duplicate or split targets return unavailable/unknown and receive no commands.

This shortened identifier is a pragmatic mapping, not a complete UUID or authentication mechanism. Session end, title changes, duplicate resumed sessions and incomplete inventories must invalidate targeting. Revalidate before navigation and check the final selected tab afterward. These live steps remain unverified; source inspection and pure matching tests do not close issue #3.

The first test uses a command-line config override in the already isolated lab. Saved user settings remain untouched. Persistent title configuration is an integration step after the test passes.
