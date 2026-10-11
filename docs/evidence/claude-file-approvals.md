# Claude file access and modification approvals (issue #72)

Recorded 2026-10-11 against Claude Code 2.1.296. Raw timeline: [claude-file-approvals.json](claude-file-approvals.json).
This builds on the transport proof in [claude-permission-transport.md](claude-permission-transport.md) (#71).

## Setup and limits

- **Isolation:** `claude --setting-sources project --model haiku --strict-mcp-config` in
  `output/claude-file-lab/project`, with `--permission-mode default` unless a case sets another mode. The
  user's hooks, permission rules and auto mode were not loaded, and no user settings file changed. Every
  target was a disposable fixture recreated for each case: `project/target.txt`, `project/nb.ipynb`, and
  `outside/outside.txt` in a sibling folder outside the project.
- **Helper:** [lab_helper.py](../../scripts/claude-permission-lab/lab_helper.py), the #71 stand-in for SteerHook's
  Claude approval file protocol, now also logs each tool input's key names and string lengths. Driver:
  [run_file_case.py](../../scripts/claude-permission-lab/run_file_case.py).
- **Decisions:** at the operator's explicit direction, the agent scripted every companion decision and native
  keystroke. No human clicked a decision, and the Steer notch was not involved. The shipped SteerHook still
  decides Bash only, so this proves Claude's side for the file family, not a Steer feature.
- **Not exercised:** `LSP` (needs a language-server plugin, which `--setting-sources project` does not load),
  overlapping file requests (the #71 overlap result came from two `Write` calls), NotebookEdit inserts of markdown
  cells or at the start, and an `Edit` without `replace_all`.
- **Follow-up runs (#196):** `Write` overwriting an existing file, `Read` with `offset`/`limit`, and NotebookEdit
  `insert` and `delete` were added with [run_family_case.py](../../scripts/claude-permission-lab/run_family_case.py),
  which replaced the original `run_file_case.py` driver used for the first 15 cases. Its prompts also permit
  `ToolSearch`, which the first notebook-delete run needed.

## Results

| Case | Request | What happened | Result |
| --- | --- | --- | --- |
| edit-allow | `Edit` of `project/target.txt` | Allow. `PostToolUse` with the same `tool_use_id` as `PreToolUse`; the file changed `alpha` to `beta`. | Pass |
| edit-deny | same | Deny. No post-tool event; the file was unchanged. | Pass |
| edit-handoff | same | `no_decision`. The helper exited silently, the native dialog stayed, and native No left the file unchanged. | Pass |
| notebook-allow | `NotebookEdit` replace of cell `c1` | Allow. Post-tool event matched; only the notebook changed. | Pass |
| notebook-deny | same | Deny. No post-tool event; unchanged. | Pass |
| write-outside-allow | `Write` creating `outside/created.txt` | Allow. Post-tool event matched; the file was created. | Pass |
| write-outside-deny | same | Deny. No file. | Pass |
| read-outside-allow | `Read` of `outside/outside.txt` | Allow. Post-tool event matched. | Pass |
| read-outside-deny | same | Deny. No post-tool event. | Pass |
| read-outside-handoff | same | `no_decision`, then native No. No further hook fired, as in #71. | Pass |
| grep-outside | `Grep` with an outside `path` | No `PermissionRequest` and no `PreToolUse`. | No request |
| glob-outside | `Glob` with an outside `path` | No `PermissionRequest` and no `PreToolUse`. Claude showed "Searched for 1 pattern". | No request |
| edit-ask-rule-allow | `Edit` under project `permissions.ask: ["Edit"]` | `PermissionRequest` fired, and the hook's allow applied the edit with no native answer. | Hook allow satisfies an ask rule |
| edit-deny-rule | `Edit` under `permissions.deny: ["Edit"]` | No `PreToolUse` or `PermissionRequest` for Edit; the file was unchanged. | Deny rule wins before the hook |
| edit-accept-edits | `Edit` in `acceptEdits` mode | No `PermissionRequest`; the edit applied. | Mode decides before the hook |
| write-overwrite-allow | `Write` replacing `project/target.txt` | Same two keys as a create. Allow; the file was overwritten. | Pass |
| read-outside-range-allow | `Read` with `offset: 1`, `limit: 1` | Keys `file_path`, `offset`, `limit`. Allow; post-tool event matched. | Pass |
| notebook-insert-allow | `NotebookEdit` insert after `c1` | Keys `notebook_path`, `cell_id`, `new_source`, `cell_type` (`code`), `edit_mode`. Allow; a cell was added. | Pass |
| notebook-delete-allow | `NotebookEdit` delete of `c1` | Keys `notebook_path`, `cell_id`, `new_source` (empty), `edit_mode`. Allow; the cell was removed. | Pass |

In every case, no fixture other than the request's own target changed.

## Decision

| Tool | Decision | Reason |
| --- | --- | --- |
| `Edit` | Include | Prompts in default mode, and allow, deny and handoff behaved exactly. |
| `Write` | Include | Same, including a target outside the project. |
| `NotebookEdit` | Include | Same, for replace, insert and delete. In 2.1.296 it is a deferred tool, so Claude may call `ToolSearch` first, which does not prompt. |
| `Read` (outside the working folders) | Include | Same. Inside the project it never prompted. |
| `Grep`, `Glob` | Exclude | No `PermissionRequest` was raised for an outside path, so there is nothing to decide. |
| `LSP` | Not decided | Not exercised; stays native. |

## Display and validation contract for the file family

The rest of #71's transport contract applies unchanged: one live helper per request, a receipt, a 30-second
deadline, silence hands back, a native answer wins, and a `.delivery` record proves only that the helper
emitted a decision.

**Accept a request only when:**

- `tool_name` is exactly `Edit`, `Write`, `NotebookEdit` or `Read`;
- `tool_input` has exactly one of the key sets observed for that tool, with the observed types (keys the tool
  schema allows but these runs did not exercise stay unsupported until proven):
  - `Edit`: `file_path`, `old_string`, `new_string`, `replace_all` (bool);
  - `Write`: `file_path`, `content` (create or overwrite);
  - `NotebookEdit` with `edit_mode` = `replace`: `notebook_path`, `cell_id`, `new_source`, `edit_mode`;
  - `NotebookEdit` with `edit_mode` = `insert`: those four keys plus `cell_type` = `code`;
  - `NotebookEdit` with `edit_mode` = `delete`: the same four keys as replace, with an empty `new_source`;
  - `Read`: `file_path`, or `file_path` with integer `offset` and `limit`;
- the path is absolute, has no surrounding whitespace, and has no control, format, bidirectional, or line or
  paragraph separator characters, so the displayed path is exactly the target;
- exactly one unmatched `PreToolUse` exists for the same session, prompt and tool **on the same path**. That is the
  existing single-candidate rule. Claude runs prompted calls one at a time (#71), so the path is enough; Steer
  does not keep the full input of every call.

Unknown keys, wrong types, relative paths or no single match: show nothing actionable and leave Claude's
dialog in charge.

**Show at minimum:**

- the action (Edit file, Write file, Edit notebook, Read file). "Write file" claims neither create nor overwrite,
  because the input does not say which;
- the full absolute path, shortened visibly with a disclosure for the full value;
- for `Edit`: the old and new text, bounded and labeled when shortened, plus "all occurrences" when
  `replace_all` is true;
- for `Write`: the content length and a bounded preview. Claude's dialog says "create" or overwrite, but the
  hook input does not, so Steer must not claim either;
- for `NotebookEdit`: the cell id, what happens to it, and a bounded `new_source`;
- for `Read`: the path, plus the line range when present.

**Offer only:** Allow once and Deny. Claude's dialog also offers "switch to accept edits" and "allow reading
from <folder> during this session". Those change session permissions, so they stay in Claude only.

## Differences from the September catalog

The [permission families catalog](https://github.com/r-curio/steer/blob/fe9457f1e9394dff2a474a93c8d8a2eb15c63ea9/docs/claude-permission-families.md)
says a hook allow cannot override a matching ask rule. On 2.1.296, a project `ask` rule for `Edit` still raised
`PermissionRequest`, and the hook's allow applied the edit without the native dialog being answered. For Steer
this is acceptable, because Allow once is the user's own explicit answer. A `deny` rule did stop the call
before any hook.
