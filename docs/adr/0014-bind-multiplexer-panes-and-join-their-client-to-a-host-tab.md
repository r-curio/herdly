# Bind multiplexer panes and join their client to a host tab

Accepted with the user on 2026-10-11 ([issue #211](https://github.com/r-curio/steer/issues/211), map [#197](https://github.com/r-curio/steer/issues/197)). This extends [ADR 0013](0013-bind-cli-sessions-to-terminal-tabs-by-tty.md) to tmux and Zellij panes. It also generalizes herdr's Ghostty-only gate ([ADR 0009](0009-talk-to-herdr-over-its-socket-and-poll-snapshots.md)) and its Ghostty tty join ([ADR 0011](0011-open-herdr-panes-only-through-an-exact-ghostty-tty-join.md)) to every enabled terminal host. herdr pane binding itself is unchanged ([ADR 0008](0008-bind-herdr-panes-when-steer-and-herdr-agree.md) for Claude, [ADR 0012](0012-bind-codex-herdr-panes-by-title-and-foreground-process.md) for Codex).

A session in a multiplexer has two layers: the pane running it, and the terminal tab running the multiplexer's one client. Each layer needs an exact handle. The live proofs ([tmux](https://github.com/r-curio/steer/issues/207), [Zellij](https://github.com/r-curio/steer/issues/208)) showed that tmux lists each pane's tty and each client's `client_tty`. Zellij lists neither a pane's tty nor its pid, and gives a client no tty, pid or socket tie. The client's host tab comes only from the `zellij` client process's controlling tty. In both, titles collide with a decoy.

## Pane binding

- **tmux:** ADR 0013 applies unchanged, with the pane in place of the tab. Codex binds by the exact ADR 0005 title as `pane_title`, plus exactly one foreground `codex` from `ps -t <pane_tty>`, a second read, and uniqueness. Claude binds by its registry PID (with `procStart`) → its tty → exactly one pane. `TMUX` and `TMUX_PANE` from hooks are diagnostics only.
- **Zellij, Codex:** the pane's `title` exactly equals the ADR 0005 title, the basename of the first word of `pane_command` is `codex`, a `codex` process's ancestry reaches that session's `zellij --server`, a second read still shows the same title, and both uniqueness checks of ADR 0013 hold. Ancestry covers a user `post_command_discovery_hook` that rewrites `pane_command`.
- **Zellij, Claude:** two signals must agree. The session's newest Steer hook event records `ZELLIJ_PANE_ID` and `ZELLIJ_SESSION_NAME` for a terminal pane (`is_plugin` false) that exists in that session. The registry PID (with `procStart`) has ancestry reaching that session's server. A pane title naming a different session vetoes. The title is not required, because a user-named pane replaces it. This is an exception to ADR 0013's diagnostics-only rule for hook identifiers: an inherited value from another server fails the ancestry check. Codex hook records are never used, as in ADR 0012.
- **herdr:** ADRs 0008 and 0012 apply unchanged.

## Layout and clients

- **tmux:** the pane's window holds exactly one pane, and the pane's session has exactly one attached client. Grouped sessions are unavailable. Steer never moves a client to another session, because `switch-client` moves every client of a session together.
- **Zellij:** the pane's tab holds exactly one selectable tiled pane and no visible floating panes, and `list-clients` for the session shows exactly one client. Zellij 0.44.1 or later is required for `focus-pane-id` and `--pane-id`.
- **herdr:** ADR 0008's target checks apply, with the client check replaced by the host-tab join below.
- **Nesting:** a multiplexer running inside another multiplexer's pane is unavailable.

## Host-tab join

- The multiplexer's single client's tty must equal the tty of exactly one tab across all enabled host inventories (ADR 0013), and that tab must be unsplit. Client ttys come from tmux's `list-clients` `client_tty`, from `lsof` for herdr (ADR 0009), and from the controlling tty of the `zellij` client process.
- **Zellij:** because no client process can be tied to a session, exactly one `zellij` client process (not `--server`) may run for the user across all sessions. A host tab title that does not start with `<session> | ` vetoes the join.
- **Ghostty without `tty`:** ADR 0011's sole-terminal rule continues to apply.
- **Codex title count:** a host tab whose tty is the joined client of an enabled multiplexer is left out of ADR 0013's Codex title uniqueness, because its title mirrors the focused pane. Its foreground process is the client, so it can never bind directly.

## Sockets, sessions and gates

- **tmux:** only the default socket `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default`, a Unix socket owned by the current user whose server runs as the current user. Sockets chosen with `-L` or `-S` are never scanned, so their sessions are unbound. Any session name is allowed.
- **Zellij:** only the default socket directory (`$TMPDIR/zellij-<uid>/contract_version_1`), with every session name allowed, since Zellij names sessions randomly. A custom `ZELLIJ_SOCKET_DIR` is not scanned. Steer lists the directory itself and addresses each session with `--session <name>`. It never runs `zellij list-sessions`, which deletes sockets that refuse a connection.
- **herdr:** ADR 0009's socket and named-session rules are unchanged.
- **Binaries:** `tmux` and `zellij` resolve from fixed locations, as `herdr` does (ADR 0009), never from `PATH`.
- **Gate:** each multiplexer has its own enable switch. Steer contacts a multiplexer only while its switch is on and at least one terminal host is enabled. ADR 0009's and ADR 0012's conditions read "any enabled host's inventory is known" in place of "Ghostty controls are enabled" and "a Ghostty inventory is known". As ADR 0013 does for hosts, a multiplexer that is enabled and running but unreadable leaves every session it could hold unavailable, and one that is not running counts as empty.

## Open sequence

1. **Revalidate** both layers on fresh reads: pane binding, layout, client count, sockets and the host-tab join.
2. **Focus the pane** once, never retried: tmux `switch-client -c <client_tty> -t %pane`, Zellij `focus-pane-id --session <name>`, herdr `agent focus`.
3. **Verify the multiplexer:** a fresh read shows the client's current pane is the target (`list-clients` for tmux and Zellij, the snapshot for herdr), with the other checks still holding. Zellij's "already focused" exit 2 counts as success only if this check passes. A Zellij client that has not yet typed may not move, and that fails here.
4. **Raise the host tab** with that host's Open ([issue #210](https://github.com/r-curio/steer/issues/210); ADR 0011 for Ghostty).
5. **Verify the host** as that host's Open requires, with the tty join unchanged.

Steer reports Opened only when steps 3 and 5 both pass. Each failed step yields one typed reason, and focus is never rolled back. What follows a failure, unavailable or the app-raise fallback, is decided in [ADR 0015](0015-raise-the-terminal-app-when-open-cannot-reach-the-exact-target.md) (issue #203).

## Considered options

- **Zellij Codex by title and `pane_command` only:** a discovery hook can rewrite `pane_command`.
- **Zellij Claude by title:** a user-named pane loses the title, so real sessions would stay unbound. Requiring both title and hook would fail for the same reason.
- **Zellij client join by `lsof` socket peers:** the proof found the socket path only on the server's descriptors. It can widen the single-client-process rule if a later proof shows matching peer addresses.
- **Count the multiplexer's host tab in the Codex title count:** every Codex pane whose host mirrors titles would be unavailable, ADR 0012's "found in both" problem.
- **Trust every socket in the per-user tmux directory:** Codex gives no socket to look for, so Steer would scan servers the user never pointed it at. Default sockets match herdr's rule.

## Not yet shown live

- Zellij Claude binding by hook pane id and ancestry, and Codex ancestry to the server.
- tmux and Zellij hosted in iTerm2, Terminal.app and Ghostty, and the host-tab join through each.
- The full two-layer Open sequence in any Steer code path.
