# Read work status with git and the GitHub CLI

Accepted on 2026-11-13 ([issue #417](https://github.com/r-curio/herdly/issues/417)). A finished row is to show how far its work got: uncommitted, not pushed, checks running, checks failing, conflict, checks passed or merged. Until now Herdly read only the branch name from `.git/HEAD`, with no git process and no network (`GitBranchReader`). This is the first time Herdly runs `git` in a session's folder. It is also the first network read of data derived from a session. Phone alerts (ADR 0019) already send fixed wording out through ntfy, but they never read anything back.

## Decision

- **Switch.** Everything sits behind "Pull request status on finished rows" on the GitHub card in Settings › Agents. Until the user chooses, it is on only while `gh` is installed and signed in to github.com.
  - Every command checks the switch immediately before it starts (`WorkStatusGate`), off the main actor, and turning it off forgets every reading.
  - With the switch off, no `git` and no `gh` process runs at all, including the card's own check. The card then finds "not installed" by looking for the binary on disk. Otherwise it shows the last check, kept in `UserDefaults` as the version and whether github.com was signed in (never an account or token), or "Status unknown" when none is kept. Check Again is disabled.
  - While the switch is on, or still undecided because its default depends on the check, the card runs `gh --version` and `gh auth status`: at launch, when Settings › Agents opens, on Check Again, and when the user turns the switch on.
- **Remembered branch.** Each scan already reads every row's HEAD from disk. While a turn runs, Herdly remembers its folder and HEAD, keyed by session and turn, in memory only. The memory is kept while any live row names the turn, including an approval or question that hides its running row, and dropped once no row does. The pull request is looked up for that branch, so it still resolves after an agent merges and the folder goes back to the default branch. There is no verdict when:
  - the HEAD or folder changed during the turn;
  - another live session was in the same folder, or one inside it, in the same scan: running, waiting, or holding an approval, question or handed-back request. Both sides are marked, so a turn that sat in an approval while another session ran there has no verdict either. A named subagent's handed-back approval can outlive its parent turn and still names that turn; if another session then runs in the folder, the finished turn is marked shared and has no verdict. That is intended: the subagent's work belongs to the turn;
  - Herdly never saw the turn running.
  A detached HEAD gets no pull request lookup.
- **Processes.** Each `git` or `gh` starts as the leader of its own process group, with close-on-exec on Herdly's end of its output pipe. Past its wait, the whole group gets SIGTERM, then SIGKILL a second later. The output reader stops either way, so a leftover descendant holding the pipe cannot block it.
- **Local git.** Herdly runs only read-only commands, each with a 3-second wait:
  - `git --no-optional-locks -c core.fsmonitor=false -C <folder>`, followed by `status --porcelain=v2 --branch`, `config --get remote.origin.url`, `remote`, or `rev-list --count HEAD --not --remotes`.
  - These run with `GIT_OPTIONAL_LOCKS=0`, a minimal environment and no prompt, so a read never takes the index lock an agent may need.
  - `/usr/bin/git` is never run, because without the developer tools it offers to install them. Herdly uses Homebrew's git or the developer tools' own.
  - A folder that is not a work tree, or a failed, timed-out or unreadable command, gives no local reading.
- **GitHub.** One `gh pr list --repo <owner/name> --head <branch> --state all --json …` call per read, with a 10-second wait.
  - The repository comes from `origin`, read once while the turn runs. A remote not on github.com means no GitHub call is ever made.
  - `gh` uses the user's own sign-in. Herdly stores no token, passes none and never runs `gh auth login`.
  - Missing, signed out, offline, rate-limited, failing, or more than one open pull request for the branch: no pull request verdict, and never an error in the notch.
- **Verdict.** `WorkStatusRule` in HerdlyCore gives the furthest verdict that is certain, or none, in this order:
  1. A merge at or after the turn started.
  2. Then, only while the folder is still on the remembered branch: uncommitted changes, then unpushed commits. Unpushed means ahead of the branch's own upstream (`origin/<branch>`). A branch with no upstream, or one tracking another branch (a worktree made from `origin/main`), counts commits on no remote instead. An upstream branch that is gone, deleted after a merge, leaves this unknown.
  3. Then the open pull request: conflict, then checks failing, running or passed.
  An unreadable folder allows only "merged". The evidence for these fields is in [github-pr-status](../evidence/github-pr-status.md).
- **Schedule.** `WorkStatusSchedule` reads a finished turn once when it appears. After that it reads again only while checks run, every 30 seconds, never past an hour from the first reading.
  - **Pending.** While GitHub is still working something out, the reading is pending. That covers an open pull request whose `mergeable` is UNKNOWN, an open pull request with no checks registered, and a pushed branch with no pull request listed. A pending reading is read again at the same 30-second interval for 5 minutes from the first reading, then settles on the furthest certain verdict.
  - Every other verdict is terminal: it is not read again, recent or Earlier. A "checks passed" row is not re-read to catch a later merge, and a reading that failed is not retried.
  - A finished turn is not read while any live row of its own remains: a background subagent's working row after the turn ended (#426), or one paused on an approval or question, which can resume editing. If such a row comes back after the turn was read, the reading is dropped and the turn reads no verdict until those rows end; then it is read again, within the original hour and 30 seconds after the last read. A handed-back reminder that outlives the turn counts as such a row. HEADs seen meanwhile still count toward the turn's memory, so a branch change while the subagent runs leaves no verdict, including one read before.
  - `WorkStatusBatch` picks each scan's reads without running anything: at most six turns per batch, one batch at a time. It skips a finished turn while other live work is in its folder (another session, or this session's next turn), or while its repository is still unread. Unknown and ambiguous turns settle as no verdict without a command.
- **Boundary.** Parsing and rules live in HerdlyCore. Processes, the switch and `UserDefaults` live in HerdlyApp (`WorkStatusReader`, `WorkStatusModel`). The row presentation is #418: a reading also carries the pull request that decided its verdict (number, and the repository from the remembered branch), and the place rules (`RowPlace`) live in HerdlyCore; the views only draw them. It never orders the queue, counts as work, acknowledges anything or moves a deadline.

## What leaves the Mac

- **Sent to GitHub through `gh`, over its own authenticated connection:** the repository's owner and name, and the branch name. GitHub learns that this account asked about that branch's pull requests.
- **Never sent:** prompts, responses, commands, file names, file contents, paths, session identifiers and tokens. The git commands are local.

## Considered options

- **GitHub's REST or GraphQL API with a token Herdly stores.** This would need Herdly's own sign-in flow and Keychain storage for a credential with repository scope. It would also create a second place where that credential can leak. `gh` already holds the user's sign-in and handles GitHub Enterprise hosts and SSO. Rejected for now.
- **libgit2, or reading `.git` files directly for status.** Working-tree status needs the index, untracked-file rules, ignore files and filesystem metadata, and `git` already implements all of that. A second implementation could disagree with what the user sees. libgit2 would also be the first third-party dependency. Reading `.git/HEAD` stays the per-scan branch read, which runs no process.
- **`gh pr checks` and `gh pr view` per pull request.** Two or three calls per read. `gh pr list --json` returns state, merge, mergeability and checks in one call, and it finds the pull request by branch.
- **Polling cadence.** Reading on every 2-second scan would mean a GitHub call per row per scan and would hit rate limits. Reading only once would never see checks finish. A fixed 30-second interval while checks run, with a one-hour cap, bounds a busy hour to about 120 calls per row. Re-reading settled verdicts every few minutes, to catch a merge after checks passed or a later push, was tried and dropped: the issue asks for refresh only while checks run.
- **Treating "merged" as known only while Herdly watched it.** Not needed: the evidence shows a merged pull request is still found by head branch after the branch is deleted.

## Not yet shown live

- A session ending uncommitted, one ending with failing checks, and one ending merged, each read from a packaged build.
- `gh` signed in through the keyring when launched from the app rather than from a terminal.
- Offline, rate-limited and expired-token behaviour, so far covered by fixtures only.
