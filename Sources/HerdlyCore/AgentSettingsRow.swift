import Foundation

/// The pill beside an agent's name in Settings › Agents (#481, Paper "Agents tab like Terminals", A6):
/// the Terminals badges, plus Restart required while a new session has yet to load Herdly's hooks.
public enum AgentRowBadge: Equatable, Sendable {
    case ready
    case restartRequired
    case needsAttention
    case off

    public var title: String {
        switch self {
        case .ready: "Ready"
        case .restartRequired: "Restart required"
        case .needsAttention: "Needs attention"
        case .off: "Off"
        }
    }
}

/// Why an agent's row asks for a new session: an update it just installed, or setup that no
/// session has loaded yet (A5).
public enum AgentRestartReason: Equatable, Sendable {
    case update
    case setup

    /// The one line under the row, with the command to run in backticks (rendered as code).
    public func line(for agent: AgentSource) -> String {
        let finish = self == .update ? "to finish updating" : "to finish setup"
        switch agent {
        case .codex: return "Quit and reopen Codex, or run `codex` in a new terminal tab, \(finish)"
        case .claude: return "Run `claude` in a new terminal tab \(finish)"
        }
    }
}

/// One line under an agent's row, in the order shown.
public enum AgentRowLine: Equatable, Hashable, Sendable {
    /// How to clear Restart required; no button (A5).
    case restart(String)
    /// Something to fix. A version problem gets its Update / Open Codex button from `AgentUpdates.row`;
    /// `configures` adds a Configure button that runs the agent's setup again.
    case problem(AgentProblem, configures: Bool)
    /// Information that asks nothing, such as why the switch is unavailable or why usage can't be read.
    case note(String)

    /// The line's text: a problem's value alone for status-like rows, otherwise prefixed by what it is about.
    public static func text(_ problem: AgentProblem, value: String) -> String {
        switch problem.kind {
        case .codexCLI, .codexDesktop, .claudeVersion: "\(problem.label): \(value)"
        case .status, .newHooks, .usage: value
        }
    }
}

/// What one row of Settings › Agents shows: its badge (nil while the first detection runs), whether
/// its switch is on, whether the switch can change, and the lines beneath it. The switch is on exactly
/// when Herdly's install record for the agent exists, the same files Undo Setup removes (A3).
public struct AgentSettingsRow: Equatable, Sendable {
    public let badge: AgentRowBadge?
    public let hooksInstalled: Bool
    public let switchEnabled: Bool
    public let lines: [AgentRowLine]

    public init(badge: AgentRowBadge?, hooksInstalled: Bool, switchEnabled: Bool, lines: [AgentRowLine]) {
        self.badge = badge
        self.hooksInstalled = hooksInstalled
        self.switchEnabled = switchEnabled
        self.lines = lines
    }

    /// What VoiceOver reads for the row: "<name>, <status>".
    public func accessibilityLabel(name: String) -> String { "\(name), \(badge?.title ?? "Checking")" }

    static let setupNotReady = "Herdly can't set this up yet. Choose Review Again from the ⋯ menu."

    /// The Codex row. `status` is nil until the first detection lands. `installed` is whether Herdly's
    /// install record exists; `planReady` whether Configure could run now; `restartAfterUpdate` whether
    /// Codex was updated since its last SessionStart (`AgentUpdates.restartRequired`).
    public static func codex(_ capabilities: CodexCapabilities, status: CodexConnectionStatus?, statusText: String,
                             installed: Bool, planReady: Bool, restartAfterUpdate: Bool) -> AgentSettingsRow {
        guard let status else {
            return AgentSettingsRow(badge: nil, hooksInstalled: installed, switchEnabled: false, lines: [])
        }
        let summary = AgentSummary.codex(capabilities, status: status, statusText: statusText)
        let restart: AgentRestartReason? = !installed ? nil
            : restartAfterUpdate ? .update
            : isAwaitingRestart(status) ? .setup : nil
        let canConfigure = planReady && (status == .notConfigured || isRepair(status))
        var lines: [AgentRowLine] = []
        if let restart { lines.append(.restart(restart.line(for: .codex))) }
        if !capabilities.cliInstalled && !capabilities.desktopInstalled {
            lines.append(.note("Codex isn't installed"))
        } else {
            for problem in summary.problems {
                // Off, connected and awaiting restart say all they need in the badge and restart line.
                if problem.kind == .status, status == .notConfigured || status == .connected || isAwaitingRestart(status) {
                    continue
                }
                lines.append(.problem(problem, configures: problem.kind == .status && installed && canConfigure))
            }
            if let note = AgentUpdates.codexInstallNote(summary, capabilities) { lines.append(.note(note)) }
        }
        let switchEnabled = installed || canConfigure
        if !switchEnabled, lines.isEmpty { lines.append(.note(setupNotReady)) }
        return AgentSettingsRow(badge: badge(installed: installed, restart: restart, lines: lines,
                                             connected: status == .connected),
                                hooksInstalled: installed, switchEnabled: switchEnabled, lines: lines)
    }

    /// One Claude folder's row. `installed` is whether the folder's install record exists; `planReady`
    /// whether its setup preview is ready; `plannedUsage` what Configure would do for usage limits,
    /// which are always on (A4); `usageInstalled` whether Herdly's status line bridge is in place and
    /// `usageStatus` how the installed usage reads.
    public static func claude(checked: Bool, _ capabilities: ClaudeCapabilities, status: ClaudeConnectionStatus,
                              statusText: String, installed: Bool, planReady: Bool, requiresConfigure: Bool,
                              addsHooks: Bool, plannedUsage: ClaudeUsageSetupStatus?, usageInstalled: Bool,
                              usageStatus: ClaudeUsageSetupStatus, restartAfterUpdate: Bool) -> AgentSettingsRow {
        guard checked else {
            return AgentSettingsRow(badge: nil, hooksInstalled: installed, switchEnabled: false, lines: [])
        }
        let summary = AgentSummary.claude(checked: true, capabilities, displayPath: "", status: status,
                                          statusText: statusText, addsHooks: false)
        let restart: AgentRestartReason? = !installed ? nil
            : restartAfterUpdate ? .update
            : status.isAwaitingRestart ? .setup : nil
        let usageWanted = plannedUsage == .ready
        let offersConfigure = installed && planReady
            && status.offersConfigure(requiresConfigure: requiresConfigure, usageMatches: usageInstalled == usageWanted)
        var lines: [AgentRowLine] = []
        if let restart { lines.append(.restart(restart.line(for: .claude))) }
        if !capabilities.installed {
            lines.append(.note("Claude Code isn't installed"))
        } else {
            for problem in summary.problems {
                if problem.kind == .status, status == .notConfigured || status == .connected || status.isAwaitingRestart {
                    continue
                }
                lines.append(.problem(problem, configures: problem.kind == .status && offersConfigure))
            }
            // A working folder with changes Configure would add: newer hooks, or the usage bridge that
            // earlier versions left to an opt-in.
            if offersConfigure, status == .connected || status.isAwaitingRestart {
                let pending = addsHooks
                    ? AgentProblem(kind: .newHooks, label: "New hooks", value: "New hooks are available, such as file approvals")
                    : usageWanted && !usageInstalled
                    ? AgentProblem(kind: .usage, label: "Usage limits", value: "Usage limits need Herdly to wrap your status line")
                    : AgentProblem(kind: .newHooks, label: "Setup", value: "Herdly's setup for this folder has changes to apply")
                lines.append(.problem(pending, configures: true))
            } else if installed, status == .connected || status.isAwaitingRestart {
                switch usageStatus {
                case .unavailable(let message), .conflict(let message): lines.append(.note(message))
                case .off, .ready: break
                }
            }
        }
        let switchEnabled = installed || (planReady && capabilities.supported)
        if !switchEnabled, lines.isEmpty { lines.append(.note(setupNotReady)) }
        return AgentSettingsRow(badge: badge(installed: installed, restart: restart, lines: lines,
                                             connected: status == .connected),
                                hooksInstalled: installed, switchEnabled: switchEnabled, lines: lines)
    }

    /// Restart required wins; a switched-off agent reads Off whatever its lines say; a row with a
    /// problem to fix needs attention, except pending new hooks or usage, which leave a working agent Ready.
    private static func badge(installed: Bool, restart: AgentRestartReason?, lines: [AgentRowLine],
                              connected: Bool) -> AgentRowBadge {
        if restart != nil { return .restartRequired }
        guard installed else { return .off }
        let needsFix = lines.contains { line in
            guard case .problem(let problem, _) = line else { return false }
            return problem.kind != .newHooks && problem.kind != .usage
        }
        return needsFix || !connected ? .needsAttention : .ready
    }

    private static func isAwaitingRestart(_ status: CodexConnectionStatus) -> Bool {
        if case .configuredAwaitingRestart = status { return true }
        return false
    }

    private static func isRepair(_ status: CodexConnectionStatus) -> Bool {
        if case .repairRequired = status { return true }
        return false
    }
}
