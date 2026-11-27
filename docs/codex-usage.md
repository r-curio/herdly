# Codex usage limits

The collapsed strip shows how much of Codex's weekly usage limit is used, as the outer ring of Codex's usage ring in the wing right of the camera housing. While Codex also reports a five-hour window that has not yet reset, the ring gains an inner ring for it; otherwise no inner ring is drawn and nothing stands in for the missing window. The open panel prints the numbers beside the ring ("36/58%", or "58%" with the week alone). Since #488, Settings › General › Usage picks which windows Codex's ring shows: a 5-hour and a Weekly checkbox, so the five-hour window, the weekly window, both or neither (no ring); the 5-hour box is disabled while Codex reports no five-hour window. The sprites and the to-check badge sit together in the wing left of it. Like [thread names](thread-names.md), this rides on a private Codex format and fails soft.

## What Codex records

Every turn, Codex appends a `token_count` event to the session's rollout under `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<session id>.jsonl`:

```
{"timestamp":"2026-09-14T03:06:53.274Z","type":"event_msg","payload":{"type":"token_count","info":{…},"rate_limits":{"limit_id":"codex","primary":{"used_percent":7.0,"window_minutes":10080,"resets_at":1789831495},"secondary":null,"credits":{…},"plan_type":"pro","rate_limit_reached_type":null}}}
```

The weekly window is whichever of `primary` and `secondary` spans 10080 minutes and the five-hour window whichever spans 300. `used_percent` is Codex's own figure and `resets_at` is the Unix time the window resets. Hook events and the session index never carry this. Observed with CLI 0.153.4.

Which plans report the short window, from the rollouts on the inspected machine:

| Plan (`plan_type`) | Shape | Seen |
| --- | --- | --- |
| `prolite` | five-hour `primary`, weekly `secondary` | 2026-05-25 to 2026-05-31 |
| `pro` | five-hour `primary`, weekly `secondary` | 2026-06-02 to 2026-07-02 |
| `pro` | weekly `primary`, `secondary` null | 2026-07-13 onward, including every `codex` event since 2026-09-08 |

Since 2026-09-11 the only events carrying a 300-minute window are for a separate limit (`limit_id` `codex_bengalfox`, `limit_name` GPT-5.3-Codex-Spark), not the plan's `codex` limit, and they report both windows at 0%. Sessions mix the two: a rollout on the inspected machine ends with a Spark event minutes after a `codex` one. The reader therefore skips any `token_count` whose `limit_id` is present and not `codex` (`CodexUsageReader.planLimitID`), so a Spark event can neither invent a five-hour readout nor zero the weekly one; a line with no `limit_id` is still read. On the current plan the five-hour readout appears only if Codex starts reporting the window on the `codex` limit again.

## Herdly's rule

`CodexUsageReader.latest` walks the newest day directories (at most 14, across the newest years and months), takes the eight most recently modified rollouts, and reads only the last 512 KB of each, newest first, until one yields the plan's weekly window. The five-hour window comes from that same line as part of the `CodexUsageReading` when the line has one; a line with only a five-hour window, or another limit's windows, is skipped like any other unreadable line, so the weekly readout is exactly as robust as before. A session that has just started and has no `token_count` yet therefore falls through to the session before it. A symlink or a non-regular file is never read. A line that is not a JSON object of the expected shape, including the cut first line of a tail read or a partial last line while Codex is appending, is skipped.

`CodexUsageWindow.isCurrent` is false once `resets_at` has passed, and `CodexUsageReading.current` drops each window that has: a weekly reading from before the reset describes last week, so the strip shows a dash instead of a stale number, and an expired five-hour reading simply leaves the strip (with the weekly still shown while it is current). The percent shown is Codex's figure rounded to a whole number and clamped to 0 to 100. Herdly never estimates usage itself.

## App integration

Each hook scan (two seconds apart while a session is live or a row is held, [architecture](architecture.md)) reads the newest rollouts off the main actor alongside the hook events, rollouts, read state, and thread names, and publishes the reading on the companion model. The ring is 18 points square: a dark-well outer track filled clockwise in Codex blue to the weekly share, and, only while a current five-hour reading exists, an inner track filled to the five-hour share (D35; see [DESIGN.md](../DESIGN.md)). With no current reading it is an empty outer track and a dim dash, collapsed and open. The strip's accessibility label speaks "Codex five-hour limit 40% used, Codex weekly limit 8% used", "Codex weekly limit 8% used", or "Codex weekly limit unknown" (`UsageStripReadout.spokenLabels`); it never mentions a five-hour limit that Codex has not reported, and speaks only the windows chosen under Settings › General › Usage (#488). `--reminder-rollouts <path>` points a lab run at a copy of the sessions tree, as it already does for reminders. Preview runs seed 37% weekly and 40% five-hour.

The wing left of the housing widened from 64 to 112 points so three sprites and the badge fit without clipping. The wing right of it is 60 points collapsed whatever the readings; open it is sized to the rings' numbers (`UsageStripReadouts.wingWidth(_:expanded:)`); the strip re-lays out on the next refresh when the reading appears or its window resets, and the left wing never moves for it.

## Verification

Automated: `Tests/HerdlyCoreTests/CodexUsageTests.swift` covers the current shape with the weekly window only, both windows from one event in either order, a five-hour window alone being skipped so the walk reaches the weekly line before it, another limit's event (the Spark shape) being skipped while a line with no limit id is read, last-readable-line-wins with skipped lines, currency until reset with clamped percent text, an expired five-hour window leaving the current reading while the weekly stays, and file selection: newest-modified first, fall-through past a rollout without usage (carrying both windows), tail reads of a rollout larger than 512 KB, and a refused symlink. `NotchPlacementTests` carry both trailing wing widths and the frames that follow from them.

Live: a check linked against `HerdlyCore` read `~/.codex/sessions` on the inspected machine in 13 ms and returned the weekly window only, 10% used, resetting 2026-09-19, from an event written that hour; no five-hour window, as the plan table above predicts. The `--preview-queue collapsed` render shows both readouts in the widened wing.
