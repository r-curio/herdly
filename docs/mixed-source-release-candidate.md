# Mixed source release candidate

Status: **source and package preparation complete; integrated live acceptance is
pending.** This runbook is the operator gate for issue #88. It joins the
existing Codex pass in [MVP acceptance](mvp-acceptance.md) with the Claude
scenarios that were implemented by issues #80–#87. A package, a smoke check,
or a fixture does not establish live release acceptance.

The runbook is intentionally one checkpoint at a time. Stop after each
checkpoint, record `pass`, `fail`, or `uncertain`, and do not infer a result
from the next checkpoint. Do not use UI automation to operate Codex, Claude,
or Ghostty.

## Evidence boundary

Keep three kinds of evidence separate:

| Evidence | What it establishes | What it cannot establish |
| --- | --- | --- |
| Source and automated | The reviewed source, tests, helper self-test, and deterministic failure rules | That a real session, tab, user choice, or server request occurred |
| Package | The exact clean source commit, artifact checksum, bundle signature, and packaged smoke result | An installed runtime or integrated live behavior |
| Live operator | What a consenting operator observed with the named artifact | A result for a different artifact, root, session, or commit |

Record the full source commit, package filename, package SHA-256, macOS and
toolchain, selected Claude root label, and date with every live result. Keep
session IDs, credentials, prompts, commands, paths, and transcripts out of the
committed record; use booleans, short labels, and redacted descriptions.

The post-merge #87 Actions run `35546830796` was refused before any step by the
account billing limit. It is not source failure, but it means this candidate
must not claim green main CI. The package record therefore names local
automated results and leaves main CI and release status separate.

## Isolated prerequisites

Use a disposable macOS account or an already approved test setup with:

1. one disposable Codex desktop task and one disposable Codex CLI session;
2. one consenting Claude configuration root selected through **Agents → Claude
   Code**, plus a second root with no accepted usage record for the unavailable
   check;
3. one unsplit Ghostty window containing the Codex and Claude sessions, with
   Automation permission granted only when the operator chooses to test exact
   return; and
4. an artifact whose checksum and source commit match
   [the package evidence](evidence/claude-release-candidate-package.json).

If an isolated Codex configuration is unavailable, stop before **L1** and
record the live gate as pending. Do not point Configure Codex at the primary
user configuration merely to complete this checklist. Use the alternate Claude
root control, never a copied credential or an unreviewed `CLAUDE_CONFIG_DIR`.

Before starting, copy the package checksum and manifest into the evidence
record. Keep the raw package, temporary roots, Ghostty state, and operator
notes outside the repository unless they contain only the redacted fields in
the template below.

## Package preparation

Run from the clean source checkout named by the package evidence:

```sh
swift test
sh scripts/package-app.sh
output/Steer.app/Contents/MacOS/Steer --smoke-test
(
    cd output/dist
    shasum -a 256 -c ./*.zip.sha256
)
codesign --verify --deep --strict output/Steer.app
output/Steer.app/Contents/Helpers/SteerHook --self-test
git diff --check
```

The package script must report `dirty_worktree: false`. Copy the generated
manifest and checksum into a new evidence record only after the package has
finished. A checked-in evidence record may be committed after the artifact was
built; its `source_commit` remains the exact clean commit named by the package
manifest.

## Live walkthrough

### L0 — Verify the candidate

| Operator action | Expected observation | Result |
| --- | --- | --- |
| Check the zip checksum, manifest commit, helper self-test, packaged smoke output, and artifact label. | All match the named candidate; the label is `unsigned-dev` or another label the manifest actually reports. | |
| Confirm the package was built from a clean checkout and note the current source commit. | `dirty_worktree` is false; the source commit is recorded in the evidence row. | |

Stop if either check fails. Do not install or configure a mismatched artifact.

### L1 — Start Codex and Claude together

| Operator action | Expected observation | Result |
| --- | --- | --- |
| Launch one disposable Codex CLI session and one newly started Claude session in separate unsplit tabs of the same Ghostty window. | The shared notch shows both sources with source labels. A Claude root reports Connected only after an exact post-configuration startup event. | |
| Run one harmless short turn in each session while the other tab is selected. | Working rows and counts remain source-scoped; one source cannot clear or rename the other. | |

Record only redacted session labels, the selected root label, and whether both
rows appeared. Do not use a project directory or title as an identity.

### L2 — Restart and recover Claude state

| Operator action | Expected observation | Result |
| --- | --- | --- |
| With the Claude session active and Steer showing it, quit and relaunch Steer once. | Current Claude inventory and fresh hook evidence return without replaying a sound. Saved questions, approvals, and running tool detail do not become live controls. | |
| End that session cleanly, start a new session from the same configured root, and wait for its startup event. | The new session connects through a fresh exact root event; an old session is not treated as connected merely because it still exists. | |

If the inventory is unavailable, duplicate, malformed, or timed out, record
`unavailable` and verify that stronger hook evidence was retained. Do not turn
an unavailable scan into an empty root.

### L3 — Answer one exact Claude question

| Operator action | Expected observation | Result |
| --- | --- | --- |
| Ask one disposable single choice question from the Claude session. | The Claude row shows the exact bounded question and choices; no Codex row changes. | |
| Choose one option once in Steer. | Claude receives the selected option through the live helper; Steer reports delivery only after the matching helper acknowledgment. | |
| Observe the next Claude state. | The question clears on Claude's resolution evidence; sending a choice does not claim completion or acknowledgment of unrelated items. | |

Do not record the question text or answer. A multi-select or typed answer is a
separate optional repeat of this checkpoint; it must follow the same identity
and one-shot rules.

### L4 — Approve one Bash request

| Operator action | Expected observation | Result |
| --- | --- | --- |
| Trigger one harmless Claude `Bash` permission request and leave the Claude tab selected elsewhere. | The row offers **Approve once**, **Deny**, and **Open in Claude** only while the exact live helper request is fresh. | |
| Choose **Approve once** once. | Exactly that Bash call is allowed; a later call asks again. | |

Record only the redacted command class and whether the helper acknowledgment
was observed. Successful local delivery is not proof of server execution.

### L5 — Deny one Bash request

| Operator action | Expected observation | Result |
| --- | --- | --- |
| Trigger a second harmless Bash request. Choose **Deny** once. | Claude reports the denial; the command does not run and the request cannot be denied twice. | |

If the request is ambiguous, expired, interrupted, or from another root, stop
the direct decision and record the native fallback from **L6** instead.

### L6 — Hand back and use the native fallback

| Operator action | Expected observation | Result |
| --- | --- | --- |
| Trigger a third Bash request, then let the 30-second deadline expire or stop Steer while the helper waits. | The row loses decision controls and retains only **Open in Claude**; no allow or deny is sent. | |
| Return to Claude and resolve the native prompt there. | Claude's native prompt remains authoritative; Steer clears only after exact resolution evidence. | |
| Click **Open in Claude** from the handed-back row when the target is verified. | The exact same-window tab is selected; navigation alone does not acknowledge the row. | |

Never replace timeout, helper loss, or uncertainty with an approval.

### L7 — Confirm a Claude outcome

| Operator action | Expected observation | Result |
| --- | --- | --- |
| Complete one harmless Claude turn, then wait for the inventory to confirm the exact session idle. | The notch shows a confirmed Finished outcome with the supplied name or a shortened session ID, and the source remains Claude. | |
| If the turn fails or is explicitly stopped with supported evidence, repeat once. | Failed or Stopped is shown only for matching evidence. A `Stop` without idle confirmation stays Status unavailable or current work. | |
| Dismiss the outcome once, then create a later turn in the same session. | Only the matching outcome is cleared; the later turn remains eligible. | |

### L8 — Verify same-window exact return

| Operator action | Expected observation | Result |
| --- | --- | --- |
| With a queued Claude outcome and another app frontmost, click **Open in Claude**. | Ghostty selects the exact unsplit tab in the current window, verified by the post-selection snapshot. | |
| Repeat after selecting another tab first. | The target tab is selected and only the matching outcome can be acknowledged after the verified transition. | |

An app activation, a title match alone, a tab that was already selected, or a
successful command call is not a pass.

### L9 — Exercise unavailable paths

Run each row separately and stop after recording it:

| Setup | Expected observation | Result |
| --- | --- | --- |
| Duplicate live Claude resumes for one session | The shared row remains visible, but direct controls and return are unavailable. | |
| Missing, overwritten, stale, or split Ghostty title | **Open in Claude** is unavailable; no terminal input or acknowledgment occurs. | |
| Claude target in another Ghostty window | Same-window return is unavailable; no arbitrary window is selected. | |
| Failed, duplicate, malformed, or incomplete `claude agents --json` inventory | The root is unavailable and existing stronger observations remain. | |
| A configured root with no accepted usage record, expired windows, or only a spend-limit object | Claude usage reads unavailable independently for each missing window. Steer does not estimate or substitute spend limits. | |
| Question helper timeout, restart, identity mismatch, or helper loss | No answer is sent; Claude's native question remains available. | |

### L10 — Prove usage on a consenting root

| Operator action | Expected observation | Result |
| --- | --- | --- |
| On the consenting test root, enable the optional usage bridge through the preview and start a fresh Claude session. | Existing status-line behavior is preserved; Steer accepts only the root-scoped sanitized record. | |
| Wait for a valid status-line payload with a future five-hour and/or seven-day reset. | Each valid window appears independently as **last reported**, with the tested root identified outside the user-facing record. | |
| Refresh one window or allow one to expire while the other remains valid. | The valid window remains; the missing or expired window becomes unavailable and does not resurrect an older reading. | |

Do not paste status-line payloads, account identifiers, or credentials into the
evidence record. This is the required consenting tested root gate.

### L11 — Run the Codex regression pass

Run the existing Codex operator rows in [MVP acceptance, sections 3a–3e](mvp-acceptance.md)
against the same candidate, including desktop/CLI completion, question,
approval allow/deny/handoff, restart, exact tab, split unavailable, and removal
checks where the isolated setup supports them. Record those results in that
table or link a redacted copy; do not repeat them here. The mixed-source pass
is complete only when Codex rows remain source isolated while Claude is active.

## Evidence record template

Copy this block into a dated evidence file. Empty fields mean pending; they do
not mean pass.

```yaml
issue: 88
status: pending
source_commit: ""
artifact: ""
artifact_sha256: ""
artifact_label: ""
package_manifest: ""
package_built_at: ""
host_macos: ""
toolchain: ""
main_ci: "blocked before steps by account billing limit; verify current run separately"
operator_date: ""
claude_code_version: ""
ghostty_version: ""
tested_root_label: ""
unproved_root_label: ""
checkpoints:
  L0_candidate: {result: "", notes: ""}
  L1_mixed_codex_claude: {result: "", notes: ""}
  L2_claude_restart_recovery: {result: "", notes: ""}
  L3_exact_question: {result: "", notes: ""}
  L4_bash_allow_once: {result: "", notes: ""}
  L5_bash_deny: {result: "", notes: ""}
  L6_handoff_native_fallback: {result: "", notes: ""}
  L7_confirmed_outcome: {result: "", notes: ""}
  L8_same_window_exact_return: {result: "", notes: ""}
  L9_unavailable_paths: {result: "", notes: ""}
  L10_usage_tested_root: {result: "", notes: ""}
  L10_usage_unproved_root: {result: "", notes: ""}
  L11_codex_regression: {result: "", notes: ""}
live_claim: "pending until every required checkpoint is recorded against this artifact"
```

The candidate is not a release or an installed-runtime proof until all required
rows have an operator result and the exact source/package identity matches.
