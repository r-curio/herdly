# Rex CLI investigation

Probed on 2026-11-23 against Rex 0.1.0 (2061), server `0.1.0-preview.21` (API revision 18), on macOS 26, from inside a Rex terminal. This records what the CLI established; it is not an acceptance run.

## Shape

- Rex.app (`com.superlogical.rex`) is a client. The server (`com.superlogical.rex.server`, executable `rex`) owns every terminal: a shell in a Rex pane descends from the server through `/usr/bin/login`, not from Rex.app. The server keeps running when the app quits.
- The local socket is `~/Library/Application Support/rex/server.sock`, mode `srw-------`, owned by the user. `REX_SERVER=unix://<percent-encoded path>` selects it; `--autostart=false` stops the CLI starting a server.
- The CLI ships twice: in the installed server (`~/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex`) and inside `Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex`.
- Terminology: a Rex *session* holds *windows* (the app's tabs); a window holds *blocks* (panes) in a tiled layer and optional floating layers. IDs are `session:<uuid>`, `window:<uuid>`, `block:<uuid>`. Each pane sets `REX_SESSION` and `REX_BLOCK` in its environment.

## Reads

- `session.view` needs the connection attached to the session first (`session.attach`); otherwise it fails with `409 conflict`.
- `session.view` gives `active_window_id` and, per window, `focused_block_id` and each block's `creator_name` (`com.superlogical.terminal` for terminals) and `host_id` (equal to `server.status`'s `host_id` for local blocks).
- Block method `process` gives `foreground.pid` (Claude Code showed its own pid, named by its version binary, `2.1.330`), `child` and `ancestors`. Block method `title` gives the OSC title (Herdly's `Herdly Claude <id>` showed there).
- A `rex do -` Lua script can make all these calls in one process: about 0.06 s for 3 sessions and 4 blocks. `rex.call` returns `nil, err` on failure; an empty Lua table serializes as `{}`.
- Rex does not report which session the app is showing: `client.inspect` lists every attached session without marking one.

## Actions

- `session.focus_block {session_id, block_id}` focuses that block and makes its window the session's active window. A closed block fails with exit 3 and `code=not_found`.
- `client.perform {client_id, action: "session.select", args: {session_id, window_id}}` asks the app to show a session. With Remote Control off (the default) it fails with `code=refused`: "Rex.app is not accepting actions. Turn on Remote Control in its Settings under Rex Server."
- Block method `write {data}` and `rex send` both delivered `ab-cXY\r` byte for byte into a raw-mode `dd | od -c` pane: no bracketed paste, nothing appended. A closed block fails with `code=not_found`.

## Not established

- Whether the app follows `session.focus_block` on a session it isn't showing (expected: not, hence the select).
- That a Codex CLI in Rex titles its block with its shortened session ID and that a lone digit `write` commits a Codex question answer; Rex's question digits stay off until a live run shows it.
- Open, visits and typed replies in the running app: unit-tested, not yet run live.
