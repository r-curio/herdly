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
        case .status, .newHooks, .usage, .pendingSetup: value
        }
    }
}

/// What Configure would do for one Claude folder, and how its usage bridge reads now: the facts the
/// folder's row needs beyond its connection status. Usage limits are always on (A4).
public struct ClaudeFolderSetup: Equatable, Sendable {
    /// Whether the folder's setup preview is ready, so Configure could run now.
    public let planReady: Bool
    public let requiresConfigure: Bool
    public let addsHooks: Bool
    /// What Configure would do for usage limits; nil without a ready preview.
    public let plannedUsage: ClaudeUsageSetupStatus?
    /// Whether Herdly's status line bridge is in place.
    public let usageInstalled: Bool
    /// How the installed usage reads.
    public let usageStatus: ClaudeUsageSetupStatus

    public init(planReady: Bool, requiresConfigure: Bool = false, addsHooks: Bool = false,
                plannedUsage: ClaudeUsageSetupStatus? = nil, usageInstalled: Bool = false,
                usageStatus: ClaudeUsageSetupStatus = .off) {
        self.planReady = planReady
        self.requiresConfigure = requiresConfigure
        self.addsHooks = addsHooks
        self.plannedUsage = plannedUsage
        self.usageInstalled = usageInstalled
        self.usageStatus = usageStatus
    }

    /// From the folder's preview, counted only when it is ready.
    public init(plan: ClaudeSetupPlan?, usageInstalled: Bool, usageStatus: ClaudeUsageSetupStatus) {
        let ready: ClaudeSetupPlan? = if let plan, case .ready = plan.status { plan } else { nil }
        self.init(planReady: ready != nil, requiresConfigure: ready?.requiresConfigure ?? false,
                  addsHooks: ready?.addsHooks ?? false, plannedUsage: ready?.usageStatus,
                  usageInstalled: usageInstalled, usageStatus: usageStatus)
    }
}

/// What one row of Settings › Agents shows: its badge (nil while the first detection runs), whether
/// its switch is on, whether it can be turned on, and the lines beneath it. The switch is on exactly
/// when Herdly's install record for the agent exists, the same files Undo Setup removes (A3). Turning
/// it off stays possible whenever that is so, so Undo is always reachable; turning it on needs setup
/// that can run now, and otherwise the switch is off, disabled, and a line says why.
public struct AgentSettingsRow: Equatable, Sendable {
    public let badge: AgentRowBadge?
    public let hooksInstalled: Bool
    /// Whether Configure can run now from an off switch; always false while the switch is on.
    public let canTurnOn: Bool
    public let lines: [AgentRowLine]

    public init(badge: AgentRowBadge?, hooksInstalled: Bool, canTurnOn: Bool, lines: [AgentRowLine]) {
        self.badge = badge
        self.hooksInstalled = hooksInstalled
        self.canTurnOn = canTurnOn && !hooksInstalled
        self.lines = lines
    }

    /// Undo Setup is reachable whenever Herdly's hooks are installed and the first detection has landed.
    public var canTurnOff: Bool { badge != nil && hooksInstalled }
    public var switchEnabled: Bool { canTurnOff || (badge != nil && canTurnOn) }

    /// What VoiceOver reads for the row: "<name>, <status>".
    public func accessibilityLabel(name: String) -> String { "\(name), \(badge?.title ?? "Checking")" }

    static let setupNotReady = "Herdly can't set this up yet. Choose Review Again from the ⋯ menu."
    /// Configure Codex's hints that used to follow its result (#481 review): Codex may still ask to
    /// trust the hooks, and Ghostty's Automation consent is separate from setup.
    static let codexTrustHint = "If Codex asks whether to trust Herdly's hooks, allow them"
    static let ghosttyAutomationHint = "Ghostty Automation isn't verified yet. Turn on Ghostty in Settings › Terminals so macOS can ask"

    /// The Codex row. `status` is nil until the first detection lands. `installed` is whether Herdly's
    /// install record exists; `planReady` whether Configure could run now; `ghosttyAutomationVerified`
    /// whether macOS has allowed Herdly to control Ghostty; `restartAfterUpdate` whether Codex was
    /// updated since its last SessionStart (`AgentUpdates.restartRequired`).
    public static func codex(_ capabilities: CodexCapabilities, status: CodexConnectionStatus?, statusText: String,
                             installed: Bool, planReady: Bool, ghosttyAutomationVerified: Bool,
                             restartAfterUpdate: Bool) -> AgentSettingsRow {
        guard let status else { return checking(installed: installed) }
        let summary = AgentSummary.codex(capabilities, status: status, statusText: statusText)
        let canConfigure = planReady && (status == .notConfigured || status.isRepair)
        var extra: [AgentRowLine] = []
        if let note = AgentUpdates.codexInstallNote(summary, capabilities) { extra.append(.note(note)) }
        // Until a session loads the new hooks, the hints Configure Codex used to print stay with the row.
        if installed, status.isAwaitingRestart {
            extra.append(.note(codexTrustHint))
            if !ghosttyAutomationVerified { extra.append(.note(ghosttyAutomationHint)) }
        }
        return assemble(.codex, installed: installed, restartAfterUpdate: restartAfterUpdate,
                        awaitingRestart: status.isAwaitingRestart, connected: status == .connected,
                        notConfigured: status == .notConfigured,
                        notInstalledNote: !capabilities.cliInstalled && !capabilities.desktopInstalled ? "Codex isn't installed" : nil,
                        problems: summary.problems, statusConfigures: installed && canConfigure, extra: extra,
                        canTurnOn: canConfigure)
    }

    /// One Claude folder's row. `status` is nil until the first detection lands. `installed` is whether
    /// the folder's install record exists; `setup` what Configure would do and how usage reads.
    public static func claude(_ capabilities: ClaudeCapabilities, status: ClaudeConnectionStatus?, statusText: String,
                              installed: Bool, setup: ClaudeFolderSetup, restartAfterUpdate: Bool) -> AgentSettingsRow {
        guard let status else { return checking(installed: installed) }
        let summary = AgentSummary.claude(checked: true, capabilities, displayPath: "", status: status,
                                          statusText: statusText, addsHooks: false)
        let usageWanted = setup.plannedUsage == .ready
        let offersConfigure = installed && setup.planReady
            && status.offersConfigure(requiresConfigure: setup.requiresConfigure,
                                      usageMatches: setup.usageInstalled == usageWanted)
        let working = status == .connected || status.isAwaitingRestart
        var extra: [AgentRowLine] = []
        if offersConfigure, working {
            // A working folder with changes Configure would add: newer hooks, the usage bridge that
            // earlier versions left to an opt-in, or other settings to write.
            let pending = setup.addsHooks
                ? AgentProblem(kind: .newHooks, label: "New hooks", value: "New hooks are available, such as file approvals")
                : usageWanted && !setup.usageInstalled
                ? AgentProblem(kind: .usage, label: "Usage limits", value: "Usage limits need Herdly to wrap your status line")
                : AgentProblem(kind: .pendingSetup, label: "Setup", value: "Herdly's setup for this folder has changes to apply")
            extra.append(.problem(pending, configures: true))
        } else if installed, working {
            switch setup.usageStatus {
            case .unavailable(let message), .conflict(let message): extra.append(.note(message))
            case .off, .ready: break
            }
        }
        return assemble(.claude, installed: installed, restartAfterUpdate: restartAfterUpdate,
                        awaitingRestart: status.isAwaitingRestart, connected: status == .connected,
                        notConfigured: status == .notConfigured,
                        notInstalledNote: capabilities.installed ? nil : "Claude Code isn't installed",
                        problems: summary.problems, statusConfigures: offersConfigure, extra: extra,
                        canTurnOn: setup.planReady && capabilities.supported && status == .notConfigured)
    }

    private static func checking(installed: Bool) -> AgentSettingsRow {
        AgentSettingsRow(badge: nil, hooksInstalled: installed, canTurnOn: false, lines: [])
    }

    /// The rules both agents share: Restart required only while hooks are installed (an update, else
    /// setup no session has loaded); a missing app replaces every other line with one note; the
    /// status problem is left out when the badge and restart line already say it; and a switch that
    /// can't move either way always has a line saying why.
    private static func assemble(_ agent: AgentSource, installed: Bool, restartAfterUpdate: Bool,
                                 awaitingRestart: Bool, connected: Bool, notConfigured: Bool,
                                 notInstalledNote: String?, problems: [AgentProblem], statusConfigures: Bool,
                                 extra: [AgentRowLine], canTurnOn: Bool) -> AgentSettingsRow {
        let restart: AgentRestartReason? = !installed ? nil
            : restartAfterUpdate ? .update
            : awaitingRestart ? .setup : nil
        var lines: [AgentRowLine] = []
        if let restart { lines.append(.restart(restart.line(for: agent))) }
        if let notInstalledNote {
            lines.append(.note(notInstalledNote))
        } else {
            let quietStatus = notConfigured || connected || awaitingRestart
            for problem in problems where !(problem.kind == .status && quietStatus) {
                lines.append(.problem(problem, configures: problem.kind == .status && statusConfigures))
            }
            lines += extra
        }
        if !installed, !canTurnOn, lines.isEmpty { lines.append(.note(setupNotReady)) }
        return AgentSettingsRow(badge: badge(installed: installed, restart: restart, lines: lines, connected: connected),
                                hooksInstalled: installed, canTurnOn: canTurnOn, lines: lines)
    }

    /// Restart required wins. A switched-off agent reads Off unless its status needs fixing (such as
    /// Herdly's hooks left in settings without an install record). An installed agent with a problem
    /// to fix needs attention, except pending setup changes, which leave a working agent Ready.
    private static func badge(installed: Bool, restart: AgentRestartReason?, lines: [AgentRowLine],
                              connected: Bool) -> AgentRowBadge {
        if restart != nil { return .restartRequired }
        let problems = lines.compactMap { line -> AgentProblem? in
            guard case .problem(let problem, _) = line else { return nil }
            return problem
        }
        guard installed else { return problems.contains { $0.kind == .status } ? .needsAttention : .off }
        let needsFix = problems.contains { ![.newHooks, .usage, .pendingSetup].contains($0.kind) }
        return needsFix || !connected ? .needsAttention : .ready
    }
}

/// What flipping a row's switch runs (A3): on runs that agent's Configure, only while setup can run;
/// off runs its Undo Setup at once, with no confirmation, whenever Herdly's hooks are installed. Nil
/// otherwise, including when the switch already reads that way.
public enum AgentSwitchChange: Equatable, Sendable {
    case configure
    case undo

    public static func change(to on: Bool, _ row: AgentSettingsRow) -> AgentSwitchChange? {
        if on { return row.badge != nil && row.canTurnOn ? .configure : nil }
        return row.canTurnOff ? .undo : nil
    }
}
