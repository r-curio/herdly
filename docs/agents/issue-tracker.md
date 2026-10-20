# Issue tracker

Use GitHub Issues at https://github.com/r-curio/herdly. Use gh for reading and publishing issues. External PRs are not a separate request surface. Publish work in dependency order and express blocking with GitHub's native issue dependencies. In prose, link the issue title rather than displaying a bare number. HITL means a live human interaction or decision is needed; AFK means the scoped work can proceed independently once its blockers are closed. Neither label authorizes deployment, changes to real user configuration, or bypassing tool permissions.

## Wayfinding operations

Use [wayfinder](../../.agents/skills/wayfinder/SKILL.md) when charting or working a decision map. The canonical map is a GitHub issue labeled `wayfinder:map`; its decision tickets are native sub-issues, labeled `wayfinder:research`, `wayfinder:prototype`, `wayfinder:grilling`, or `wayfinder:task`, plus `type:afk` or `type:hitl`.

1. Create the map and child issues before wiring relationships. With `gh api`, attach each child using `POST /repos/r-curio/herdly/issues/{map_number}/sub_issues` and integer `sub_issue_id`. Add each blocker using `POST /repos/r-curio/herdly/issues/{blocked_number}/dependencies/blocked_by` and integer `issue_id`. Body IDs are GitHub's numeric issue IDs, not issue numbers; fetch them with `GET /repos/r-curio/herdly/issues/{number}`. Read back both relationships after publishing.
2. Find the frontier by listing the map's `sub_issues` and each open child's `dependencies/blocked_by`, following pagination. Keep open, unassigned children whose blockers are all closed. Choose the first eligible child in the map's sub-issue order. Labels alone do not establish readiness.
3. Claim before work with `gh issue edit <number> --repo r-curio/herdly --add-assignee @me`; read back the assignee and recheck blockers. An assigned open ticket is claimed. Blocked tickets carry `blocked` and no ready label. After reviewing closed blockers' results, use `ready-for-agent` or `ready-for-human` as appropriate.
4. Dispatch research tickets to subagents using the research skill. Keep each ticket's artifact in an isolated `docs/<ticket>-research-<topic>` branch/worktree and publish a durable artifact/context link on its issue. The `docs/` prefix follows this repo's branch rule in AGENTS.md. Live human decisions remain HITL; charting resolves no non-research tickets.
5. Record the answer in a resolution comment, close the ticket, then append its linked title and one-line gist to the map's Decisions so far. Refresh the map before editing to preserve other sessions' updates. Recheck affected children's blockers and labels. Resolve at most one non-research ticket per session.

Keep open work discoverable through child queries, not duplicated in the map body. Put newly specifiable questions into children and wire their blockers; keep only unshaped in-scope questions in Not yet specified. Close mis-scoped children as not planned and link them under Out of scope. Build tickets produced as a map's handoff are separate from its decision children and are linked from the final resolution.

Reference: [sub-issue API](https://docs.github.com/en/rest/issues/sub-issues) and [issue-dependency API](https://docs.github.com/en/rest/issues/issue-dependencies).
