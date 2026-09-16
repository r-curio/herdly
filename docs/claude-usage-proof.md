# Claude usage and status-line coexistence proof

Compatibility evidence for [Prove Claude usage payload and status-line coexistence](https://github.com/r-curio/steer/issues/67), part of [Claude Code parity: find the path to an implementation backlog](https://github.com/r-curio/steer/issues/32). Checked 2026-09-16 against Claude Code **2.1.273**.

## Result

Steer can passively observe Claude's five-hour and seven-day usage for the tested first-party Max configuration, but status-line composition must be optional and conditional.

A native capture helper can preserve stdin, stdout, stderr, exit status, cwd, environment, arguments, ANSI, and multiline output with low overhead. It cannot claim compatibility with every existing shell command: a slow command with a descendant passed Claude's ordinary refresh cancellations but caused the composed session to hang during exit, while the same command without the wrapper exited cleanly. Setup must run a bounded cancellation/exit probe and leave an incompatible existing status line untouched.

Missing, expired, malformed, provider-specific, shadowed, policy-blocked, or unproved data is unavailable. Steer must never estimate usage or merge readings across configuration roots.

## Evidence boundary

- The live account-status interface reported one logged-in first-party Max subscription and one visible configuration root. Email, organization identity, credentials, transcripts, and the real settings file were not read or recorded.
- All Claude sessions used command-line `--settings` in an ignored disposable directory with only project setting sources enabled. The real status-line configuration was neither loaded nor changed.
- One harmless model request asked for the exact response `LAB_OK`.
- Sanitized samples retained only CLI version, top-level field names, presence flags, usage-window field names and values, hashed session identity, and local receipt time. Raw payloads were buffered only long enough to forward them to the simulated existing command.
- Alternate providers, alternate configuration roots, managed restrictions, and an independently missing live five-hour or seven-day window were not available in this environment. Their behavior remains contract-backed rather than live-proved.

## Installed payload

The first status-line invocation had no `rate_limits`. About 1.17 seconds later, before user input, the same new session carried both windows. After the response, `prompt_id` and `prompt_cache` appeared; the usage shape and values were unchanged.

Sanitized startup shape:

```json
{
  "version": "2.1.273",
  "prompt_id_present": false,
  "rate_limits_present": false,
  "rate_limits": {}
}
```

Sanitized pre-prompt and post-response usage shape:

```json
{
  "version": "2.1.273",
  "rate_limits_present": true,
  "rate_limits": {
    "five_hour": {
      "used_percentage": 1,
      "resets_at": 1789558800
    },
    "seven_day": {
      "used_percentage": 42,
      "resets_at": 1789876800
    }
  }
}
```

The reset timestamps were 2026-09-16 19:40 +08:00 and 2026-09-20 12:00 +08:00. The early transition shows that a startup invocation may gain cached or freshly fetched account data without a user prompt. Local receipt time is therefore an observation time, not proof that Claude fetched a new server reading for that invocation. The UI should say or imply “last reported,” never “checked now.”

Anthropic's current [status-line contract](https://code.claude.com/docs/en/statusline) says `rate_limits` is available for Claude.ai Pro/Max or a Claude apps gateway with a spend limit, and each of `five_hour`, `seven_day`, and `spend_limit` may be independently absent and is dropped after its reset. The live account exposed only the two subscription windows. `spend_limit` must not be relabeled as weekly usage.

## Composition proof

The accepted design buffers stdin once, records a bounded sanitized projection through an atomic side write, then replaces itself with the prior shell command using the buffered bytes as stdin. Capture failure is fail-open and silent: the prior command still runs.

| Check | Result |
| --- | --- |
| Exact forwarding | SHA-256 and byte count matched at the wrapper and simulated existing command. |
| Output | ANSI and two output lines were byte-identical. |
| Shell behavior | Quoted arguments, an embedded apostrophe, cwd, environment, and exit status 7 were preserved. |
| Concurrent writes | 24 parallel native invocations produced unique, readable atomic samples and exact forwarded output. |
| Capture failure | A non-writable capture directory did not change the existing command's output or exit status. |
| Refresh cancellation | Claude canceled two five-second composed commands before completion; no process remained after normal session exit. |
| Descendants | Repeated refreshes killed 28 slow descendant trees, but the final composed descendant tree kept Claude alive during exit. The direct unwrapped control exited cleanly. Composition must be refused when the bounded descendant/exit probe fails. |
| Latency | A Python wrapper was rejected at 553 ms median and 1.53 s p95. The compiled native prototype added 6.5 ms median; total native p95 was 20.7 ms across 80 runs. |
| Live rendering | Claude displayed the simulated existing ANSI/multiline status unchanged through the native wrapper. |

The prototype is evidence, not production code. Product implementation should use the packaged native helper and repeat the latency and cancellation checks against the shipped artifact.

## Setup, repair, and undo consequences

Setup must:

1. Probe Claude Code's version and actual payload fields. Version 2.1.273 is proved; documentation gives 2.1.251 as the field floor, but lower versions are not live-tested here.
2. Preview the selected configuration root, scope, provider class, effective status-line command, presentation fields, and every owned file. Do not inspect credentials.
3. Preserve the complete prior `statusLine` object, including `padding`, `refreshInterval`, and `hideVimModeIndicator`, plus unrelated settings.
4. Run bounded byte/output/exit, refresh-cancellation, descendant, and session-exit probes against an existing command. If any fails, do not compose or modify it; report usage integration unavailable.
5. Install only at a user-selected personal scope. Never overwrite a shared project or managed setting, and never claim active delivery from a successful JSON write alone.
6. Start a new disposable Claude session and require a valid sanitized payload from that exact root before reporting connected.

A standard-library setup fixture proved the ownership rule: repeated install was byte-stable and non-recursive; repair recreated only a missing owned artifact; undo restored the prior `statusLine` while preserving a later unrelated edit; and undo refused to overwrite a later user edit to `statusLine`.

The production acceptance checks must repeat those cases against the real settings editor, plus no-existing-status-line, higher-scope override, untrusted workspace, managed-only hooks/status line, selected setting sources, malformed JSON, alternate roots, active sessions, and app reinstall. Repair and undo must compare the currently installed value with the recorded owned value before changing anything.

## Truthful reading semantics

- Qualify every reading by Claude session and configuration root. The payload has no stable account identity suitable for cross-root aggregation.
- Show each subscription window only when its object is present, finite, in 0–100, and its reset is in the future.
- Expire each window independently on Steer's clock even if Claude emits no new payload. Absence after reset is normal, not zero usage.
- Ignore `spend_limit` for the five-hour/weekly UI. It is a provider/gateway spend cap and may exceed 100%.
- Treat malformed, future-version-unknown, missing, expired, or capture-failed values as unavailable. Keep the existing status line working.
- Rebuild readings after restart. A persisted snapshot is not current runtime proof.
- Report shadowed configuration, workspace trust refusal, managed restriction, incompatible existing command, and unconfigured alternate root as distinct setup states.

## Remaining uncertainty

No live state with only one subscription window was available before the five-hour reset at 19:40 +08:00, and no alternate provider/root was configured. The independent-absence rule is established by Anthropic's contract and must have decoder/clock fixtures, but it is not live evidence from this machine. This is sufficient to make those cases unavailable by default; enabling another provider/root requires its own live delivery probe.
