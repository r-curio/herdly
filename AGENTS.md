# Working on Herdly

## Product

Herdly is a native macOS companion for a developer running several local Codex sessions while working in other apps. One shared notch shows work in progress, questions, approval requests, and completions, with actions for returning to the originating session. The user continues launching and using Codex normally; Codex must remain usable when Herdly is closed or unavailable.

The initial surfaces are Codex desktop and Codex CLI running directly in Ghostty, with one session per unsplit tab. Remote sessions, other agents, other terminal hosts, split-pane targeting, and other operating systems are outside the initial scope. Exact desktop conversation focus remains deferred; opening a task is not proof that its result was read.

### Sources of truth

| Source | Read when |
| --- | --- |
| [Product behavior](docs/product.md) | Before implementation; authoritative agreed user experience. |
| [Domain glossary](CONTEXT.md) | Before changing models, terminology, or state transitions. |
| [Architecture draft](docs/architecture.md) | Before implementation; distinguish proposals from verified capabilities. |
| [Architecture decisions](docs/adr) | Before changing the relevant integration or architectural boundary. |
| [Design system](DESIGN.md) | For UI, layout, typography, color, motion, and accessibility work. |
| [MVP acceptance](docs/mvp-acceptance.md) and [evidence](docs/evidence) | Before making integration or release claims. |
| Paper: [session states and journey](https://app.paper.design/file/01M5BZ6XS02TKJWZ4CF0MVYBNW/p-1-0) (decision log D1…), [Herdly Settings](https://app.paper.design/file/01M4E368NRBEWP2KJFYFTZ4P2J/p-2-0) | When a ticket or doc cites a D-number or artboard ID. The docs record the agreed wording; the artboard shows layout. |

UI work runs design-first: the user agrees designs and numbered decisions in Paper (a design session leaves the repo untouched), `paper-to-issues` turns them into GitHub issues, and `ship-issue` / `ship-batch` implement them. "Steer" is Herdly's former name and still appears in old worktrees and Paper file names.

Agreed behavior is authoritative. Older README summaries, dated investigations, and unrun acceptance steps can lag it. Apply explicit superseding decisions and identify conflicts; ask about unresolved product choices instead of inventing behavior. A draft integration, generated schema, closed ticket, or passing build is not live proof.

### Product invariants

- **Attention:** one shared notch on the active display. Agreed visibility keeps it available across foreground apps; notification eligibility and acknowledgment have separate rules. Follow the placement contract for display-specific behavior.
- **Queue:** actionable approvals, unanswered questions, handed-back requests, unknown Claude waiting sessions, unacknowledged completions, status-unavailable Claude sessions, then running work; oldest arrival first within each group, except live approvals, which go soonest deadline first. The default sort is "By need"; "Newest first" reorders everything below live approvals and waiting questions. Working and to-check counts are distinct. Queue order never serializes Codex execution.
- **Approval:** only the user's explicit allow-once or deny choice produces a decision. Each request has its own 30-second deadline from receipt. Hover, queue position, retries, and display changes never extend it. Timeout, error, disconnect, or uncertainty hands back with no decision.
- **Handoff:** after handoff, offer only Open in Codex. Retain the reminder until matching resolution evidence arrives; its presence does not prove Codex still needs permission. Desktop approvals remain native until their transport and handoff policy are verified.
- **Identity:** distinguish source, session, turn, request/call, completion, and live approval interaction. A project directory, title, command string, or foreground app alone cannot identify the intended action.
- **Targeting:** revalidate the exact target before navigation or input. Missing, duplicate, or split targets never select a tab or pane; Open may only raise the session's terminal app (Open fallback, ADR 0015). Closed sessions and unreadable hosts return unavailable. Never send input to an arbitrary terminal.
- **Questions:** relay only the option the user chose, through a supported route with a fresh pending-request check. The Ghostty question-key exception in ADR 0006 does not permit keystroke approvals. Consult ADR 0007 for daemon questions.
- **Acknowledgment:** require explicit dismissal or source-specific evidence defined in the product docs. Desktop activation and navigation alone acknowledge nothing. Clearing one item preserves other turns and requests.
- **Recovery:** restore uncertain completions silently. Persisted requests cannot recreate a live approval connection or active decision controls.
- **Presentation:** preserve unknown states, label shortened commands, expose full details, and show Codex's reason/name only when provided. Sending a decision or prompt does not establish execution or acknowledgment.

## Architecture and repository map

The project is a Swift 6 package targeting macOS 14 or later. [Package.swift](Package.swift) defines the deployment floor and targets.

| Location | Owns |
| --- | --- |
| `Sources/HerdlyCore/` | Session/attention models, deterministic transitions, matching, bounded record decoding, persistence formats, and safe file access. Keep AppKit, sockets, and process orchestration outside this target. |
| `Sources/HerdlyApp/` | SwiftUI content, AppKit panels/windows, main-actor state ownership, native navigation, integration clients, and storage locations. |
| `Sources/HerdlyHook/` | Decode hook input, deliver events, arbitrate one request outcome, and emit Codex-compatible output. |
| `Tests/HerdlyCoreTests/` | Swift Testing checks for state, identity, records, and integration boundaries. |
| `scripts/` | Build/package scripts, capability probes, and isolated integration labs. Read a lab before executing it. |
| `docs/` | Product contracts, decisions, runbooks, and durable evidence. |
| `output/` | Ignored local build and lab artifacts. |

Use native macOS and standard library facilities first. Add dependencies or abstractions for concrete requirements. Preserve the core/app/helper boundaries; a new transport does not justify a generic agent framework.

## Code conventions

### Swift and state

- Follow surrounding style: four-space indentation, `UpperCamelCase` types, `lowerCamelCase` members/functions, and domain-specific names. Keep unrelated formatting out of the diff.
- Prefer structs and enums for values and state transitions. Represent invalid, unavailable, and uncertain states explicitly rather than overloading booleans or empty strings.
- Keep access narrow. Expose core APIs needed across targets and restrict mutation with `private` or `private(set)` where appropriate.
- Pass time, identities, and observations into state rules so deadline and race tests are deterministic. Keep filesystem, process, and UI work out of pure transitions.
- Own UI state on `@MainActor`; move blocking scans and process work off it. Transfer safe values across isolation boundaries. Resolve concurrency diagnostics instead of bypassing them with unchecked annotations without a documented invariant.
- Preserve bounded parsing, safe file access, atomic snapshot replacement, and exact identity checks. Malformed or partial input must not grant permission or clear unrelated attention.
- Keep helpers focused on one responsibility. Comments explain constraints and tradeoffs; document non-obvious inputs, outcomes, and failure behavior at the boundary.

### Native interface

- Use SwiftUI for content and AppKit for panel, window, activation, and platform behavior. Put business rules in HerdlyCore rather than view bodies.
- Follow [DESIGN.md](DESIGN.md) and the existing `NotchStyle` tokens. Preserve the compact native interface and session color semantics.
- Preserve keyboard navigation, VoiceOver labels, Reduce Motion behavior, full command details, and explicit unavailable/unknown states.
- Keep model ownership consistent with surrounding views. A feature change is not a reason to migrate the whole observation model or raise the deployment target.

### Scripts and records

- Prefer existing Python standard-library and POSIX shell patterns. Quote paths, propagate failures, bound waits, and use explicit lab paths instead of personal paths in application code.
- Keep protocol stdout clean; diagnostics must not corrupt Codex-compatible helper output.
- Store only metadata required by the feature. Redact secrets and unrelated conversation content before committing evidence.
- Keep binaries, caches, personal configuration, and transient lab output out of commits; follow [.gitignore](.gitignore).

## Working process

1. **Establish scope.** Read `git status --short`, `git branch --show-current`, the requested ticket or agreed task, and relevant product/architecture docs. Preserve existing user changes.
2. **Isolate work.** Keep changes scoped to one ticket on its own branch, prefixed by the kind of change: `feat/` for new or changed behavior, `fix/` for a bug fix, `docs/` for documentation only. These are the only prefixes: any other change (a refactor, tests, scripts, packaging or CI) uses `fix/` when it corrects something broken and `feat/` otherwise, and a change that mixes kinds takes the prefix of its main purpose. Follow the prefix with the ticket number when there is one and a short slug, such as `fix/153-herdr-route-gaps` or `docs/branch-prefixes`. For a direct request without a ticket, use an equivalently scoped branch; do not invent a ticket number. Existing `codex/` branches keep their names. Avoid unrelated cleanup. Implement in a fresh worktree, `git worktree add ../Herdly-worktrees/<branch> -b <branch> origin/main`, and leave the primary checkout on whatever branch the user has it on. Parallel issues collide most in `ControlsView.swift`, `NotchView.swift` and `main.swift`; name any of these you edit in the handoff so the second merge knows to rebase.
3. **Check dependencies.** Use GitHub Issues in `r-curio/herdly`. Verify blockers and their actual results before starting. Follow [issue tracker](docs/agents/issue-tracker.md) and [triage labels](docs/agents/triage-labels.md). External PRs are not a separate triage intake.
4. **Choose tools.** Use the [local AI tooling guide](docs/agents/ai-tooling.md). Read applicable skills before using them; prefer this project's variants for SwiftUI and tracker workflows.
5. **Implement completely.** Follow the real data/state path through affected surfaces. Continue routine authorized work; ask when an unresolved decision or unavailable dependency prevents a correct result.
6. **Verify.** Every nontrivial behavior needs a focused runnable check, including affected failure and uncertainty paths. Update the relevant contract or runbook when behavior changes.
7. **Review and hand off.** Inspect scope and whitespace. Report changes, checks, outcomes, and remaining uncertainty. Stage explicit files when committing. Local edits do not imply push, merge, release, or installation. When the user asks to merge, squash-merge (`gh pr merge <pr> --squash --delete-branch`) with the title `feat|fix|docs: <plain summary> (#<issue>)`, then close out the issue and worktree as `ship-issue` describes.

Use `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix` according to the label guide. Blocked issues have no ready label. Follow [domain guidance](docs/agents/domain.md) when updating the glossary or recording architectural tradeoffs.

## Checks and evidence

Run from the repository root. The local checks below are the required gate for merges and release candidates. [CI](.github/workflows/macos.yml) is optional: when a run is available, report its result accurately, but an unavailable or unstarted run does not block work.

| Purpose | Command |
| --- | --- |
| Core suite | `swift test` |
| Focused test | `swift test --filter <test-name>` |
| Development app bundle | `sh scripts/build-app.sh` |
| Development distribution package | `sh scripts/package-app.sh` |
| Packaged-app smoke check | `output/Herdly.app/Contents/MacOS/Herdly --smoke-test` |
| Whitespace check | `git diff --check` |

Use Swift Testing (`import Testing`, `@Test`, `#expect`) and existing fixtures. Test observable behavior: duplicate/reordered events, exact identity isolation, deadline boundaries, late decisions, malformed records, restart recovery, and unavailable targets as relevant. Prefer explicit clocks and temporary directories over sleeps or real user state.

For Swift behavior changes, run focused checks while iterating and `swift test` before handoff. For app/helper/resources or packaging changes, build and run applicable packaging/smoke checks. For documentation-only changes, verify claims, links, commands against source scripts, and the diff; a full app build is unnecessary.

Separate evidence in reports:

- **Source inspection:** what code, schemas, or docs establish.
- **Automated checks:** exact checks and outcomes, including fixture/replay limitations.
- **Live application proof:** installed runtime, tested scenario, and observed result. Identify the artifact/commit when known; the current checkout need not be the running app's source.

The user runs Herdly from the primary checkout's `output/Herdly.app` (bundle ID `dev.rcurio.herdly.prototype`). "Relaunch my Herdly" means: update the primary checkout, `sh scripts/build-app.sh`, run the smoke test, then quit and reopen it:

```sh
osascript -e 'quit app id "dev.rcurio.herdly.prototype"'; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f output/Herdly.app/Contents/MacOS/Herdly >/dev/null || break; sleep 0.5; done; pkill -f output/Herdly.app/Contents/MacOS/Herdly; open output/Herdly.app
```

Keep one Herdly running: launch a worktree build only after quitting the user's copy, and relaunch theirs afterwards. A UI change keeps "matches the Paper artboard" as an open check until someone compares the running app with the cited artboard; report it as unticked, with the artboard ID and a two-minute compare step. Report CPU and memory in absolute units (CPU seconds per wall minute, wakeups/s, MB footprint from `top -l` and `vmmap --summary`), never percentages alone.

A package or smoke test does not complete integrated operator acceptance. Ad-hoc signing is not Developer ID signing or notarization. Reconcile older checklist expectations with current product behavior before following them. For interactive manual testing, guide one checkpoint at a time.

## Integration safety and reference routes

Never change the user's real hook or permission configuration merely to run tests. Use isolated configuration and disposable tasks where supported. Preserve normal Codex use. Never automatically approve on error or timeout, or choose a question answer on the user's behalf.

| Changing or investigating | Read first |
| --- | --- |
| Desktop events | [Desktop integration](docs/desktop-live-integration.md), [investigation](docs/codex-desktop-investigation.md) |
| CLI targeting | [CLI integration](docs/cli-notch-integration.md), ADRs 0004–0005 in [decisions](docs/adr) |
| Approvals and reminders | [Approval reconciliation](docs/approval-reconciliation.md), [reminder integration](docs/reminder-integration.md) |
| Questions and daemon responses | [User-input requests](docs/user-input-requests.md), ADRs 0006–0007 in [decisions](docs/adr) |
| Follow-up prompts | [Session replies](docs/session-replies.md); verify transport scope and live evidence separately |
| Discovery, names, read state | [Discovery](docs/session-discovery.md), [thread names](docs/thread-names.md), [desktop read state](docs/desktop-read-state.md) |
| Persistence | [Restart recovery](docs/restart-recovery.md) |
| Notch and interaction | [Notch placement](docs/notch-placement.md), [design system](DESIGN.md) |
| Setup and distribution | [Install](docs/install.md), [MVP acceptance](docs/mvp-acceptance.md) |

Keep these documents as the detailed sources of truth. Update their facts rather than duplicating long procedures or dated capability inventories here.
