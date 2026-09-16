# Claude completion read evidence

Research resolution for [Determine whether Claude exposes completion read evidence](https://github.com/r-curio/steer/issues/68), under [Claude Code parity: find the path to an implementation backlog](https://github.com/r-curio/steer/issues/32). Checked 2026-09-16 against Claude Code **2.1.273**.

## Answer

Claude Code does **not** expose a supported read receipt for a particular completed, failed, or interrupted outcome. Its supported external inventory reports session lifecycle, and its hooks report lifecycle events; neither reports that the user viewed an outcome.

The strongest trustworthy acknowledgment remains Steer's own **verified visit to the exact originating Ghostty tab after the outcome was observed**. That proves the result was put in front of the user, not that they read every line. Explicit dismissal remains the only source-independent acknowledgment.

Agent View cannot improve this contract. It can show or attach to a result, but `claude agents --json --all` exposes no peeked, attached, viewed, unread, or read field. A later prompt, process exit, session deletion, state transition, notification delivery, app activation, or Ghostty activation without exact tab verification is not read evidence.

`MessageDisplay` cannot improve it either. The event identifies a rendered assistant message by `session_id`, `turn_id`, display-only `message_id`, batch index, and final-batch flag, but Anthropic also fires it for noninteractive Agent SDK and `claude -p` runs. It proves emission/rendering, including when nobody is watching.

## Evidence boundary

This investigation used official Anthropic documentation, prior isolated Claude/Ghostty proof already committed in this repository, and read-only inspection of the installed CLI. No model request ran, no transcript or credential was read, and no Claude, Ghostty, or Codex configuration was changed.

Installed observations:

- `claude --version` returned `2.1.273 (Claude Code)`.
- The installed Mach-O is signed by `Developer ID Application: Anthropic PBC (Q6L2SF6YDW)`.
- `claude agents --help` documents `--json` for active sessions and `--all` for completed background sessions.
- Sanitized projections of `claude agents --json` and `--json --all` contained only `cwd`, `id`, `kind`, `name`, `pid`, `sessionId`, `startedAt`, `state`, and `status` across the live entries. No private names, paths, summaries, prompts, transcript contents, or identifiers were retained.

The absence of a field in one installed payload is not alone proof that no feature exists. The conclusion rests on the documented complete external JSON field table, documented hook schemas, and the absence of any first-party read-state contract among those interfaces.

## What the first-party interfaces establish

### Hooks establish outcomes, not views

The official [hooks reference](https://code.claude.com/docs/en/hooks) defines `Stop` when the main agent finishes responding, `StopFailure` for API errors, and `SessionEnd` for session termination. Their inputs carry lifecycle identity and result context, but no subsequent user-view event or read state. `Notification` is explicitly a side-effect hook for forwarding alerts; delivery is not acknowledgment.

Other documented signals remain insufficient:

- `MessageDisplay(final: true)` proves the interface finished rendering one assistant message, not that a person saw it; its display `message_id` cannot be correlated with transcript API message IDs.
- `Notification(idle_prompt)` means roughly 60 seconds passed after Claude finished while the user did not type. It proves inactivity, not reading; absence is ambiguous.
- a later `UserPromptSubmit` proves subsequent activity in the same session. Its new prompt identity does not identify which earlier result, if any, the user reviewed.
- `SessionStart(source: resume)` proves the session resumed, not that a particular prior outcome was viewed.

The existing [Claude lifecycle proof](https://github.com/r-curio/steer/blob/a5bd06fdc9560b010ef491ee7a1a61ee261342ab/docs/claude-lifecycle-proof.md) adds two important limits on 2.1.273:

- a user interrupt emitted no `Stop`, `StopFailure`, or interruption hook;
- a `Stop` hook could continue the response, producing another `Stop` for the same prompt.

Outcome classification therefore follows its own evidence rules. A read policy cannot repair missing or provisional outcome evidence.

For interrupted work, this is a hard gap: `Stop` explicitly excludes user interruption, and documented `SessionEnd` reasons do not identify an interrupted turn. Do not infer an exact interrupted outcome from a missing hook, process disappearance, or session-level Agent View state.

### Agent View exposes lifecycle, not acknowledgment

Anthropic documents [`claude agents --json --all`](https://code.claude.com/docs/en/agent-view#list-sessions-as-json) as the supported way for another program to read session state. Its documented fields are session identity and display context plus `state`, live-process `status`, and `waitingFor`. The states distinguish working, blocked, done, failed, and stopped. There is no read, unread, viewed, peeked, selected, or attached acknowledgment field.

Agent View's UI can [peek at a finished result or attach to its full conversation](https://code.claude.com/docs/en/agent-view#peek-and-reply), but the supported JSON surface does not report those interactions. Completed rows remain lifecycle records; `done` means the task finished and is ready for another prompt, not that its result was read. The private files below the Claude configuration directory are explicitly not a stable interface and must not be parsed as a substitute.

### Terminal focus can prove presentation only when exact

The repository's isolated [Claude Ghostty targeting proof](https://github.com/r-curio/steer/issues/36#issuecomment-5693311640) established a conditional binding on Claude Code 2.1.273 and Ghostty 1.3.1. A visit is usable only when a fresh inventory finds one exact full-session-ID title in one unsplit terminal, the locator is revalidated immediately before selection, and a fresh post-selection snapshot reports that same window/tab/terminal selected.

That signal belongs to Ghostty and Steer, not Claude. It proves presentation of the originating surface after an outcome, not comprehension of the result.

## Acknowledgment contract

For each queued Claude outcome, retain its exact outcome identity separately from the session. When available, this is agent kind + full Claude session ID + prompt ID + outcome occurrence. A full session ID alone is insufficient because one session can produce several outcomes and duplicate live resumes can share an identity.

A verified visit may acknowledge only outcome items that satisfy all of these conditions:

1. Steer had already captured and queued the item before the focus/navigation observation began.
2. The observed target is the fresh, unique, unsplit Ghostty terminal bound to that full Claude session ID.
3. A fresh post-selection observation confirms the same exact target is selected in the foreground window.
4. No duplicate, stale, overwritten, split, closed, or otherwise ambiguous target exists.

One verified visit may acknowledge multiple already-queued outcomes for that exact session. It must not acknowledge an outcome observed later, another session, or another live instance that shares a duplicated resumed session ID. Merely being on the tab when an outcome arrives is not a later visit and does not satisfy this rule.

The currently proven Claude/Ghostty route is limited to a unique unsplit target in Ghostty's current front window. Cross-window raising, duplicate resumes, split tabs, stale or overwritten titles, missing targets, and unknown focus remain unavailable. For Agent View rows, Steer has no supported exact peek/attach observation, so only explicit dismissal can acknowledge the item.

## Restart behavior

Claude exposes no read state that Steer can re-query after restart. Therefore:

- an explicit dismissal or verified visit that Steer already persisted remains acknowledged;
- a visit that occurred while Steer was not observing cannot be recovered;
- restored outcomes without a persisted acknowledgment are **uncertain**, not authoritatively unread;
- uncertain outcomes return silently, with no replayed sound, and keep explicit Open/Dismiss handling where the target remains available.

Inventory persistence across Claude supervisor restarts preserves session lifecycle, not user-view evidence.

## Decay and action expiry

A timer is not a read receipt. It may safely end transient presentation or remove a control whose own validity expired, provided Steer records the reason as **expired/unavailable**, never acknowledged or read.

Use the narrow existing validity rule before adding a general timer:

- direct approval controls already end at their request deadline or handoff;
- question answers exist only while the exact live helper invocation remains pending;
- Open in Claude depends on fresh exact target availability, not age;
- completion-card follow-up has no supported Claude transport and should not be shown;
- the three-second spotlight and one-shot sound may decay without clearing the attention item.

If product policy later chooses to auto-remove old outcome attention, model that as a separate **auto-expired** disposition with its own timestamp. Do not write it into the acknowledged set, describe it as read, use it as evidence that the user visited Claude, or let it clear newer outcomes. A generic attention TTL is not required to make the integration safe; explicit dismissal plus exact post-outcome visit is the smaller truthful contract.

## Decision input

Adopt the same acknowledgment semantics for Claude CLI outcomes as for other verified Ghostty CLI outcomes: explicit dismissal or a verified exact visit after observation. Preserve uncertain restored items. Do not claim a Claude-native receipt.

If a decay policy is desired, apply it only to the specific action or presentation lifetime first. Any automatic removal from the attention queue must remain a distinct auto-expiry decision, not an acknowledgment.
