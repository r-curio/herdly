# Open and acknowledge visits the same way on every terminal host

Accepted with the user on 2026-10-11 ([issue #210](https://github.com/r-curio/herdly/issues/210), map [#197](https://github.com/r-curio/herdly/issues/197)). This generalizes [ADR 0011](0011-open-herdr-panes-only-through-an-exact-ghostty-tty-join.md)'s Open sequence, visit rule and dwell rule to iTerm2, Terminal.app and WezTerm tabs, and to tmux, Zellij and herdr panes hosted in any enabled terminal. Binding is unchanged: [ADR 0013](0013-bind-cli-sessions-to-terminal-tabs-by-tty.md) (terminal tabs) and [ADR 0014](0014-bind-multiplexer-panes-and-join-their-client-to-a-host-tab.md) (multiplexer panes and their host-tab join) decide what the exact target is. [ADR 0015](0015-raise-the-terminal-app-when-open-cannot-reach-the-exact-target.md) decides what an Open falls back to.

Before this decision Ghostty had three visit rules. A Codex tab acknowledged its completions at any scan that showed it selected with Ghostty frontmost. A Claude tab acknowledged only on a switch to it after the completion arrived, and never acknowledged a completion that arrived while the tab was already in front. herdr used that interval rule plus a five-second dwell. The live proofs ([iTerm2](../evidence/iterm2-live.md), [Terminal.app](../evidence/terminal-app-live.md), [WezTerm](../evidence/wezterm-live.md), [tmux](../evidence/tmux-live.md), [Zellij](../evidence/zellij-live.md)) showed that each new host can say what is in front, and that WezTerm cannot raise a window that is not already focused.

## Visible

A bound tab or pane is **visible** when a fresh read shows it in front, its binding still holds on fresh inventories, and its tty is unchanged:

- **iTerm2:** iTerm2 is frontmost, and the current session of its current window's current tab is the bound session (by GUID).
- **Terminal.app:** Terminal is frontmost, its front window is the bound tab-window, and the window server lists that window on screen.
- **WezTerm:** WezTerm is frontmost, and `list-clients` `focused_pane_id` is the bound pane.
- **Ghostty:** ADR 0011's test: the bound tab selected with Ghostty frontmost, in the current window. Without `tty`, ADR 0011's interim rules apply unchanged.
- **Multiplexer pane:** the single client's current pane is the bound pane (`list-clients` for tmux and Zellij, the snapshot for herdr), and the client's joined host tab is visible by its host's test.

Frontmost is read from macOS's frontmost application, not from the host. iTerm2 and Terminal.app keep a current window and session while another app is in front, and WezTerm's `focused_pane_id` keeps its last value, so the host's answer alone is never enough.

## Open sequence

1. **Revalidate** the binding, layout and (for a pane) the host-tab join on fresh reads (ADRs 0013 and 0014).
2. **Focus the pane**, for a multiplexer only, and **verify the multiplexer** (ADR 0014 steps 2–3).
3. **Select and raise the host tab:**
   - **iTerm2:** `select` the window, tab and session, then `activate`.
   - **Terminal.app:** set the tab-window's `frontmost`, then `activate`. This may switch macOS Spaces, which follows from the user's explicit Open.
   - **WezTerm:** only when the target's window is the window of `focused_pane_id`: `activate-pane --pane-id`, then activate WezTerm. A target in another window skips `activate-pane`, because nothing can raise that window or read back which tab it shows, and falls back.
   - **Ghostty:** ADR 0011.
4. **Verify** that the target is visible.

Every command is sent once and never retried. Open reports Opened, and acknowledges, only when every verification passes. An Open on an actionable CLI approval request hands it back first, with no decision.

## Failures

- **Revalidate:** ADR 0015's categories. An unreadable host, an ended session or closed tab, or an app that is not running or cannot be identified is unavailable. No unique target or an unsupported layout falls back.
- **Select or raise:** a command error is unavailable when it is an Automation denial or shows the target is gone (such as Terminal.app's stale tab reference). Any other error falls back.
- **Verify:** a successful command whose target is not visible afterwards falls back. The app is already activated, so the fallback adds nothing.
- **Multiplexer:** a failed pane focus or pane verification falls back without touching the host tab. A verified pane whose host tab cannot be raised or verified is a partial reach and falls back, keeping the pane focus.

Only a verified Open acknowledges. A fallback acknowledges nothing (ADR 0015).

## Acknowledgment

One rule for every terminal host, Ghostty included, and for Codex and Claude alike. Only completions are acknowledged by a visit; approval requests, question requests and reminders clear only on resolution evidence.

- **Open:** a verified Open acknowledges the session's completions that arrived before the pre-Open read.
- **Manual visit:** the target was not visible in one scan and is visible in the next, and the completion arrived before the earlier scan (ADR 0009's interval rule).
- **Dwell:** a completion that arrives while its target is visible is acknowledged once the target has stayed visible for five seconds after it arrived. ADR 0011's dwell rules apply with "visible" as defined here: a run can begin before the completion, and a gap of more than five seconds between visible scans, a hidden or different target, a failed scan, or a scan taken while a check or Open is in flight restarts the run. A pane left in front while the user is away acknowledges; the user accepted that in ADR 0011.

A visit or dwell acknowledges every queued completion of that session that qualifies; later arrivals stay independent.

## Windows

iTerm2 and Terminal.app Open and visits reach a tab in any window: both crossed windows in every live attempt. WezTerm's Open reaches only the focused window; its visits count in any window that becomes focused, because `focused_pane_id` follows the focused window. Ghostty stays limited to its current window until a Ghostty with `tty` is proven ([#155](https://github.com/r-curio/herdly/issues/155)).

## Presentation and scanning

- A completion whose target is visible when it arrives gets no spotlight and no sound. It stays queued until dwell, a visit or dismissal clears it. This extends the product rule that Ghostty presents completions only while outside the originating pane.
- Herdly checks visibility every two seconds, off the main actor, with at most one check in flight per host, only while that host holds a target bound to a live session and macOS reports that host as the frontmost app. A host that is not frontmost has nothing visible, so it is not asked. Multiplexer reads follow ADR 0014's gates.

## Considered options

- **Keep Ghostty's three rules and give only new hosts the herdr rule:** two behaviors for the same act, and a Claude completion that arrived in a watched tab would still never clear on its own.
- **Ghostty's Codex rule everywhere (visible at any scan acknowledges):** a completion would clear within two seconds of a glance, with no switch or dwell to show it was seen.
- **Send WezTerm's `activate-pane` to a window that is not focused:** it changes that window's tab where Herdly cannot verify it.
- **Scan every two seconds whenever a bound session is live:** the same answers with Apple Events sent to apps that are not in front.
- **Trust the host's own focus report:** iTerm2, Terminal.app and WezTerm keep reporting a current target while another app is in front.

## Not yet shown live

- The visible tests and the dwell run on iTerm2, Terminal.app and WezTerm in any Herdly code path.
- Visibility through a multiplexer hosted in iTerm2, Terminal.app or Ghostty.
- WezTerm's `focused_pane_id` following a window switch made by the user rather than the CLI.
