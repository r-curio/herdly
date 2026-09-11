# Working on Steer

Read the product behavior, architecture draft, and relevant ADRs before implementation. Agreed behavior is authoritative; a draft integration is not a proven capability. Preserve normal Codex use and never automatically approve on an error or timeout.

Keep changes scoped to one ticket on a codex/ branch. Use native macOS and standard library facilities first. Every nontrivial behavior needs a focused runnable check. Separate source inspection, automated checks, and live application proof in reports. Do not change the user's real hook or permission configuration merely to run tests; use isolated test configuration where supported.

## Agent skills

### Issue tracker

Use GitHub Issues in r-curio/steer. External pull requests are not a separate triage intake. See [issue tracker](docs/agents/issue-tracker.md).

### Triage labels

Use needs-triage, needs-info, ready-for-agent, ready-for-human, and wontfix. Blocked issues must not carry a ready label. See [triage labels](docs/agents/triage-labels.md).

### Domain docs

This is a single-context project: [CONTEXT.md](CONTEXT.md) is the glossary, and [docs/adr](docs/adr) holds architecture decisions. See [domain guidance](docs/agents/domain.md).
