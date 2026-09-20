# Claude setup

Claude setup is explicit and scoped to one configuration root. The default root is `~/.claude`; an alternate root selected from **Agents → Claude Code** is kept independent. Steer never scans for accounts or credentials and never merges roots.

The preview and install own one packaged `SteerHook` copy, one set of hook entries in that root's `settings.json`, and the `SessionStart` title hook. The title hook returns Claude's supported JSON `terminalSequence` response containing `Steer Claude <full-session-id>` for exact Ghostty matching; it never writes the OSC sequence as plain hook stdout. Steer does not install a launcher, change permission rules, or restart Claude sessions.

The installed hook set observes session, prompt, tool, Bash permission, subagent, notification, stop, and session-end events for the later Claude intake slice. The Bash matcher is observation/setup only here; native Claude remains the fallback until the approval slice proves a direct decision path. The optional usage bridge is offered in the same preview and is off by default. Selecting it records the intent but does not edit `statusLine` until the compatibility probe passes; the core connection remains independent. This setup slice stores only event name, session identity, Steer source and installation identity, receipt timestamps, and Claude's SessionStart source. It does not persist prompts, commands, paths, reasons, tool input, or other event payloads before the later intake work.

The preview lists only the Steer-owned hook events, helper path, event-record path, title response shape, usage intent, and the count of active sessions needing restart. It does not display the complete `settings.json` or unrelated settings and credentials. Steer reads `claude agents --json` in a bounded subprocess with the selected `CLAUDE_CONFIG_DIR`, validates the top-level array, canonical full session IDs, supported kinds, lifecycle fields, and duplicate identities, then keeps only an active count. A disabled, failed, timed-out, malformed, or incomplete inventory is reported as unavailable; Steer never treats it as an empty root, never persists the inventory payload, and does not write a new core setup until the selected root can be read successfully.

Steer configures the selected user root. Claude can also merge project and command-line settings, but their effective hook state is not inspectable from this setup preview. Steer detects a mismatched `CLAUDE_CONFIG_DIR` and managed policies that block user hooks; otherwise it stays conservative and requires a new `SessionStart` event from the exact selected root before reporting Connected. It does not write setup that it can already identify as shadowed.

## States

- **Not configured**: no Steer install record exists for the selected root.
- **Configured; restart required**: owned files are present, but Steer has not observed a post-install Claude event from this root.
- **Connected**: a newly received `SessionStart` event whose Claude `source` is `startup`, carrying this root's installation identity, was observed after installation. Resume, clear, compact, or other events from another root, another installation, another hook event, or before installation do not connect the root.
- **Repair required**: an owned hook or helper is missing.
- **Conflict**: an owned value changed, duplicate Steer installs exist, or the install record is inconsistent. Steer does not overwrite it.
- **Blocked by policy**: managed settings allow only managed hooks, or hooks are disabled.
- **Shadowed**: a higher-priority settings source wins; Steer does not try to defeat it.
- **Unsupported**: the detected Claude Code version is older than the tested `2.1.273` baseline. Newer versions still need a fresh runtime event before they become connected.

Ghostty readiness is separate from connection health. A root can be connected while Ghostty controls are off or still awaiting Automation permission. Exact return remains unavailable for stale, duplicate, overwritten, split, cross-window, or otherwise ambiguous targets.

## Ownership and undo

Reinstall reuses the root's installation identity and recreates only missing exact entries. A changed owned handler is a conflict. Undo restores the original `settings.json` byte-for-byte when it is unchanged; after unrelated edits it removes only unchanged Steer-owned entries and preserves the other settings. Missing or inconsistent state refuses guessed restoration and leaves targeted manual recovery to the operator.

Automated coverage is in `Tests/SteerCoreTests/ClaudeSetupTests.swift`. It uses temporary roots only; it does not modify the user's Claude or Ghostty configuration. Live proof that a newly started session delivers an event is still an operator acceptance step, and existing sessions are intentionally reported as requiring restart. A helper self-test proves the Claude JSON response and metadata boundary; it does not prove that a running terminal applied the title or that project and command-line settings were absent.
