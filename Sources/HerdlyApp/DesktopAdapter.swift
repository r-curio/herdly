import AppKit
import HerdlyCore

/// The only AppKit boundary needed by the desktop MVP: app activation and deep-link delivery.
@MainActor
final class DesktopAdapter {
    /// `--assume-codex-away` is a lab override for placement probes on a machine where Codex is
    /// foreground; it changes nothing unless passed.
    func codexForeground() -> Bool? {
        if CommandLine.arguments.contains("--assume-codex-away") { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map { $0 == CodexSetupDetection.desktopBundleIdentifier }
    }

    func runningInstallations() -> [URL?] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == CodexSetupDetection.desktopBundleIdentifier }
            .map(\.bundleURL)
    }

    func open(taskID: String) async -> NavigationResult {
        await DesktopNavigation.open(taskID: taskID, runningAppURLs: runningInstallations()) { task, installation in
            _ = try await NSWorkspace.shared.open([task], withApplicationAt: installation,
                                                   configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
