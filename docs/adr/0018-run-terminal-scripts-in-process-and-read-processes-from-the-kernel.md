# Run terminal scripts in process and read processes from the kernel

Accepted on 2026-10-22 ([issue #303](https://github.com/r-curio/herdly/issues/303)). Scheduled scans used to start a subprocess for most reads: `/usr/bin/osascript` for each Ghostty, iTerm2 and Terminal.app request, and `/bin/ps` for the Codex process listing, the Zellij process table and the per-tty foreground read. `ClaudeStatusLineCompatibility`'s descendant walk, which runs only around a status-line probe, used `/bin/ps` too. Herdly now does all of these in its own process. Multiplexer CLIs (`tmux`, `zellij`, `wezterm`, herdr) stay subprocesses, because a CLI is their only interface.

## Terminal scripts

- **API and thread:** OSAKit. Each adapter (`AppleEvents.js` plus `Ghostty.js`, `ITerm2.js` or `TerminalApp.js`) is compiled once with the JavaScript `OSALanguage`, and its existing `run(argv)` handler is called once per request. `AppleEventScripts` runs every compile and every request on one dedicated thread, one at a time, because OSA is not safe to run from several threads at once. A slow app can therefore make another app's read in the same scan time out. That read reports unreadable, never a partial result.
- **Deadline:** a subprocess could be killed at its five-second deadline; an in-process script cannot. The deadline now travels with the request, on the system uptime clock, and `AppleEvents.js` enforces it on every event:
  - each Apple Event waits at most the time left;
  - no event is sent once the deadline has passed;
  - a request that ran out of time fails, and is never reported as not running;
  - a request without a deadline fails before sending anything.
  The caller waits for the deadline plus half a second, then returns nil. A request still queued at its deadline never starts. A late script keeps running until its current event returns, which is the same side-effect window `osascript` had: killing it never recalled an event already sent.
- **Unchanged:** the kernel pid lookup before each request (see [Never launching the app](../cli-notch-integration.md#never-launching-the-app-270)), the not-running reply without running a script, events addressed only to that pid, the 2 MiB reply cap, nil on any script error, and the Automation permission check. Events now come from Herdly's own process instead of its `osascript` child.

## Process listings

`KernelProcessTable` (HerdlyApp) reads `sysctl` `KERN_PROC_ALL` or `KERN_PROC_TTY` for pid, ppid, uid, tty, process group and short name, and `KERN_PROCARGS2` for argument vectors. `ProcessListing` (HerdlyCore) renders those records as the exact text shapes `ps` printed (`pid=,args=`, `pid=,ppid=`, `pid=,ppid=,uid=,tty=,comm=` and `pid=,stat=,comm=` for one tty). The existing parsers, and the identity rules built on them, are unchanged. Every shape takes a byte limit and stops as soon as it passes it.

Known differences from `ps`, all on purpose:

- **Unreadable argument vectors:** `ps` is setuid root and reads every user's arguments; Herdly reads only its own user's. Any process whose vector cannot be read is left out of the `pid=,args=` listing, so another user's `codex app-server` can never count as a Codex CLI. Herdly can never target another user's processes anyway.
- **`comm`:** argv[0] for the user's own processes, as `ps` printed it, because Zellij targeting matches `codex` by it. For everyone else it is the kernel's short name, which stops at 16 bytes.
- **`stat`:** only the `+` foreground flag (`P_CONTROLT` and process group equal to the terminal's) is guaranteed to match. The state letter can differ, and no parser reads it.

## Considered options

- **Keep `osascript` and `ps`.** Simplest, but each scan paid a `posix_spawn` per read, which showed in every profile cycle.
- **`NSAppleScript` or a fresh `OSAScript` per request.** Recompiling every request throws away most of the saving, and `NSAppleScript` has no way to choose the JavaScript language the adapters are written in.
- **Feed kernel records to the parsers directly.** Cleaner long-term, but it would mean rewriting four parsers and their tests, which risks drifting from the identity rules. Rendering `ps` text keeps those rules byte-for-byte and testable against captured `ps` output. A later change can make the move.
- **Run scripts on several threads.** Rejected: OSA is not thread-safe.

## Not yet shown live

- **Automation grant:** macOS already attributed the `osascript` child's events to Herdly, so the grant and its prompt should be unchanged. No live run has confirmed it.
- **Terminal reads, Open and question relay** on Ghostty, iTerm2 and Terminal.app through the in-process runner. The deadline and not-running behaviour are so far shown only by unit tests and a lab against a throwaway app.
