import Foundation

public enum AttentionSource: String, Codable, Sendable {
    case desktop
    case cli
}

public enum AttentionRequestState: Equatable, Codable, Sendable {
    case actionable
    case handedBack
}

public struct AttentionRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let source: AttentionSource
    public let session: UUID
    public let turn: UUID
    public let arrivedAt: Double
    public let expiresAt: Double
    public let details: ApprovalDetails?
    public fileprivate(set) var state: AttentionRequestState
    public var identity: RequestIdentity { RequestIdentity(source: source, request: id) }

    public init(id: UUID, source: AttentionSource = .desktop, session: UUID, turn: UUID, arrivedAt: Double,
                handoffAfter: Double = ApprovalTiming.handoffTimeout, state: AttentionRequestState = .actionable,
                details: ApprovalDetails? = nil) {
        self.init(id: id, source: source, session: session, turn: turn, arrivedAt: arrivedAt,
                  expiresAt: arrivedAt + handoffAfter, state: state, details: details)
    }

    public init(id: UUID, source: AttentionSource = .desktop, session: UUID, turn: UUID, arrivedAt: Double,
                expiresAt: Double, state: AttentionRequestState = .actionable,
                details: ApprovalDetails? = nil) {
        self.id = id
        self.source = source
        self.session = session
        self.turn = turn
        self.arrivedAt = arrivedAt
        self.expiresAt = expiresAt
        self.state = state
        self.details = details
    }

    fileprivate mutating func expire(at now: Double) {
        if state == .actionable && now >= expiresAt { state = .handedBack }
    }
}

public struct RequestIdentity: Hashable, Codable, Sendable {
    public let source: AttentionSource
    public let request: UUID
    public init(source: AttentionSource, request: UUID) {
        self.source = source
        self.request = request
    }
}

public struct CompletionIdentity: Hashable, Codable, Sendable {
    public let source: AttentionSource
    public let session: UUID
    public let turn: UUID
    public init(source: AttentionSource, session: UUID, turn: UUID) {
        self.source = source
        self.session = session
        self.turn = turn
    }
}

public struct AttentionTurnIdentity: Hashable, Codable, Sendable {
    public let source: AttentionSource
    public let session: UUID
    public let turn: UUID
    public init(source: AttentionSource, session: UUID, turn: UUID) {
        self.source = source
        self.session = session
        self.turn = turn
    }
}

public struct AttentionCompletion: Identifiable, Equatable, Sendable {
    public let source: AttentionSource
    public let session: UUID
    public let turn: UUID
    public let arrivedAt: Double
    public var id: CompletionIdentity { CompletionIdentity(source: source, session: session, turn: turn) }

    public init(source: AttentionSource, session: UUID, turn: UUID, arrivedAt: Double) {
        self.source = source
        self.session = session
        self.turn = turn
        self.arrivedAt = arrivedAt
    }
}

public struct RunningIdentity: Hashable, Codable, Sendable {
    public let source: AttentionSource
    public let session: UUID
    public let turn: UUID
    public init(source: AttentionSource, session: UUID, turn: UUID) {
        self.source = source
        self.session = session
        self.turn = turn
    }
}

public struct AttentionRunning: Identifiable, Equatable, Sendable {
    public let source: AttentionSource
    public let session: UUID
    public let turn: UUID
    public let arrivedAt: Double
    public var id: RunningIdentity { RunningIdentity(source: source, session: session, turn: turn) }

    public init(source: AttentionSource, session: UUID, turn: UUID, arrivedAt: Double) {
        self.source = source
        self.session = session
        self.turn = turn
        self.arrivedAt = arrivedAt
    }
}

public enum AttentionItemID: Hashable, Sendable {
    case request(RequestIdentity)
    case completion(CompletionIdentity)
    case running(RunningIdentity)
}

public enum AttentionItemKind: Int, Equatable, Sendable {
    case actionableRequest
    case handedBackRequest
    case completion
    case running
}

public struct AttentionItem: Identifiable, Equatable, Sendable {
    public let id: AttentionItemID
    public let kind: AttentionItemKind
    public let session: UUID
    public let arrivedAt: Double
    public let request: AttentionRequest?
    public let completion: AttentionCompletion?
    public let running: AttentionRunning?
}

/// Merges all session activity into one deterministic attention projection.
public struct AttentionQueue: Sendable {
    private var requests: [RequestIdentity: AttentionRequest] = [:]
    private var completions: [CompletionIdentity: AttentionCompletion] = [:]
    private var runningBySession: [SourceSession: AttentionRunning] = [:]
    private var resolvedTurns: Set<AttentionTurnIdentity> = []
    private var decidedRequests: Set<RequestIdentity> = []
    private var acknowledged: Set<CompletionIdentity>

    public init(acknowledged: Set<CompletionIdentity> = []) {
        self.acknowledged = acknowledged
    }

    public var items: [AttentionItem] { makeItems() }
    public var workingCount: Int { runningBySession.count }
    public var toCheckCount: Int { requests.count + completions.count }
    public var acknowledgedCompletions: Set<CompletionIdentity> { acknowledged }

    public func items(viewing session: UUID) -> [AttentionItem] {
        items.filter { $0.session != session }
    }

    public func visibleItems(viewing session: UUID) -> [AttentionItem] {
        items(viewing: session)
    }

    public mutating func apply(requests incomingRequests: [AttentionRequest] = [],
                               completions incomingCompletions: [AttentionCompletion] = [],
                               running incomingRunning: [AttentionRunning] = [], now: Double? = nil) {
        for incoming in incomingCompletions {
            guard completions[incoming.id] == nil, !acknowledged.contains(incoming.id) else { continue }
            completions[incoming.id] = incoming
            let turn = AttentionTurnIdentity(source: incoming.source, session: incoming.session, turn: incoming.turn)
            resolvedTurns.insert(turn)
            requests = requests.filter { !resolvedTurns.contains(AttentionTurnIdentity(source: $0.value.source, session: $0.value.session, turn: $0.value.turn)) }
            runningBySession = runningBySession.filter {
                $0.value.id != RunningIdentity(source: incoming.source, session: incoming.session, turn: incoming.turn)
            }
        }
        for incoming in incomingRequests where !decidedRequests.contains(incoming.identity)
            && !resolvedTurns.contains(AttentionTurnIdentity(source: incoming.source, session: incoming.session, turn: incoming.turn)) {
            if var current = requests[incoming.identity] {
                if incoming.arrivedAt < current.arrivedAt {
                    current = AttentionRequest(id: current.id, source: current.source, session: current.session, turn: current.turn,
                                               arrivedAt: incoming.arrivedAt, expiresAt: min(current.expiresAt, incoming.expiresAt),
                                               state: current.state, details: current.details ?? incoming.details)
                }
                if incoming.state == .handedBack { current.state = .handedBack }
                if current.details == nil { current = AttentionRequest(id: current.id, source: current.source, session: current.session,
                                                                        turn: current.turn, arrivedAt: current.arrivedAt,
                                                                        expiresAt: current.expiresAt, state: current.state,
                                                                        details: incoming.details) }
                requests[incoming.identity] = current
            } else {
                requests[incoming.identity] = incoming
            }
        }
        for incoming in incomingRunning {
            let key = SourceSession(source: incoming.source, session: incoming.session)
            guard !resolvedTurns.contains(AttentionTurnIdentity(source: incoming.source, session: incoming.session, turn: incoming.turn)) else { continue }
            guard runningBySession[key]?.arrivedAt ?? -.infinity < incoming.arrivedAt else { continue }
            runningBySession[key] = incoming
        }
        if let now { expire(at: now) }
    }

    public mutating func apply(scan: ReminderScan, desktopEvents: [DesktopEvent], now: Double) {
        let cliCompletions = scan.cliCompletions.map {
            AttentionCompletion(source: .cli, session: $0.session, turn: $0.turn,
                                arrivedAt: timestamp($0.receivedAt))
        }
        let desktopState = DesktopState.replay(desktopEvents.filter { !scan.cliSessions.contains($0.session) })
        let desktopCompletions = desktopState.completed.map {
            AttentionCompletion(source: .desktop, session: $0.session, turn: $0.turn,
                                arrivedAt: timestamp($0.receivedAt))
        }
        let desktopRunning = desktopState.running.map {
            AttentionRunning(source: .desktop, session: $0.session, turn: $0.turn,
                             arrivedAt: timestamp($0.startedAt))
        }
        let cliRunning = scan.cliState.running.map {
            AttentionRunning(source: .cli, session: $0.session, turn: $0.turn,
                             arrivedAt: timestamp($0.startedAt))
        }
        runningBySession.removeAll()
        resolve(scan.completed.union(scan.canceled), source: .cli)
        let bySource = Dictionary(scan.attentionRequests.map { ($0.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        resolve(requests: scan.resolvedRequests.compactMap { resolution in
            (bySource[resolution.requestID] ?? requests.values.first { $0.id == resolution.requestID }?.source)
                .map { RequestIdentity(source: $0, request: resolution.requestID) }
        })
        apply(requests: scan.attentionRequests,
              completions: desktopCompletions + cliCompletions,
              running: desktopRunning + cliRunning, now: now)
        resolve(requests: requests.values.filter { request in
            guard let ended = scan.sessionEnds[request.session] else { return false }
            return ended >= request.arrivedAt
        }.map(\.identity))
    }

    private mutating func resolve(_ turns: Set<TurnIdentity>, source: AttentionSource) {
        let qualified = Set(turns.map { AttentionTurnIdentity(source: source, session: $0.session, turn: $0.turn) })
        resolvedTurns.formUnion(qualified)
        requests = requests.filter { !qualified.contains(AttentionTurnIdentity(source: $0.value.source, session: $0.value.session, turn: $0.value.turn)) }
        runningBySession = runningBySession.filter {
            !qualified.contains(AttentionTurnIdentity(source: $0.value.source, session: $0.value.session, turn: $0.value.turn))
        }
    }

    /// Clears exactly these requests on resolution evidence and prevents a later scan from reviving them.
    public mutating func resolve(requests identities: [RequestIdentity]) {
        for identity in identities {
            decidedRequests.insert(identity)
            requests.removeValue(forKey: identity)
        }
    }

    public mutating func expire(at now: Double) {
        for id in requests.keys {
            requests[id]?.expire(at: now)
        }
    }

    public mutating func dismiss(_ id: AttentionItemID) {
        switch id {
        case let .request(id):
            resolve(requests: [id])
        case let .completion(id):
            acknowledged.insert(id)
            completions.removeValue(forKey: id)
        case let .running(id):
            runningBySession.removeValue(forKey: SourceSession(source: id.source, session: id.session))
        }
    }

    private func makeItems() -> [AttentionItem] {
        let requestItems = requests.values.map { request in
            AttentionItem(id: .request(request.identity), kind: request.state == .actionable ? .actionableRequest : .handedBackRequest,
                          session: request.session, arrivedAt: request.arrivedAt, request: request,
                          completion: nil, running: nil)
        }
        let completionItems = completions.values.map { completion in
            AttentionItem(id: .completion(completion.id), kind: .completion, session: completion.session,
                          arrivedAt: completion.arrivedAt, request: nil, completion: completion, running: nil)
        }
        let runningItems = runningBySession.values.map { active in
            AttentionItem(id: .running(active.id), kind: .running, session: active.session,
                          arrivedAt: active.arrivedAt, request: nil, completion: nil, running: active)
        }
        return (requestItems + completionItems + runningItems).sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.arrivedAt != $1.arrivedAt { return $0.arrivedAt < $1.arrivedAt }
            return $0.id.sortKey < $1.id.sortKey
        }
    }
}

private struct SourceSession: Hashable, Sendable {
    let source: AttentionSource
    let session: UUID
}

private extension AttentionItemID {
    var sortKey: String {
        switch self {
        case let .request(id): return "request:\(id.source.rawValue):\(id.request.uuidString)"
        case let .completion(id): return "completion:\(id.source.rawValue):\(id.session.uuidString):\(id.turn.uuidString)"
        case let .running(id): return "running:\(id.source.rawValue):\(id.session.uuidString):\(id.turn.uuidString)"
        }
    }
}

private func timestamp(_ value: String) -> Double {
    RolloutTimestamp.parse(value) ?? 0
}
