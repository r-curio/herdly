# Thread names

Herdly labels a notch item with the name Codex desktop shows for that thread in its sidebar, such as "Sync main and resolve conflicts", instead of the shortened session identifier. The identifier remains the fallback whenever no name is known. Like the [desktop read state](desktop-read-state.md), this rides on a private Codex format and fails soft.

## What Codex records

Codex desktop names a thread about fifteen seconds after its first prompt and appends one JSON line to `~/.codex/session_index.jsonl`:

```
{"id":"0199a000-0000-7000-8000-0000000000d5","thread_name":"Sync main and resolve conflicts","updated_at":"2026-09-14T02:30:15.871051Z"}
```

A rename appends another line for the same id, so the last line for an id is the current name. Thread ids equal Codex session ids. The same name is also stored in the `name` column of the `threads` table in `~/.codex/state_5.sqlite` (the `title` column there is the first user message, not the sidebar name); on the inspected machine the two agreed on every shared id, and the index was chosen because it is a small append-only text file that needs no SQLite access. Rollout files and hook events never carry the name.

Only desktop threads are named. CLI sessions have no entry, so they keep the `session xxxxxxxx` label. Observed with CLI 0.153.4 and desktop 26.901.51231.

## Herdly's rule

`ThreadNameReader` reads the index with the same bounds as other Codex files (regular file, no symlink, at most 20 MB) and returns a map from session id to the latest non-empty name. A line that is not a JSON object with a UUID `id` and a string `thread_name`, including a partial last line while Codex is appending, is skipped without affecting other lines. A missing or unreadable file yields no names.

`StripSummary.sessionLabel` returns the thread name when known, otherwise the shortened identifier. The strip subject prefers the thread name, then a request's task name from Codex, then the identifier. Herdly never invents a name.

## App integration

Each two-second scan reads the index off the main actor alongside the hook events, rollouts, and read state, and publishes the map on the companion model. A running item may show the identifier for its first scans and switch to the name once Codex writes it. Rows show the name in the header (one line, tail-truncated) and, when a request has details, the full name as a selectable "thread" line. `--thread-names <path>` points a lab run at a copy of the file.

## Verification

Automated: `Tests/HerdlyCoreTests/ThreadNamesTests.swift` covers the real shape, last-line-wins on rename, skipped unreadable lines, file bounds, and label preference.

Live walkthrough after each desktop update:

1. Start a desktop thread and switch away. Expect: the item shows `session xxxxxxxx`, then the sidebar name within about twenty seconds.
2. Rename the thread in Codex desktop. Expect: the label follows on the next scan.
3. Start a CLI session. Expect: the identifier label, unchanged.
4. Run with `--thread-names /nonexistent`. Expect: identifiers everywhere, no error.
