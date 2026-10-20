# herdr pane IDs from a shared Codex daemon (#116)

Run on 2026-10-07 for [Prove the herdr items not yet shown live](https://github.com/r-curio/herdly/issues/116), under the map [herdr support: find the safe route for sessions in herdr](https://github.com/r-curio/herdly/issues/100). The run stopped after check 1 because that check found a safety problem with the binding rule in [ADR 0008](../adr/0008-bind-herdr-panes-when-herdly-and-herdr-agree.md). Checks 2 to 6 were not run.

## Setup

| Component | Version |
| --- | --- |
| macOS | Darwin 25.5.0 |
| Ghostty | 1.3.1 |
| herdr | 0.9.3, protocol 22; integrations codex v8 and claude v10, both current |
| Codex CLI | 0.160.1 |
| Steer hook | built from `main` after #121, so it records `herdr_pane_id` and `herdr_socket_path` |

- **Lab:** the disposable session `herdr --session steer-probe` ran in a new unsplit Ghostty tab, with its working directory in the ignored `output/herdr-lab`.
- **Hooks:** a project-level `output/herdr-lab/.codex/hooks.json` ran the built `output/Steer.app/Contents/Helpers/SteerHook` for SessionStart, UserPromptSubmit, Stop, SessionEnd and PostToolUse. Events went to `output/herdr-lab/events`. The lab had no approval hooks.
- **Trust:** the lab hooks were trusted through Codex's own prompt.
- **Isolation:** the user's real `~/.codex/hooks.json` and Steer's real events directory were not changed. One disposable Codex agent, `probe`, ran in `steer-probe` pane `w1:p1` and was asked only to reply "OK".

## Result: hooks report the pane of whichever CLI started the daemon

1. **Correct environment in the CLI:** the probe CLI process had `HERDR_PANE_ID=w1:p1` and `HERDR_SOCKET_PATH=…/sessions/steer-probe/herdr.sock`.
2. **Wrong pane in every hook record:** all three hook records for the probe session (SessionStart, UserPromptSubmit, Stop) carried `herdr_pane_id = w1:p2` and `herdr_socket_path = ~/.config/herdr/herdr.sock`. That is a pane in the user's **default** herdr session.
3. **The cause:** Codex 0.160.1 ran the hooks inside its managed app-server daemon (`codex app-server --listen unix:// --managed-daemon`), not in the CLI process. The daemon was a child of an earlier Codex CLI in default-session pane `w1:p2`. It inherited that CLI's environment, and so did every hook it ran. The process table showed this directly: the daemon and its helpers carried `HERDR_PANE_ID=w1:p2`, while the probe CLI carried `w1:p1`.
4. **herdr's integration made the same mistake:** herdr's own Codex hook also runs inside the daemon. After the probe's first turn, default-session pane `w1:p2`, where the user's real Codex was working, reported `agent_session` equal to the **probe's** session ID. `steer-probe` pane `w1:p1`, where the probe actually ran, reported `agent_session: null`.
5. **The two signals agreed on the wrong pane:** Steer's hook record and herdr's `agent_session` named the same pane on the default socket. ADR 0008 treats that agreement as proof of the binding, so the probe session would have bound to the user's real Codex pane. Question keys under ADR 0010 would then have gone to that pane.
6. **Exit did not clear it:** when the probe Codex exited (two `ctrl+c`), no session-end hook fired, and `w1:p2` kept the probe's session ID. Nothing in this run changed herdr state directly. The label came from herdr's own integration.

## Safety at the time of the run

- The running Steer app read the real events directory, which the installed hook (built 2026-09-15) writes without herdr fields. Its ADR 0009 gate therefore stayed closed and it never contacted herdr.
- No herdr build of Steer had been installed or released.

## What this means

- **ADR 0008 is unsafe as written:** agreement between the hook's `HERDR_PANE_ID` and herdr's `agent_session` does not prove the pane when Codex runs hooks in a shared managed daemon, which is the default in Codex 0.160.1. Both signals come from the same inherited environment, so they are not independent.
- **Before acceptance:** binding, Open and the question relay for Codex sessions in herdr must stay unavailable until a decision replaces or strengthens the rule.
- **Claude Code:** not exercised. Whether Claude runs hooks in a shared process is unknown.
- **Decision:** [ADR 0012](../adr/0012-bind-codex-herdr-panes-by-title-and-foreground-process.md) (issue #144) replaces ADR 0008 for Codex: a Codex session binds by its pane's title and foreground process. Claude Code keeps ADR 0008 with an added foreground-process check. Supporting observations are in [the #144 evidence](herdr-daemon-pane-signals.md).

## Cleanup

- The probe Codex exited, and `steer-probe` was stopped and deleted. Its Ghostty tab was left open at a shell prompt, because Ghostty 1.3.1 cannot identify that tab exactly.
- The lab files in `output/herdr-lab` are ignored by git.
- Codex recorded its own trust entries for the lab hooks in `~/.codex/config.toml`.
