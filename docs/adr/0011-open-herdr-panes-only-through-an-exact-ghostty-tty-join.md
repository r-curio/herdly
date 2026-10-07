# Open herdr panes only through an exact Ghostty TTY join

Accepted with the user on 2026-10-07 (issue #105). Open in Codex or Open in Claude for a session in a herdr tab focuses the bound herdr pane and then selects the Ghostty tab hosting herdr's client. Steer finds that tab only by matching the client's TTY from `lsof` with the `tty` of exactly one Ghostty terminal. Ghostty 1.3.1 does not expose a terminal's `tty`, and titles collide between herdr clients (see the [live proof](../evidence/herdr-ghostty-live.md)). On such a Ghostty, herdr Open is unavailable and Steer sends no herdr request. The `tty` property is merged upstream for Ghostty 1.4.0 ([ghostty#11592](https://github.com/ghostty-org/ghostty/issues/11592)). Whether a stable release exposes it must be verified on the installed version before acceptance.

## Sequence

1. **Revalidate.** Re-read the herdr snapshot, `pane.process_info` for the bound pane, integration status (Claude only), and `lsof`, plus a fresh Ghostty inventory. Apply the session's pane binding and target checks (ADR 0008 for Claude, ADR 0012 for Codex) and ADR 0009's protocol and socket checks. Require exactly one Ghostty terminal whose `tty` equals the single client's TTY, in an unsplit tab in the current Ghostty window.
2. **Focus herdr.** Send `agent focus` with the bound pane ID, once and never retried. This also marks the agent seen in herdr, which follows from the user's explicit Open.
3. **Verify herdr.** A fresh snapshot must show exactly the bound pane focused, with the binding and client checks still holding.
4. **Raise Ghostty.** Select the matched tab and activate Ghostty.
5. **Verify Ghostty.** A fresh inventory must show the matched tab selected, its window frontmost, and the TTY join unchanged.

Steer reports Opened only when steps 3 and 5 both pass. An Open on an actionable CLI approval request hands it back first, as for a Ghostty tab.

## Rules

- **Failures:** each failed step yields one typed unavailable reason. ADR 0009's reasons apply, plus "Ghostty cannot identify herdr's tab" (no `tty`, zero or several matching terminals) and "Ghostty tab in another window". The reminder or completion is retained. Steer never rolls back herdr focus after a later step fails, never falls back to another pane or tab, and never sends input.
- **Windows:** only the current Ghostty window is used, as for Claude tabs, until cross-window return is proven live. That limit is then widened for both together.
- **Acknowledgment:** only completions are acknowledged by a visit. Approval requests, question requests, and reminders clear only on resolution evidence. A successful Open acknowledges a completion that arrived before the pre-Open snapshot. A manual visit acknowledges one when ADR 0009's interval rule holds and the second snapshot also shows the TTY-matched Ghostty tab selected with Ghostty frontmost. Without a TTY join, only explicit dismissal acknowledges.

## Considered options

- **Focus herdr without raising Ghostty on 1.3.1:** changes herdr's view and seen state without a result Steer can verify.
- **A unique window-title beacon through `client.window_title.set`:** edits herdr state and still matches on a title.
- **Raise Ghostty before focusing herdr:** a failed herdr focus would leave the user looking at the wrong pane.
