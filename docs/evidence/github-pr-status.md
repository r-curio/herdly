# GitHub pull request status through `gh`

Recorded on 2026-11-13 for [issue #417](https://github.com/r-curio/herdly/issues/417), before building on it. Every call was read-only, run by hand from a terminal with GitHub CLI 2.102.0 (`/opt/homebrew/bin/gh`), signed in to github.com through the keyring, against `r-curio/herdly`. Tokens and account details are redacted. This is source and CLI evidence, not live proof of Herdly: no Herdly build made these calls.

## 1. A merged pull request is still found by its head branch after the branch is deleted

The three most recently merged branches no longer exist on the remote:

```sh
git ls-remote --heads origin fix/409-exec-runs-hidden          # prints nothing
git ls-remote --heads origin docs/hold-license                 # prints nothing
git ls-remote --heads origin fix/411-claude-question-open-hand-back   # prints nothing
```

Each is still listed by its head branch with every state:

```sh
gh pr list --repo r-curio/herdly --head fix/409-exec-runs-hidden --state all \
  --json number,state,headRefName,mergedAt,isCrossRepository
```

```json
[{"headRefName":"fix/409-exec-runs-hidden","isCrossRepository":false,"mergedAt":"2026-11-11T04:43:51Z","number":410,"state":"MERGED"}]
```

The same held for `docs/hold-license` (#415, merged 2026-11-13T02:24:12Z) and `fix/411-claude-question-open-hand-back` (#412, merged 2026-11-12T06:10:06Z). The REST view agrees: `gh api repos/r-curio/herdly/pulls/410` gives `head.ref` `fix/409-exec-runs-hidden`, `head.repo` `r-curio/herdly`, `merged: true`.

**Finding:** the lookup is reliable on github.com, because GitHub keeps a pull request's head ref name after the branch is deleted. So "merged" does not depend on Herdly having watched the merge. Two limits remain:

- `--head` matches the branch name only. A fork's pull request with the same branch name also matches, so Herdly keeps only `isCrossRepository: false`.
- A branch name reused after an earlier merge also matches the old pull request. Herdly therefore counts a merge only when `mergedAt` is at or after the turn started.

A branch with no pull request returns `[]` with exit status 0:

```sh
gh pr list --repo r-curio/herdly --head no-such-branch-xyz --state all --json number   # []
```

## 2. Which fields carry check state and mergeability

`gh pr list --json` and `gh pr view --json` both expose `statusCheckRollup`, `mergeable` and `mergeStateStatus`. One `gh pr list` call therefore reads everything:

```sh
gh pr list --repo r-curio/herdly --head <branch> --state all --limit 20 \
  --json number,state,headRefName,headRefOid,isCrossRepository,mergedAt,mergeable,statusCheckRollup
```

An open pull request with a conflict and failed checks (#288, `fix/284-branch-read-blocks-scan`), with URLs shortened:

```json
[{"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","number":288,"state":"OPEN",
  "statusCheckRollup":[
    {"__typename":"CheckRun","name":"swift","workflowName":"macOS","status":"COMPLETED","conclusion":"FAILURE",
     "startedAt":"2026-10-15T01:40:46Z","completedAt":"2026-10-15T01:40:52Z","detailsUrl":"https://github.com/…"},
    {"__typename":"CheckRun","name":"swift","workflowName":"macOS","status":"COMPLETED","conclusion":"FAILURE", "…": "…"}]}]
```

- **Checks:** `statusCheckRollup` is a list. Each entry is either a `CheckRun`, with `status` (`QUEUED`, `IN_PROGRESS`, `COMPLETED`, and so on) and, once completed, `conclusion` (`SUCCESS`, `FAILURE`, `NEUTRAL`, `SKIPPED`, `CANCELLED`, `TIMED_OUT`, `ACTION_REQUIRED`, `STARTUP_FAILURE`, `STALE`), or a `StatusContext`, with `state` (`SUCCESS`, `PENDING`, `EXPECTED`, `FAILURE`, `ERROR`). Only `CheckRun` with `COMPLETED`/`FAILURE` was seen live. The other values come from GitHub's GraphQL enums, which `gh` passes through, and are covered by fixtures only. Herdly reads any value it does not know as unknown, which gives no verdict.
- `gh pr checks <n> --json` offers `bucket` (`pass`, `fail`, `pending`, `skipping`, `cancel`) and `state`, giving `[{"bucket":"fail","name":"swift","state":"FAILURE","workflow":"macOS"}, …]` for #410. It needs a second call per pull request and cannot list by branch, so Herdly does not use it.
- **Mergeability:** `mergeable` is `MERGEABLE`, `CONFLICTING` or `UNKNOWN`. `mergeStateStatus` (`DIRTY`, `CLEAN`, `BLOCKED`, `BEHIND`, `UNSTABLE`, `UNKNOWN`, …) mixes in checks and branch protection, so Herdly reads conflicts from `mergeable` alone.
- **Lazy mergeability:** the first query of #288 returned `"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"`, and a query three seconds later returned `CONFLICTING`/`DIRTY`. GitHub computes mergeability on demand. `UNKNOWN` therefore never reads as a conflict. Herdly marks such a reading pending and reads it again every 30 seconds, for up to 5 minutes from the first reading, to pick up the computed value. It does the same for an open pull request with no checks registered yet, and for a pushed branch whose pull request is not listed yet. After that it settles on what it has.
- **Merged pull requests:** a merged one (#410) reports `mergeable: UNKNOWN`. Herdly does not consult mergeability once `state` is `MERGED`.

## 3. Sign-in and failures

```sh
gh auth status --hostname github.com --json hosts
```

- **Signed in:** `{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"<redacted>","tokenSource":"keyring",…}]}}`, exit 0. With `--json`, `gh` exits 0 even when an account has a problem, so Herdly reads `state`.
- **Signed out** (an empty `GH_CONFIG_DIR`): `{"hosts":{}}`. Without `--json` it prints "You are not logged into any GitHub hosts. To log in, run: gh auth login" and exits 1.
- **Outside a repository** without `--repo`: `gh pr list` fails with "failed to run git: fatal: not a git repository", exit 1. Herdly always passes `--repo owner/name`, read from the folder's `origin` while the turn ran, so a worktree deleted after the merge still resolves.
- **Not shown live:** offline, rate-limited and expired-token runs. Herdly treats any non-zero exit, timeout or unparseable output as unavailable.
