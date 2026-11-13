# Scan hook records on change, and on a clock only while something can change unseen

Accepted on 2026-11-13 ([issue #306](https://github.com/r-curio/herdly/issues/306)). Until now the hook scan ran every two seconds whether or not anything had changed or any session existed. A file-system watch on the hook directories already existed, but only to make that timed scan's listings cheaper. The scan is the only route by which an approval or question reaches the notch, and the hook helper gives up on the companion after `ApprovalTiming.connectionTimeout` (5 seconds), so how often it runs is a safety property as well as a cost.

## Decision

- **Rule.** `HookScanSchedule` in HerdlyCore answers whether a scan is due from monotonic time, the last scan's start, pending change evidence, whether the watch can be trusted, and `HookScanNeeds`. The app only feeds it; the watch, the timer and AppKit stay in HerdlyApp.
- **Evidence.** A change in a watched hook directory, dropped or overflowed watch events, and app activation make a scan due on the next refresh tick. Evidence stays pending until a scan starts, so one that arrives during a scan, or after its listing, causes the next scan. The watch's callback sets a lock-protected flag that the tick reads; it never hops to the main actor.
- **Spacing.** Scans stay at least two seconds apart, as before, so a burst of records costs no more scans than the fixed clock did. An explicit request (a setting change, an approval leaving the queue) bypasses spacing, as before.
- **Fixed two-second clock, kept while something can change unseen.** The scan also reads inputs no watch covers: Codex rollouts, the process table, Claude's session registry and usage files, thread names, desktop read state. The clock is kept while any of these holds: no scan has applied yet; a source could not be read; a row or result is held; a session, subagent, daemon thread or fresh rollout candidate is live; a Codex process or the Codex app is running, or the process table is unreadable; the Codex hook folder is unset or a Claude root is not connected; a Claude usage window resets within the safety interval; the notch is open or Herdly is active; a hook directory is unwatched, its stream failed to start, or its watch was lost.
- **Safety scan.** Otherwise a scan runs every `safetyInterval`, derived as the helper's connection timeout less the slowest refresh tick and a second of scan time: 3 seconds. A hook record whose file-system event never arrives is therefore still receipted inside the helper's window instead of being handed back. A test pins the relation.
- **Uncertainty scans.** An untrusted watch, a clock that cannot be compared, and anything the rule cannot establish all give the two-second clock, never a skip.

## Alternatives weighed

- **A 10-second safety scan.** It removes four fifths of quiet-state scans instead of a third. Rejected: with nothing held and one missed event, an approval would wait past the helper's 5 seconds and be handed back with no decision. That is the safe failure, but on the fixed clock the same request was shown, and arrival must not get slower.
- **Hopping from the watch callback to the main actor to scan at once.** Rejected: it adds wakeups under a burst of records and a second route into the scan. Polling a flag on the existing tick costs nothing new, and the tick is at most a second.
- **Slowing the clock while only finished results are held.** Not done: desktop read state and acknowledgment evidence are polled, and it was not established that they can wait.

## Consequences

- With any row, session or Codex process present, the cadence is what it was. The saving is confined to a Herdly with nothing to show: a third fewer scans, and a new record picked up within a tick instead of after two to three seconds.
- Dropping a condition from the fixed clock needs its own signal first: a watch on the rollout root and on Claude's registry, and process-exit notification for tracked pids. Each is a separate change with its own evidence.
- In the quiet state, work that runs after each scan (Claude usage refresh, the restart recheck) follows the safety interval.
- Not yet shown live: watch delivery in the running app, and whether Herdly's own writes into the hook directories keep the quiet state from being reached.
