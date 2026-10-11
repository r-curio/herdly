# Raise the terminal app when Open cannot reach the exact target

Accepted with the user on 2026-10-11 (issue #203, map #197). Open in Codex or Open in Claude for a CLI session no longer returns unavailable when the session's terminal app is known and running but Steer cannot reach the exact tab or pane. It performs an **Open fallback** instead: it raises that terminal app and nothing more. This replaces product principle 4's "exact or unavailable" for every terminal host, including Ghostty and herdr, and follows Open Island's behavior (`TerminalJumpService.swift`, commit b50f87a) without its first-match or launch shortcuts. Binding rules are unchanged: [ADR 0013](0013-bind-cli-sessions-to-terminal-tabs-by-tty.md) (terminal tabs) and [ADR 0014](0014-bind-multiplexer-panes-and-join-their-client-to-a-host-tab.md) (multiplexer panes) still decide what counts as the exact target.

Amended 2026-10-11 ([issue #214](https://github.com/r-curio/steer/issues/214)): a Codex CLI session has no process of its own to walk from until a tab binds, because its hooks run in the shared daemon (ADR 0012). Two cases follow, each a deliberate choice:

- **Several tabs carry the session's title:** Steer walks from each candidate tab's single foreground `codex` process. If every walk reaches the same running app, that app is raised. If they reach different apps, Steer raises the app of the candidate whose tty was written most recently, read from the tty device's modification time; if two candidates' times fall within one second of each other, or any time cannot be read, Open is unavailable ("can't be identified"). This is a guess the user accepted for a rare case (the same session open twice, or a tab copying its title); it never selects a tab, acknowledges nothing and is never an input target.
- **The session's app is switched off:** Steer never scans that app, so it never sees the Codex tab and cannot identify the app. Open is unavailable ("can't be identified"). Claude sessions in a switched-off app still fall back, because their registry PID walks to the app.

## When Open falls back

Open falls back only after revalidation finds the session live and its terminal app identified and running, and only for these failures:

- **No unique target:** zero or several tabs or panes match, including colliding titles and a Ghostty without `tty` outside ADR 0011's sole-terminal rule.
- **Unsupported layout:** a split tab, a multiplexer window with several panes or clients, or an exact tab in another window that the host's Open does not yet cross to.
- **Partial reach:** an exact step succeeded and verified, but a later one cannot. Examples: herdr, tmux or Zellij focused the bound pane, but the host tab hosting its client cannot be found; or WezTerm activated the exact pane but cannot raise its window. Steer keeps the verified steps, never rolls them back, and raises the app.

Open stays unavailable, with its typed reason, when:

- **The host cannot be read:** a scripting error, macOS Automation permission denied, a multiplexer socket that is missing or fails its trust check, or a missing or outdated Claude integration that a binding depends on. Raising the app would hide a problem the user must fix.
- **The session has ended:** its process is gone or its tab is closed. There is nothing to return to.
- **The terminal app is not running.** Steer never launches it.
- **The terminal app cannot be identified,** as below.

## Which app and window

The app raised is the one the session's live process runs under: Steer walks from the bound process (ADR 0013's foreground Codex process on the tab's tty, or Claude's registry PID) up its parent processes to a supported terminal app. For a multiplexer, the walk reaches the multiplexer server, so Steer continues from the client found by ADR 0014's host join (the client's tty) to the app hosting that client. A walk that fails, ends at an unsupported app, or finds no attached client leaves Open unavailable. `TERM_PROGRAM`, hook-recorded hosts, and "the first running terminal" are never used.

Steer then activates the app as a whole. macOS brings forward whichever of its windows was last in front. Steer never picks a window or tab, not even when every candidate shares one window.

## What a fallback is not

An Open fallback is navigation only:

- It never acknowledges a completion, starts or counts toward a dwell run, or clears a reminder, approval request, or question request.
- It never makes a tab, pane, or app an input target. Typed question options and session replies still need the exact binding.
- An Open on an actionable CLI approval request still hands it back first, with no decision.
- A later manual visit acknowledges under the usual visit rules only when the exact binding can verify that tab.

## Presentation

The fallback is silent. Open looks the same whether it will reach the exact target or fall back, the card shows no reason line for a fallback case, and the click reports no message. Reason lines remain only for the unavailable cases above. Setup guidance that a fallback case used to show on the card, such as "Update Ghostty to return to herdr panes", stays only in the Terminals settings rows. The user accepted that a fallback which lands on the wrong tab is noticed only by looking. This amends product principle 3 for Open.

## Considered options

- **Exact or unavailable (status quo):** safe, but leaves the user with nothing when the app itself is plainly known.
- **Open Island's first match among several candidates:** sends the user to an arbitrary tab, which the targeting rule forbids.
- **Launch the app when it is not running:** changes the user's environment and cannot bring back the session.
- **Fall back on scripting errors and denied permission:** hides a fix the user must make.
- **Find the app from `TERM_PROGRAM` or "the first running terminal":** Codex's shared daemon cannot supply the former, and the latter can raise an app the session is not in.
- **Raise the one window that holds every candidate:** a guess presented as knowledge, with a code path for every host.
- **Report the fallback after the click or keep a reason line on the card:** both were offered; the user chose a silent fallback.
