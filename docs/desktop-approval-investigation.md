# Desktop lifecycle and approval gate (#2)

Checked 2026-09-11. Status: blocked; no real desktop approval was answered or intercepted. [Issue #2](https://github.com/r-curio/steer/issues/2).

## Reproducible installed-runtime evidence

```sh
python3 scripts/probe_codex_contract.py --self-test
python3 scripts/probe_codex_contract.py --binary /Applications/ChatGPT.app/Contents/Resources/codex
python3 scripts/probe_codex_contract.py --binary /opt/homebrew/bin/codex
```

All three passed. The probe runs version and schema generation only, writes temporary schemas, and reports relevant methods and required/optional parameter fields. It does not start an app server, read transcripts, install hooks, change permission settings or request a model turn.

Desktop engine `0.153.4` and shell CLI `0.145.0` both define turn start/completion, thread status, hook start/completion, and request resolution notifications. Both define legacy command/patch approvals and modern command/file/permission approvals. The desktop command request additionally has optional `kind`; the older CLI schema lacks it. Equal method names therefore do not establish equal behavior.

| Installed protocol | Identity and display consequence |
| --- | --- |
| Modern command/file approvals | Required `threadId`, `turnId`, `itemId`, `startedAtMs`; command/reason are not universally required |
| Permission approvals | Also require `cwd` and `permissions` |
| Legacy approvals | Use `conversationId` and `callId`; do not interpret these as the modern shape |
| `serverRequest/resolved` | Requires `threadId` and `requestId`; retain original transport request ID for reconciliation |
| Hook notifications | Require `threadId` and `run`; `turnId` is optional |

These are definitions, not events observed from the user's existing desktop runtime. A second app server would prove only its own behavior. The installed `app-server proxy` command exists, but no supported attachment to the running desktop with appropriate event delivery and request ownership has been established. No private connection was attempted.

## Candidate hook contract

The official [PermissionRequest reference](https://learn.chatgpt.com/docs/hooks#permissionrequest) describes synchronous decisions before the native prompt. Emit `hookSpecificOutput.hookEventName = PermissionRequest` with `decision.behavior = allow` or `deny` only for an explicit live user decision. Emit no decision for handoff. This is separate from `PreToolUse`'s output shape.

No decision lets Codex continue its own approval rules; it does not override another matching hook's allow or deny. Steer must preserve those existing rules. Unsupported requests stay native. A timeout is never an allow decision.

Documented input includes session, turn, tool name and tool input, but no guaranteed `tool_use_id` for PermissionRequest. Give each helper invocation its own identity; do not join a later native resolution to a handed-back hook solely by session or command. The hook-to-native-request correlation is still an unresolved integration contract.

## Missing live proof

Use disposable existing-desktop work with isolated test configuration and a permitted UI route. Capture actual events for start, completion and interruption, then exercise an approval-requiring harmless marker-file action in a temporary directory. For each supported approval category, record the exact runtime request and hook invocation identities, output, whether the marker changed, and native resolution evidence. Redact unrelated prompt/command data.

Run explicit allow once, deny, no decision after 30 seconds from companion receipt, Open in Codex, manual return, unknown focus, disconnect and helper failure. Also run two requests within one session and submit a late reply to the first: it must not answer the second. Verify a native prompt appears when the original policies require one, and that answering it clears only that pending request. Record unsupported categories as native-only. Repeat for the shell CLI independently in #3.

None of those live cases ran. Computer-use access to `com.openai.codex` was rejected for safety reasons; additionally, the existing-runtime event/approval attachment is not proven. The schema checks do not resolve either blocker. No simulator result is presented as approval handoff evidence. #4 and #9 remain blocked.

## Issue #9 implementation boundary

The helper now publishes one identity-bound approval request and waits for the
companion's receipt handshake before starting the 30-second decision deadline.
The helper first has a separate two-second receipt-connection deadline and then
an independent 31-second decision wait bound. Bounded regular-file reads,
malformed, late, duplicate, unknown, or failed decisions all return no
decision. The native hook response is emitted only for an explicit allow-once
or deny. The notch renders only Codex-provided fields and offers decision
buttons for CLI requests whose rollout identifies a CLI session; desktop
requests retain only Open in Codex because the desktop transport and handoff
policy remain unverified. Focused/unknown Ghostty or desktop observations hand
back with no decision.

`swift test` and `SteerHook --self-test` exercise the coordinator, atomic
identity checks, deadline preservation, and request detail replay. These are
isolated helper/core checks, not live desktop approval evidence. No desktop
allow/deny/timeout was run, and no existing hooks or permissions were changed.

The first isolated run with the installed Codex CLI 0.145.0 also exposed a
payload-coverage failure: a harmless `touch` request arrived as
`PermissionRequest` with `tool_name: Bash`, which the pre-fix helper rejected
before publishing a request. It therefore fell through to Codex's native
approval and the marker stayed absent after cancellation. `Bash` is now a
supported, self-tested alias; this diagnosis is not live handoff evidence, and
desktop approval remains unverified.

### Real CLI conservative-handoff retest

The subsequent isolated retest used the installed Codex CLI with session
`01a09248-ce66-7823-8e80-5043df76f11e`, turn
`01a09249-2e6e-7613-a414-cd556a328af2`, and the real Bash command
`touch /tmp/steer-approval-lab/TIMEOUT_MARKER-2`. The hook published request
`FBF4D0AD-AF2B-4652-9819-798AD02E1717` with the real project, action, command,
and long request details. The running exact-branch app wrote the companion
receipt at `received_at=1789160668.896307` with a 30-second expiry, then wrote
`no_decision` at `1789160668.944046` because the PTY was not a verified Ghostty
pane and the required observation was unavailable. The helper returned the
request to Codex's native approval UI; after native cancellation the marker
remained absent.

This proves real Bash ingestion, companion receipt, conservative unknown-focus
handback, and no accidental allow. It does not prove Ghostty allow/deny,
30-second timeout, or desktop decision transport.

Setup migration recognizes the prior Steer command shape with its two-second
hook timeout, upgrades it in place to the 35-second bounded hook timeout, and
collapses duplicate copies. Ambiguous multiple Steer installations return an
explicit conflict instead of adding another handler.

## Isolated lifecycle experiment prepared

The official [hook discovery and review documentation](https://learn.chatgpt.com/docs/hooks) supports project-local `.codex/hooks.json`, requires project trust and review of non-managed hook definitions, and merges hooks from other active sources. No trust bypass is used. Existing user/system hooks may still apply; this is isolation of Steer's test configuration, not an empty global configuration.

```sh
python3 scripts/desktop_hook_lab.py --self-test
python3 scripts/desktop_hook_lab.py --prepare output/desktop-hook-lab
python3 scripts/desktop_hook_lab.py --report output/desktop-hook-lab
```

Preparation requires a new directory and refuses to overwrite one. It creates a separate Git project with only its own hook configuration. The generated command uses absolute, shell-quoted interpreter and recorder paths. Normal Steer tasks and user-level Codex configuration are unchanged.

The recorder accepts events only for the disposable project or its subdirectories. It records event name, receipt time, correlation IDs, permission mode and field names. It does not store prompt, transcript or tool-input contents. Records use separate unique files to avoid concurrent append collisions. All capture paths produce no stdout decision; errors also return no decision. PermissionRequest is observed only when Codex's existing policy requests permission. The two-second hook timeout bounds this initial recorder, not the eventual thirty-second approval design.

Self-check passed using a temporary fixture project: the generated command runs with spaces in paths, writes no stdout/stderr, retains correlation IDs, excludes private content, rejects outside-project events and handles malformed/oversized input without changing approval behavior. Those fixtures are not desktop integration evidence.

For the live check, open `output/desktop-hook-lab` as a **local project in the existing Codex desktop app**. Review/trust the recorder through Codex's normal hook-review flow if prompted, then submit: `Reply only STEER-LIFECYCLE-OK. Do not run tools or change files.` If trust is granted after startup, submit that prompt again in the same task. Correlate the captured session ID with that desktop task before declaring lifecycle access proved. No permission test or allow/deny decision is required for this first prompt.

At preparation time the report contained zero events. Allow once, deny, thirty-second no-decision, disconnect and native-resolution correlation are still unverified. They must not be inferred from recorder self-checks or the mere existence of a hooks.json file. Live desktop interaction requires the user because computer-use access to Codex is restricted.

## Subsequent desktop lifecycle evidence

The later clean-run record for session
`01a08f51-a2fd-74c0-a9e9-d7e8a31c634c` identifies originator `Codex Desktop`,
source `vscode`, and rollout metadata from the existing desktop runtime. Hooks
were enabled after SessionStart, then captured UserPromptSubmit
`8bedf2d3-754c-4c00-8da4-635e14e82fe8` at
`2026-09-11T07:26:54.343057+00:00` for turn
`01a08f5c-b815-7f93-9659-e980527dc5cf`, followed by Stop
`b4baa09c-eb98-4cb9-b75c-9bd2f3405c24` at
`2026-09-11T07:26:57.252939+00:00`. This proves a real desktop turn
start/completion through the isolated recorder, but not full SessionStart
capture, approval handoff, or permanent companion attachment. The redacted
metadata-only pair is replayable from `docs/evidence/`.
