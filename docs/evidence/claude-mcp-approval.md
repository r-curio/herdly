# One bounded Claude MCP approval (issue #75)

Recorded 2026-10-11 against Claude Code 2.1.296. Raw timeline: [claude-mcp-approval.json](claude-mcp-approval.json).

## Setup and limits

- **Server:** [lab_mcp_server.py](../../scripts/claude-permission-lab/lab_mcp_server.py), a standard-library stdio
  server named `steer-lab`, loaded only through `--mcp-config` with `--strict-mcp-config`. It has two tools with
  the same harmless behavior (echo a string of at most 64 characters):
  - `lab_echo`, an ordinary tool;
  - `lab_confirm`, marked `_meta["anthropic/requiresUserInteraction"] = true`, the flag Claude Code 2.1.296 reads
    from an MCP tool's metadata.

  The server logs every call, so a run shows whether a call reached it. Start logging was added before the
  server-loss run; the earlier MCP runs log calls only.
- **Isolation:** the #72 lab ([run_family_case.py](../../scripts/claude-permission-lab/run_family_case.py)). No user
  MCP servers were loaded, nothing external was written, and no "don't ask again" rule was saved.
- **Decisions:** scripted by the agent at the operator's explicit direction; none were human-clicked.

## Results

| Case | What happened | Result |
| --- | --- | --- |
| mcp-allow | `PermissionRequest` for `mcp__steer-lab__lab_echo` with `tool_input` `{"text": "hello"}`. Allow; the server logged one call; `PostToolUse` followed. | Pass |
| mcp-deny | Deny. The server logged no call. | Pass |
| mcp-handoff | `no_decision`; the native dialog stayed; native No; no call. | Pass |
| mcp-user-interaction-allow | `PermissionRequest` for `lab_confirm` fired, and the helper emitted a plain allow (no `updatedInput`). Claude **did not apply it**: its own dialog stayed open with Yes and No only, and the driver's native No interrupted the call. The server logged no call. | Hook allow not applied |
| mcp-server-loss-allow | The lab server was killed after the receipt and before the decision. When allow was emitted, Claude **restarted the server** (a second `initialize` from a new process) and the call reached the new process. | Allow outlives a server restart |

The two handoff-style cases show repeated native Esc presses in the raw timeline. The driver re-read an already
answered dialog; the first keypress answered it. The driver fix was verified by rerunning `webfetch-handoff`
([web evidence](claude-web-approvals.md)).

## Decision

**Reject direct MCP approval for now. Record the narrow contract a future opt-in would need.**

- The transport works for an ordinary tool: allow, deny and handoff behaved exactly. But Steer cannot know what an
  arbitrary server does with its input, so it cannot show an MCP call's full consequence. A generic "any MCP tool"
  surface is therefore rejected.
- The only safe shape is a tool the user has explicitly named for direct approval. Steer has no such setting, and
  adding one is a product decision outside this map. So no MCP tool is decided from the notch, and MCP requests
  stay in Claude.
- A tool marked `anthropic/requiresUserInteraction` is excluded outright: a plain hook allow was not applied, and its
  own dialog is the interaction surface. (A hook `updatedInput` path exists in Claude's source but was not exercised.)
- MCP elicitation (form) requests are not `PermissionRequest`s and stay excluded.

## Minimum contract for a future opt-in

- **Identity:** the exact scoped name `mcp__<server>__<tool>`, matched against a user-named allow-list. Never a
  server-wide or wildcard match.
- **Input:** a flat object of short strings, shown in full, key by key. Anything nested or long stays native.
- **Server restart:** Claude restarts a lost stdio server and still runs an allowed call. So an approval
  authorizes the named tool, not a particular server process. The card must not claim more.
- **Never offer:** Claude's "don't ask again for <tool> in <folder>", which saves a rule.
