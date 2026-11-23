# Rex acceptance

Run 2026-11-23 on macOS 26 against Rex 0.1.0 (2061), server `0.1.0-preview.21`, Codex CLI 0.164.0 and Claude Code 2.1.330, inside the user's own Rex with its Remote Control setting on. Scratch sessions ran in a scratch directory in their own Rex tabs, opened without focus and closed afterwards. Multiplexers inside Rex were left out at the user's request.

| Check | Result | Evidence |
| --- | --- | --- |
| Codex binding inputs | PASS | A Codex CLI in a Rex block titled it `01a20775-ad96-7473-9211-d1769...` (ADR 0005's shortened identifier) and Rex's `process` reported its foreground process as `codex`, the two facts ADR 0013 binds on. |
| Claude Open (Herdly) | PASS | Herdly at the merge of #452 (with a temporary launch hook that fired the same Open as a click) opened a Claude session in a Rex session the app was not showing: `session.focus_block`, `session.select` through Remote Control, Rex raised, verify passed ("Open: verified"). An Open clicked by the user during the run also verified. |
| Unusable Ghostty | PASS after fix | Before #452's last commit, the same Open failed "Herdly can't read Ghostty" with Ghostty switched on but not running; after it, it verified. |
| Digit proof (ADR 0017) | PASS | A Codex `request_user_input` question in Plan mode ("Pick a fruit": Apple, Banana, Cherry) appeared at 08:13:11.909Z; one block `write` of `2` alone, no CR, was sent at 08:13:12Z; the rollout recorded `{"answers":{"fruit":{"answers":["Banana"]}}}` at 08:13:12.633Z and Codex replied `• Banana`. This is the route `RexInput` uses, run from the CLI rather than a Herdly code path, as for WezTerm (#245). An earlier question ("Pick a color") was answered Red 5 s after it appeared, before any key was sent; Herdly's hook records show no answer from Herdly, and the likeliest source is the user's own click on the notch card. |
| Codex typed reply | PASS | Two block `write`s, the text and then `\r` a second later (`RexInput.payload`), started a new Codex turn with that text. |
| Claude typed reply | PASS | One block `write` of the text with `\r` (`textAndSubmit`) submitted the prompt to a Claude Code session. |
| Hook identifiers | NOTE | Codex's hook records carried `rex_block` of another block: daemon-run hooks inherit the daemon's environment (#284). `REX_BLOCK` is recorded for diagnostics only and never binds. |

## Not reached

- Herdly's own Rex digit route end to end: Codex offers `request_user_input` only through its daemon, and Herdly answers a question the daemon holds through the daemon first (ADR 0010), as in WezTerm's and tmux's runs. The digit itself is the proof above.
- Visits with more than one Rex session: Rex reports no event, method or client action naming the session its app shows (checked `rex events --all` while the app switched sessions: only `client_performed` for requested selects). With several sessions a visit is unknown and acknowledges nothing; with one session it is exact.
- tmux, Zellij and herdr inside Rex (skipped at the user's request).
