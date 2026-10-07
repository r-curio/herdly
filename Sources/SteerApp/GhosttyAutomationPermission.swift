import AppKit
import CoreServices
import SteerCore

/// Asks macOS whether Steer may send Apple Events to Ghostty. This sends no event, so it neither
/// launches Ghostty nor reads its tabs. With `askIfNeeded` it shows the Automation prompt when no
/// decision exists and blocks until the user answers, so call it off the main actor.
enum GhosttyAutomationPermission {
    static let bundleIdentifier = "com.mitchellh.ghostty"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static let deniedGuidance = "Turn on Steer › Ghostty in System Settings › Privacy & Security › Automation."

    static var ghosttyIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func openSettings() { NSWorkspace.shared.open(settingsURL) }

    static func check(askIfNeeded: Bool) -> GhosttyAutomationAccess {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let desc = target.aeDesc else { return .unknown(-1) }
        return GhosttyAutomationAccess(status: AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, askIfNeeded))
    }
}
