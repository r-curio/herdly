import AppKit
import SteerCore

/// The only AppKit boundary needed by the desktop MVP: app activation and deep-link delivery.
@MainActor
final class DesktopAdapter {
    func codexForeground() -> Bool? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map { $0 == "com.openai.codex" }
    }

    func runningInstallations() -> [URL?] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.openai.codex" }
            .map(\.bundleURL)
    }

    func open(taskID: String) async -> NavigationResult {
        await DesktopNavigation.open(taskID: taskID, runningAppURLs: runningInstallations()) { task, installation in
            _ = try await NSWorkspace.shared.open([task], withApplicationAt: installation,
                                                   configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
