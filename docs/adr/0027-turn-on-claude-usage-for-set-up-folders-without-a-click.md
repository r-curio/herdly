# Turn on Claude usage for set-up folders without a click

Accepted on 2026-11-25 ([issue #481](https://github.com/r-curio/herdly/issues/481), agreed with the user). Settings › Agents now gives each agent one on/off switch and no options, so Claude's usage limits on the strip are always on. Showing usage needs Herdly's status-line bridge in the folder's `settings.json`. Until now Herdly only changed a user's Claude settings when they clicked Configure. Folders set up before this change have hooks but no bridge.

## Decision

- **When Herdly writes.** On detection, Herdly adds the usage bridge to a Claude folder by itself only when all of these hold:
  - Herdly's install record for that folder exists, with matching installation ID and root;
  - the folder is connected or waiting for its first session (never a repair, conflict or unreadable state);
  - the `statusLine` is still the one Herdly recorded at install;
  - an existing status line passes the compatibility probe;
  - `settings.json` is a readable regular file under 20 MB, unchanged since Herdly read it, and checked again just before writing.

  A status line that is already bridged is never wrapped again. Folders Herdly hasn't set up are never touched.
- **How it writes.** The change is the same one Configure makes for usage: the same backup, an atomic replacement, and the install record updated so Undo Setup restores the user's original bytes exactly.
- **One write at a time.** Configure, Undo Setup, the helper refresh and the usage upgrade for Claude folders all run through one actor, `ClaudeSetupWrites`. Each re-reads the folder's files when its turn comes. A write queued behind another writes nothing if the file changed in between.
- **Failure is shown, never guessed.** If any check fails, nothing is written and usage reads unavailable. A failed write the rollback recovered shows one line on the row. A failed rollback is kept in a marker in Herdly's Application Support, never in the Claude folder. That folder's row shows Needs attention and further upgrades stop until a Configure or Undo Setup succeeds.

## Alternatives weighed

- **Show a one-click Configure line instead.** Rejected by the user. Usage is meant to be always on, and turning the agent's switch on is already consent to Herdly managing that folder's settings.
- **Never touch a status line the user already has.** Rejected: most users with a status line would never get usage, and the probe plus the byte-identical fallback already guard against breaking it.
- **Lock `settings.json` across processes.** Rejected: Claude Code and editors don't honour such locks. The re-read just before writing narrows the window, the same exposure Configure already has.

## Consequences

- Detection is no longer read-only for Claude folders. Any future background writer must go through `ClaudeSetupWrites` and follow the same guards.
- Each automatic upgrade leaves a backup folder that Undo Setup doesn't delete, as Configure already does.
- Running Claude sessions may not show the new status line until they restart. This hasn't been checked live.
- A user who edits `settings.json` at the same moment Herdly writes could, in rare cases, lose that edit. The pre-write re-read makes this unlikely, but doesn't rule it out.
