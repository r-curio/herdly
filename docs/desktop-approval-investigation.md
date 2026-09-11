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
