import Foundation

public struct Reminder: Codable, Equatable, Identifiable, Sendable {
    public let request_id: UUID
    public let session_id: UUID
    public let turn_id: UUID
    public let outcome: String
    public let source: AttentionSource?
    public let received_at: String?
    public let captured_at: Double?
    public let task_name: String?
    public let project: String?
    public let action: String?
    public let command: String?
    public let reason: String?
    public let long_text: String?
    public var id: UUID { request_id }

    public init(request_id: UUID, session_id: UUID, turn_id: UUID, outcome: String,
                received_at: String? = nil, captured_at: Double? = nil, source: AttentionSource? = nil,
                task_name: String? = nil, project: String? = nil, action: String? = nil,
                command: String? = nil, reason: String? = nil, long_text: String? = nil) {
        self.request_id = request_id
        self.session_id = session_id
        self.turn_id = turn_id
        self.outcome = outcome
        self.source = source
        self.received_at = received_at
        self.captured_at = captured_at
        self.task_name = task_name
        self.project = project
        self.action = action
        self.command = command
        self.reason = reason
        self.long_text = long_text
    }
}

public struct TurnIdentity: Hashable, Codable, Sendable {
    public let session: UUID
    public let turn: UUID
    public init(session: UUID, turn: UUID) {
        self.session = session
        self.turn = turn
    }
}

public struct ReminderScan: Sendable {
    public var reminders: [Reminder] = []
    public var attentionRequests: [AttentionRequest] = []
    /// Fresh pending requests with no companion receipt yet; the app issues receipts for them.
    public var awaitingReceipt: [ApprovalRequest] = []
    /// Native resolutions read from session rollouts for handed-back requests.
    public var resolvedRequests: [ApprovalResolution] = []
    /// Latest SessionEnd hook time per session; a request received before it cannot still be pending.
    public var sessionEnds: [UUID: Double] = [:]
    public var completed: Set<TurnIdentity> = []
    public var canceled: Set<TurnIdentity> = []
    public var cliEvents: [CLIEvent] = []
    public var cliCompletions: [CLICompletion] = []
    public var cliSessions: Set<UUID> = []
    public var liveCLISessions: Set<UUID> = []
    public var cliState = CLIState()
}

public struct ReminderQueue: Sendable {
    public private(set) var items: [Reminder] = []
    private var resolved: Set<TurnIdentity> = []
    public init() {}
    public func visibleItems(cliSessions: Set<UUID>, desktopForeground: Bool) -> [Reminder] {
        items.filter { !desktopForeground || cliSessions.contains($0.session_id) }
    }
    public mutating func apply(_ scan: ReminderScan) {
        resolved.formUnion(scan.completed)
        resolved.formUnion(scan.canceled)
        for item in scan.reminders where item.outcome == "no_decision" && !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
        items.removeAll { resolved.contains(TurnIdentity(session: $0.session_id, turn: $0.turn_id)) }
    }
}

public enum ReminderReader {
    private static func bounded(_ url: URL, limit: Int) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
        return bytes
    }

    public static func completed(in data: Data, session: UUID) -> Set<TurnIdentity> {
        outcomes(in: data, session: session).completed
    }

    private static func outcomes(in data: Data, session: UUID) -> (completed: Set<TurnIdentity>, canceled: Set<TurnIdentity>) {
        guard data.last == 10, data.count <= 32 * 1024 * 1024 else { return ([], []) }
        var completed: Set<TurnIdentity> = []
        var canceled: Set<TurnIdentity> = []
        for (index, line) in data.split(separator: 10, omittingEmptySubsequences: false).dropLast().enumerated() {
            guard line.count <= 1024 * 1024,
                  let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = event["payload"] as? [String: Any] else { return ([], []) }
            if index == 0 {
                guard event["type"] as? String == "session_meta",
                      let id = payload["id"] as? String, UUID(uuidString: id) == session else { return ([], []) }
                if let explicit = payload["session_id"],
                   (explicit as? String).flatMap(UUID.init(uuidString:)) != session { return ([], []) }
            } else if event["type"] as? String == "session_meta" { return ([], []) }
            if event["type"] as? String == "event_msg", let kind = payload["type"] as? String,
               ["task_complete", "turn_aborted"].contains(kind) {
                guard let id = payload["turn_id"] as? String, let turn = UUID(uuidString: id) else { return ([], []) }
                let identity = TurnIdentity(session: session, turn: turn)
                if kind == "task_complete" { completed.insert(identity) }
                else { canceled.insert(identity) }
            }
        }
        return (completed, canceled)
    }

    public static func scan(events: URL, rollouts: URL) -> ReminderScan {
        var result = ReminderScan()
        guard let files = try? FileManager.default.contentsOfDirectory(at: events, includingPropertiesForKeys: [.creationDateKey]),
              files.count <= 4096 else { return result }
        let ordered = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
        }
        var probes: [UUID: [ApprovalResolutionProbe]] = [:]
        for url in ordered where url.pathExtension == "approval" {
            if let bytes = bounded(url, limit: 65536), let item = try? JSONDecoder().decode(ApprovalRequest.self, from: bytes),
               [.pending, .noDecision].contains(item.outcome) {
                let source = AttentionSource.desktop
                let receipt = ApprovalReceipts.existing(for: item.id, in: events)
                if item.outcome == .pending, item.receivedAt == 0, receipt == nil {
                    // The helper stops waiting for a receipt after the connection timeout. A request first
                    // seen later than that has no live helper, so it is handed back without controls.
                    let published = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    if Date().timeIntervalSince(published) <= ApprovalTiming.connectionTimeout {
                        result.awaitingReceipt.append(item)
                        continue
                    }
                }
                // Restart revalidation: while the helper still reports `pending`, a saved decision record
                // decides the state. A helper-written `no_decision` outcome is authoritative on its own.
                let decided = item.outcome == .pending ? ApprovalDecisions.existing(for: item.id, in: events) : nil
                if decided?.decision.isUserDecision == true { continue }
                // A request that never got a receipt has no arrival time of its own; its file's creation
                // time stands in so ordering, session-end and rollout matching never treat it as ancient.
                let published = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate?.timeIntervalSince1970) ?? 0
                let receivedAt = receipt?.receivedAt ?? (item.receivedAt > 0 ? item.receivedAt : published)
                let expiresAt = receipt?.expiresAt ?? (item.expiresAt > 0 ? item.expiresAt : receivedAt + ApprovalTiming.handoffTimeout)
                let actionable = item.outcome == .pending && receipt != nil && decided == nil
                probes[item.sessionID, default: []].append(ApprovalResolutionProbe(requestID: item.id, turn: item.turnID,
                                                                                    command: item.details.command, notBefore: receivedAt))
                result.attentionRequests.append(AttentionRequest(id: item.id, source: source, session: item.sessionID, turn: item.turnID,
                                                                 arrivedAt: receivedAt, expiresAt: expiresAt,
                                                                 state: actionable ? .actionable : .handedBack,
                                                                 details: item.details))
                if item.outcome == .noDecision {
                    result.reminders.append(Reminder(request_id: item.id, session_id: item.sessionID, turn_id: item.turnID,
                                                     outcome: item.outcome.rawValue, captured_at: item.receivedAt, source: source,
                                                     task_name: item.details.taskName, project: item.details.project,
                                                     action: item.details.action, command: item.details.command,
                                                     reason: item.details.reason, long_text: item.details.longText))
                }
            } else if let bytes = bounded(url, limit: 65536), let item = try? JSONDecoder().decode(Reminder.self, from: bytes),
                      ["pending", "no_decision"].contains(item.outcome) {
                let arrival = item.captured_at ?? item.received_at.flatMap(RolloutTimestamp.parse)
                    ?? ((try? url.resourceValues(forKeys: [.creationDateKey]).creationDate?.timeIntervalSince1970) ?? 0)
                result.attentionRequests.append(AttentionRequest(id: item.id, source: item.source ?? .desktop,
                                                                 session: item.session_id, turn: item.turn_id,
                                                                 arrivedAt: arrival, state: item.outcome == "no_decision" ? .handedBack : .actionable,
                                                                 details: ApprovalDetails(taskName: item.task_name, project: item.project,
                                                                                          action: item.action, command: item.command,
                                                                                          reason: item.reason, longText: item.long_text)))
                if item.outcome == "no_decision" { result.reminders.append(item) }
            }
        }
        struct Hook: Decodable {
            let hook_event_name: String
            let session_id: UUID
            let turn_id: UUID?
            let received_at: String
        }
        let hooks = ordered.filter { $0.pathExtension == "json" }.compactMap { url -> Hook? in
            guard let bytes = bounded(url, limit: 65536) else { return nil }
            return try? JSONDecoder().decode(Hook.self, from: bytes)
        }
        for hook in hooks where hook.hook_event_name == "SessionEnd" {
            guard let ended = RolloutTimestamp.parse(hook.received_at) else { continue }
            result.sessionEnds[hook.session_id] = max(result.sessionEnds[hook.session_id] ?? 0, ended)
        }
        let sessions = Set(result.attentionRequests.map(\.session)).union(hooks.map(\.session_id))
        guard !sessions.isEmpty,
              let enumerator = FileManager.default.enumerator(at: rollouts, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { return result }
        var paths: [UUID: [URL]] = [:]
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count > 50000 { return result }
            guard url.pathExtension == "jsonl" else { continue }
            for session in sessions where url.lastPathComponent.lowercased().hasSuffix(session.uuidString.lowercased() + ".jsonl") {
                paths[session, default: []].append(url)
            }
        }
        // ponytail: bounded full rereads every two seconds; use cursors if histories grow.
        for (session, urls) in paths where urls.count == 1 {
            if let bytes = bounded(urls[0], limit: 32 * 1024 * 1024) {
                let terminal = outcomes(in: bytes, session: session)
                let finished = terminal.completed
                result.completed.formUnion(finished)
                result.canceled.formUnion(terminal.canceled)
                if let sessionProbes = probes[session] {
                    result.resolvedRequests += ApprovalResolutionReader.resolutions(in: bytes, session: session, probes: sessionProbes)
                }
                guard let first = bytes.split(separator: 10).first,
                      let event = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
                      event["type"] as? String == "session_meta",
                      let meta = event["payload"] as? [String: Any],
                      (meta["id"] as? String).flatMap(UUID.init(uuidString:)) == session,
                      meta["source"] as? String == "cli" else { continue }
                result.cliSessions.insert(session)
                let sessionHooks = hooks.filter { $0.session_id == session }.sorted { $0.received_at < $1.received_at }
                for hook in sessionHooks {
                    switch hook.hook_event_name {
                    case "SessionStart":
                        result.cliEvents.append(.sessionStarted(session: session, receivedAt: hook.received_at))
                    case "UserPromptSubmit":
                        if let turn = hook.turn_id {
                            result.cliEvents.append(.turnStarted(session: session, turn: turn, receivedAt: hook.received_at))
                        }
                    case "Stop":
                        if let turn = hook.turn_id {
                            result.cliEvents.append(.turnCompleted(session: session, turn: turn, receivedAt: hook.received_at))
                            if finished.contains(TurnIdentity(session: session, turn: turn)) {
                                result.cliCompletions.append(CLICompletion(session: session, turn: turn, receivedAt: hook.received_at))
                            }
                        }
                    case "SessionEnd":
                        result.cliEvents.append(.sessionEnded(session: session, receivedAt: hook.received_at))
                    default:
                        break
                    }
                }
            }
        }
        result.cliEvents.sort { $0.receivedAt < $1.receivedAt }
        result.cliState = CLIState.replay(result.cliEvents)
        result.liveCLISessions = result.cliState.liveSessions
        result.attentionRequests = result.attentionRequests.map { request in
            guard result.cliSessions.contains(request.session), request.source != .cli else { return request }
            return AttentionRequest(id: request.id, source: .cli, session: request.session, turn: request.turn,
                                    arrivedAt: request.arrivedAt,
                                    expiresAt: request.expiresAt, state: request.state, details: request.details)
        }
        result.cliCompletions.sort { $0.receivedAt < $1.receivedAt }
        return result
    }
}
