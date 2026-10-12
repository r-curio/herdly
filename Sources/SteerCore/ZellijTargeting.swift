import Foundation

// Zellij targeting (#242): ADR 0014's pane binding (Codex by title, `pane_command` and a `codex` under the
// session's server; Claude by hook pane id and ancestry), its layout and client checks, its two-layer
// Open with the `<session> | ` host-title veto, and ADR 0016's visible test for a pane. Pure; SteerApp
// runs the commands (ZellijRunner.swift).

// MARK: - Snapshot

/// One read of every live session in the default socket directory, with the process table.
public struct ZellijSnapshot: Equatable, Sendable {
    public let socketDirectory: String
    public let sessions: [ZellijSession]
    public let processes: ZellijProcessTable

    public init(socketDirectory: String, sessions: [ZellijSession], processes: ZellijProcessTable) {
        self.socketDirectory = socketDirectory
        self.sessions = sessions
        self.processes = processes
    }

    public func session(_ name: String) -> ZellijSession? {
        sessions.first { $0.name == name }
    }

    /// The session's one server in the default directory, with its start time; nil when not found.
    public func server(_ session: String) -> ZellijServerIdentity? {
        processes.server(session: session, socketDirectory: socketDirectory)
    }

    /// ADR 0013's inventory with the pane in place of the tab: one entry per terminal pane, with no tty
    /// (Zellij lists none) and its tab's visible pane count, so a split is visible. Plugins never count.
    public var inventory: TerminalHostInventory {
        .tabs(sessions.flatMap { session in
            session.panes.filter { !$0.isPlugin }.map { pane in
                TerminalTab(tabID: ZellijPaneTarget(session: session.name, paneID: pane.id).handle, tty: nil,
                            title: pane.title, paneCount: session.tab(pane.tabID)?.visiblePanes ?? 0)
            }
        })
    }

    /// The ttys of the `zellij` client processes: host tabs ADR 0014 leaves out of the Codex title count.
    public var clientTTYs: Set<String> {
        Set(processes.clientProcesses.compactMap(\.tty))
    }

    /// Every terminal pane carrying `title`, across sessions.
    public func panes(titled title: String) -> [ZellijPaneTarget] {
        sessions.flatMap { session in
            session.panes.filter { !$0.isPlugin && $0.title == title }.map { ZellijPaneTarget(session: session.name, paneID: $0.id) }
        }
    }
}

/// One read of the default socket directory, from SteerApp's side.
public enum ZellijRead: Equatable, Sendable {
    /// No contract directory, or no socket in it accepts connections: no session runs.
    case notRunning
    /// No `zellij` at the fixed locations.
    case binaryNotFound
    /// The installed CLI is older than 0.44.1 (or its version could not be read: nil). `running`: a
    /// `zellij --server` process runs, so a session could exist that Steer cannot reach.
    case unsupportedVersion(ZellijVersion?, running: Bool)
    /// A directory or socket fails the trust check, or a server runs as another user.
    case untrustedSocket
    /// A command failed, timed out or printed a malformed listing, or a session name cannot be addressed.
    case unreadable
    case snapshot(ZellijSnapshot)

    /// ADR 0013's inventory: Zellij that may be running but cannot be read holds every session it could
    /// hold unavailable; one not running holds nothing.
    public var inventory: TerminalHostInventory {
        switch self {
        case .notRunning: .notRunning
        case .unsupportedVersion(_, let running): running ? .unreadable : .notRunning
        case .binaryNotFound, .untrustedSocket, .unreadable: .unreadable
        case .snapshot(let snapshot): snapshot.inventory
        }
    }

    public var snapshot: ZellijSnapshot? {
        if case .snapshot(let value) = self { return value }
        return nil
    }
}

// MARK: - Binding

/// One Zellij terminal pane: its session's name and its terminal id. `handle` is how it travels as a
/// tab id or typed-input pane id; a session name never contains `/`.
public struct ZellijPaneTarget: Equatable, Hashable, Sendable {
    public let session: String
    public let paneID: Int

    public init(session: String, paneID: Int) {
        self.session = session
        self.paneID = paneID
    }

    /// `terminal_<id>`, as `--pane-id` and `focus-pane-id` take it.
    public var paneArgument: String { "terminal_\(paneID)" }
    public var handle: String { "\(session)/\(paneArgument)" }

    public init?(handle: String) {
        let parts = handle.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let session = ZellijSessionName.validated(String(parts[0])),
              parts[1].hasPrefix("terminal_") else { return nil }
        let digits = parts[1].dropFirst("terminal_".count)
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int(digits) else {
            return nil
        }
        self.init(session: session, paneID: id)
    }
}

/// Why a session Zellij could hold has no pane. Every reason disables Open's exact path and typed input;
/// none clears attention or picks another pane.
public enum ZellijUnavailable: Error, Equatable, Hashable, Sendable {
    /// A shared ADR 0013 reason: an unreadable host, duplicate titles, an ended or unidentified process.
    case terminal(TerminalTabUnavailable)
    /// The titled pane's `pane_command` does not start with `codex`.
    case notCodexCommand
    /// No one `zellij --server` for the session in the default directory (renamed, or another directory).
    case serverNotFound
    /// No `codex` process's ancestry reaches the session's server.
    case codexNotUnderServer
    /// A second read no longer shows the same pane with the title.
    case titleChanged
    /// The pane's tab shows more than one pane.
    case split
    // Claude Code.
    /// The session's newest hook records name different panes.
    case conflictingHookRecords
    /// The recorded pane is not a terminal pane of the recorded session.
    case hookPaneMissing
    /// The registered process runs under a Zellij server other than the recorded session's.
    case processNotUnderServer
    /// The pane's title names a different session.
    case conflictingTitle
}

/// A CLI session's Zellij binding (ADR 0014).
public enum ZellijBinding: Equatable, Sendable {
    /// Zellij has nothing to say: no Zellij pane carries the Codex title, or the Claude session's newest
    /// hook event recorded no Zellij pane, or its process runs under no Zellij server. Other hosts' rules decide.
    case notInZellij
    case bound(ZellijPaneTarget)
    case unavailable(ZellijUnavailable)
}

public enum ZellijBindingRules {
    /// ADR 0014's Codex rule over ADR 0013's shared inputs, Zellij's inventory among them, and the
    /// Zellij read behind it: the one pane across every enabled host showing the session's title is a
    /// Zellij pane, the first word of its `pane_command` is `codex`, a `codex` process's ancestry reaches
    /// the session's server, and a second read shows the same pane. Codex hook records are never read.
    public static func codex(sessionID: String, liveness: HerdrSessionLiveness, liveSessions: Set<String>,
                             switches: TerminalHostSwitches, inventories: [TerminalHost: TerminalHostInventory],
                             processes: [String: [TerminalProcess]], secondRead: [TerminalHost: TerminalHostInventory],
                             multiplexerClientTTYs: Set<String>, zellij: ZellijSnapshot?) -> ZellijBinding {
        guard switches.mayContact(.zellij), let zellij,
              let title = HerdrCodexBindingRules.title(forSession: sessionID.lowercased()),
              !zellij.panes(titled: title).isEmpty else { return .notInZellij }
        let base = TerminalTabBindingRules.codex(sessionID: sessionID, liveness: liveness, liveSessions: liveSessions,
                                                 switches: switches, inventories: inventories, processes: processes,
                                                 secondRead: secondRead, multiplexerClientTTYs: multiplexerClientTTYs)
        switch base {
        case .bound: return .notInZellij
        case .unavailable(.ttyUnknown(.zellij)): break
        case .unavailable(let reason): return .unavailable(.terminal(reason))
        }
        let carriers = zellij.panes(titled: title)
        guard carriers.count == 1, let target = carriers.first, let session = zellij.session(target.session),
              let pane = session.terminalPane(target.paneID) else { return .unavailable(.terminal(.duplicateTitles(carriers.count))) }
        guard commandName(pane.paneCommand) == HerdrCodexBindingRules.processName else { return .unavailable(.notCodexCommand) }
        guard let server = zellij.server(target.session) else { return .unavailable(.serverNotFound) }
        guard !zellij.processes.processes(named: HerdrCodexBindingRules.processName, under: server.pid).isEmpty else {
            return .unavailable(.codexNotUnderServer)
        }
        switch TerminalTabBindingRules.titledTabs(title, switches: switches, inventories: secondRead,
                                                  excluding: multiplexerClientTTYs) {
        case .failure(.hostUnreadable(let host)): return .unavailable(.terminal(.hostUnreadable(host)))
        case .failure: return .unavailable(.titleChanged)
        case .success(let again):
            guard again.count == 1, again[0].host == .zellij, again[0].tab.tabID == target.handle else {
                return .unavailable(.titleChanged)
            }
        }
        guard session.tab(pane.tabID)?.visiblePanes == 1, !pane.isFloating else { return .unavailable(.split) }
        return .bound(target)
    }

    /// ADR 0014's Claude rule: two signals agree. The session's newest Steer hook records name one
    /// terminal pane of one session, and the registered process (with `procStart`) runs under that
    /// session's server. A pane title naming a different session vetoes; the title is not required.
    ///
    /// - Parameters:
    ///   - newestRecords: this session's newest hook records (`HerdrBindingInputs.newestRecords`).
    ///   - zellij: the latest read, nil while Zellij may not be contacted or has not been read.
    public static func claude(sessionID: String, liveness: HerdrSessionLiveness, newestRecords: [HerdrHookPaneRecord],
                              process: TerminalSessionProcess, observed: TerminalProcessObservation?,
                              zellij: ZellijRead?) -> ZellijBinding {
        let recorded = Set(newestRecords.filter { $0.agent == .claude && $0.sessionID == sessionID }.map(\.zellijPane))
        guard !recorded.isEmpty else { return .notInZellij }
        guard recorded.count == 1, let only = recorded.first else { return .unavailable(.conflictingHookRecords) }
        guard let hookPane = only else { return .notInZellij }
        if liveness == .ended { return .unavailable(.terminal(.sessionEnded)) }
        let snapshot: ZellijSnapshot
        switch zellij {
        case .notRunning?, .unsupportedVersion(_, running: false)?: return .notInZellij
        case .snapshot(let value)?: snapshot = value
        case .binaryNotFound?, .unsupportedVersion?, .untrustedSocket?, .unreadable?, nil:
            return .unavailable(.terminal(.hostUnreadable(.zellij)))
        }
        let registered: ClaudeSessionRegistry.Process
        switch process {
        case .unidentified: return .unavailable(.terminal(.processUnidentified))
        case .ambiguous: return .unavailable(.terminal(.processAmbiguous))
        case .registered(let value): registered = value
        }
        guard let observed, observed.pid == registered.pid else { return .unavailable(.terminal(.processEnded)) }
        if let start = registered.procStart, observed.procStart != start { return .unavailable(.terminal(.processStartMismatch)) }
        // The servers above the process: none means it is not in Zellij at all, whatever it inherited.
        let ancestors = Set(snapshot.processes.ancestors(of: registered.pid) ?? [])
        let serversAbove = snapshot.processes.processes.values.filter {
            $0.name == ZellijProcessTable.processName && ancestors.contains($0.pid)
        }
        guard !serversAbove.isEmpty else { return .notInZellij }
        guard let server = snapshot.server(hookPane.sessionName), ancestors.contains(server.pid) else {
            return .unavailable(.processNotUnderServer)
        }
        guard let session = snapshot.session(hookPane.sessionName), let id = Int(hookPane.paneID),
              let pane = session.terminalPane(id) else { return .unavailable(.hookPaneMissing) }
        if TerminalTabBindingRules.titleNamesAnotherSession(pane.title, claudeSessionID: sessionID) {
            return .unavailable(.conflictingTitle)
        }
        guard session.tab(pane.tabID)?.visiblePanes == 1, !pane.isFloating else { return .unavailable(.split) }
        return .bound(ZellijPaneTarget(session: session.name, paneID: id))
    }

    /// The basename of `command`'s first word, `~/` and absolute paths included.
    static func commandName(_ command: String?) -> String? {
        guard let first = command?.split(separator: " ", maxSplits: 1).first, !first.isEmpty else { return nil }
        return (String(first) as NSString).lastPathComponent
    }
}

// MARK: - Layout, clients and nesting

/// How one Zellij command ended, from SteerApp's side (`ZellijRunner.run`).
public enum ZellijCommandOutcome: Equatable, Sendable {
    /// Exit status 0, with this stdout.
    case succeeded(String)
    /// A non-zero exit, with stderr (bounded): Zellij refused, or reported an error such as "already focused".
    case failed(stderr: String)
    /// No exit within the bounded wait; the process was terminated. It may have acted.
    case timedOut
    /// The binary could not be started.
    case notLaunched
}

/// Why a bound Zellij pane cannot be targeted. Each is a layout or pane state, never a reason to pick
/// another pane.
public enum ZellijPaneUnavailable: Error, Equatable, Hashable, Sendable {
    /// The pane is no longer a terminal pane of its session.
    case paneGone
    /// Its program exited (a held pane).
    case paneExited
    /// Its tab shows more than one pane, or it floats (ADR 0004, ADR 0014).
    case split
    /// A `zellij` client runs inside another multiplexer's pane, or its ancestry could not be read.
    case nested
    /// No one server for its session in the default directory.
    case serverNotFound
    /// No client is attached to its session.
    case noClient
    /// `count` clients are attached to its session.
    case clients(Int)
    /// `count` `zellij` client processes run for this user, so none can be tied to the session.
    case clientProcesses(Int)
}

/// The one client an Open moves and raises: Zellij's id for it (from `list-clients`) and its process.
public struct ZellijOpenClient: Equatable, Sendable {
    public let clientID: String
    public let pid: Int32
    /// Normalized `/dev/ttysNNN`: the host tab's.
    public let tty: String

    public init(clientID: String, pid: Int32, tty: String) {
        self.clientID = clientID
        self.pid = pid
        self.tty = tty
    }
}

public enum ZellijLayout {
    /// ADR 0014's pane layer: a live terminal pane, alone and tiled in its tab, its session's server
    /// found, and no `zellij` client nested in another multiplexer. Enough for typed input; Open also
    /// needs `client(for:in:)` and the host-tab join.
    public static func paneLayer(_ target: ZellijPaneTarget, in snapshot: ZellijSnapshot) -> ZellijPaneUnavailable? {
        guard let session = snapshot.session(target.session), let pane = session.terminalPane(target.paneID) else {
            return .paneGone
        }
        if pane.exited { return .paneExited }
        guard !pane.isFloating, session.tab(pane.tabID)?.visiblePanes == 1 else { return .split }
        guard snapshot.server(target.session) != nil else { return .serverNotFound }
        // Zellij ties no client to a session, so any nested client could be this session's.
        if snapshot.processes.clientProcesses.contains(where: snapshot.processes.isNested) { return .nested }
        return nil
    }

    /// The one client of the pane's session, and the one `zellij` client process for the user (ADR 0014):
    /// zero or several of either are unavailable.
    public static func client(for target: ZellijPaneTarget, in snapshot: ZellijSnapshot) -> Result<ZellijOpenClient, ZellijPaneUnavailable> {
        guard let session = snapshot.session(target.session) else { return .failure(.paneGone) }
        guard let client = session.clients.first else { return .failure(.noClient) }
        guard session.clients.count == 1 else { return .failure(.clients(session.clients.count)) }
        let processes = snapshot.processes.clientProcesses
        guard processes.count == 1, let process = processes.first, let tty = process.tty else {
            return .failure(.clientProcesses(processes.count))
        }
        return .success(ZellijOpenClient(clientID: client.clientID, pid: process.pid, tty: tty))
    }
}

// MARK: - Open (ADR 0014 "Open sequence")

/// What revalidation established and every later step must still hold: the bound pane, the one client
/// and its process, the session's server, and where the client's tty joins.
public struct ZellijOpenPlan: Equatable, Sendable {
    public let pane: ZellijPaneTarget
    public let client: ZellijOpenClient
    public let server: ZellijServerIdentity
    public let host: MultiplexerHostTarget

    public init(pane: ZellijPaneTarget, client: ZellijOpenClient, server: ZellijServerIdentity, host: MultiplexerHostTarget) {
        self.pane = pane
        self.client = client
        self.server = server
        self.host = host
    }
}

public enum ZellijOpen {
    /// Step 1 over a fresh binding and the Zellij read behind it. `join` is called only once the pane and
    /// its one client hold, with that client's tty; `hostTitle` reads the joined tab's title from the same
    /// fresh inventories. A host tab not titled `<session> | ` vetoes the join (ADR 0014). A binding miss
    /// resolves as any tab's (ADR 0015); a layout or client problem falls back, walking every client.
    public static func plan(_ binding: ZellijBinding, snapshot: ZellijSnapshot, join: (String) -> MultiplexerHostJoin,
                            hostTitle: (TerminalTabTarget) -> String?) -> Result<ZellijOpenPlan, OpenMiss> {
        let pane: ZellijPaneTarget
        switch binding {
        case .notInZellij: return .failure(.fallBack(.noUniqueTarget, candidates: 1))
        case .unavailable(let reason): return .failure(miss(reason))
        case .bound(let target): pane = target
        }
        guard ZellijLayout.paneLayer(pane, in: snapshot) == nil, let server = snapshot.server(pane.session),
              case .success(let client) = ZellijLayout.client(for: pane, in: snapshot) else {
            return .failure(.fallBack(.unsupportedLayout, candidates: 1))
        }
        switch join(client.tty) {
        case .tab(let tab):
            guard let title = hostTitle(tab), title.hasPrefix(titlePrefix(pane.session)) else {
                return .failure(.fallBack(.noUniqueTarget, candidates: 1))
            }
            return .success(ZellijOpenPlan(pane: pane, client: client, server: server, host: .tab(tab)))
        case .ghostty:
            return .success(ZellijOpenPlan(pane: pane, client: client, server: server, host: .ghostty))
        case .miss(let miss):
            return .failure(miss)
        }
    }

    /// ADR 0015's categories for a Zellij binding miss.
    public static func miss(_ reason: ZellijUnavailable) -> OpenMiss {
        switch reason {
        case .terminal(let shared): TerminalTabOpen.miss(shared)
        case .split: .fallBack(.unsupportedLayout, candidates: 1)
        case .notCodexCommand, .serverNotFound, .codexNotUnderServer, .titleChanged, .conflictingHookRecords,
             .hookPaneMissing, .processNotUnderServer, .conflictingTitle:
            .fallBack(.noUniqueTarget, candidates: 1)
        }
    }

    /// Zellij titles each client's host terminal `<session> | <focused pane title>`.
    public static func titlePrefix(_ session: String) -> String { "\(session) | " }

    /// The veto for a host tab Ghostty's own join chose at raise time.
    public static func hostTitleAllowed(_ title: String?, for plan: ZellijOpenPlan) -> Bool {
        title?.hasPrefix(titlePrefix(plan.pane.session)) ?? false
    }

    /// Step 2, sent once and never retried. It moves the session's last active client, which is the one
    /// client only once that client has typed (zellij-live.md); step 3 says whether it moved.
    public static func focusArguments(_ plan: ZellijOpenPlan) -> [String] {
        ["--session", plan.pane.session, "action", "focus-pane-id", plan.pane.paneArgument]
    }

    /// Step 2's result. "already focused" exits 2 and counts only if step 3 verifies it; any other
    /// failure falls back without touching the host tab; a binary that no longer starts is unreadable.
    public static func focused(_ outcome: ZellijCommandOutcome) -> OpenMiss? {
        switch outcome {
        case .succeeded: nil
        case .failed(let stderr) where stderr.contains("is already focused"): nil
        case .failed, .timedOut: .fallBack(.notVerified, candidates: 1)
        case .notLaunched: .unavailable(.hostUnreadable(.zellij))
        }
    }

    /// Step 3 over a fresh read and the binding re-run on it: the same server, the same client (its id
    /// and process) still the only one, now on the pane, whose layout still holds.
    public static func verifyPane(_ plan: ZellijOpenPlan, read: ZellijRead, binding: ZellijBinding) -> OpenMiss? {
        let notVerified = OpenMiss.fallBack(.notVerified, candidates: 1)
        guard binding == .bound(plan.pane), let snapshot = read.snapshot,
              ZellijLayout.paneLayer(plan.pane, in: snapshot) == nil, snapshot.server(plan.pane.session) == plan.server,
              case .success(let client) = ZellijLayout.client(for: plan.pane, in: snapshot), client == plan.client,
              snapshot.session(plan.pane.session)?.clients.first?.paneID == plan.pane.paneID else { return notVerified }
        return nil
    }

    /// Every `zellij` client process, which an Open fallback walks to the app hosting it (ADR 0015).
    public static func fallbackClientPIDs(in snapshot: ZellijSnapshot?) -> [Int32] {
        snapshot?.processes.clientProcesses.map(\.pid) ?? []
    }

    /// ADR 0016's sequence with Zellij's two layers, each step at most once, stopping at the first failure.
    /// Failures of the host steps after a verified pane are a partial reach (`TmuxOpen.hostRaised`).
    public static func run(now: @escaping () -> Double,
                           revalidate: @escaping () async -> Result<ZellijOpenPlan, OpenMiss>,
                           focus: @escaping (ZellijOpenPlan) async -> OpenMiss?,
                           verifyPane: @escaping (ZellijOpenPlan) async -> OpenMiss?,
                           raise: @escaping (ZellijOpenPlan) async -> OpenMiss?,
                           verifyHost: @escaping (ZellijOpenPlan) async -> OpenMiss?,
                           isolation: isolated (any Actor)? = #isolation) async -> TerminalOpenRun<ZellijOpenPlan, OpenMiss> {
        await TerminalOpenSequence.run(TerminalOpenSteps(
            now: now, revalidate: { _ in await revalidate() }, focusPane: focus, verifyPane: verifyPane,
            raise: { TmuxOpen.hostRaised(await raise($0)) }, verify: { TmuxOpen.hostRaised(await verifyHost($0)) }))
    }
}

// MARK: - Visits

public enum ZellijVisibility {
    /// ADR 0016's test for a Zellij pane: the frontmost host's visible tab (`hostFront`, by its tty) runs
    /// the one `zellij` client process, exactly one session lists exactly one client, and the pane that
    /// client focuses passes the pane layer. Whether it is a session's bound pane is the caller's
    /// comparison. A Zellij or host read that failed is unknown.
    public static func reading(_ snapshot: ZellijSnapshot?,
                               hostFront: TerminalVisibilityReading<String>) -> TerminalVisibilityReading<String> {
        guard let snapshot else { return .unknown }
        switch hostFront {
        case .unknown: return .unknown
        case .nothing, .unchecked: return .nothing
        case .visible(let tty):
            let processes = snapshot.processes.clientProcesses
            guard processes.count == 1, processes[0].tty == tty else { return .nothing }
            let attached = snapshot.sessions.filter { !$0.clients.isEmpty }
            guard attached.count == 1, let session = attached.first, session.clients.count == 1,
                  let paneID = session.clients[0].paneID else { return .nothing }
            let target = ZellijPaneTarget(session: session.name, paneID: paneID)
            guard ZellijLayout.paneLayer(target, in: snapshot) == nil else { return .nothing }
            return .visible(target.handle)
        }
    }
}
