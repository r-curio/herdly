# Contributing to Herdly

Thanks for your interest. Herdly is maintained by one person, so the process is small.

## Before you start

- Open an issue first for anything beyond a small fix. Product behavior is agreed in [docs/product.md](docs/product.md) and the [architecture decisions](docs/adr); a change that alters agreed behavior needs that agreement before code.
- Pull requests are reviewed as part of the normal issue flow; they are not a separate request queue. Link the issue your PR addresses.
- Read [AGENTS.md](AGENTS.md). It is written for coding agents but is the clearest summary of the project's invariants, repository layout, and conventions. If you use an agent, see [Using AI agents on Herdly](docs/agents/ai-tooling.md).

## Requirements

- macOS 14 or later.
- Full Xcode 16 or later (Swift 6). The Command Line Tools alone can fail on newer SDKs with "plugin for module 'SwiftUIMacros' not found" or "plugin for module 'TestingMacros' not found". The workaround is to point `SDKROOT` at an older SDK and pass the Testing plugin path:

  ```sh
  ls /Library/Developer/CommandLineTools/SDKs/
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX<older>.sdk swift test \
      -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX<older>.sdk sh scripts/build-app.sh
  ```

- Python 3 for the scripts in `scripts/` and the feedback relay; they use the standard library only.

You don't need Codex or Claude Code installed to run `swift test`. The tests use fixtures and temporary directories and never read your real `~/.codex` or `~/.claude`; the one test that reads live Codex data (`liveResolutionEvidence`) is skipped unless `HERDLY_LIVE_EVENTS` is set.

## Making a change

1. Work on a branch named `feat/<issue>-<slug>`, `fix/<issue>-<slug>`, or `docs/<slug>`.
2. Keep the change to one issue and follow the surrounding style.
3. Run the checks:

   ```sh
   swift test
   git diff --check
   ```

   For app, helper, or packaging changes, also run `sh scripts/build-app.sh` and `output/Herdly.app/Contents/MacOS/Herdly --smoke-test`. For changes under `relay/feedback`, run `python3 -m unittest discover -s relay/feedback`.
4. Never change your real Codex or Claude Code hook or permission configuration to run tests; the lab scripts in `scripts/` use isolated configuration. Read a lab before running it.

If a setup experiment leaves your real Codex configuration in a bad state and Herdly's Undo setup can't help, follow [Recovery when Undo setup is unavailable](docs/install.md#recovery-when-undo-setup-is-unavailable).

## Pull requests

- Link the issue the PR addresses.
- Run the checks above and say which ones you ran and what they reported.
- Include a screenshot for any UI change.
- Never touch real agent configuration (`~/.codex`, `~/.claude`) in code, tests, or scripts; use isolated paths.
- Never paste transcripts, secrets, or personal paths into the PR, its evidence, or commits.

## Development tools

### Preview the notch with sample items

`--preview-queue <mode>` seeds in-memory sample items for screenshots. It never scans Codex events, never saves, and never releases approvals.

```sh
output/Herdly.app/Contents/MacOS/Herdly --preview-queue expanded
```

Modes: `collapsed`, `expanded`, `empty-collapsed`, `empty-expanded`, `empty-not-connected`, `row-note`, `row-note-reply`, `walk`, `clicked-approval`, `clicked-approval-long`, `clicked-claude-approval`, `clicked-question`, and the spotlight modes `spotlight`, `spotlight-approval`, `spotlight-handed-back`, `spotlight-question`, `spotlight-question-edit`, `spotlight-question-review`, `spotlight-question-long`, `spotlight-question-unavailable`, `spotlight-claude-question`, `spotlight-claude-multiselect`, `spotlight-claude-steps`, `spotlight-result`, and `spotlight-result-markdown`. Add `--preview-keyboard` to draw a question or walk card as if it had the keyboard. The modes are defined in `Sources/HerdlyApp/main.swift`.

Quit your running Herdly first so only one copy is running.

### Replay desktop activity

To replay desktop activity from an isolated event directory, use the [desktop integration runbook](docs/desktop-live-integration.md).

### Run the desktop probe

```sh
python3 scripts/probe_codex_desktop.py --self-test
python3 scripts/probe_codex_desktop.py --app /Applications/ChatGPT.app
```

The probe only inspects bundle metadata and generated protocol definitions. It does not install hooks, change settings, or connect to conversations. Pass the actual installed desktop bundle path when different.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
