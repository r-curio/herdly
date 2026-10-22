import Darwin
import Foundation
import HerdlyCore

/// iTerm2's AppleScript reads and the one selection an Open sends, through the bundled `ITerm2.js`
/// (#238). Called only while iTerm2's switch is on. Nothing here writes text to a session (ADR 0017),
/// reads `jobName`, or launches iTerm2. Blocking: call off the main actor.
enum ITerm2Navigation {
    static let bundleIdentifier = "com.googlecode.iterm2"

    /// A fresh inventory; nil when the script failed, timed out, was denied or replied malformed.
    static func snapshot() -> ITerm2Reading? {
        GhosttyNavigation.request(["action": "snapshot"], script: .iTerm2).flatMap(ITerm2Reading.parse)
    }

    /// The inventory as ADR 0013 reads it: a failed read of a running iTerm2 is unreadable.
    static func inventory(_ reading: ITerm2Reading?) -> TerminalHostInventory {
        switch reading {
        case nil: .unreadable
        case .notRunning?: .notRunning
        case .snapshot(let value)?: value.inventory
        }
    }

    /// ADR 0016's select step for `plan`: ITerm2.js rechecks the session's tty and that it is alone in
    /// its tab, then selects the window, tab and session and activates iTerm2. Sends no input. Without a
    /// reply, a fresh consent check tells an Automation denial (unavailable) from any other error or
    /// timeout (a fallback, ADR 0016).
    static func select(_ plan: ITerm2OpenPlan) -> ITerm2SelectReply {
        guard let data = GhosttyNavigation.request(["action": "select", "session": plan.target.tabID,
                                                     "tty": plan.target.tty], script: .iTerm2),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = value["status"] as? String else {
            let access = GhosttyAutomationPermission.check(askIfNeeded: false, target: bundleIdentifier)
            return access == .denied ? .denied : .noReply
        }
        return ITerm2SelectReply(status: status)
    }
}

/// Kernel reads behind ADR 0013's tty rules for any tty-bound host. Read-only.
enum TerminalTTYReads {
    /// Each tty's processes from the kernel (#303), in `ps -o pid=,stat=,comm= -t <tty>` form and parsed;
    /// a failed, malformed or over-64 KiB read is absent, which the rules treat as unreadable.
    static func processes(on ttys: Set<String>) -> [String: [TerminalProcess]] {
        var result: [String: [TerminalProcess]] = [:]
        for tty in ttys {
            guard let normalized = GhosttyTTYMatch.normalizedTTY(tty) else { continue }
            let name = String(normalized.dropFirst(5))
            guard let records = KernelProcessTable.records(onTTY: name) else { continue }
            let output = ProcessListing.pidStatComm(records, tty: name)
            guard output.utf8.count <= 64 * 1024, let parsed = TerminalForegroundProcesses.parse(output) else { continue }
            result[normalized] = parsed
        }
        return result
    }

    /// When the tty device was last written (its modification time, Unix seconds); nil when unreadable.
    static func writtenAt(_ tty: String) -> Double? {
        guard let normalized = GhosttyTTYMatch.normalizedTTY(tty) else { return nil }
        var info = stat()
        guard stat(normalized, &info) == 0 else { return nil }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    /// A fresh kernel read of `pid`: its start time in Claude's `procStart` layout and its controlling
    /// tty, so ADR 0013's rule can compare the start time Claude registered (a reused PID never binds).
    static func observation(of pid: Int32) -> TerminalProcessObservation? {
        guard let process = HerdrProcessTree.ancestry(of: pid).first, process.pid == pid else { return nil }
        return TerminalProcessObservation(pid: pid, procStart: ClaudeSessionRegistry.procStart(of: pid), tty: process.tty)
    }
}
