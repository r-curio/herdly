import AppKit
import CoreGraphics
import Foundation
import SteerCore

/// Terminal.app's Apple Events and the window server's on-screen list (#239), through the bundled
/// `TerminalApp.js` and the shared JXA runner (`TerminalScript`, by process id). Only called while
/// Terminal.app's switch is on. Blocking: call off the main actor except where noted. Nothing here
/// launches Terminal, creates a tab, or types anywhere but the one tab-window and tty passed in. `ps`
/// and kernel reads are the shared `TerminalTTYReads`.
enum TerminalAppNavigation {
    static let bundleIdentifier = "com.apple.Terminal"

    /// One inventory read.
    enum Read: Equatable, Sendable {
        case notRunning
        case snapshot(TerminalAppSnapshot)
        /// Running, but the read failed or was refused.
        case unreadable

        var inventory: TerminalHostInventory {
            switch self {
            case .notRunning: .notRunning
            case .snapshot(let snapshot): snapshot.inventory
            case .unreadable: .unreadable
            }
        }

        var snapshot: TerminalAppSnapshot? {
            if case .snapshot(let value) = self { return value }
            return nil
        }
    }

    static func snapshot() -> Read {
        read(request(["action": "snapshot"]))
    }

    /// A snapshot request's result as a read: Terminal not running, or quit during the read (#270), is
    /// `notRunning`; any other failure of a running Terminal is unreadable.
    static func read(_ result: TerminalAppScriptResult) -> Read {
        guard case .reply(let data) = result else { return .unreadable }
        if result.status == "not_running" { return .notRunning }
        return TerminalAppSnapshot.parse(data).map(Read.snapshot) ?? .unreadable
    }

    /// ADR 0016 step 3, sent once: set the tab-window's `frontmost`, then activate Terminal.
    static func raise(_ target: TerminalTabTarget) -> TerminalAppScriptResult {
        guard let window = Int(target.tabID) else { return .reply(Data(#"{"status":"gone"}"#.utf8)) }
        return request(["action": "raise", "window": window, "tty": target.tty])
    }

    /// ADR 0017: one `do script` into the bound tab. Terminal appends the newline.
    static func type(_ text: String, into pane: TypedInputPane) -> TerminalAppScriptResult {
        guard pane.host == .terminalApp, let window = Int(pane.paneID), let tty = pane.tty else {
            return .reply(Data(#"{"status":"gone"}"#.utf8))
        }
        return request(["action": "type", "window": window, "tty": tty, "text": text])
    }

    /// The window server's on-screen windows of the Terminal process `pid` (CGWindowIDs, which equal
    /// Terminal's window ids); nil when the list could not be read.
    static func onScreenWindowIDs(pid: pid_t?) -> Set<Int>? {
        guard let pid,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return Set(info.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? Int32 == pid else { return nil }
            return window[kCGWindowNumber as String] as? Int
        })
    }

    /// Terminal's process id. Main actor, as `TerminalApps.isRunning`.
    @MainActor
    static func pid() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier
    }

    /// Without a reply, a fresh consent check tells an Automation denial from any other failure, as
    /// iTerm2's select does (#238).
    private static func request(_ value: [String: Any]) -> TerminalAppScriptResult {
        if let data = GhosttyNavigation.request(value, script: .terminalApp) { return .reply(data) }
        let access = GhosttyAutomationPermission.check(askIfNeeded: false, target: bundleIdentifier)
        return access == .denied ? .denied : .failed
    }
}
