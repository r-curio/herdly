# Claude permission families beyond Bash

Status: research snapshot, checked 2026-09-16 against Claude Code 2.1.273. This is an inventory, not live interoperability proof or a product-support decision.

## Conclusion

Claude Code exposes one documented decision route for every tool call that reaches a permission prompt: the `PermissionRequest` hook can return `allow` or `deny`. That common route is not enough to make direct approval safe. Its input deliberately omits `tool_use_id`, so it cannot by itself distinguish two identical requests within the same session and prompt. Each helper invocation needs its own local identity, and overlapping, late, canceled, and handed-back requests need isolated live proof before Steer can offer controls.

The first useful proof frontier is file access/modification, web access, `ExitPlanMode`, and one known MCP tool. Conditional or product-specific tools should first receive an explicit include/reject decision. PowerShell and interactions that do not use `PermissionRequest` are outside the local macOS permission boundary.

## Installed runtime inspection

Read-only inspection found:

- `claude --version`: `2.1.273 (Claude Code)`.
- `/Users/dev/.local/bin/claude` resolves to `/Users/dev/.local/share/claude/versions/2.1.273`.
- The executable is an arm64 Mach-O signed by `Developer ID Application: Anthropic PBC (Q6L2SF6YDW)` with SHA-256 `953e9880dbcb0b70f31c1f508de6a3fd389753d131688557fd992da9184693fb`.
- `claude --help` exposes manual, accept-edits, auto, don't-ask, plan, and bypass permission modes plus allow/deny tool flags. Embedded symbol inspection contains the documented `PermissionRequest` path and the relevant built-in tool names, including `Artifact`, `Monitor`, `PowerShell`, `ShareOnboardingGuide`, and `WebFetch`.

This confirms the installed version and broad feature presence only. No session was started, no permission was requested or decided, and no settings or real configuration were read or changed.

## Permission-producing inventory

The official [tools reference](https://code.claude.com/docs/en/tools-reference#built-in-tools) marks the following built-ins as requiring permission in Manual mode. Availability and whether a particular call prompts still depend on path, permission rules, mode, platform, provider, account, and feature flags.

| Family | Tools or request shape beyond Bash | When it can prompt | First-party decision route | Inventory disposition |
| --- | --- | --- | --- | --- |
| File modification | `Edit`, `Write`, `NotebookEdit` | Manual mode; edits may be auto-approved in `acceptEdits`; protected or out-of-scope paths can still prompt | `PermissionRequest` allow/deny | Candidate: prove as one family, retaining the exact tool name and absolute target |
| File access | `Read`, plus `Grep`, `Glob`, and `LSP` governed by Read rules | Normally no prompt inside working/additional directories; outside paths can prompt | `PermissionRequest` allow/deny | Candidate: prove an external-path read and verify which sibling tools actually emit the event |
| Web access | `WebFetch`, `WebSearch` | Manual mode unless an allow rule or another mode decides it; WebFetch supports domain rules, WebSearch only whole-tool rules | `PermissionRequest` allow/deny | Candidate: prove separately because their inputs and remembered rules differ |
| Plan transition | `ExitPlanMode` | When Claude presents a plan for approval | `PermissionRequest` allow/deny; Anthropic publishes an explicit allow example | Candidate: prove separately because approval changes mode and keeps the current conversation |
| Workspace transition | `EnterWorktree` | The path form prompts when entering outside `.claude/worktrees/`; creation and paths inside that directory do not | `PermissionRequest` allow/deny | Decide scope first; it changes cwd and write access rather than performing an ordinary tool action |
| Long-running observation | `Monitor` | Command and WebSocket sources can prompt; command permission rules follow Bash | `PermissionRequest` allow/deny for prompts that reach it | Decide scope first; command behavior overlaps Bash while WebSocket approval is distinct |
| Alternate shell | `PowerShell` | When available and not already allowed | `PermissionRequest` allow/deny | Exclude from this macOS/Ghostty destination; reconsider only with Windows scope |
| User-installed capability | `Skill`, `Workflow` | Manual mode when not already allowed; exact behavior depends on installed content | `PermissionRequest` allow/deny | Decide scope first; approving the launcher is not approval of all nested tool calls |
| Hosted publication | `Artifact`, `ShareOnboardingGuide` | When available by plan/login/provider and not already allowed | `PermissionRequest` allow/deny | Decide scope first; these create hosted or shareable external artifacts |
| External tools | `mcp__<server>__<tool>` | MCP tools generally require explicit permission unless pre-approved | `PermissionRequest` allow/deny for ordinary tool approval | Candidate: prove one bounded known tool; reject a generic “approve any MCP” surface |

The tool table also marks several actions as no-permission, including `Agent`, `AskUserQuestion`, `CronCreate`, `ReadMcpResourceTool`, and task-list operations. They do not enter this inventory merely because they may be consequential. The table and rule families are documented in [Tools reference: Configure tools](https://code.claude.com/docs/en/tools-reference#configure-tools-with-permission-rules-and-hooks).

## Hook contract and identity

The [PermissionRequest reference](https://code.claude.com/docs/en/hooks#permissionrequest) says the event runs when Claude Code is about to ask for permission. In a context that cannot display a prompt, it still runs; no hook decision means denial. The input combines common hook fields with:

- `session_id` and, after user input, `prompt_id` (available since 2.1.196);
- optional `agent_id` and `agent_type` for subagent calls;
- `transcript_path`, `cwd`, and `permission_mode`;
- `tool_name` and the full `tool_input` object;
- optional `permission_suggestions`, which is not guaranteed to match the dialog's visible choices.

It explicitly does **not** include `tool_use_id`. The transcript is also written asynchronously and may lag the in-memory turn, so it cannot safely fill that gap at request time. The fields and version boundary are documented under [common input fields](https://code.claude.com/docs/en/hooks#common-input-fields) and [PermissionRequest input](https://code.claude.com/docs/en/hooks#permissionrequest-input).

The supported response is:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
```

`behavior` may be `allow` or `deny`. Allow may replace the complete input with `updatedInput` or apply `updatedPermissions`; deny may include `message` and `interrupt`. Steer needs neither persistent permission changes nor input rewriting for an allow-once/deny surface and should omit both. Exit code 2 without a decision object leaves the permission flow unchanged. See [PermissionRequest decision control](https://code.claude.com/docs/en/hooks#permissionrequest-decision-control).

### Consequence for Steer

The smallest safe identity is a Steer-generated request ID bound to one live hook process plus the observed source, session, prompt, optional agent, tool name, bounded input fingerprint, receipt, and deadline. Those fields are validation evidence, not a substitute for the live helper connection. A later request with identical documented fields must not inherit an earlier decision.

## Native prompt and concurrency boundary

Documentation establishes a synchronous pre-prompt gate: a hook decision answers on the user's behalf and an allow can skip the dialog. It does not establish what happens when the helper waits, times out, disconnects, races a terminal action, or when two indistinguishable requests overlap.

All matching hook handlers run in parallel, and command/HTTP/MCP-tool handlers default to a 600-second timeout ([hook handler fields](https://code.claude.com/docs/en/hooks#hook-handler-fields)). Steer therefore cannot infer exclusivity from hook ordering or use the default timeout as its product deadline. Live proof must cover:

1. allow once and deny for one request;
2. no decision and explicit handoff to the native prompt;
3. helper failure/disconnect and timeout;
4. two overlapping requests, including identical `tool_name` and `tool_input`;
5. a late answer to the first after the second exists;
6. terminal/native action while Steer is waiting;
7. exact cleanup evidence for each outcome.

Until that passes, all non-Bash requests remain native-only.

## Policy and version restrictions

- Permission rules are evaluated deny, ask, then allow; a hook `allow` cannot override matching deny or ask rules. Managed settings have highest precedence. See [permission evaluation](https://code.claude.com/docs/en/permissions#manage-permissions) and [settings precedence](https://code.claude.com/docs/en/permissions#settings-precedence).
- `acceptEdits`, `auto`, `dontAsk`, `plan`, and `bypassPermissions` change whether a request reaches the hook. A missing event does not mean the tool is unsupported. See [permission modes](https://code.claude.com/docs/en/permissions#permission-modes).
- `allowManagedHooksOnly` can block user/project/local hooks, and `allowManagedPermissionRulesOnly` can make managed policy the only rule source. Steer setup must report these as unavailable rather than weaken policy. See [hook locations](https://code.claude.com/docs/en/hooks#hook-locations) and [managed settings](https://code.claude.com/docs/en/permissions#managed-settings).
- Version 2.1.273 is newer than the relevant documented floors: `prompt_id` 2.1.196, stable hyphenated MCP matcher handling 2.1.195, the `manual` alias 2.1.200, and current edit/write Read-deny checks 2.1.228. Supporting older clients would require an explicit compatibility floor rather than assuming this inventory applies.
- A sandboxed Bash network prompt does not emit `PermissionRequest`; the delayed `Notification(permission_prompt)` signal has no decision control. That path is not a non-Bash candidate. See [PermissionRequest](https://code.claude.com/docs/en/hooks#permissionrequest).

## Candidate and exclusion matrix

| Candidate | Why it merits proof | Required discriminating case | Current state |
| --- | --- | --- | --- |
| Shared request transport | Every family depends on it; documented identity lacks `tool_use_id` | Duplicate identical requests, late decision, native answer, timeout, disconnect | Must pass before family controls |
| File access/modification | Core local-development workflow with bounded path-oriented inputs | External Read plus Edit, Write, NotebookEdit; exact target and post-result isolation | Prove after transport |
| WebFetch and WebSearch | Common developer workflow; distinct domain versus whole-tool rule semantics | Allow, deny, handoff, redirect/changed input display, policy override | Prove after transport |
| ExitPlanMode | Officially documented PermissionRequest approval; semantically a plan decision | Exact plan/session binding, native fallback, current-mode restoration | Prove after transport |
| One known MCP tool | Establishes whether bounded external-tool approval can be made safe | Exact scoped tool name/input, ordinary versus `requiresUserInteraction`, reconnect | Prove after transport; no generic MCP approval |
| EnterWorktree, Monitor, Skill, Workflow | Real prompts but conditional or compound semantics | Human first decides whether each belongs in Steer's product boundary | Decision before proof |
| Artifact, ShareOnboardingGuide | Externally visible publication/share actions | Human first decides whether Steer should surface hosted publishing approvals | Decision before proof |
| PowerShell | Not part of the initial macOS target | None | Excluded from this map's destination |
| AskUserQuestion | User-input flow, not a permission-required tool in the table | Covered by the separate Claude question path | Excluded from this permission map |
| MCP elicitation and `requiresUserInteraction` | Separate form/interaction contract; not ordinary tool approval | Would require its own destination and UI contract | Excluded from direct generic MCP approval |
| `EndConversation` and sandbox-network notifications | `PermissionRequest` does not cover them | No supported allow-once/deny route here | Excluded |

## Sources

- Anthropic, [Hooks reference](https://code.claude.com/docs/en/hooks), checked 2026-09-16.
- Anthropic, [Tools reference](https://code.claude.com/docs/en/tools-reference), checked 2026-09-16.
- Anthropic, [Configure permissions](https://code.claude.com/docs/en/permissions), checked 2026-09-16.
- Anthropic, [MCP permissions](https://code.claude.com/docs/en/agent-sdk/mcp#allow-mcp-tools), checked 2026-09-16.
- Anthropic, [Hooks guide: auto-approve specific permission prompts](https://code.claude.com/docs/en/hooks-guide#auto-approve-specific-permission-prompts), checked 2026-09-16.
