# Bind herdr panes when Steer and herdr agree

A CLI session in herdr is bound to a pane only when two independent signals agree: Steer's own hook recorded that `HERDR_PANE_ID` (with the default `HERDR_SOCKET_PATH`) in the session's newest event, and herdr's fresh snapshot shows exactly that one pane reporting the session as its `agent_session`. Either signal alone can be stale: herdr never verifies `agent_session` and can restore an old one after a restart, while a hook record only proves the session ran in that pane at some point. Requiring both keeps the binding exact without trusting either source alone.

## Rules

- **Duplicates:** two or more panes reporting the session, or a pane whose newest Steer hook event belongs to a different session, leave the session without a binding.
- **Void binding:** the session ended, herdr reports `null` or another session for the pane, or the herdr server's identity changed since the hook record. After a server restart the binding stays void until a new Steer hook event from that pane. A Codex session before its first turn has no binding. A void binding disables Open and question relay; it never clears attention.
- **Titles veto, never bind:** a pane title shaped like a shortened Codex session identifier that names a different session makes the target unavailable. A missing or free-form title, including every Claude Code title, is ignored.
- **Target checks before every Open or relay:** the bound pane's tab holds exactly one pane (a split or zoomed split is unavailable, as in ADR 0004); the session's socket is herdr's default socket (named sessions are unavailable); the server has exactly one attached client and its ancestry reaches Ghostty (zero, several, or non-Ghostty clients are unavailable).
- **Integration:** `herdr integration status` must report `current (vN)` for the session's own agent (`claude` or `codex`). Not installed, outdated, or unparseable output is unavailable with guidance toward `herdr integration install <agent>`. Steer never changes herdr configuration.
- **Versions:** herdr protocols are allowlisted, starting with protocol 22 (herdr 0.9.3), and checked before any herdr use. An unlisted protocol disables herdr targeting and relay; hook notifications continue.

## Considered options

- **herdr's `agent_session` only:** unverified and restorable after a restart, so it can point at a pane that no longer runs the session.
- **Steer's hook record only:** cannot tell whether the pane still runs the session after the agent exits or the pane is reused.

That Steer's hook sees `HERDR_PANE_ID` for both Claude Code and Codex is inferred from herdr's integrations and must be shown live before acceptance.
