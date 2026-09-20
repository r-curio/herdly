# Claude setup

Claude setup is explicit and scoped to one configuration root. The default root is `~/.claude`; an alternate root selected from **Agents → Claude Code** is kept independent. Steer never scans for accounts or credentials and never merges roots.

The preview and install own one packaged `SteerHook` copy, one set of hook entries in that root's `settings.json`, and the `SessionStart` title hook. The title hook emits `Steer Claude <full-session-id>` for exact Ghostty matching. Steer does not install a launcher, change permission rules, or restart Claude sessions.

The installed hook set observes session, prompt, tool, Bash permission, subagent, notification, stop, and session-end events for the later Claude intake slice. The Bash matcher is observation/setup only here; native Claude remains the fallback until the approval slice proves a direct decision path. The optional usage bridge is offered in the same preview and is off by default. Selecting it records the intent but does not edit `statusLine` until the compatibility probe passes; the core connection remains independent.

## States

- **Not configured**: no Steer install record exists for the selected root.
- **Configured; restart required**: owned files are present, but Steer has not observed a post-install Claude event from this root.
- **Connected**: a bounded event carrying this root's installation identity was observed.
- **Repair required**: an owned hook or helper is missing.
- **Conflict**: an owned value changed, duplicate Steer installs exist, or the install record is inconsistent. Steer does not overwrite it.
- **Blocked by policy**: managed settings allow only managed hooks, or hooks are disabled.
- **Shadowed**: a higher-priority settings source wins; Steer does not try to defeat it.
- **Unsupported**: the detected Claude Code version is older than the tested `2.1.273` baseline. Newer versions still need a fresh runtime event before they become connected.

Ghostty readiness is separate from connection health. A root can be connected while Ghostty controls are off or still awaiting Automation permission. Exact return remains unavailable for stale, duplicate, overwritten, split, cross-window, or otherwise ambiguous targets.

## Ownership and undo

Reinstall reuses the root's installation identity and recreates only missing exact entries. A changed owned handler is a conflict. Undo restores the original `settings.json` byte-for-byte when it is unchanged; after unrelated edits it removes only unchanged Steer-owned entries and preserves the other settings. Missing or inconsistent state refuses guessed restoration and leaves targeted manual recovery to the operator.

Automated coverage is in `Tests/SteerCoreTests/ClaudeSetupTests.swift`. It uses temporary roots only; it does not modify the user's Claude or Ghostty configuration. Live proof that a newly started session delivers an event is still an operator acceptance step, and existing sessions are intentionally reported as requiring restart.
