# Bind Codex herdr panes by title and foreground process

Accepted with the user on 2026-10-07 (issue #144). This supersedes [ADR 0008](0008-bind-herdr-panes-when-steer-and-herdr-agree.md) for Codex CLI sessions. Claude Code sessions still follow ADR 0008.

Codex 0.160.1 runs hooks inside a shared managed app-server daemon by default (`daemon_auto_start`). The daemon inherits the environment of whichever CLI started it. Every hook it runs, Steer's and herdr's own Codex integration alike, reports that CLI's `HERDR_PANE_ID`. The pane can be the user's real Codex ([#116 run](../evidence/herdr-daemon-hook-env.md)) or a pane that no longer exists ([#144 observation](../evidence/herdr-daemon-pane-signals.md)). The hook record and herdr's `agent_session` therefore come from the same tainted source and cannot agree independently. Codex exposes no client identity for a thread.

A Codex session is instead bound from what its pane shows. The CLI in the pane writes the title, and herdr reads the pane's foreground process from the pane's own terminal. The daemon can affect neither.

## Rules

- **Binding:** a live Codex session is bound to a herdr pane when all of these hold in one fresh snapshot of the default socket:
  - herdr's `pane.process_info` for the pane lists exactly one foreground process named `codex`;
  - the pane's `terminal_title_stripped` exactly equals the session's shortened identifier as ADR 0005 renders it (the first 29 characters of the session UUID followed by `...`);
  - exactly one pane in the snapshot has that title, and exactly one live tracked session has that prefix.
- **Vetoes:** if herdr's `agent` for the pane is set, it must be `codex`. ADR 0008's target checks still apply: an unsplit, unzoomed tab, the default socket, and exactly one attached client whose ancestry reaches Ghostty.
- **Ignored for Codex:** the hook record's `HERDR_PANE_ID` and `HERDR_SOCKET_PATH`, herdr's `agent_session`, and `herdr integration status codex`. Codex requires no herdr integration. The hook keeps recording its herdr fields for diagnostics. No herdr rule reads a Codex hook record, including ADR 0008's duplicate check for Claude and ADR 0009's gate.
- **Route:** the title decides the route. A title found only in the herdr snapshot uses herdr. A title found only in the Ghostty inventory uses the Ghostty tab (ADR 0005). Found in both or in neither, the session is unavailable.
- **Gate:** besides ADR 0009's hook-record rule, Steer may contact herdr when a live Codex session's title is found in no Ghostty terminal and the default herdr socket exists and passes ADR 0009's socket trust check.
- **Freshness:** Open (ADR 0011) and the question relay (ADR 0010) re-run this whole rule against a fresh snapshot and fresh `pane.process_info` immediately before acting. Nothing carries over from the scan that built the card. A restarted Codex that resumed the same session in the same pane still binds.
- **Void binding:** the session ended, or any rule above fails. ADR 0008's server-restart rule does not apply, because the binding needs no hook event. A void binding disables Open and question relay. It never clears attention.
- **Question relay:** ADR 0010's `blocked` veto stays. Under the daemon, herdr's Codex integration reports lifecycle state to the daemon's inherited pane, so a status that came from it is meaningless.
- **Status source:** herdr's protocol 22 snapshot does not say whether a pane's `agent` or `agent_status` came from screen detection or from an integration report, so Steer reads both as reported. The `agent` veto can only make a pane unavailable. A `blocked` status that the integration misattributed could weaken ADR 0010's veto, so acceptance must show herdr marking a daemon-run Codex pane `blocked` while it waits on a question. If it does not, the herdr relay for Codex is unavailable.

## Considered options

- **ADR 0008's agreement rule:** both signals come from the daemon's inherited environment.
- **Require proof that the hook ran in the pane:** the hook would record its ancestry, and Steer would require the recorded pane's foreground process among the ancestors. This is safe, but Codex in herdr would never bind on Codex's default configuration.
- **Both routes, hook-ancestry proof first and the title otherwise:** a second rule that only helps `--no-daemon` users, who already bind by title.
- **Match the foreground process by `argv`:** would accept a script or editor whose path merely contains `codex`.
- **Pin the foreground PID between the scan and the action:** a restart that resumed the same session would fail without gaining safety, because the title already names the session.
- **Keep requiring herdr's Codex integration:** under the daemon it reports to the wrong pane, and nothing in this rule uses it.

The title is a shortened identifier written by whatever process holds the terminal, not authentication. The foreground-process check and both uniqueness checks keep a wrong match unavailable rather than misdirected. It depends on Steer's Configure Codex setting `tui.terminal_title = ["session-id"]`.

## Not yet shown live

These must pass in #128 before acceptance:

- binding under the daemon after the daemon's starting pane has closed;
- a Ghostty tab route while the daemon was started inside herdr;
- duplicate titles from two CLIs resuming the same session;
- a relayed key under the daemon;
- herdr's `blocked` status for a daemon-run Codex pane waiting on a question;
- the foreground process of an npm-installed Codex.
