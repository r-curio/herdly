# Bind CLI sessions to terminal tabs by tty

Accepted with the user on 2026-10-11 ([issue #209](https://github.com/r-curio/steer/issues/209), map [#197](https://github.com/r-curio/steer/issues/197)). This extends [ADR 0005](0005-bind-ghostty-tabs-by-codex-title.md) to iTerm2, Terminal.app and WezTerm and generalizes [ADR 0012](0012-bind-codex-herdr-panes-by-title-and-foreground-process.md)'s foreground-process check to every terminal tab. Multiplexer panes and the join to their host tab are decided in [ADR 0014](0014-bind-multiplexer-panes-and-join-their-client-to-a-host-tab.md).

Amended 2026-10-13 ([issue #268](https://github.com/r-curio/steer/issues/268), the user's decision, option A): a tab that shows a Codex session's title but runs no foreground `codex` is not a candidate. It neither binds nor blocks the real tab. The iTerm2 run for [#243](https://github.com/r-curio/steer/issues/243) found a decoy tab making the real Codex tab unbound, which conflicted with MVP acceptance §3d H2 ("the decoy binds nothing"). The Codex uniqueness rule below reflects the amendment.

The live proofs ([iTerm2](https://github.com/r-curio/steer/issues/204), [Terminal.app](https://github.com/r-curio/steer/issues/205), [WezTerm](https://github.com/r-curio/steer/issues/206)) showed that every host lists each tab's tty. They also showed that a decoy can carry any title in every host and that WezTerm hides an OSC 2 title behind an earlier OSC 1 icon title. `ps -t <tty>` reported the foreground process group correctly every time, while iTerm2's `jobName` stayed stale for undisplayed tabs. A tab's tty is the one handle every host shares, and only the process running on it can change what runs there.

## Rules

- **Inventory:** each enabled host contributes a fresh, complete inventory listing every tab's tty, title and pane count. Enabled hosts are those the user turned on in Steer. A host that is not running counts as empty. If an enabled host is running but its inventory fails or permission is denied, every session that host could hold is unavailable, because that host cannot be ruled out. Hosts that are not enabled are never scanned and cannot hold a binding.
- **Codex CLI:** a live Codex session is bound to a tab when all of these hold:
  - the tab's title exactly equals the session's shortened identifier as rendered under ADR 0005;
  - `ps -t <tty>` shows exactly one foreground process named `codex`;
  - a second read still shows that tab with the same title;
  - exactly one candidate tab across all enabled inventories has that title, and exactly one live tracked session has that prefix.

  A titled tab is a **title decoy**, and no candidate, when it is unsplit, lists a tty, and a successful `ps -t` read of that tty shows no foreground `codex` (amended 2026-10-13, #268). Uniqueness is counted, and the second read is compared, without decoys. Every other titled tab still counts:
  - a tab whose `ps -t` read failed or was not taken, because it may run `codex`; an unreadable read fails closed and is never taken for "no `codex`";
  - a split tab, because `ps -t` reads only one pane's tty;
  - a tab showing several foreground `codex` processes;
  - a tab or pane that lists no tty: Ghostty without `tty` (ADR 0005's title-only rule, below) and Zellij panes (ADR 0014).

  So two titled tabs that both run `codex` still leave the session unbound, and a decoy alone binds nothing. The decoy check uses the `ps -t` reads taken between the two inventory reads; a titled tab that first appears in the second read has no read and voids the binding.

  As in ADR 0012, Codex hook environment variables are ignored because the daemon inherits them.
- **Claude Code:** the session registry names the session's live interactive PID, with `procStart` checked as in ADR 0008. That process's tty must match exactly one tab across all enabled inventories, and `ps -t` must show that PID in the foreground group. The title is not required. A title naming a *different* session (a Steer Claude title or a shortened Codex identifier) vetoes the binding. Several roots or holders reporting the session leave it unbound, as in ADR 0008.
- **Hook-recorded identifiers:** `ITERM_SESSION_ID`, `TERM_SESSION_ID`, `WEZTERM_PANE` and similar are recorded for diagnostics only. They neither bind nor veto. A terminal launched from another agent's session inherits that session's values (iTerm2 proof).
- **Target checks:** the bound tab holds exactly one pane. A split is unavailable (ADR 0004). Binding never depends on focus, the front window or the number of windows.
- **Void binding:** the binding is void when the session ends, the tab closes, its tty leaves the inventory, the foreground process changes, or, for Codex, the title changes (a user rename or another program's OSC). Renaming a Claude tab does not void its binding. A void binding disables Open and typed input; it never clears attention.
- **Freshness:** Open and typed input re-run this whole rule against fresh inventories and a fresh `ps` immediately before acting. After a restart of Steer, a host, or the agent, nothing persisted is trusted; bindings are rebuilt from fresh observation.
- **Ghostty:** while the installed Ghostty's dictionary exposes `tty`, its tabs follow these rules, including the foreground check and the decoy rule. Without it, Ghostty keeps ADR 0005's title-only matching and the Claude full-title match described in `docs/claude-setup.md`, and its titled tabs always count, since no process check is possible there.
- **Every consumer follows the decoy rule (2026-10-13):** Open on every host, visits, typed input and the scan that decides whether a card offers Open all use this one binding on the same reads, and `ps -t` is read for every titled tab of every tty-listing host they count. A host whose only tab carrying the title is a decoy, while the binding names a tab in another host, leaves the session to that host's Open route rather than falling back. herdr panes keep ADR 0012's rule unchanged.

## Considered options

- **Title only for Codex (ADR 0005 as written):** a decoy wins whenever the real tab is gone.
- **Count every titled tab, decoys included (this ADR as accepted on 2026-10-11):** safe, but a decoy that prints the title leaves the real tab unbound, and ADR 0015's fallback then has no `codex` to walk from in the decoy, so Open does nothing (#268). Replaced by the 2026-10-13 amendment.
- **Ignore every tab without exactly one foreground `codex`:** would also drop a split tab and a tab with several `codex` processes, either of which may hold the session. The amendment ignores only a tab whose read positively shows no `codex`.
- **Claude by title, or title and tty together:** the title adds no exactness over the tty join. WezTerm's OSC 1 masking and tmux's passthrough loss would leave real sessions unbound.
- **Claude hook identifiers as a binding signal or veto:** inherited environments make them wrong in ways that would mislead or falsely block. The registry tty join is already exact.
- **A host's own job field (iTerm2 `jobName`):** it is stale for undisplayed tabs and specific to one host.
- **Scan every installed host, enabled or not:** would ask for Automation access to apps the user never turned on.

## Accepted gap

Hosts that are not enabled are not scanned. A second Codex CLI resuming the same session in such a host could duplicate the title without Steer seeing it, so the enabled tab would still bind. The foreground check still requires a real `codex` on the bound tab. Claude cannot be affected, because its binding follows the session's own process.

The title remains a shortened identifier written by whatever process holds the terminal, not authentication.
