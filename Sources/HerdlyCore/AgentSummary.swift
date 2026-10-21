import Foundation

/// One row in an agent's Settings card that names something to fix, such as
/// "Codex desktop · Update to 26.901.51231 or later". Rows come only from existing setup state,
/// and a card shows at most one row of each kind.
public struct AgentProblem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Hashable, Sendable {
        case codexCLI
        case codexDesktop
        case claudeVersion
        case status
        case newHooks
        case usage
    }

    public let kind: Kind
    public let label: String
    public let value: String
    public var id: Kind { kind }

    public init(kind: Kind, label: String, value: String) {
        self.kind = kind
        self.label = label
        self.value = value
    }
}

/// The status beside an agent's name: connected, needing attention (with a short reason), or
/// not yet known because the first detection has not landed.
public enum AgentHeaderStatus: Equatable, Sendable {
    case connected
    case attention(String)
    case checking

    public var title: String {
        switch self {
        case .connected: "Connected"
        case .attention(let reason): reason
        case .checking: "Checking"
        }
    }
}

/// The usage row's value: a current reading, no current window reported, or why usage cannot be read.
public enum AgentUsage: Equatable, Sendable {
    case reading(String)
    case unavailable
    case problem(String)

    /// The problem row for a setup that cannot read usage; a missing window is not a problem.
    public var problem: AgentProblem? {
        guard case .problem(let reason) = self else { return nil }
        return AgentProblem(kind: .usage, label: "Usage limits", value: reason)
    }
}

/// What an agent's Settings card says beside and beneath its name, and which problem rows it shows.
/// An empty `problems` list means the card shows none.
public struct AgentSummary: Equatable, Sendable {
    public let subtitle: String
    public let status: AgentHeaderStatus
    public let problems: [AgentProblem]

    public init(subtitle: String, status: AgentHeaderStatus, problems: [AgentProblem]) {
        self.subtitle = subtitle
        self.status = status
        self.problems = problems
    }

    /// Codex, from one setup reading. `status` is nil until the first detection lands; until then
    /// versions and status are unknown, so nothing is reported as a problem. Each surface's version
    /// goes in the subtitle. An unsupported surface asks for the tested minimum. A missing surface
    /// is a problem only when no surface is supported, since one is enough to use Herdly. Any
    /// status short of connected adds `statusText` as the Status row.
    public static func codex(_ capabilities: CodexCapabilities, status: CodexConnectionStatus?,
                             statusText: String) -> AgentSummary {
        guard let status else { return AgentSummary(subtitle: "Checking…", status: .checking, problems: []) }
        let surfaces = [
            (kind: AgentProblem.Kind.codexCLI, short: "CLI", name: "Codex CLI", installed: capabilities.cliInstalled,
             supported: capabilities.cli, version: capabilities.cliVersion, minimum: CodexSetupRequirements.minimumCLIVersion),
            (kind: AgentProblem.Kind.codexDesktop, short: "Desktop", name: "Codex desktop", installed: capabilities.desktopInstalled,
             supported: capabilities.desktop, version: capabilities.desktopVersion, minimum: CodexSetupRequirements.minimumDesktopVersion)
        ]
        let anySupported = surfaces.contains { $0.supported }
        let subtitle = surfaces.map { surface in
            surface.installed ? "\(surface.short) \(surface.version ?? "version unknown")" : "\(surface.short) not installed"
        }.joined(separator: " · ")
        var problems: [AgentProblem] = surfaces.compactMap { surface in
            if !surface.installed {
                return anySupported ? nil : AgentProblem(kind: surface.kind, label: surface.name, value: "Not installed")
            }
            return surface.supported ? nil
                : AgentProblem(kind: surface.kind, label: surface.name, value: updateText(surface.minimum))
        }
        let header: AgentHeaderStatus
        switch status {
        case .connected: header = .connected
        case .configuredAwaitingRestart: header = .attention("Restart required")
        case .notConfigured: header = .attention("Not configured")
        case .permissionRequired: header = .attention("Permission required")
        case .repairRequired: header = .attention("Repair required")
        case .unavailable, .unsupported, .malformed, .conflict: header = .attention("Not ready")
        }
        // An unsupported status that a version row already explains would only repeat it.
        let statusCoveredByVersion: Bool = if case .unsupported = status { !problems.isEmpty } else { false }
        if status != .connected, !statusCoveredByVersion { problems.append(AgentProblem(kind: .status, label: "Status", value: statusText)) }
        return AgentSummary(subtitle: subtitle, status: header, problems: problems)
    }

    /// Claude Code, for one configuration folder: version and folder in the subtitle. Until the first
    /// detection lands (`checked` false) the folder reads as Checking with no problems. An unsupported
    /// version asks for the tested minimum and stands in for the matching unsupported status. A root
    /// that is installed but missing newer Herdly hooks keeps working, so that note is its own row.
    public static func claude(checked: Bool, _ capabilities: ClaudeCapabilities, displayPath: String,
                              status: ClaudeConnectionStatus, statusText: String, addsHooks: Bool) -> AgentSummary {
        guard checked else { return claudeWithoutFolders(checked: false) }
        let subtitle = "\(capabilities.version ?? "Not detected") · \(displayPath)"
        var problems: [AgentProblem] = []
        let outdated = capabilities.installed && !capabilities.supported
        if outdated {
            problems.append(AgentProblem(kind: .claudeVersion, label: "Claude Code",
                                         value: updateText(ClaudeSetupRequirements.minimumCLIVersion)))
        }
        let statusCoveredByVersion: Bool = if case .unsupported = status { outdated } else { false }
        if status != .connected, !statusCoveredByVersion {
            problems.append(AgentProblem(kind: .status, label: "Status", value: statusText))
        }
        if addsHooks, status == .connected || status.isAwaitingRestart {
            problems.append(AgentProblem(kind: .newHooks, label: "New hooks",
                                         value: "Configure to add them, such as file approvals"))
        }
        let header: AgentHeaderStatus = status == .connected ? .connected
            : status.isAwaitingRestart ? .attention("Restart required") : .attention("Not ready")
        return AgentSummary(subtitle: subtitle, status: header, problems: problems)
    }

    /// The Claude Code card's header when there is no folder to describe: Checking until the first
    /// detection lands, then Not ready.
    public static func claudeWithoutFolders(checked: Bool) -> AgentSummary {
        checked ? AgentSummary(subtitle: "No Claude folder", status: .attention("Not ready"), problems: [])
            : AgentSummary(subtitle: "Checking…", status: .checking, problems: [])
    }

    /// The usage row's value: the setup's own explanation, as a problem, when usage cannot be read;
    /// otherwise the current subscription windows in short form, or unavailable when none is current.
    public static func claudeUsage(_ reading: ClaudeUsageReading?, status: ClaudeUsageSetupStatus, now: Double) -> AgentUsage {
        switch status {
        case .unavailable(let message), .conflict(let message): return .problem(message)
        case .off, .ready: break
        }
        guard let reading = reading?.current(now: now) else { return .unavailable }
        let five = reading.fiveHour.map { "5h \($0.percentText)" } ?? "5h unavailable"
        let seven = reading.sevenDay.map { "7d \($0.percentText)" } ?? "7d unavailable"
        return .reading("\(five) · \(seven)")
    }

    private static func updateText(_ minimum: String) -> String { "Update to \(minimum) or later" }
}
