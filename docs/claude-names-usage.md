# Claude names and usage integration

Research for [Establish Claude’s names and usage integration](https://github.com/r-curio/steer/issues/34), part of [Claude Code parity: find the path to an implementation backlog](https://github.com/r-curio/steer/issues/32). Checked 2026-09-14.

## Conclusion and evidence boundary

Use an optional status-line bridge for names and usage, alongside the hook-driven lifecycle adapter. This is a proposed integration, not a verified capability or a product decision. Preserve the existing status-line command; if composition cannot be proved safe, leave this enhancement unavailable and bring the gap to the setup decision ticket.

Read-only local checks report Claude Code **2.1.270**. Its help exposes `--name`, `--settings`, and `--setting-sources`. This verifies installed CLI options, not emitted status-line payloads. No real configuration, credentials, or transcripts were read, no settings changed, and no model request or live experiment ran. Current online documentation can describe behavior newer than the installed binary; the lab must verify relevant fields.

## Documented contracts

The following compact findings come from Anthropic’s [status-line reference](https://code.claude.com/docs/en/statusline):

- Shell command receives JSON stdin and supplies display stdout.
- `session_id` identifies the session. `session_name` prefers `--name` or `/rename`, then an AI title; it excludes the default display name and may be absent.
- `rate_limits.five_hour` and `.seven_day` each contain `used_percentage` (0–100) and `resets_at` (Unix seconds). Windows are independently optional and disappear at reset.
- Rate limits arrive after an API response for Pro/Max subscribers or a Claude apps gateway with a spend limit. Gateway `spend_limit` is a separate window and can exceed 100%; it is not weekly subscription usage.
- Startup/resume, assistant messages, compaction, permission changes, and reset times trigger updates. Updates debounce at 300 ms; a newer invocation cancels an in-flight script. An optional `refreshInterval` supplements events.
- `padding` and `hideVimModeIndicator` affect presentation. Workspace trust gates execution.

Settings precedence, highest first, is managed → command-line → project-local → shared-project → user. `--settings` merges additional JSON; it does not defeat managed settings. User settings normally live in `~/.claude/settings.json`, project files in `.claude/settings.json` and `.claude/settings.local.json`. Per-session selected sources and higher-level overrides mean editing the user file alone does not prove installation is effective. See [settings and precedence](https://code.claude.com/docs/en/settings).

`allowManagedHooksOnly` also narrows `statusLine` to managed settings, so this restriction blocks a normal user-installed bridge. Hook entries otherwise merge across scopes. Do not mistake successful JSON installation for an active bridge. See [hooks policy](https://code.claude.com/docs/en/hooks#hook-locations).

`CLAUDE_CONFIG_DIR` can select another configuration root, including for separate accounts. An API key can select API billing instead of subscription use; inspect capability signals rather than assuming the signed-in subscription governs a session. Never read keys to implement the feature. See [environment variables](https://code.claude.com/docs/en/env-vars).

## Proposed minimum integration

These are Steer recommendations, not promises from Anthropic:

1. Add a mode to the existing native helper. Capture only agent/session identity, optional name, optional usage windows, version, and observation time into a bounded atomic record in Steer’s storage. Do not persist the complete status-line input or request a refresh from Claude’s service.
2. Treat metadata as a snapshot, not lifecycle evidence. Missing names use the existing shortened-ID fallback. Missing or malformed windows remain unavailable; never estimate from tokens, cost, or context percentages. Validate finite values and future reset timestamps. Expire displayed readings on Steer’s clock even when no further event arrives.
3. Keep a reading tied to its originating Claude session/configuration context. The documented payload does not establish an account identity for safe aggregation. Do not average windows or merge separate configuration roots; choose any account-wide display policy in the parity decision ticket. Label Claude and Codex distinctly.
4. A capture timestamp is local receipt time, not proof of a fresh server measurement. Label readings as last reported. Do not add a polling timer merely to reread cached data. Rebuild current usage after restart rather than displaying a persisted value as freshly verified.
5. Reuse existing queue label and expiry presentation behavior, but keep Claude decoding separate from `CodexUsageReader`. The inspected [Codex usage implementation](../Sources/SteerCore/CodexUsage.swift) reads a different rollout contract; [thread-name behavior](thread-names.md) already provides a truthful ID fallback.

## Composition and reversible setup proposal

Preview the target root, scope, existing command, and changed fields. Preserve the entire previous `statusLine` object and unrelated configuration. Install a wrapper only in the chosen personal scope; do not rewrite a shared project or managed policy to force activation. Report shadowed, disabled, untrusted, or policy-blocked configuration distinctly.

The wrapper must provide the original command its complete, unchanged stdin once. Capture through a bounded side path, then invoke the stored original command with equivalent shell semantics, working directory, environment, arguments, stdout/stderr, and exit behavior. Do not split a command string into argv, concatenate it unsafely into generated shell source, consume its stdin, or emit capture diagnostics into display stdout. Preserve existing presentation fields and refresh settings. Do not install a new scripting dependency or change the user’s permission rules.

Cancellation is the main composition risk: validate that descendant commands terminate, old invocations cannot overwrite newer observations, and capture failure never prevents the user’s command from running. A process-replacement approach after capture is a candidate, not an established equivalent to Claude’s shell launcher. If equivalence fails for an existing command, leave it untouched and record the unsupported setup. With no existing command, a capture-only wrapper’s blank-output layout needs live validation.

Record ownership and pre-install values. Reinstall must detect its own wrapper instead of wrapping recursively. Undo restores owned fields only if still unchanged since installation; preserve later user edits and report conflicts. Remove only Steer-owned artifacts. Recheck actual delivery from a new Claude invocation before reporting connected; settings edits alone are insufficient proof.

## Remaining checks before implementation decisions close

- **Payload lab:** startup without requests, explicit name, generated title, rename, resume, clear, missing name, and independently missing windows; record sanitized samples and installed version.
- **Usage lab:** Pro/Max and any actually used alternate provider; before-first-response absence, reset without further model work, account/config-root switches, and concurrent sessions. Unsupported providers stay unproven; a gateway spend cap must never appear as weekly usage.
- **Wrapper check:** byte-identical input/output, multiline/ANSI output, inline commands with quoting, arguments, exit failures, unavailable capture storage, rapid cancellation, slow descendants, and concurrent writes. Measure added wall time; require no noticeable regression and record the measurements rather than inventing a latency guarantee.
- **Setup check:** existing/no status line, higher-scope override, alternate root, selected sources, trust refusal, managed restriction, repeated install, user edits after install, repair, and undo. Use disposable configuration and pre/post comparisons, never modify the real setup for a test.

The research question is answered sufficiently to inform the parity and setup discussions. Wrapper transparency, installed payloads, update latency, and provider availability remain explicit live-proof obligations; none is established by this document.
