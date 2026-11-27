# Preserve the existing Codex workflow

The product is a companion to the Codex desktop app and CLI: users continue launching and using both normally, without needing to work through the companion. Codex must remain usable when the companion is closed or unavailable; integration choices must preserve that independence rather than make the companion responsible for starting or supervising Codex. This keeps the existing workflow intact, at the cost of relying on the events and integration points those existing surfaces expose.

Initial support is Codex only. Additional agents are a possible future change, not a requirement to build a general plugin system now.

Amended 2026-09-20 ([issue #80](https://github.com/r-curio/herdly/issues/80)): Claude Code joined as a second agent, configured reversibly per root ([Claude setup](../claude-setup.md)). The same rule applies to it: Claude Code stays usable when the companion is closed, and adding it did not introduce a general plugin system. The current list of supported agents and surfaces is in [product notes](../product.md#initial-supported-surfaces).

Agreed visibility and interaction behavior is recorded in [product notes](../product.md). Event transport remains undecided; the native macOS technology choice is recorded in [ADR 0003](0003-use-native-macos-ui.md).
