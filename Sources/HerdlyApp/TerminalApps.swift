import AppKit
import Darwin
import Foundation
import HerdlyCore

/// The process walk, running check and activation behind an Open fallback (ADR 0015). Read-only
/// except `activate`, which raises a running app as a whole: macOS brings forward whichever of its
/// windows was last in front. Nothing here selects a window or tab, launches an app, or sends input.
enum TerminalApps {
    /// Walks from `pid` up its parents (at most `HerdrProcessTree.maximumDepth` processes) to the
    /// nearest process that is an app's main executable. Safe off the main actor.
    static func walk(from pid: Int32) -> TerminalAppWalk {
        let chain = HerdrProcessTree.ancestry(of: pid)
        guard chain.first?.pid == pid else { return .failed }
        return TerminalAppWalk(ancestorBundleIdentifiers: chain.map { appBundleIdentifier(of: $0.pid) })
    }

    /// Whether `host`'s app is running. Main actor: `NSRunningApplication` was seen to come back
    /// empty intermittently off it.
    @MainActor
    static func isRunning(_ host: TerminalHost) -> Bool {
        guard let identifier = host.bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    /// The terminal app macOS reports frontmost, nil for any other app (ADR 0016: frontmost is read from
    /// macOS, never from the host). Main actor, as `isRunning`.
    @MainActor
    static func frontmostHost() -> TerminalHost? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.flatMap(TerminalHost.init(bundleIdentifier:))
    }

    /// Activates the running app; false when it is not running (it is never launched) or macOS did not
    /// activate it. The caller rechecks `isRunning` to tell the two apart.
    @MainActor
    static func activate(_ host: TerminalHost) -> Bool {
        guard let identifier = host.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first else { return false }
        return app.activate()
    }

    /// The bundle identifier when `pid` runs the main executable of an app (`X.app/Contents/MacOS/…`).
    /// Safe off the main actor; WezTerm's socket check uses it too (#240).
    static func appBundleIdentifier(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let macOS = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app" else { return nil }
        return Bundle(url: bundle)?.bundleIdentifier
    }
}
