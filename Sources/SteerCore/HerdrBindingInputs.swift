import Foundation

// Builds ADR 0008's binding inputs from what Steer already has: a herdr scan (HerdrSnapshot.swift)
// and Steer's own hook records carrying `herdr_pane_id`/`herdr_socket_path` (HookEventRecords.swift).
// Everything but `HerdrHookRecordReader` is a pure function of its inputs. SteerApp owns the
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
/// - `notInHerdr`: the session's newest Steer hook event carried no `HERDR_PANE_ID` (or Steer has
///   no hook event for it). herdr has nothing to say about it; the Ghostty tab rules apply.
/// - `bound`: every ADR 0008 rule held against the latest scan. Before any focus or key, the
///   caller must still revalidate against a fresh scan (ADR 0009 freshness).
/// - `unavailable`: the session runs in herdr, but Steer cannot target its pane. Open and relay
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
    /// Ghostty controls are off in this launch, so Steer does not contact herdr (ADR 0009 gate).
    case ghosttyControlsOff
    /// The gate is open but no herdr scan has completed since it opened.
    case notScanned
    /// The scan failed as a whole: herdr not found or not running, untrusted socket, protocol,
    /// timeout, malformed reply, or a failed `herdr integration status`/`lsof`.
    case herdr(HerdrUnavailableReason)
    /// The scan could not identify one herdr server process and its start time, so a restart since
    /// the hook record cannot be ruled out.
    case serverIdentityUnknown
    /// ADR 0008's rules did not hold for the session.
    case binding(HerdrBindingUnavailable)
    /// The session is Codex, and its binding is withheld. Codex can run hooks inside a shared
    /// app-server daemon, so the hook's `HERDR_PANE_ID` and herdr's `agent_session` can both name
    /// the pane of whichever CLI started the daemon (docs/evidence/herdr-daemon-hook-env.md).
    /// Temporary until issue #144 decides an independent signal.
    case codexPaneUnverified
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

    /// The binding's view of one decoded Steer hook event record, or nil when it is not one of
    /// Steer's hook events. The agent comes from the helper's `source`; the arrival time from
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
                                   socketPath: HerdrSocketPath.recorded(in: object), recordedAt: recordedAt)
    }

    /// `record` with its session ID normalized, so records built anywhere compare exactly.
    public static func normalized(_ record: HerdrHookPaneRecord) -> HerdrHookPaneRecord {
        let sessionID = normalizedSessionID(record.sessionID, agent: record.agent)
        guard sessionID != record.sessionID else { return record }
        return HerdrHookPaneRecord(sessionID: sessionID, agent: record.agent, paneID: record.paneID,
                                   socketPath: record.socketPath, recordedAt: record.recordedAt)
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
            ($0.sessionID, $0.agent.rawValue, $0.paneID ?? "", $0.socketPath ?? "")
                < ($1.sessionID, $1.agent.rawValue, $1.paneID ?? "", $1.socketPath ?? "")
        }
    }

    // MARK: - Contact gate (ADR 0009)

    /// The pane IDs recorded by live sessions' newest hook events: the gate's second input.
    public static func gatePaneIDs(records: [HerdrHookPaneRecord], liveSessions: Set<HerdrSessionKey>) -> Set<String> {
        Set(newestRecords(records).filter {
            liveSessions.contains(HerdrSessionKey(agent: $0.agent, sessionID: $0.sessionID))
        }.compactMap(\.paneID))
    }

    /// Steer may contact herdr only while Ghostty controls are on and at least one live session's
    /// newest hook event recorded a pane ID.
    public static func allowsContact(ghosttyControlsEnabled: Bool, paneIDs: Set<String>) -> Bool {
        ghosttyControlsEnabled && !paneIDs.isEmpty
    }

    // MARK: - Observation

    /// The rules' observation of one scan, or nil when the scan has no server start time.
    ///
    /// Steer only ever connects to the default socket, so the session is the default one. The
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
                                clients: clients, integrations: scan.integration.states, panes: panes)
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
    private static func panesInTab(_ tabID: String, snapshot: HerdrSnapshot) -> Int {
        guard let tab = snapshot.tab(tabID) else { return 0 }
        let layout = snapshot.layouts.filter { $0.tabID == tabID }.map(\.paneIDs.count).max() ?? 0
        let listed = snapshot.panes.filter { $0.tabID == tabID }.count
        return max(tab.paneCount, layout, listed)
    }

    // MARK: - Binding

    /// One session's binding.
    ///
    /// - Parameters:
    ///   - hookRecords: Steer's hook records for every herdr-capable session it read, any order.
    ///   - ghosttyControlsEnabled: Ghostty controls in this launch.
    ///   - outcome: the latest herdr scan, nil when none has completed since the gate opened.
    ///   - defaultSocketPath: herdr's default socket as the client resolves it.
    /// - Returns: `notInHerdr` when the session's newest hook event carried no pane ID; otherwise
    ///   `bound` only when Ghostty controls are on, the scan succeeded with a server start time,
    ///   and `HerdrBindingRules` bound the session.
    /// Withholds a Codex session's `bound` result (`codexPaneUnverified`); every other result is
    /// returned unchanged. Apply it wherever the app hands out a binding, before Open or relay
    /// reads it. Temporary until issue #144.
    public static func withholdingUnverifiedCodex(_ binding: HerdrSessionBinding,
                                                  for session: HerdrSessionKey) -> HerdrSessionBinding {
        guard session.agent == .codex, case .bound = binding else { return binding }
        return .unavailable(.codexPaneUnverified)
    }

    public static func binding(
        for session: HerdrSessionKey,
        liveness: HerdrSessionLiveness,
        hookRecords: [HerdrHookPaneRecord],
        ghosttyControlsEnabled: Bool,
        outcome: HerdrScanOutcome?,
        defaultSocketPath: String
    ) -> HerdrSessionBinding {
        let hookRecords = hookRecords.map(normalized)
        let newest = newestRecords(hookRecords).filter {
            $0.agent == session.agent && $0.sessionID == session.sessionID
        }
        guard newest.contains(where: { $0.paneID != nil }) else { return .notInHerdr }
        guard ghosttyControlsEnabled else { return .unavailable(.ghosttyControlsOff) }
        guard let outcome else { return .unavailable(.notScanned) }
        let scan: HerdrScan
        switch outcome {
        case .available(let value): scan = value
        case .unavailable(let reason): return .unavailable(.herdr(reason))
        }
        guard let observation = observation(from: scan) else { return .unavailable(.serverIdentityUnknown) }
        switch HerdrBindingRules.evaluate(sessionID: session.sessionID, liveness: liveness, hookRecords: hookRecords,
                                          observation: observation, defaultSocketPath: defaultSocketPath) {
        case .bound(let target): return .bound(target)
        case .unavailable(.notInHerdr), .unavailable(.noHookRecord): return .notInHerdr
        case .unavailable(let reason): return .unavailable(.binding(reason))
        }
    }
}

/// Reads the newest window of Steer's hook event records for the herdr binding. Each record file
/// is written once by an atomic move, so a decoded record is cached by path and the cache is
/// trimmed to the current window; a scan decodes only new files. Run it off the main actor.
public enum HerdrHookRecordReader {
    /// Matches the Claude observation reader's per-record bound.
    public static let maximumRecordSize = 128 * 1024

    public struct Result: Sendable {
        /// Each session's newest records (`HerdrBindingInputs.newestRecords`).
        public let records: [HerdrHookPaneRecord]
        /// Pass back into the next read.
        public let cache: [String: HerdrHookPaneRecord?]
    }

    /// Unreadable or overgrown directories contribute nothing, as with the other hook readers.
    public static func read(directories: [URL], cache: [String: HerdrHookPaneRecord?] = [:]) -> Result {
        var records: [HerdrHookPaneRecord] = []
        var kept: [String: HerdrHookPaneRecord?] = [:]
        for directory in directories {
            guard let entries = HookEventListing.entries(in: directory) else { continue }
            for url in HookEventListing.newestRecords(entries) {
                let path = url.path
                let record: HerdrHookPaneRecord?
                if let cached = cache[path] { record = cached } else { record = decode(url) }
                kept[path] = record
                if let record { records.append(record) }
            }
        }
        return Result(records: HerdrBindingInputs.newestRecords(records), cache: kept)
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
