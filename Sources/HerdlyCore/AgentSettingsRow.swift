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

    /// The one line under the row, with the command to run in backticks (rendered as code). After
    /// setup, Codex's line also asks the user to allow Herdly's hooks if Codex prompts to trust them.
    public func line(for agent: AgentSource) -> String {
        switch (agent, self) {
        case (.codex, .update): "Quit and reopen Codex, or run `codex` in a new terminal tab, to finish updating"
        case (.codex, .setup): "Quit and reopen Codex, or run `codex` in a new terminal tab, and allow Herdly's hooks if Codex asks"
        case (.claude, .update): "Run `claude` in a new terminal tab to finish updating"
        case (.claude, .setup): "Run `claude` in a new terminal tab to finish setup"
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
        case .status, .newHooks, .usage, .pendingSetup, .usageWriteFailed: value
        }
    }
}

/// What Configure would do for one Claude folder, and how its usage bridge reads now: the facts the
/// folder's row needs beyond its connection status. Usage limits are always on (A4).
public struct ClaudeFolderSetup: Equatable, Sendable {
    /// Whether the folder's setup preview is ready, so Configure could run now.
    public let planReady: Bool
    /// Whether Configure would change settings other than the usage status line, which detection
    /// adds on its own (`ClaudeSetupInstaller.upgradeUsage`).
    public let requiresConfigure: Bool
    public let addsHooks: Bool
    /// What Configure would do for usage limits; nil without a ready preview.
    public let plannedUsage: ClaudeUsageSetupStatus?
    /// Whether Herdly's status line bridge is in place.
    public let usageInstalled: Bool
    /// How the installed usage reads.
    public let usageStatus: ClaudeUsageSetupStatus
    /// What the last automatic usage upgrade did (`ClaudeSetupInstaller.upgradeUsage`).
    public let usageUpgrade: ClaudeUsageUpgrade

    public init(planReady: Bool, requiresConfigure: Bool = false, addsHooks: Bool = false,
                plannedUsage: ClaudeUsageSetupStatus? = nil, usageInstalled: Bool = false,
                usageStatus: ClaudeUsageSetupStatus = .off, usageUpgrade: ClaudeUsageUpgrade = .skipped) {
        self.planReady = planReady
        self.requiresConfigure = requiresConfigure
        self.addsHooks = addsHooks
        self.plannedUsage = plannedUsage
        self.usageInstalled = usageInstalled
        self.usageStatus = usageStatus
        self.usageUpgrade = usageUpgrade
    }

    /// From the folder's preview, counted only when it is ready.
    public init(plan: ClaudeSetupPlan?, usageInstalled: Bool, usageStatus: ClaudeUsageSetupStatus,
                usageUpgrade: ClaudeUsageUpgrade = .skipped) {
        let ready: ClaudeSetupPlan? = if let plan, case .ready = plan.status { plan } else { nil }
        self.init(planReady: ready != nil, requiresConfigure: ready?.changesBeyondUsage ?? false,
                  addsHooks: ready?.addsHooks ?? false, plannedUsage: ready?.usageStatus,
                  usageInstalled: usageInstalled, usageStatus: usageStatus, usageUpgrade: usageUpgrade)
    }
}

/// What one row of Settings › Agents shows: its badge (nil while the first detection runs), whether
/// its switch is on, whether setup could run from the off position, and the lines beneath it. The switch is on exactly
/// when Herdly's install record for the agent exists, the same files Undo Setup removes (A3). Turning
/// it off stays possible whenever that is so, so Undo is always reachable; turning it on needs setup
/// that can run now, and otherwise the switch is off, disabled, and a line says why.
public struct AgentSettingsRow: Equatable, Sendable {
    public let badge: AgentRowBadge?
    public let hooksInstalled: Bool
    /// Whether the agent's first setup could run now: a ready preview with no install record yet.
    public let setupCanRun: Bool
    public let lines: [AgentRowLine]

    public init(badge: AgentRowBadge?, hooksInstalled: Bool, setupCanRun: Bool, lines: [AgentRowLine]) {
        self.badge = badge
        self.hooksInstalled = hooksInstalled
        self.setupCanRun = setupCanRun
        self.lines = lines
    }

    /// An off switch turns on only when setup can run; an installed agent is already on.
    public var canTurnOn: Bool { badge != nil && !hooksInstalled && setupCanRun }
    /// Undo Setup is reachable whenever Herdly's hooks are installed and the first detection has landed.
    public var canTurnOff: Bool { badge != nil && hooksInstalled }
    public var switchEnabled: Bool { canTurnOn || canTurnOff }

    /// What VoiceOver reads for the row: "<name>, <status>".
    public func accessibilityLabel(name: String) -> String { "\(name), \(badge?.title ?? "Checking")" }

    static let setupNotReady = "Herdly can't set this up yet. Choose Review Again from the ⋯ menu."
    /// The Codex row. `status` is nil until the first detection lands. `installed` is whether Herdly's
    /// install record exists; `planReady` whether Configure could run now; `restartAfterUpdate` whether
    /// Codex was updated since its last SessionStart (`AgentUpdates.restartRequired`).
    ///
    /// For both agents the switch turns on only from Not configured: a repair status only arises once
    /// the install record exists, so its switch is already on and the repair runs from the status
    /// line's Configure button.
    public static func codex(_ capabilities: CodexCapabilities, status: CodexConnectionStatus?, statusText: String,
                             installed: Bool, planReady: Bool, restartAfterUpdate: Bool) -> AgentSettingsRow {
        guard let status else { return checking(installed: installed) }
        let summary = AgentSummary.codex(capabilities, status: status, statusText: statusText)
        var extra: [AgentRowLine] = []
        if let note = AgentUpdates.codexInstallNote(summary, capabilities) { extra.append(.note(note)) }
        return assemble(.codex, installed: installed, restartAfterUpdate: restartAfterUpdate,
                        status: RowStatus(awaitingRestart: status.isAwaitingRestart, connected: status == .connected,
                                          notConfigured: status == .notConfigured),
                        notInstalledNote: !capabilities.cliInstalled && !capabilities.desktopInstalled ? "Codex isn't installed" : nil,
                        problems: summary.problems, statusConfigures: installed && planReady && status.isRepair,
                        extra: extra, setupCanRun: planReady && status == .notConfigured)
    }

    /// One Claude folder's row. `status` is nil until the first detection lands. `installed` is whether
    /// the folder's install record exists; `setup` what Configure would do and how usage reads.
    public static func claude(_ capabilities: ClaudeCapabilities, status: ClaudeConnectionStatus?, statusText: String,
                              installed: Bool, setup: ClaudeFolderSetup, restartAfterUpdate: Bool) -> AgentSettingsRow {
        guard let status else { return checking(installed: installed) }
        let summary = AgentSummary.claude(checked: true, capabilities, displayPath: "", status: status,
                                          statusText: statusText, addsHooks: false)
        // Usage never asks for Configure: detection adds the bridge to an installed folder on its own.
        let offersConfigure = installed && setup.planReady
            && status.offersConfigure(requiresConfigure: setup.requiresConfigure, usageMatches: true)
        let working = status == .connected || status.isAwaitingRestart
        var extra: [AgentRowLine] = []
        // A usage upgrade that couldn't restore the settings it was changing needs the user, whatever
        // else holds, even with the install record gone.
        if case .rollbackIncomplete(let message) = setup.usageUpgrade {
            extra.append(.problem(AgentProblem(kind: .usageWriteFailed, label: "Usage limits", value: message),
                                  configures: false))
        }
        if offersConfigure, working {
            // A working folder with changes Configure would add: newer hooks, or other settings to write.
            let pending = setup.addsHooks
                ? AgentProblem(kind: .newHooks, label: "New hooks", value: "New hooks are available, such as file approvals")
                : AgentProblem(kind: .pendingSetup, label: "Setup", value: "Herdly's setup for this folder has changes to apply")
            extra.append(.problem(pending, configures: true))
        } else if installed, working, let reason = usageUnavailable(setup) {
            extra.append(.note(reason))
        }
        return assemble(.claude, installed: installed, restartAfterUpdate: restartAfterUpdate,
                        status: RowStatus(awaitingRestart: status.isAwaitingRestart, connected: status == .connected,
                                          notConfigured: status == .notConfigured),
                        notInstalledNote: capabilities.installed ? nil : "Claude Code isn't installed",
                        problems: summary.problems, statusConfigures: offersConfigure, extra: extra,
                        setupCanRun: setup.planReady && capabilities.supported && status == .notConfigured)
    }

    static let usagePending = "Usage limits are unavailable until Herdly can add its status line"

    /// Why an installed folder has no usage, in one quiet line, or nil when usage reads. A bridge the
    /// preview could add but detection hasn't (the settings changed meanwhile, or a check failed)
    /// waits for the next check; otherwise the installed usage's own reason, such as a status line
    /// that failed the compatibility probe and was left as it is.
    private static func usageUnavailable(_ setup: ClaudeFolderSetup) -> String? {
        switch setup.usageUpgrade {
        case .failed(let message): return "Couldn't add Herdly's usage status line: \(message)"
        case .rollbackIncomplete: return nil
        case .applied, .skipped: break
        }
        if !setup.usageInstalled, setup.plannedUsage == .ready { return usagePending }
        switch setup.usageStatus {
        case .unavailable(let message), .conflict(let message): return message
        case .off, .ready: return nil
        }
    }

    private static func checking(installed: Bool) -> AgentSettingsRow {
        AgentSettingsRow(badge: nil, hooksInstalled: installed, setupCanRun: false, lines: [])
    }

    /// The parts of either agent's connection status the shared rules read.
    private struct RowStatus {
        let awaitingRestart: Bool
        let connected: Bool
        let notConfigured: Bool
    }

    /// The rules both agents share: Restart required only while hooks are installed (an update, else
    /// setup no session has loaded); a missing app replaces every other line with one note; the
    /// status problem is left out when the badge and restart line already say it; and a switch that
    /// can't move either way always has a line saying why.
    private static func assemble(_ agent: AgentSource, installed: Bool, restartAfterUpdate: Bool, status: RowStatus,
                                 notInstalledNote: String?, problems: [AgentProblem], statusConfigures: Bool,
                                 extra: [AgentRowLine], setupCanRun: Bool) -> AgentSettingsRow {
        let restart: AgentRestartReason? = !installed ? nil
            : restartAfterUpdate ? .update
            : status.awaitingRestart ? .setup : nil
        var lines: [AgentRowLine] = []
        if let restart { lines.append(.restart(restart.line(for: agent))) }
        if let notInstalledNote {
            lines.append(.note(notInstalledNote))
        } else {
            let quietStatus = status.notConfigured || status.connected || status.awaitingRestart
            for problem in problems where !(problem.kind == .status && quietStatus) {
                lines.append(.problem(problem, configures: problem.kind == .status && statusConfigures))
            }
            lines += extra
        }
        if !installed, !setupCanRun, lines.isEmpty { lines.append(.note(setupNotReady)) }
        return AgentSettingsRow(badge: badge(installed: installed, restart: restart, lines: lines, connected: status.connected),
                                hooksInstalled: installed, setupCanRun: setupCanRun, lines: lines)
    }

    /// Settings a failed rollback may have left half-written outrank everything. Then Restart required
    /// wins. A switched-off agent reads Off unless its status needs fixing (such as
    /// Herdly's hooks left in settings without an install record). An installed agent with a problem
    /// to fix needs attention, except pending setup changes, which leave a working agent Ready.
    private static func badge(installed: Bool, restart: AgentRestartReason?, lines: [AgentRowLine],
                              connected: Bool) -> AgentRowBadge {
        let problems = lines.compactMap { line -> AgentProblem? in
            guard case .problem(let problem, _) = line else { return nil }
            return problem
        }
        if problems.contains(where: { $0.kind == .usageWriteFailed }) { return .needsAttention }
        if restart != nil { return .restartRequired }
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
        if on { return row.canTurnOn ? .configure : nil }
        return row.canTurnOff ? .undo : nil
    }
}
