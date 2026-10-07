# herdr in Ghostty: live proof (#102)

Run on 2026-10-07 for [Prove herdr in Ghostty live](https://github.com/r-curio/steer/issues/102), under the map [herdr support: find the safe route for sessions in herdr](https://github.com/r-curio/steer/issues/100). It checks the open questions from the [herdr socket API investigation](https://github.com/r-curio/steer/blob/codex/research-herdr-socket-api/docs/herdr-socket-api-investigation.md). No Steer code drove herdr. Every step used the herdr CLI, Ghostty's scripting dictionary or the read-only probe below.

## Setup

| Component | Version |
| --- | --- |
| macOS | Darwin 25.5.0 |
| Ghostty | 1.3.1 (stable; the terminal object exposes no `tty` or `pid`) |
| herdr | 0.9.3, protocol 22, client and server matching |
| herdr integrations | codex v8, claude v10 (both reported current) |
| Codex CLI | 0.154.0, run with `-m gpt-5.5 -s read-only` because the configured default model is rejected by this CLI |
| Claude Code | 2.1.292, installed but not exercised |

The disposable session was `herdr --session steer-probe`, created in a new unsplit Ghostty tab through Ghostty's `new tab` scripting command, with its working directory in the ignored `output/herdr-lab`. The user's default herdr session and its panes were never targeted. One disposable Codex agent, named `probe`, ran in pane `w1:p1`. The only question answered was one this test asked Codex to pose, Alpha or Beta. No herdr, Codex, Claude or Ghostty configuration was changed. Steer's real hooks were installed and ran as normal. Afterwards the session was stopped (`herdr session stop`) and deleted (`herdr session delete`), and its Ghostty tab was closed.

The probe `scripts/probe_herdr.py` reads one session's `status` and `api snapshot`, counts the attached TUI clients from `lsof -U` peers on that session's `herdr-client.sock`, walks each client's process ancestry, and with `--ghostty` reads Ghostty's window, tab and terminal names. It sends no state-changing herdr request, no Ghostty command and no key. `python3 scripts/probe_herdr.py --self-test` covers the lsof peer parsing, title redaction and snapshot summary.

## Results

### 1. Codex in a herdr tab reports its full `agent_session`: yes, from the first turn

- Before the first prompt, herdr detected `agent: codex` in `w1:p1` with `agent_session: null`. Codex 0.154.0 runs SessionStart hooks only when the first turn starts, so neither herdr's integration nor Steer's hook had reported anything yet. The pane's `terminal_title` already showed Steer's session-id title (`01a1142d-7a21-7383-a6aa-40030...`).
- After the first prompt, the snapshot carried `{"source": "herdr:codex", "agent": "codex", "kind": "id", "value": "01a1142d-7a21-7383-a6aa-40030c90d7cf"}`. That value equals the session UUID in the rollout file name and the `session_id` in Steer's own hook event files for the same run.
- When Codex exited (two `ctrl+c`), the pane reported `agent: null` and `agent_session: null` within 3 s. A restarted Codex in the same pane got a new session and reported the new UUID the same way.
- Not tested: how long a restored `agent_session` persists after a herdr server restart.

### 2. API focus changes what the Ghostty-hosted client displays: yes, for tabs and workspaces

The session held workspace `w1` ("Steer") with tabs `w1:t1` (Codex) and `w1:t2` (a shell showing `TAB-B-MARKER`), and workspace `w2` ("probe-ws-b"). There was exactly one attached client. Two signals showed what that client displayed:

- the title the herdr client writes to its Ghostty terminal (default `ui.window_title`, `<host>: <workspace>`), read through Ghostty's `name` property;
- for a tab switch inside one workspace, the client's visible screen, captured with Ghostty's `write_screen_file:copy` action. This used the system clipboard briefly; its text was saved first and restored byte for byte.

| Request | Snapshot focus (ws, tab, pane) | Ghostty title | Visible screen |
| --- | --- | --- | --- |
| initial | w1, w1:t1, w1:p1 | `<host>: Steer` | Codex (`answer: Beta`) |
| `tab focus w1:t2` | w1, w1:t2, w1:p2 | `<host>: Steer` | `TAB-B-MARKER` |
| `tab focus w2:t1` | w2, w2:t1, w2:p1 | `<host>: probe-ws-b` | not captured |
| `agent focus probe` | w1, w1:t1, w1:p1 | `<host>: Steer` | Codex (`answer: Beta`) |
| `agent focus w1:p1` (pane ID target) | w1, w1:t1, w1:p1 | `<host>: Steer` | not captured |

- `agent focus` also changed the agent's `agent_status` from `done` to `idle`. The focus marks the agent seen, as the source says.
- `herdr pane focus` takes only a direction in 0.9.3 (`--direction left|right|up|down`), not a pane ID. Steer would focus by agent name, agent pane ID or tab ID.
- Ghostty had no window on screen during these steps. herdr changed what the client draws, but it did not raise Ghostty or select the Ghostty tab. Steer still has to bring the hosting Ghostty tab forward itself.
- Not tested: focus with two attached clients. While three clients were attached (below), no focus request was sent.

### 3. Steer can find the one client but cannot name its Ghostty tab on Ghostty 1.3.1

- **Client count:** lsof peers on the session's `herdr-client.sock` matched the attached clients exactly. Two failed scripting attempts had each opened a Ghostty tab before reporting an error, so for a while three Ghostty tabs ran clients of the session. The probe reported three client PIDs on `ttys012`, `ttys014` and `ttys015`, each with the ancestry `herdr → login → ghostty`. As each extra tab was closed, its client disappeared from the count, leaving one.
- **Outer terminal:** the remaining client was PID 93954 on `ttys015`, whose ancestry ends at the Ghostty app process. The herdr API reports nothing about clients.
- **Ghostty tab:** Ghostty 1.3.1's terminal object has no `tty` or `pid`, so `ttys015` cannot be joined to a Ghostty terminal ID. Titles do not separate clients. All three clients of the test session showed the identical title `<host>: Steer`, and the user's default session also has a workspace labelled "Steer", so its client would show the same title while that workspace is displayed. The terminal's working directory (the directory in which herdr was launched) is not unique either.
- **Answer:** Steer can tell that exactly one herdr client is attached, and that it runs inside Ghostty. On Ghostty 1.3.1 it cannot identify which Ghostty tab hosts that client without a heuristic, and ADR 0005 rules heuristics out. A Ghostty build exposing `tty` would make the lsof TTY an exact join. That build is on Ghostty's tip channel, which was not installed or run (see the [Ghostty investigation](../ghostty-investigation.md)). Writing a unique title beacon through `client.window_title.set` or a custom `ui.window_title` would change herdr state and was not attempted.

### 4. A single digit selects and submits a Codex question option: yes, without Enter

- In Plan mode (`request_user_input` is refused in Default mode on this CLI), Codex asked one question with options `1. Alpha`, `2. Beta` and Codex's own `3. None of the above`. herdr reported the agent `blocked`. The pane footer read `tab to add notes | enter to submit answer | esc to interrupt`.
- `herdr --session steer-probe agent send-keys probe 2` returned `ok`. Within 3 s the pane showed `Questions 1/1 answered … answer: Beta`, and the rollout recorded `function_call_output` `{"answers":{"choice":{"answers":["Beta"]}}}` for that call ID. Enter was not needed, despite the footer text. This is the behavior ADR 0006 expects from the source.
- The same single key, `2`, also committed Codex's startup "Update available" list (Skip) without Enter.
- Not tested: multi-question calls, the race against a manual answer, and a key sent while the agent was not blocked.

## Not covered

- A Claude Code session in herdr.
- Whether Steer's own hook sees `HERDR_PANE_ID` and `HERDR_SOCKET_PATH`. herdr's Codex hook, which reads those variables, reported successfully from the same Codex process, so Steer's sibling hook very likely inherits them. That is an inference: Steer's hook does not record its environment.
- Restore after a herdr server restart, `herdr agent attach` and remote clients, and how quickly events arrive.
- Steer itself driving herdr. The decisions in #103 to #106 are still open.
