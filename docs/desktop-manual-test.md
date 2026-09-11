# Desktop jump-back experiment

This is a user-operated navigation test for #1. It does not test automatic focus detection, completion acknowledgment or approval handoff. The earlier proposal to detect focus just by watching the user switch tasks was premature: no usable external focus signal has been established.

## Preparation

Create two disposable local Codex tasks named **Steer Test A** and **Steer Test B**, with prompts to reply only A and B respectively. No project files or tool actions are needed. Record their actual task IDs; names alone are not navigation identities. Do not use public conversation share URLs as local task locators.

The candidate route from installed-source inspection is `codex://threads/<task-id>`. Its live behavior remains unverified. Once the two actual IDs are known, prepare a clickable link for each. The user opens the links manually; no diagnostic controls or reads Codex's interface.

## Exercise

1. Select B manually. Click A's test link. Report which task and app installation actually opened.
2. Select A manually. Click B's test link. Report which task opened.
3. Switch to another app. Click A's link from there and report the result.
4. If multiple Codex installations are present, record whether the same running installation handled every link. Do not change default URL handlers during this test.

Record each result as **correct task**, **wrong task/app**, **no navigation**, or **uncertain**. A link launching an app is insufficient: the visible originating task must match. User observations are manual evidence, not an automated detector's output.

## Evidence record

| Item | Result |
| --- | --- |
| Task A ID | Awaiting user |
| Task B ID | Awaiting user |
| B → A | Not run |
| A → B | Not run |
| Other app → A | Not run |
| Correct running installation | Not run |
| Automatic focused-task signal | Unavailable in this diagnostic |

Stop if any link targets the wrong task or installation; do not use it for approval handoff. Even if every navigation test passes, #1 remains open until Steer can independently observe the selected task and handle unknown state. The [app-server reference](https://learn.chatgpt.com/docs/app-server) documents stored thread reads and loaded thread lists; neither establishes which task the user is viewing.
