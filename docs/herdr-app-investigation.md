# Herdr app investigation

Probed on 2026-11-23 against Herdr.app 0.1.16 (`dev.herdr.app`) and herdr-core 0.1.22 (`dev.herdr.core`), protocol generation 1, on macOS 26, from inside a Herdr terminal. This records what the probe established; it is not an acceptance run. The Herdr app is a different product from `herdr`, the terminal multiplexer Herdly already reads (ADR 0009); its `herdr server` socket does not list Herdr app terminals.

## Shape

- Herdr.app shows terminals arranged in *spaces*, *tabs* and split *panes*. The terminals run in herdr-core (`hc`), a per-user core that keeps them alive when the window closes. A shell in a Herdr pane descends from herdr-core's holder process, `~/.local/share/herdr-core/active/Herdr Core.app/Contents/MacOS/herdr-core hold`, not from Herdr.app.
- Each core terminal has an address (`t1`, `t2`…), its own pty and, while the window shows it, the labels `herdr.space` and `herdr.tab`. Its environment carries `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET` and `TERM_PROGRAM=ghostty` (herdr-core's emulation identity, not Ghostty).
- The core socket is `~/.local/state/herdr-core/default/default.sock`, mode `srwxr-xr-x`, in a `0700` folder owned by the user. The window's socket is `~/.config/herdr-app/herdr-app.sock`, also `srwxr-xr-x`, in a `0755` folder. Connecting to either needs write permission, which only the owner has.
- `hc connect` and the other `hc` commands start a core when none is running (seen with a missing core: "cannot start core"), so Herdly never runs `hc`.

## Reads

- The core speaks JSON-RPC 2.0, one message per line, directly on its socket. `terminal.list` returns every live terminal with `address`, `pid` (the terminal's own process, whose tty is the pane's pty), `foreground {pid, argv, name}`, `title` (Codex's OSC title; empty for Claude Code) and `labels`. Another machine's terminals show as `machine/t7`. Errors are `{error: {code, message, data: {kind}}}` with stable kinds such as `not_found`.
- `Herdr ls` (Herdr.app's own executable with arguments) lists spaces > tabs > terminals with each terminal's pane id; `Herdr status` gives the shown `space`, `tab` and `focused_pane`. Both talk to the running window and exit 2 with "no Herdr window at …" when it is not open. Run with no arguments, the executable opens the window, so Herdly always passes arguments and checks the window's socket first.

## Actions

- `Herdr do agent.focus '{"terminal":"t1"}'` and `pane.focus` print `{"ok": true}` and exit 0; an unknown terminal prints `{"error": "no running terminal \"t9\""}` and exits 1. Only a focus on the already shown terminal was run, to avoid moving the user's view.
- `terminal.send {terminal, text}` pasted the text and pressed Enter into a disposable, unlabeled `cat` terminal (not shown in the window): `cat` echoed the line once. The reply came back in 0.3 s. The core documents that it waits for about three seconds of quiet, and for a person's unsent draft in that terminal up to 60 s, and refuses a program reporting `blocked`. `terminal.keys {terminal, keys: ["1"]}` returned a result too. The probe terminal was killed and removed.

## Not established

- Open live: `agent.focus` switching space and tab for a terminal the window isn't showing, and the verify that follows.
- Typed replies into a live Claude Code or Codex session (whether Codex submits from `terminal.send`'s own Enter), and a lone digit committing a Codex question answer, so question digits stay off (`HerdrAppInput.questionDigitsProvenLive`).
- Whether a peek overlay or `terminal.show` changes what `Herdr ls` reports for a pane.
