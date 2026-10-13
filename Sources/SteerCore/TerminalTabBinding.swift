import Foundation

// ADR 0013: a CLI session binds to a terminal tab by the tab's tty. Every rule here is a pure
// function of fresh host inventories, `ps -t` reads and Steer's own session records, passed in by
// SteerApp, which owns the Apple Events, host CLIs, subprocesses and scheduling.

// MARK: - Foreground processes

/// One process on a tab's tty, from `ps -o pid=,stat=,comm= -t <tty>`. `foreground` is the `+` in
/// `stat`: the process is in its terminal's foreground process group (`man ps`). `name` is the
/// executable's basename; arguments are never read, so a shell or script mentioning an agent is
/// not that agent.
public struct TerminalProcess: Equatable, Hashable, Sendable {
    public let pid: Int32
    public let name: String
    public let foreground: Bool

    public init(pid: Int32, name: String, foreground: Bool) {
        self.pid = pid
        self.name = name
        self.foreground = foreground
    }
}

public enum TerminalForegroundProcesses {
    /// Rows accepted from one `ps -t` read; a larger read is malformed rather than truncated.
    public static let maximumProcesses = 256

    /// The processes in `output`, the stdout of `ps -o pid=,stat=,comm= -t <tty>`, or nil when any
    /// row is malformed or there are more than `maximumProcesses`. Blank lines are skipped.
    public static func parse(_ output: String) -> [TerminalProcess]? {
        var processes: [TerminalProcess] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), pid > 0 else { return nil }
            let command = fields[2].trimmingCharacters(in: .whitespaces)
            let name = command.hasPrefix("/") ? (command as NSString).lastPathComponent : command
            guard !name.isEmpty else { return nil }
            processes.append(TerminalProcess(pid: pid, name: name, foreground: fields[1].contains("+")))
            guard processes.count <= maximumProcesses else { return nil }
        }
        return processes
    }
}

// MARK: - Host inventories

/// One tab in a terminal host's inventory. `tabID` is the host's own handle for the tab (an iTerm2
/// session GUID, a Terminal.app tab window, a WezTerm pane ID) and means nothing across hosts.
/// `tty` is nil when the host cannot report it (Ghostty without `tty`); such a tab still counts
/// for Codex title uniqueness but never binds by these rules. `paneCount` counts every pane in the
/// tab, so a split is visible.
public struct TerminalTab: Equatable, Hashable, Sendable {
    public let tabID: String
    public let tty: String?
    public let title: String?
    public let paneCount: Int

    public init(tabID: String, tty: String?, title: String?, paneCount: Int) {
        self.tabID = tabID
        self.tty = tty
        self.title = title
        self.paneCount = paneCount
    }
}

/// One enabled host's fresh inventory (ADR 0013 "Inventory").
public enum TerminalHostInventory: Equatable, Sendable {
    /// The host is not running, so it holds no tab.
    case notRunning
    /// The host is running but its inventory failed or permission was denied: it cannot be ruled
    /// out, so every session it could hold is unavailable.
    case unreadable
    /// A complete inventory of every tab.
    case tabs([TerminalTab])
}

/// The one tab a session is bound to.
public struct TerminalTabTarget: Equatable, Hashable, Sendable {
    public let host: TerminalHost
    public let tabID: String
    /// `/dev/ttysNNN`.
    public let tty: String

    public init(host: TerminalHost, tabID: String, tty: String) {
        self.host = host
        self.tabID = tabID
        self.tty = tty
    }
}

/// Why a session has no tab binding. Every reason disables Open and typed input; none clears
/// attention or falls back to another tab.
public enum TerminalTabUnavailable: Error, Equatable, Hashable, Sendable {
    case sessionEnded
    /// This enabled host is running but its inventory failed, permission was denied, or it has
    /// not been read: it cannot be ruled out.
    case hostUnreadable(TerminalHost)
    /// No tab in the enabled inventories has the session's title.
    case titleNotFound
    /// `count` tabs across the enabled inventories have the session's title.
    case duplicateTitles(Int)
    /// The Codex session is not among the live tracked sessions passed in.
    case sessionNotLive
    /// Not exactly one live tracked Codex session renders this shortened identifier; `count` do.
    case sessionPrefixNotUnique(Int)
    /// The only tab showing the title is in a host that does not report its tty (Ghostty without
    /// `tty`), so ADR 0005's title rule decides it instead.
    case ttyUnknown(TerminalHost)
    /// The tab holds more than one pane (ADR 0004).
    case split
    /// A second read no longer shows the same tab, tty and title.
    case titleChanged
    /// The tab's tty has `count` foreground processes named `codex`, not exactly one.
    case foregroundProcesses(count: Int)
    /// `ps -t` for the tab's tty failed or was malformed.
    case processesUnreadable

    // Claude Code.
    /// No registry names the session's process.
    case processUnidentified
    /// Several roots or holders report the session.
    case processAmbiguous
    /// The registered process no longer exists.
    case processEnded
    /// The live process's start time is not the `procStart` Claude recorded (a reused PID), or
    /// could not be read.
    case processStartMismatch
    /// The process has no controlling tty.
    case noTerminal
    /// No tab of an enabled host has the process's tty: a multiplexer pane or a switched-off app.
    case ttyNotInEnabledHost
    /// `count` tabs across the enabled inventories report the process's tty.
    case duplicateTTYs(Int)
    /// The tab's title names a different session.
    case conflictingTitle
    /// The registered process is not in the tty's foreground process group.
    case agentProcessNotInForeground
}

/// The process Claude's session registry names for a session (ADR 0008, ADR 0013).
public enum TerminalSessionProcess: Equatable, Sendable {
    /// No registry lists the session as interactive, or its source carries no PID.
    case unidentified
    /// Several roots or holders report the session, so no one process can be followed.
    case ambiguous
    /// The one registry entry holding the session, with the `procStart` Claude recorded.
    case registered(ClaudeSessionRegistry.Process)
}

/// A fresh kernel read of the registered PID: its start time in Claude's `procStart` layout
/// (`ClaudeSessionRegistry.procStart`) and its controlling tty. nil fields could not be read.
public struct TerminalProcessObservation: Equatable, Sendable {
    public let pid: Int32
    public let procStart: String?
    public let tty: String?

    public init(pid: Int32, procStart: String?, tty: String?) {
        self.pid = pid
        self.procStart = procStart
        self.tty = tty
    }
}

public enum TerminalTabBinding: Equatable, Sendable {
    case bound(TerminalTabTarget)
    case unavailable(TerminalTabUnavailable)
}

extension TerminalHost {
    /// The hosts whose inventories list each tab's or pane's tty, so ADR 0013's rules bind there: every
    /// terminal, and tmux, whose `list-panes` gives each pane's tty (ADR 0014). Zellij and herdr list no
    /// pane tty and keep their own rules.
    public static let ttyBound: [TerminalHost] = terminals + [.tmux]

    /// The hosts whose titles count toward ADR 0013's Codex title uniqueness: every tty-listing host and
    /// Zellij, whose panes carry Codex titles but list no tty (#242). A Zellij pane is never bound by
    /// these rules: its only titled match reads `ttyUnknown(.zellij)`, and Zellij's own rule decides.
    public static let titleCounted: [TerminalHost] = ttyBound + [.zellij]
}

public enum TerminalTabBindingRules {
    /// ADR 0013's Codex CLI rule. Codex hook records are never read: under the shared daemon they
    /// name another tab (ADR 0012).
    ///
    /// - Parameters:
    ///   - liveSessions: every live tracked Codex session ID. This session must be among them, and
    ///     its shortened identifier must be unique among them.
    ///   - switches: only terminal hosts switched on are read; an inventory given for any other
    ///     host is ignored.
    ///   - inventories: the first fresh read of every enabled host.
    ///   - processes: `ps -t` per normalized tty (`TerminalForegroundProcesses.parse`), read after
    ///     `inventories`; a missing entry is an unreadable read.
    ///   - secondRead: every enabled host read again after `processes`.
    ///   - multiplexerClientTTYs: the ttys of enabled multiplexers' attached clients (tmux's
    ///     `client_tty`). A terminal tab on one of them mirrors the focused pane's title and runs the
    ///     client, so it is left out of the title count (ADR 0014, "Codex title count").
    /// - Returns: `.bound` only when every rule holds on both reads; otherwise the first failing
    ///   reason. The order of hosts and tabs in the inputs does not matter. A tmux pane binds as a
    ///   tab does, with its host `.tmux` and its `%pane` id (ADR 0014). A title decoy
    ///   (`isCodexTitleDecoy`) is left out of both reads' title counts (ADR 0013's 2026-10-13
    ///   amendment, #268).
    public static func codex(sessionID: String, liveness: HerdrSessionLiveness, liveSessions: Set<String>,
                             switches: TerminalHostSwitches, inventories: [TerminalHost: TerminalHostInventory],
                             processes: [String: [TerminalProcess]],
                             secondRead: [TerminalHost: TerminalHostInventory],
                             multiplexerClientTTYs: Set<String> = []) -> TerminalTabBinding {
        if liveness == .ended { return .unavailable(.sessionEnded) }
        guard let title = HerdrCodexBindingRules.title(forSession: sessionID.lowercased()) else {
            return .unavailable(.titleNotFound)
        }
        let live = Set(liveSessions.map { $0.lowercased() })
        // Otherwise a live sibling sharing the prefix would be counted as this session's tab.
        guard live.contains(sessionID.lowercased()) else { return .unavailable(.sessionNotLive) }
        let sharing = live
            .filter { HerdrCodexBindingRules.title(forSession: $0) == title }.count
        guard sharing == 1 else { return .unavailable(.sessionPrefixNotUnique(sharing)) }

        let target: TerminalTabTarget
        switch titledTab(title, switches: switches, inventories: inventories, processes: processes,
                         excluding: multiplexerClientTTYs) {
        case .success(let value): target = value
        case .failure(let reason): return .unavailable(reason)
        }
        guard let read = processes[target.tty] else { return .unavailable(.processesUnreadable) }
        let count = read.filter { $0.foreground && $0.name == HerdrCodexBindingRules.processName }.count
        guard count == 1 else { return .unavailable(.foregroundProcesses(count: count)) }

        switch titledTab(title, switches: switches, inventories: secondRead, processes: processes,
                         excluding: multiplexerClientTTYs) {
        case .success(let again) where again == target: return .bound(target)
        case .success: return .unavailable(.titleChanged)
        case .failure(.hostUnreadable(let host)): return .unavailable(.hostUnreadable(host))
        case .failure: return .unavailable(.titleChanged)
        }
    }

    /// ADR 0013's Claude Code rule: the session's own registered process, its tty, and exactly one
    /// tab on that tty across the enabled inventories. The title is not required; one naming a
    /// different session vetoes. Hook-recorded tab identifiers are never read.
    ///
    /// - Parameters:
    ///   - process: the registry entry holding the session, across every configured root.
    ///   - observed: a fresh kernel read of `process`'s PID, nil when it no longer exists.
    ///   - switches, inventories, processes: as for `codex`.
    /// - Returns: `.bound` only when every rule holds; otherwise the first failing reason.
    public static func claude(sessionID: String, liveness: HerdrSessionLiveness, process: TerminalSessionProcess,
                              observed: TerminalProcessObservation?, switches: TerminalHostSwitches,
                              inventories: [TerminalHost: TerminalHostInventory],
                              processes: [String: [TerminalProcess]]) -> TerminalTabBinding {
        if liveness == .ended { return .unavailable(.sessionEnded) }
        let registered: ClaudeSessionRegistry.Process
        switch process {
        case .unidentified: return .unavailable(.processUnidentified)
        case .ambiguous: return .unavailable(.processAmbiguous)
        case .registered(let value): registered = value
        }
        guard let observed, observed.pid == registered.pid else { return .unavailable(.processEnded) }
        // A PID reused by a later process never stands in for the registered one.
        if let recorded = registered.procStart, observed.procStart != recorded {
            return .unavailable(.processStartMismatch)
        }
        guard let tty = observed.tty.flatMap(GhosttyTTYMatch.normalizedTTY) else { return .unavailable(.noTerminal) }

        let onTTY: [HostTab]
        switch enabledTabs(switches: switches, inventories: inventories) {
        case .success(let tabs): onTTY = tabs.filter { $0.tab.tty.flatMap(GhosttyTTYMatch.normalizedTTY) == tty }
        case .failure(let reason): return .unavailable(reason)
        }
        guard let match = onTTY.first else { return .unavailable(.ttyNotInEnabledHost) }
        guard onTTY.count == 1 else { return .unavailable(.duplicateTTYs(onTTY.count)) }
        if titleNamesAnotherSession(match.tab.title, claudeSessionID: sessionID) {
            return .unavailable(.conflictingTitle)
        }
        guard match.tab.paneCount == 1 else { return .unavailable(.split) }
        guard let read = processes[tty] else { return .unavailable(.processesUnreadable) }
        guard read.contains(where: { $0.pid == registered.pid && $0.foreground }) else {
            return .unavailable(.agentProcessNotInForeground)
        }
        return .bound(TerminalTabTarget(host: match.host, tabID: match.tab.tabID, tty: tty))
    }

    /// True when `title` is a Steer Claude title for another session or any shortened Codex
    /// identifier. A free-form title, including a user's rename, never vetoes.
    static func titleNamesAnotherSession(_ title: String?, claudeSessionID: String) -> Bool {
        guard let title else { return false }
        if title.hasPrefix(ClaudeSetupRequirements.titlePrefix) {
            return title != ClaudeSetupRequirements.titlePrefix + claudeSessionID
        }
        return HerdrBindingRules.isShortenedCodexSessionTitle(title)
    }

    typealias HostTab = (host: TerminalHost, tab: TerminalTab)

    /// The one unsplit tab with a tty that shows `title` across the enabled inventories. A terminal tab
    /// whose tty is in `excluding` (a multiplexer client's) and a title decoy are not counted.
    private static func titledTab(_ title: String, switches: TerminalHostSwitches,
                                  inventories: [TerminalHost: TerminalHostInventory],
                                  processes: [String: [TerminalProcess]],
                                  excluding clientTTYs: Set<String>) -> Result<TerminalTabTarget, TerminalTabUnavailable> {
        let titled: [HostTab]
        switch titledTabs(title, switches: switches, inventories: inventories, processes: processes, excluding: clientTTYs) {
        case .success(let tabs): titled = tabs
        case .failure(let reason): return .failure(reason)
        }
        guard let match = titled.first else { return .failure(.titleNotFound) }
        guard titled.count == 1 else { return .failure(.duplicateTitles(titled.count)) }
        guard let tty = match.tab.tty.flatMap(GhosttyTTYMatch.normalizedTTY) else {
            return .failure(.ttyUnknown(match.host))
        }
        guard match.tab.paneCount == 1 else { return .failure(.split) }
        return .success(TerminalTabTarget(host: match.host, tabID: match.tab.tabID, tty: tty))
    }

    /// Every enabled tab or pane showing `title`, a terminal tab on one of `clientTTYs` (a multiplexer
    /// client's) and a title decoy (`isCodexTitleDecoy` over `processes`) left out; Zellij's rule counts
    /// with it too (#242).
    static func titledTabs(_ title: String, switches: TerminalHostSwitches,
                           inventories: [TerminalHost: TerminalHostInventory],
                           processes: [String: [TerminalProcess]],
                           excluding clientTTYs: Set<String>) -> Result<[HostTab], TerminalTabUnavailable> {
        enabledTabs(switches: switches, inventories: inventories).map { tabs in
            tabs.filter { entry in
                guard entry.tab.title == title, !isCodexTitleDecoy(entry.tab, processes: processes) else { return false }
                guard entry.host.kind == .terminal, !clientTTYs.isEmpty,
                      let tty = entry.tab.tty.flatMap(GhosttyTTYMatch.normalizedTTY) else { return true }
                return !clientTTYs.contains(tty)
            }
        }
    }

    /// ADR 0013's 2026-10-13 amendment (#268, the user's decision): a tab showing a Codex title is a
    /// decoy, and no candidate, when it is an unsplit tab with a tty whose `ps -t` read succeeded and shows
    /// no foreground `codex`. Every other titled tab still counts: one whose `ps` was not read or failed
    /// (it may run `codex`, so an unreadable read fails closed), a split (`ps` reads one pane's tty), one
    /// showing several foreground `codex`, and a tab or pane listing no tty (Ghostty without `tty` keeps
    /// ADR 0005's title rule; a Zellij pane keeps ADR 0014's).
    public static func isCodexTitleDecoy(_ tab: TerminalTab, processes: [String: [TerminalProcess]]) -> Bool {
        guard tab.paneCount == 1, let tty = tab.tty.flatMap(GhosttyTTYMatch.normalizedTTY),
              let read = processes[tty] else { return false }
        return !read.contains { $0.foreground && $0.name == HerdrCodexBindingRules.processName }
    }

    /// Every tab of every enabled terminal host and every pane of an enabled multiplexer whose titles
    /// count (`TerminalHost.titleCounted`: tmux and Zellij), in host order. Hosts switched off are never read, whatever
    /// `inventories` holds for them. The first enabled host whose inventory is unreadable or missing
    /// fails the whole read, because a session could be on a tab it holds.
    private static func enabledTabs(switches: TerminalHostSwitches,
                                    inventories: [TerminalHost: TerminalHostInventory])
        -> Result<[HostTab], TerminalTabUnavailable> {
        var tabs: [HostTab] = []
        for host in TerminalHost.titleCounted where switches.mayContact(host) {
            switch inventories[host] {
            case .notRunning?: continue
            case .tabs(let hostTabs)?: tabs += hostTabs.map { (host, $0) }
            case .unreadable?, nil: return .failure(.hostUnreadable(host))
            }
        }
        return .success(tabs)
    }
}
