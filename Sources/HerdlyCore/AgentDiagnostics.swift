import Foundation

/// The wording of Settings › Agents' Show Diagnostics… sheets and setup previews, where the versions
/// moved when rows lost their subtitles (#481, A1). Plain text, one fact per line.
public enum AgentDiagnostics {
    /// A surface's version as a short value: the version when it is supported, otherwise why not.
    public static func surfaceVersion(installed: Bool, supported: Bool, version: String?, minimum: String) -> String {
        guard installed else { return "Not installed" }
        guard supported else { return "\(version ?? "Unknown version") · needs \(minimum) or later" }
        return version ?? "Installed"
    }

    /// One line per Codex surface and Ghostty: its version and whether Herdly supports it.
    public static func codexSurfaces(_ capabilities: CodexCapabilities) -> [String] {
        func text(_ name: String, installed: Bool, supported: Bool, version: String?, minimum: String) -> String {
            guard installed else { return "\(name): unavailable" }
            guard supported else { return "\(name) \(version ?? "version unknown"): unsupported; requires ≥ \(minimum)" }
            return "\(name) \(version ?? "version unknown"): available"
        }
        return [
            text("Codex CLI", installed: capabilities.cliInstalled, supported: capabilities.cli,
                 version: capabilities.cliVersion, minimum: CodexSetupRequirements.minimumCLIVersion),
            text("Codex desktop", installed: capabilities.desktopInstalled, supported: capabilities.desktop,
                 version: capabilities.desktopVersion, minimum: CodexSetupRequirements.minimumDesktopVersion),
            text("Ghostty", installed: capabilities.ghosttyInstalled, supported: capabilities.ghostty,
                 version: capabilities.ghosttyVersion, minimum: CodexSetupRequirements.minimumGhosttyVersion)
        ]
    }

    public static func codex(_ capabilities: CodexCapabilities, installed: Bool, statusText: String) -> String {
        (codexSurfaces(capabilities) + [hooks(installed), "Status: \(statusText)"]).joined(separator: "\n")
    }

    /// One Claude folder: its version, folder, hooks, status, usage and active sessions.
    /// `usage` is the folder's current reading, used only once Herdly's status line bridge is installed.
    public static func claude(_ capabilities: ClaudeCapabilities, displayPath: String, installed: Bool,
                              statusText: String, usageInstalled: Bool, usage: AgentUsage,
                              activeSessions: String) -> String {
        let support = !capabilities.installed ? "not installed"
            : capabilities.supported ? "supported"
            : "unsupported; requires ≥ \(ClaudeSetupRequirements.minimumCLIVersion)"
        return [
            "Claude Code \(capabilities.version ?? "version unknown"): \(support)",
            "Folder: \(displayPath)",
            hooks(installed),
            "Status: \(statusText)",
            "Usage limits: \(usageInstalled ? usageText(usage) : "not installed")",
            "Active sessions: \(activeSessions)"
        ].joined(separator: "\n")
    }

    /// A usage reading in words: the windows, no current window, or why usage can't be read.
    public static func usageText(_ usage: AgentUsage) -> String {
        switch usage {
        case .reading(let text): text
        case .unavailable: "no current window"
        case .problem(let reason): reason
        }
    }

    /// The setup preview's usage line: what Configure does with the user's status line.
    public static func usagePlan(_ status: ClaudeUsageSetupStatus, usageInstalled: Bool) -> String {
        let value = switch status {
        case .ready: usageInstalled ? "installed" : "wraps the existing status line"
        case .unavailable(let message), .conflict(let message): "unavailable; status line left as it is (\(message))"
        case .off: "off"
        }
        return "usage limits (always on): \(value)"
    }

    private static func hooks(_ installed: Bool) -> String { "Herdly hooks: \(installed ? "installed" : "not installed")" }
}
