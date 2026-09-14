# Codex weekly limit

The collapsed strip shows how much of Codex's weekly usage limit is used, as a small bar with the percent beside it in the wing right of the camera housing. The sprites, the "+N" overflow mark, and the to-check badge sit together in the wing left of it. Like [thread names](thread-names.md), this rides on a private Codex format and fails soft.

## What Codex records

Every turn, Codex appends a `token_count` event to the session's rollout under `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<session id>.jsonl`:

```
{"timestamp":"2026-09-14T03:06:53.274Z","type":"event_msg","payload":{"type":"token_count","info":{…},"rate_limits":{"limit_id":"codex","primary":{"used_percent":7.0,"window_minutes":10080,"resets_at":1789831495},"secondary":null,"credits":{…},"plan_type":"pro","rate_limit_reached_type":null}}}
```

The weekly window is whichever of `primary` and `secondary` spans 10080 minutes. On the inspected machine the current plan reports it as `primary` with no `secondary`; older rollouts from another plan report a five-hour `primary` (300 minutes) and the weekly window as `secondary`. `used_percent` is Codex's own figure and `resets_at` is the Unix time the window resets. Hook events and the session index never carry this. Observed with CLI 0.153.4.

## Steer's rule

`CodexUsageReader.latest` walks the newest day directories (at most 14, across the newest years and months), takes the eight most recently modified rollouts, and reads only the last 512 KB of each, newest first, until one yields a weekly window. A session that has just started and has no `token_count` yet therefore falls through to the session before it. A symlink or a non-regular file is never read. A line that is not a JSON object of the expected shape, including the cut first line of a tail read or a partial last line while Codex is appending, is skipped.

`CodexWeeklyLimit.isCurrent` is false once `resets_at` has passed: a reading from before the reset describes last week, so the strip shows a dash instead of a stale number. The percent shown is Codex's figure rounded to a whole number and clamped to 0 to 100. Steer never estimates usage itself.

## App integration

Each two-second scan reads the newest rollouts off the main actor alongside the hook events, rollouts, read state, and thread names, and publishes the reading on the companion model. The readout is a 4-by-14-point vertical bar (dark-well track, ink fill from the bottom to the used share) with the percent in ink beside it, or an empty track and a dim dash while there is no current reading; the strip's accessibility label speaks "weekly limit 8% used" or "weekly limit unknown". `--reminder-rollouts <path>` points a lab run at a copy of the sessions tree, as it already does for reminders. Preview runs seed 37%.

The wing left of the housing widened from 64 to 112 points so three sprites, the overflow mark, and the badge fit without clipping; the wing right of it stays 60 points.

## Verification

Automated: `Tests/SteerCoreTests/CodexUsageTests.swift` covers the real shape with the weekly window as primary, preference for the 10080-minute window as secondary, a five-hour window alone yielding nothing, last-readable-line-wins with skipped lines, currency until reset with clamped percent text, and file selection: newest-modified first, fall-through past a rollout without usage, tail reads of a rollout larger than 512 KB, and a refused symlink. `NotchPlacementTests` carry the new wing width.

Live: a check linked against `SteerCore` read `~/.codex/sessions` on the inspected machine in 7 ms and returned 8% used, resetting 2026-09-19, from an event written that minute.
