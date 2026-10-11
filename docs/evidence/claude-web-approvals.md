# Claude WebFetch and WebSearch approvals (issue #73)

Recorded 2026-10-11 against Claude Code 2.1.296. Raw timeline: [claude-web-approvals.json](claude-web-approvals.json).
This builds on the transport proof in [claude-permission-transport.md](claude-permission-transport.md) (#71).

## Setup and limits

- **Isolation:** the same lab as #72 ([run_family_case.py](../../scripts/claude-permission-lab/run_family_case.py)):
  `claude --setting-sources project --permission-mode default --model haiku --strict-mcp-config` in
  `output/claude-file-lab/project`. User hooks, rules and auto mode were not loaded, and no allow rule was saved.
- **Targets:** `WebFetch` fetched only `https://example.com/`, once through an `httpbin.org` redirect to it.
  `WebSearch` searched only for `example domain`.
- **Decisions:** at the operator's explicit direction, the agent scripted every companion decision and native
  keystroke. None were human-clicked. The Steer notch was not involved.
- **Deferred tools:** in 2.1.296 both tools are deferred, so Claude first called `ToolSearch`, which never prompted.

## Results

| Case | What happened | Result |
| --- | --- | --- |
| webfetch-allow | `PermissionRequest(WebFetch)` with `url` and `prompt`. Allow; `PostToolUse` followed. | Pass |
| webfetch-deny | Deny. No post-tool event; Claude stopped. | Pass |
| webfetch-handoff | `no_decision`; the helper exited silently; the native dialog stayed, and native No showed "Interrupted". | Pass |
| webfetch-redirect-allow | The first request named the `httpbin.org` URL. Claude did not follow the redirect itself: it made a **second** `WebFetch` call for `https://example.com/`, which raised its own `PermissionRequest`. Each was allowed separately. | Pass: every new URL is a new request |
| webfetch-domain-deny-rule | Project rule `deny: ["WebFetch(domain:example.com)"]`. `PreToolUse` fired, but no `PermissionRequest`; nothing was fetched. | Deny rule wins before the hook |
| websearch-allow | `PermissionRequest(WebSearch)` with `query` and `mode` (`standard`). Allow; `PostToolUse` followed. | Pass |
| websearch-deny | Deny. No post-tool event. | Pass |
| websearch-handoff | `no_decision`, then native No ("Interrupted"). | Pass |

The driver pressed Esc more than once in the two handoff cases, because it re-read the already answered
dialog. Every extra keypress came after the first had answered the dialog, so the results stand. The driver
now ignores screen text drawn before its last answer.

## Decision

| Tool | Decision | Reason |
| --- | --- | --- |
| `WebFetch` | Include | Allow, deny and handoff behaved exactly, and a redirect produces a new request for the new URL, so an approval never silently covers another host. |
| `WebSearch` | Include | Allow, deny and handoff behaved exactly. |

## Display and validation contract

**Accept only:**

- `WebFetch` with exactly `url` (an absolute `https` or `http` URL with a host) and `prompt` (a string);
- `WebSearch` with exactly `query` (a non-empty string) and `mode` equal to `standard`, the only value observed.

Anything else stays in Claude's dialog.

**Show:**

- WebFetch: "Fetch web page", the full URL, its host, and Claude's bounded `prompt`;
- WebSearch: "Search the web" and the query.

**Offer only:** Allow once and Deny. Claude's "don't ask again for <domain>" and "don't ask again for Web
Search" save a permission rule, so they stay in Claude only.

**Matching:** the one open `PreToolUse` of the same tool on the same URL (WebFetch) or query (WebSearch),
under #71's single-candidate rule.
