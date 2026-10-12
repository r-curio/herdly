import Darwin
import Foundation
import SteerCore

/// iTerm2's AppleScript reads and the one selection an Open sends, through the bundled `ITerm2.js`
/// (#238). Called only while iTerm2's switch is on. Nothing here writes text to a session (ADR 0017),
/// reads `jobName`, or launches iTerm2. Blocking: call off the main actor.
enum ITerm2Navigation {
    static let bundleIdentifier = "com.googlecode.iterm2"

    /// A fresh inventory; nil when the script failed, timed out, was denied or replied malformed.
    static func snapshot() -> ITerm2Reading? {
        GhosttyNavigation.request(["action": "snapshot"], resource: "ITerm2").flatMap(ITerm2Reading.parse)
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
    /// its tab, then selects the window, tab and session and activates iTerm2. Nil when iTerm2 did not
    /// reply. Sends no input.
    static func select(_ plan: ITerm2OpenPlan) -> ITerm2SelectReply? {
        guard let data = GhosttyNavigation.request(["action": "select", "session": plan.target.tabID,
                                                     "tty": plan.target.tty], resource: "ITerm2"),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = value["status"] as? String else { return nil }
        return ITerm2SelectReply(rawValue: status) ?? .changed
    }
}

/// Kernel and `ps` reads behind ADR 0013's tty rules for any tty-bound host. Read-only.
enum TerminalTTYReads {
    /// `ps -o pid=,stat=,comm= -t <tty>` for each tty, parsed; a failed or malformed read is absent,
    /// which the rules treat as unreadable. Bounded: two seconds and 64 KiB per read.
    static func processes(on ttys: Set<String>) -> [String: [TerminalProcess]] {
        var result: [String: [TerminalProcess]] = [:]
        for tty in ttys {
            guard let normalized = GhosttyTTYMatch.normalizedTTY(tty),
                  case .success(let output) = HerdrSubprocess.run(executable: "/bin/ps",
                                                                  arguments: ["-o", "pid=,stat=,comm=", "-t",
                                                                              String(normalized.dropFirst(5))],
                                                                  timeout: 2, limit: 64 * 1024),
                  let parsed = TerminalForegroundProcesses.parse(output) else { continue }
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

    /// A fresh read of `pid`'s controlling tty. The start time is not re-read: Claude's inventory
    /// already verified `procStart` when it named the process (`ClaudeInventorySession.pid`).
    static func observation(of pid: Int32) -> TerminalProcessObservation? {
        guard let process = HerdrProcessTree.ancestry(of: pid).first, process.pid == pid else { return nil }
        return TerminalProcessObservation(pid: pid, procStart: nil, tty: process.tty)
    }
}
