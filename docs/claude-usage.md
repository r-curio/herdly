# Claude usage

Claude usage is a per configuration root status line integration, on for every root Herdly configures
(#481, Paper "Agents tab like Terminals", A4). Earlier versions made it an opt-in; that choice is
ignored. A root Herdly set up with it off gets the bridge on its own at the next setup check, with no
Configure click: only while the root has Herdly's install record and a connected or restart-awaiting
setup, the status line is still the one Herdly recorded, `settings.json` is unchanged since the
check read it, and an existing command passes the compatibility probe. It changes only `statusLine`,
backs up the settings as Configure does, writes atomically, and keeps the original status line in
the install record, so Undo Setup restores it byte for byte. Otherwise nothing is written and usage
reads unavailable (`ClaudeSetupInstaller.upgradeUsage`). A write that fails is rolled back and the
folder's row says usage couldn't be added; if the rollback fails too, the row reads Needs attention
with the reason, since the settings may be half-written. Configure, Undo Setup, the helper refresh
and this upgrade take turns on one queue (`ClaudeSetupWrites`), so a switch flipped mid-upgrade
waits for it, and each re-reads the folder's files when its turn comes.
Herdly does not scan credentials, merge roots, estimate usage, or substitute gateway spend limits for
subscription usage.

## Bridge behavior

When Herdly configures a root, it previews the selected root's existing `statusLine` command and runs a bounded
compatibility probe before composing it. The probe exercises normal completion and cancellation. A
command that does not exit within the probe bound, including one that leaves a descendant alive, is
left unchanged. An incompatible, malformed, or policy-shadowed status line leaves the core Claude
hooks connected and reports Claude usage as unavailable.

The packaged `HerdlyHook` streams Claude's status-line stdin through the existing shell command and
keeps only a bounded prefix for the optional sanitized record. Oversized input is forwarded intact
but produces no usage record; capture-store and pipe-closure errors leave the existing command to
finish and preserve its output and exit status. The bridge preserves stdin bytes, stdout, stderr,
working directory, environment, arguments, and exit status for a normal command. It stores one
atomic `herdly-latest.json` snapshot per selected root, and lookup reads only that fixed owned path.
Repair and undo validate that path's filename, regular-file identity, and Herdly source marker before
removing it, leaving unrelated files untouched. They compare the exact Herdly-owned status-line value
and report a conflict before changing a later user edit.

## Reading contract

Each record is qualified by the selected configuration root and a canonical Claude session UUID.
Records with a missing or noncanonical session ID are unavailable. Herdly shows the five-hour and
seven-day subscription windows independently when each object is finite, in the range 0–100, and
its reset is still in the future on Herdly's clock. A missing, malformed, expired, or unproved window
is unavailable. A newer malformed record does not resurrect an older reading. The `spend_limit`
object is ignored.

The strip draws the current five-hour and seven-day windows as one orange ring (inner ring five-hour, outer ring seven-day) ahead of Codex's blue ring; a window that is not current draws no ring, and the open panel prints the numbers beside it ("61/18%"). With several roots it shows only the newest still-current reading (`ClaudeUsageReading.newest`; equal observation times go to the lexicographically smallest root path); a root whose windows have all reset never hides an older current one.

The expanded notch does not list Claude usage. The Claude Code setup page lists every opted-in root and labels readings as **last reported**. Readings are
not proof that Claude made a fresh server request. A root with no accepted record remains unavailable;
Herdly does not claim live delivery for roots that have not supplied a valid session record.

## Verification boundary

Automated coverage is in `Tests/HerdlyCoreTests/ClaudeUsageTests.swift`. It covers independent window
decoding and expiry, missing windows, spend-limit exclusion, malformed newest records, separate roots,
required session identity, oversized records, repeated-refresh retention, unrelated over-cap siblings,
forged owned filenames, undo after many refreshes, status-line quoting, slow-command rejection,
reversible setup, and status-line conflict handling. Packaged helper checks also cover exact large
stdin forwarding, a command that exits without reading stdin, output preservation, and exit status.

The compatibility and status-line coexistence proof is recorded in [Claude usage and status-line
coexistence proof](https://github.com/r-curio/herdly/blob/9b4f835/docs/claude-usage-proof.md). That proof
used one disposable first-party Max root and did not read or change the real settings or credentials.
Live delivery through this product bridge has not been verified on a shipped
artifact. This check is optional; no live proof is claimed here.
