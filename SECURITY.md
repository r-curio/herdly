# Security policy

Herdly relays approval decisions and question answers to local Codex and Claude sessions, so bugs that could approve a request without the user's explicit choice, send input to the wrong terminal, or expose session content are treated as security issues.

## Scope

- The Herdly app and its bundled hook helper (`Sources/`).
- The feedback relay in [`relay/feedback`](relay/feedback), which receives Send Feedback notes from the app and emails them to the maintainer; see [docs/feedback-relay.md](docs/feedback-relay.md). Bugs that let a caller bypass its limits, inject mail headers, or read another person's note are in scope.

## Supported versions

Only the latest [GitHub release](https://github.com/r-curio/herdly/releases) is supported. No release is Developer ID signed or notarized yet; builds are ad-hoc signed.

## Reporting a vulnerability

Please report privately through GitHub's [private vulnerability reporting](https://github.com/r-curio/herdly/security/advisories/new) rather than a public issue. Include the steps to reproduce, the affected version (Settings › About shows it), and the impact you observed.

You should get a reply within a week.
