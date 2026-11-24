# Open Claude Desktop sessions through its own link

Accepted on 2026-11-24 ([issue #471](https://github.com/r-curio/herdly/issues/471)). Claude Desktop's Code tab runs Claude Code itself, with the user's hooks loaded, so its sessions already reach Herdly's Claude intake: lifecycle, questions and approvals, all through the existing helper ([evidence](../evidence/claude-desktop-sessions.md)). They have no terminal, so every terminal route (ADRs 0013–0016) finds nothing, and Open ended in "Herdly can't tell which terminal this session is in."

## Decision

- **Which sessions.** A Claude session is Claude Desktop's while the session registry lists its interactive entry with `entrypoint: "claude-desktop"` (`ClaudeSessionHost`). Its identity is unchanged: hook records do not say where a session runs, so a registry-derived surface would split one session into two identities. The registry decides presentation and the Open route only.
- **Exact target.** Claude Desktop keeps one file per Code session under `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<uuid>.json`, naming its own id (`sessionId`) and the hook session (`cliSessionId`). That join is the only source of the target: `claude://code/continue?session=local_<uuid>`, the link Claude Desktop registers and validates (`^local_[A-Za-z0-9-]{1,64}$`). A hook session two files claim with different ids has no target.
- **Open.** At click time Herdly re-reads every configured root's registry and the session files. The session must be listed once in complete inventories, as Claude Desktop's in its own root, with Claude Desktop running. Herdly opens the link, then waits up to 5 s for that session's `lastFocusedAt` to move past the click, which is the verification. A session Claude Desktop already showed at the click (frontmost, with the latest `lastFocusedAt`) counts as reached at once, because Claude Desktop writes no new focus for it (found live on 2026-11-24). An unverified jump, or no exact id, brings Claude Desktop forward and shows "Herdly couldn't find this session in Claude Desktop, so it brought Claude Desktop forward." on the card. Unlike a terminal fallback (ADR 0015), this note is shown, as agreed. As with any fallback, the Open hands an actionable request back with no decision.
- **Acknowledgment.** No Claude Desktop Open, verified or not, acknowledges a result, and focus in Claude Desktop is not read evidence. Only Dismiss clears a desktop result, as for Codex desktop.
- **Presentation.** The row's place reads "Claude Desktop" in place of "project @ branch" (agreed 2026-11-24).
- **Bounds.** At most 4096 session files of up to 1 MiB each are read, without following symlinks. Anything unreadable leaves the session without an exact target rather than guessing.

## Alternatives weighed

- **Make Claude Desktop a terminal host.** Rejected: there is no tab, tty or Automation consent, and the host enum drives Settings › Terminals and every terminal route.
- **`claude://code/continue?session=last` or raising the app alone.** Rejected as the main route: neither selects the session the user clicked.
- **Reading Claude Desktop's IndexedDB or window contents for focus.** Rejected: larger, more private, and no more stable than the session file.

## Consequences

- The session files and the link are Claude Desktop internals. A release that moves or changes them degrades Open to raising Claude Desktop with the note; nothing reaches the wrong session, because the link names one exact id.
- Claude Desktop ignores the link while its OS entry points setting is off; Open then cannot verify and falls back.
- Claude Desktop runs sessions in `auto` permission mode by default, so notch approvals for them are rare (agreed: nothing added).
- Remote, SSH and cloud desktop sessions, and regular Claude chats, are out of scope.
