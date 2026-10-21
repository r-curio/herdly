import Foundation

/// One row in an agent's Settings card that names something to fix, such as
/// "Codex desktop · Update to 26.901.51231 or later". Rows come only from existing setup state.
public struct AgentProblem: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// What an agent's Settings card says beneath its name, and which problem rows it shows.
/// An empty `problems` list means the card shows none.
public struct AgentSummary: Equatable, Sendable {
    public let subtitle: String
    public let problems: [AgentProblem]

    public init(subtitle: String, problems: [AgentProblem]) {
        self.subtitle = subtitle
        self.problems = problems
    }

    /// Codex: each surface's version in the subtitle. An unsupported surface asks for the tested
    /// minimum. A missing surface is a problem only when no surface is supported, since one
    /// supported surface is enough to use Herdly. Any status short of connected adds `statusText`.
    public static func codex(_ capabilities: CodexCapabilities, connected: Bool, statusText: String) -> AgentSummary {
        let surfaces = [
            (short: "CLI", name: "Codex CLI", installed: capabilities.cliInstalled, supported: capabilities.cli,
             version: capabilities.cliVersion, minimum: CodexSetupRequirements.minimumCLIVersion),
            (short: "Desktop", name: "Codex desktop", installed: capabilities.desktopInstalled, supported: capabilities.desktop,
             version: capabilities.desktopVersion, minimum: CodexSetupRequirements.minimumDesktopVersion)
        ]
        let anySupported = surfaces.contains { $0.supported }
        let subtitle = surfaces.map { surface in
            surface.installed ? "\(surface.short) \(surface.version ?? "version unknown")" : "\(surface.short) not installed"
        }.joined(separator: " · ")
        var problems: [AgentProblem] = surfaces.compactMap { surface in
            if !surface.installed {
                return anySupported ? nil : AgentProblem(label: surface.name, value: "Not installed")
            }
            return surface.supported ? nil : AgentProblem(label: surface.name, value: updateText(surface.minimum))
        }
        if !connected { problems.append(AgentProblem(label: "Status", value: statusText)) }
        return AgentSummary(subtitle: subtitle, problems: problems)
    }

    /// Claude Code, for one configuration folder: version and folder in the subtitle. An unsupported
    /// version asks for the tested minimum and stands in for the matching unsupported status. A root
    /// that is installed but missing newer Herdly hooks keeps working, so that note is its own row.
    public static func claude(_ capabilities: ClaudeCapabilities, displayPath: String,
                              status: ClaudeConnectionStatus, statusText: String, addsHooks: Bool) -> AgentSummary {
        let subtitle = "\(capabilities.version ?? "Not detected") · \(displayPath)"
        var problems: [AgentProblem] = []
        let outdated = capabilities.installed && !capabilities.supported
        if outdated {
            problems.append(AgentProblem(label: "Claude Code", value: updateText(ClaudeSetupRequirements.minimumCLIVersion)))
        }
        let statusCoveredByVersion: Bool = if case .unsupported = status { outdated } else { false }
        if status != .connected, !statusCoveredByVersion {
            problems.append(AgentProblem(label: "Status", value: statusText))
        }
        if addsHooks, status == .connected || status.isAwaitingRestart {
            problems.append(AgentProblem(label: "New hooks", value: "Configure to add them, such as file approvals"))
        }
        return AgentSummary(subtitle: subtitle, problems: problems)
    }

    /// The usage row's value: the setup's own explanation when usage cannot be read, otherwise the
    /// current subscription windows in short form.
    public static func claudeUsage(_ reading: ClaudeUsageReading?, status: ClaudeUsageSetupStatus, now: Double) -> String {
        switch status {
        case .unavailable(let message), .conflict(let message): return message
        case .off, .ready: break
        }
        guard let reading = reading?.current(now: now) else { return "No current reading" }
        let five = reading.fiveHour.map { "5h \($0.percentText)" } ?? "5h unavailable"
        let seven = reading.sevenDay.map { "7d \($0.percentText)" } ?? "7d unavailable"
        return "\(five) · \(seven)"
    }

    private static func updateText(_ minimum: String) -> String { "Update to \(minimum) or later" }
}
