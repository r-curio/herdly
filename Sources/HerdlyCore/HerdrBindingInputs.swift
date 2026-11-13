import Foundation

// Builds a CLI session's herdr binding from what Herdly already has: a herdr scan (HerdrSnapshot.swift),
// Herdly's own hook records carrying `herdr_pane_id`/`herdr_socket_path` (HookEventRecords.swift) for
// Claude Code (ADR 0008), and its live Codex sessions and Ghostty titles for Codex (ADR 0012).
// Everything but `HerdrHookRecordReader` is a pure function of its inputs. HerdlyApp owns the
// monitor, the scan schedule and the session liveness it passes in (Companion+Herdr.swift).

/// One CLI session as the herdr binding sees it. Codex session IDs are UUIDs written in either
/// case, so they are lowercased here and everywhere they meet `HerdrBindingRules`, which compares
/// exactly. Claude session IDs are compared as written.
public struct HerdrSessionKey: Hashable, Sendable {
    public let agent: HerdrAgentKind
    public let sessionID: String

    public init(agent: HerdrAgentKind, sessionID: String) {
        self.agent = agent
        self.sessionID = HerdrBindingInputs.normalizedSessionID(sessionID, agent: agent)
    }
}

/// A CLI session's herdr binding, as Open, question relay and presentation consume it.
///
/// - `notInHerdr`: herdr has nothing to say about the session; the Ghostty tab rules apply. For
///   Claude Code, its newest Herdly hook event carried no `HERDR_PANE_ID` (or Herdly has no hook
///   event for it). For Codex, no successful scan shows its title in a pane: herdr was not
///   contacted, the scan failed, or the title is in no pane, in which case the Ghostty rules find
///   no tab either and the session stays unavailable (ADR 0012 "Route").
/// - `bound`: every ADR 0008 (Claude) or ADR 0012 (Codex) rule held against the latest scan. Before
///   any focus or key, the caller must still revalidate against a fresh scan (ADR 0009 freshness).
/// - `unavailable`: the session runs in herdr, but Herdly cannot target its pane. Open and relay
///   are disabled; attention is never cleared and no other pane is used.
public enum HerdrSessionBinding: Equatable, Sendable {
    case notInHerdr
    case bound(HerdrPaneTarget)
    case unavailable(HerdrSessionUnavailable)

    public var target: HerdrPaneTarget? {
        if case .bound(let target) = self { return target }
        return nil
    }
}

/// Why a session that runs in herdr has no usable pane right now.
public enum HerdrSessionUnavailable: Equatable, Hashable, Sendable {
    /// herdr's switch is off, or no terminal is on, so Herdly does not contact herdr (product.md,
    /// "Agreed terminal host presentation").
    case herdrSwitchedOff
    /// Ghostty controls are off in this launch, so Herdly cannot reach herdr's client tab (ADR 0011).
    case ghosttyControlsOff
    /// The gate is open but no herdr scan has completed since it opened.
    case notScanned
    /// The scan failed as a whole: herdr not found or not running, untrusted socket, protocol,
    /// timeout, malformed reply, or a failed `herdr integration status`/`lsof`.
    case herdr(HerdrUnavailableReason)
    /// The scan could not identify one herdr server process and its start time, so a restart since
    /// the hook record cannot be ruled out.
    case serverIdentityUnknown
    /// The session's binding rules (ADR 0008 or ADR 0012) did not hold.
    case binding(HerdrBindingUnavailable)
}

public enum HerdrBindingInputs {
    // MARK: - Session identity

    /// Codex UUIDs lowercased; Claude session IDs unchanged.
    public static func normalizedSessionID(_ sessionID: String, agent: HerdrAgentKind) -> String {
        agent == .codex ? sessionID.lowercased() : sessionID
    }

    // MARK: - Hook records

    /// Longest Claude session ID accepted, matching the Claude hook helper's bound.
    static let maximumSessionID = 256

    /// The binding's view of one decoded Herdly hook event record, or nil when it is not one of
    /// Herdly's hook events. The agent comes from the helper's `source`; the arrival time from
    /// `captured_at`, falling back to `received_at`. `paneID` and `socketPath` are validated as
    /// `HerdrPaneID` and `HerdrSocketPath` read them, so a malformed value is absent.
    public static func hookRecord(from object: [String: Any]) -> HerdrHookPaneRecord? {
        guard let event = object["hook_event_name"] as? String, !event.isEmpty,
              let rawSession = object["session_id"] as? String else { return nil }
        let agent: HerdrAgentKind
        switch object["source"] as? String {
        case CodexSetupRequirements.helperSource?:
            guard UUID(uuidString: rawSession) != nil else { return nil }
            agent = .codex
        case ClaudeSetupRequirements.helperSource?:
            guard !rawSession.isEmpty, rawSession.utf8.count <= maximumSessionID else { return nil }
            agent = .claude
        default:
            return nil
        }
        let recordedAt: Double
        if let captured = object["captured_at"] as? Double, captured.isFinite, captured > 0 {
            recordedAt = captured
        } else if let received = (object["received_at"] as? String).flatMap(RolloutTimestamp.parse) {
            recordedAt = received
        } else {
            return nil
        }
        return HerdrHookPaneRecord(sessionID: normalizedSessionID(rawSession, agent: agent), agent: agent,
                                   paneID: HerdrPaneID.recorded(in: object),
                                   socketPath: HerdrSocketPath.recorded(in: object), recordedAt: recordedAt,
                                   zellijPane: TerminalHookIdentifiers.zellijPane(in: object))
    }

    /// `record` with its session ID normalized, so records built anywhere compare exactly.
    public static func normalized(_ record: HerdrHookPaneRecord) -> HerdrHookPaneRecord {
        let sessionID = normalizedSessionID(record.sessionID, agent: record.agent)
        guard sessionID != record.sessionID else { return record }
        return HerdrHookPaneRecord(sessionID: sessionID, agent: record.agent, paneID: record.paneID,
                                   socketPath: record.socketPath, recordedAt: record.recordedAt,
                                   zellijPane: record.zellijPane)
    }

    /// Each session's newest records, session IDs normalized: every record sharing the session's newest arrival time, so
    /// a disagreeing tie still reaches the rules as `conflictingHookRecords`. Identical records
    /// collapse. The result is sorted, so it does not depend on input order.
    public static func newestRecords(_ records: [HerdrHookPaneRecord]) -> [HerdrHookPaneRecord] {
        var newest: [HerdrSessionKey: [HerdrHookPaneRecord]] = [:]
        for record in records.map(normalized) {
            let key = HerdrSessionKey(agent: record.agent, sessionID: record.sessionID)
            guard let current = newest[key]?.first else { newest[key] = [record]; continue }
            if record.recordedAt > current.recordedAt {
                newest[key] = [record]
            } else if record.recordedAt == current.recordedAt, !(newest[key] ?? []).contains(record) {
                newest[key, default: []].append(record)
            }
        }
        return newest.values.flatMap { $0 }.sorted {
            ($0.sessionID, $0.agent.rawValue, $0.paneID ?? "", $0.socketPath ?? "",
             $0.zellijPane?.sessionName ?? "", $0.zellijPane?.paneID ?? "")
                < ($1.sessionID, $1.agent.rawValue, $1.paneID ?? "", $1.socketPath ?? "",
                   $1.zellijPane?.sessionName ?? "", $1.zellijPane?.paneID ?? "")
        }
    }

    // MARK: - Contact gate (ADR 0009)

    /// The pane IDs recorded by live Claude Code sessions' newest hook events: the hook-record half
    /// of the gate. Codex records never open it, because under the shared daemon their pane
    /// belongs to another CLI (ADR 0012).
    public static func gatePaneIDs(records: [HerdrHookPaneRecord], liveSessions: Set<HerdrSessionKey>) -> Set<String> {
        Set(newestRecords(records).filter {
            $0.agent == .claude && liveSessions.contains(HerdrSessionKey(agent: $0.agent, sessionID: $0.sessionID))
        }.compactMap(\.paneID))
    }

    /// The Codex half of the gate (ADR 0012): a Ghostty inventory is known, a Codex session in
    /// `codex.liveSessions` (live, or loaded by the daemon as a terminal session) renders a title, and
    /// herdr's default socket passes ADR 0009's trust check. A title already in
    /// Ghostty still opens it, so a scan can find the same title in herdr before either route acts.
    public static func codexGateOpens(_ codex: HerdrCodexTitles, defaultSocketTrusted: Bool) -> Bool {
        defaultSocketTrusted && codex.ghostty != nil && !codex.liveTitles.isEmpty
    }

    /// Herdly may contact herdr only while herdr's switch allows it (`TerminalHostSwitches.mayContact`)
    /// and either a live Claude session's newest hook event recorded a pane ID or the Codex half of
    /// the gate holds.
    public static func allowsContact(herdrEnabled: Bool, paneIDs: Set<String>, codexGate: Bool = false) -> Bool {
        herdrEnabled && (!paneIDs.isEmpty || codexGate)
    }

    /// What a scan inside the gate reads: Claude's integration status and process info for the panes
    /// live Claude sessions recorded, only when a Claude pane opened the gate, and process info for
    /// panes showing the title of a Codex session in `codex.liveSessions` (live, or loaded by the
    /// daemon as a terminal session) outside Ghostty.
    /// `clientHostCommands` are the enabled terminal hosts that may hold herdr's client (ADR 0014).
    public static func scanRequest(paneIDs: Set<String>, codex: HerdrCodexTitles,
                                   clientHostCommands: Set<String> = ["ghostty"]) -> HerdrScanRequest {
        HerdrScanRequest(includeIntegration: !paneIDs.isEmpty, processInfoTitles: codex.outsideGhostty,
                         processInfoPaneIDs: paneIDs, clientHostCommands: clientHostCommands)
    }

    // MARK: - Observation

    /// The rules' observation of one scan, or nil when the scan has no server start time.
    ///
    /// Herdly only ever connects to the default socket, so the session is the default one. The
    /// client verdict keeps only a count for a wrong client count, so that case becomes that many
    /// placeholder clients (negative process IDs) and the rules report the same count. A pane's
    /// `agent_session` is used only when its agent matches the pane's detected agent and it is an
    /// `id`; a `path` value can never equal a session ID, so it is kept distinguishable and the
    /// rules report a mismatch rather than a missing session.
    public static func observation(from scan: HerdrScan) -> HerdrObservation? {
        guard let startedAt = scan.serverStartedAt else { return nil }
        let clients: [HerdrClientObservation]
        switch scan.client {
        case .success(let client):
            clients = [HerdrClientObservation(processID: client.pid, ancestryReachesGhostty: true)]
        case .failure(.wrongClientCount(let count)):
            clients = (0..<max(0, count)).map { HerdrClientObservation(processID: -Int32($0 + 1), ancestryReachesGhostty: true) }
        case .failure(.nonGhosttyClient):
            clients = [HerdrClientObservation(processID: -1, ancestryReachesGhostty: false)]
        case .failure:
            clients = []
        }
        let snapshot = scan.snapshot
        let panes = snapshot.panes.map { pane -> HerdrPaneObservation in
            HerdrPaneObservation(paneID: pane.paneID, agent: agent(of: pane), agentSession: reportedSession(of: pane),
                                 panesInTab: panesInTab(pane.tabID, snapshot: snapshot),
                                 terminalTitle: pane.terminalTitle)
        }
        return HerdrObservation(protocolVersion: snapshot.protocolVersion,
                                server: HerdrServerInstance(startedAt: startedAt), session: .defaultSession,
                                clients: clients, integrations: scan.integration.states, panes: panes,
                                processInfo: scan.processInfo)
    }

    private static func agent(of pane: HerdrPane) -> HerdrAgentKind? {
        guard let detected = pane.agent.flatMap(HerdrAgentKind.init(rawValue:)) else { return nil }
        if let session = pane.agentSession, session.agent != detected.rawValue { return nil }
        return detected
    }

    private static func reportedSession(of pane: HerdrPane) -> String? {
        guard let session = pane.agentSession else { return nil }
        guard session.kind == "id" else { return "\(session.kind):\(session.value)" }
        return HerdrAgentKind(rawValue: session.agent).map { normalizedSessionID(session.value, agent: $0) }
            ?? session.value
    }

    /// Every pane in the tab, including panes hidden by a zoomed split: the largest of herdr's own
    /// count, the layout's panes and the snapshot's panes in that tab. A tab missing from the
    /// snapshot counts as zero, which the rules treat as unusable.
    static func panesInTab(_ tabID: String, snapshot: HerdrSnapshot) -> Int {
        guard let tab = snapshot.tab(tabID) else { return 0 }
        let layout = snapshot.layouts.filter { $0.tabID == tabID }.map(\.paneIDs.count).max() ?? 0
        let listed = snapshot.panes.filter { $0.tabID == tabID }.count
        return max(tab.paneCount, layout, listed)
    }

    // MARK: - Binding

    /// One session's binding.
    ///
    /// - Parameters:
    ///   - hookRecords: Herdly's hook records for every herdr-capable session it read, any order.
    ///     Only Claude Code records are read.
    ///   - herdrEnabled: herdr's switch allows contact (`TerminalHostSwitches.mayContact(.herdr)`).
    ///   - ghosttyControlsEnabled: Ghostty controls in this launch.
    ///   - gateOpen: whether ADR 0009's gate holds, so a nil `outcome` is a scan still pending rather
    ///     than herdr not being contacted.
    ///   - outcome: the latest herdr scan, nil when none has completed since the gate opened.
    ///   - defaultSocketPath: herdr's default socket as the client resolves it.
    ///   - codex: live Codex sessions and Ghostty titles, read only for a Codex session.
    ///   - claudeProcess: the Claude session's live interactive process as Claude's inventories name
    ///     it (`ClaudeSessionProcess(sessionID:inventories:)`); see `HerdrBindingRules.evaluate`.
    /// - Returns: for Claude Code, `notInHerdr` when the session's newest hook event carried no pane
    ///   ID; otherwise `bound` only when herdr's switch and Ghostty controls are on, the scan succeeded with a server
    ///   start time, and `HerdrBindingRules` bound the session. For Codex, see `codexBinding`.
    public static func binding(
        for session: HerdrSessionKey,
        liveness: HerdrSessionLiveness,
        hookRecords: [HerdrHookPaneRecord],
        herdrEnabled: Bool,
        ghosttyControlsEnabled: Bool,
        gateOpen: Bool,
        outcome: HerdrScanOutcome?,
        defaultSocketPath: String,
        codex: HerdrCodexTitles,
        claudeProcess: ClaudeSessionProcess = .unidentified
    ) -> HerdrSessionBinding {
        if session.agent == .codex {
            return codexBinding(for: session, liveness: liveness, herdrEnabled: herdrEnabled,
                                ghosttyControlsEnabled: ghosttyControlsEnabled,
                                gateOpen: gateOpen, outcome: outcome, codex: codex)
        }
        let hookRecords = hookRecords.map(normalized).filter { $0.agent == .claude }
        let newest = newestRecords(hookRecords).filter {
            $0.agent == session.agent && $0.sessionID == session.sessionID
        }
        guard newest.contains(where: { $0.paneID != nil }) else { return .notInHerdr }
        guard herdrEnabled else { return .unavailable(.herdrSwitchedOff) }
        guard ghosttyControlsEnabled else { return .unavailable(.ghosttyControlsOff) }
        guard let outcome else { return .unavailable(.notScanned) }
        let scan: HerdrScan
        switch outcome {
        case .available(let value): scan = value
        case .unavailable(let reason): return .unavailable(.herdr(reason))
        }
        guard let observation = observation(from: scan) else { return .unavailable(.serverIdentityUnknown) }
        switch HerdrBindingRules.evaluate(sessionID: session.sessionID, liveness: liveness, hookRecords: hookRecords,
                                          observation: observation, defaultSocketPath: defaultSocketPath,
                                          agentProcess: claudeProcess) {
        case .bound(let target): return .bound(target)
        case .unavailable(.notInHerdr), .unavailable(.noHookRecord): return .notInHerdr
        case .unavailable(let reason): return .unavailable(.binding(reason))
        }
    }

    /// A Codex session's binding and route (ADR 0012). The title decides the route:
    /// - in a pane of a successful scan and in no Ghostty terminal: `HerdrCodexBindingRules`;
    /// - in both: unavailable, because the route is unknown;
    /// - in no pane of a successful scan: `notInHerdr`, and the Ghostty tab rules apply.
    ///
    /// While the gate holds without a successful scan, herdr cannot be ruled out, so the session is
    /// unavailable; only `notRunning` counts as herdr showing nothing, since no server holds a pane.
    /// With herdr's switch or Ghostty controls off, no known Ghostty inventory, or the gate closed,
    /// herdr counts as not showing the title.
    public static func codexBinding(
        for session: HerdrSessionKey,
        liveness: HerdrSessionLiveness,
        herdrEnabled: Bool,
        ghosttyControlsEnabled: Bool,
        gateOpen: Bool,
        outcome: HerdrScanOutcome?,
        codex: HerdrCodexTitles
    ) -> HerdrSessionBinding {
        guard session.agent == .codex, herdrEnabled, ghosttyControlsEnabled, let ghostty = codex.ghostty,
              let title = HerdrCodexBindingRules.title(forSession: session.sessionID) else { return .notInHerdr }
        let scan: HerdrScan
        switch outcome {
        case .available(let value)?: scan = value
        case .unavailable(.notRunning)?: return .notInHerdr
        case .unavailable(let reason)?: return .unavailable(.herdr(reason))
        case nil: return gateOpen ? .unavailable(.notScanned) : .notInHerdr
        }
        guard scan.snapshot.panes.contains(where: { $0.terminalTitle == title }) else { return .notInHerdr }
        guard !ghostty.contains(title) else { return .unavailable(.binding(.titleInHerdrAndGhostty)) }
        switch HerdrCodexBindingRules.evaluate(sessionID: session.sessionID, liveness: liveness,
                                               liveSessions: codex.liveSessions, scan: scan) {
        case .bound(let target): return .bound(target)
        case .unavailable(let reason): return .unavailable(.binding(reason))
        }
    }
}

/// Reads the newest window of Herdly's hook event records for the herdr binding. Each record file
/// is written once by an atomic move, so a decoded record is cached by path and the cache is
/// trimmed to the current window; a scan decodes only new files, and a scan whose directories list
/// the same records as the last one returns that scan's result as it is. Run it off the main actor.
public enum HerdrHookRecordReader {
    /// Matches the Claude observation reader's per-record bound.
    public static let maximumRecordSize = 128 * 1024

    /// What one read keeps for the next.
    public struct Cache: Sendable {
        /// The decoded record of each path in the window; nil for a file that holds no usable record.
        /// Only the reader writes it: a holder that wants other records starts a new cache from
        /// them (`init(records:)`), which carries no earlier result.
        public private(set) var records: [String: HerdrHookPaneRecord?]
        /// The last read's result and the listings it was made from.
        fileprivate var lastRead: LastRead?

        public init(records: [String: HerdrHookPaneRecord?] = [:]) {
            self.records = records
        }
    }

    /// What one read returned, with the directory listings that led to it.
    fileprivate struct LastRead: Sendable {
        let listings: [DirectoryListing]
        let newest: [HerdrHookPaneRecord]
    }

    /// One directory as a read found it: unreadable, or listed under `HookEventListing`'s number for
    /// that listing, which names one exact sequence of records.
    fileprivate enum DirectoryListing: Equatable, Sendable {
        case unreadable(String)
        case records(String, number: UInt64)
    }

    public struct Result: Sendable {
        /// Each session's newest records (`HerdrBindingInputs.newestRecords`).
        public let records: [HerdrHookPaneRecord]
        /// Pass back into the next read.
        public let cache: Cache
        /// The last read's result was returned without looking at any record, for tests.
        let reused: Bool

        /// No directories to read.
        public static let empty = Result(records: [], cache: Cache(), reused: false)
    }

    /// Unreadable or overgrown directories contribute nothing, as with the other hook readers.
    public static func read(directories: [URL], cache: Cache = Cache()) -> Result {
        var windows: [ArraySlice<URL>] = []
        // Nil once a directory's listing has no number: nothing says it is the one read before.
        var listings: [DirectoryListing]? = []
        for directory in directories {
            let key = directory.standardizedFileURL.path
            guard let listing = HookEventListing.numberedRecords(in: directory) else {
                listings?.append(.unreadable(key))
                continue
            }
            if let number = listing.number { listings?.append(.records(key, number: number)) } else { listings = nil }
            windows.append(listing.records)
        }
        // The same records and the same decoded cache give the same result: a window holds
        // thousands of records, and walking them every scan was this reader's whole cost (#306).
        if let listings, let last = cache.lastRead, last.listings == listings {
            return Result(records: last.newest, cache: cache, reused: true)
        }
        var records: [HerdrHookPaneRecord] = []
        var kept: [String: HerdrHookPaneRecord?] = [:]
        for url in windows.joined() {
            let path = url.path
            let record: HerdrHookPaneRecord?
            if let cached = cache.records[path] { record = cached } else { record = decode(url) }
            kept[path] = record
            if let record { records.append(record) }
        }
        let newest = HerdrBindingInputs.newestRecords(records)
        var next = Cache(records: kept)
        next.lastRead = listings.map { LastRead(listings: $0, newest: newest) }
        return Result(records: newest, cache: next, reused: false)
    }

    private static func decode(_ url: URL) -> HerdrHookPaneRecord? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumRecordSize + 1), data.count <= maximumRecordSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return HerdrBindingInputs.hookRecord(from: object)
    }
}
