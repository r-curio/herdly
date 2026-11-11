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

    public func with(state: AttentionRequestState) -> AttentionRequest {
        AttentionRequest(id: id, source: source, session: session, turn: turn, arrivedAt: arrivedAt,
                         expiresAt: expiresAt, state: state, details: details)
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

public struct AttentionCompletion: Identifiable, Equatable, Codable, Sendable {
    public let source: AttentionSource
    public let session: UUID
    public let turn: UUID
    public let arrivedAt: Double
    public let status: AgentOutcomeStatus
    /// True when the user may have viewed this result while the companion was not observing
    /// (it was queued or arrived while fully quit). Such an item is retained without a sound.
    public let uncertain: Bool
    public var id: CompletionIdentity { CompletionIdentity(source: source, session: session, turn: turn) }

    public init(source: AttentionSource, session: UUID, turn: UUID, arrivedAt: Double,
                uncertain: Bool = false, status: AgentOutcomeStatus = .finished) {
        self.source = source
        self.session = session
        self.turn = turn
        self.arrivedAt = arrivedAt
        self.uncertain = uncertain
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case source, session, turn, arrivedAt, uncertain, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(AttentionSource.self, forKey: .source)
        session = try container.decode(UUID.self, forKey: .session)
        turn = try container.decode(UUID.self, forKey: .turn)
        arrivedAt = try container.decode(Double.self, forKey: .arrivedAt)
        uncertain = try container.decodeIfPresent(Bool.self, forKey: .uncertain) ?? false
        status = try container.decodeIfPresent(AgentOutcomeStatus.self, forKey: .status) ?? .finished
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(session, forKey: .session)
        try container.encode(turn, forKey: .turn)
        try container.encode(arrivedAt, forKey: .arrivedAt)
        try container.encode(uncertain, forKey: .uncertain)
        try container.encode(status, forKey: .status)
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
    public let prompt: String?
    public let action: ToolAction?
    public var id: RunningIdentity { RunningIdentity(source: source, session: session, turn: turn) }
    public var rowText: String? { action?.rowText ?? QuestionPrompt.display(prompt, limit: 160) }
    public var fullAction: String? { action?.fullText }
    public var fullPrompt: String? { prompt }
    public var promptIsTruncated: Bool {
        guard action == nil, let prompt else { return false }
        return QuestionPrompt.displayIsTruncated(prompt, limit: 160)
    }

    public init(source: AttentionSource, session: UUID, turn: UUID, arrivedAt: Double,
                prompt: String? = nil, action: ToolAction? = nil) {
        self.source = source
        self.session = session
        self.turn = turn
        self.arrivedAt = arrivedAt
        self.prompt = prompt
        self.action = action
    }
}

public enum AttentionItemID: Hashable, Sendable {
    case request(RequestIdentity)
    case question(QuestionIdentity)
    case completion(CompletionIdentity)
    case running(RunningIdentity)
}

/// Declaration order is queue priority. A question outranks a handed-back request: Codex is blocked
/// on it and the user has not seen it yet, while a handed-back request was already surfaced once.
public enum AttentionItemKind: Int, Equatable, Sendable {
    case actionableRequest
    case question
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
    public let question: AttentionQuestion?
}

/// Merges all session activity into one deterministic attention projection.
public struct AttentionQueue: Equatable, Sendable {
    private var requests: [RequestIdentity: AttentionRequest] = [:]
    private var completions: [CompletionIdentity: AttentionCompletion] = [:]
    private var runningBySession: [SourceSession: AttentionRunning] = [:]
    private var questions: [QuestionIdentity: AttentionQuestion] = [:]
    /// Questions cleared by evidence or dismissal; a scan that cannot read the rollout must not revive them.
    private var answeredQuestions: Set<QuestionIdentity> = []
    /// Turns the rollout recorded as complete or aborted; a question for one is never (re)admitted.
    private var endedTurns: Set<TurnIdentity> = []
    private var resolvedTurns: Set<AttentionTurnIdentity> = []
    private var decidedRequests: Set<RequestIdentity> = []
    /// Requests whose companion receipt this process issued: the only verified live interactions.
    private var liveReceipts: Set<RequestIdentity> = []
    private var acknowledged: Set<CompletionIdentity>
    /// Completions that arrived before this cannot have been observed by this process, so a visit
    /// to them cannot be verified: they enter as uncertain whenever a scan first finds them.
    private let observingSince: Double

    public init(acknowledged: Set<CompletionIdentity> = [], observingSince: Double = -.infinity) {
        self.acknowledged = acknowledged
        self.observingSince = observingSince
    }

    /// Restores completions as uncertain: a visit while the companion was quit cannot be verified.
    /// Requests and running work are not restored; current evidence must reproduce them.
    public init(snapshot: AttentionSnapshot, observingSince: Double = -.infinity) {
        self.observingSince = observingSince
        acknowledged = snapshot.acknowledged
        for saved in snapshot.completions where !acknowledged.contains(saved.id) {
            completions[saved.id] = AttentionCompletion(source: saved.source, session: saved.session, turn: saved.turn,
                                                        arrivedAt: saved.arrivedAt, uncertain: true, status: saved.status)
        }
    }

    public var snapshot: AttentionSnapshot {
        let ordered = completions.values.sorted { (a: AttentionCompletion, b: AttentionCompletion) in
            a.arrivedAt != b.arrivedAt ? a.arrivedAt < b.arrivedAt : AttentionItemID.completion(a.id).sortKey < AttentionItemID.completion(b.id).sortKey
        }
        return AttentionSnapshot(completions: ordered, acknowledged: acknowledged)
    }

    public var items: [AttentionItem] { makeItems() }
    public var workingCount: Int { runningBySession.count }
    /// Sessions Codex is in a turn for right now, whether or not they are shown as working: a
    /// session blocked on a question is mid-turn too, and its running row is only withheld from the
    /// display. Anything that must not act on a session between turns reads this, never the rows.
    public var sessionsInTurn: Set<UUID> {
        Set(runningBySession.values.map(\.session)).union(questions.values.map(\.session))
    }
    public var toCheckCount: Int { requests.count + questions.count + completions.count }
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
            questions = questions.filter { !resolvedTurns.contains(AttentionTurnIdentity(source: $0.value.source, session: $0.value.session, turn: $0.value.turn)) }
            runningBySession = runningBySession.filter {
                $0.value.id != RunningIdentity(source: incoming.source, session: incoming.session, turn: incoming.turn)
            }
        }
        for incoming in incomingRequests where !decidedRequests.contains(incoming.identity)
            && !endedTurns.contains(TurnIdentity(session: incoming.session, turn: incoming.turn))
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

    /// Adds running work found by session discovery. A session whose running turn a hook already
    /// reported this scan keeps the hook's row: an observed event outranks an inferred one.
    public mutating func apply(discovered: [AttentionRunning]) {
        apply(running: discovered.filter { runningBySession[SourceSession(source: $0.source, session: $0.session)] == nil })
    }

    /// Adds pending questions. One already answered, dismissed, or belonging to an ended turn stays
    /// out; a repeat keeps the earliest arrival and the first readable text.
    public mutating func apply(questions incoming: [AttentionQuestion]) {
        for question in incoming where !answeredQuestions.contains(question.id)
            && !endedTurns.contains(TurnIdentity(session: question.session, turn: question.turn))
            && !resolvedTurns.contains(AttentionTurnIdentity(source: question.source, session: question.session, turn: question.turn)) {
            guard let current = questions[question.id] else { questions[question.id] = question; continue }
            if question.arrivedAt < current.arrivedAt || (current.prompts.isEmpty && !question.prompts.isEmpty) {
                questions[question.id] = AttentionQuestion(source: current.source, session: current.session, turn: current.turn,
                                                           callID: current.callID, arrivedAt: min(current.arrivedAt, question.arrivedAt),
                                                           prompts: current.prompts.isEmpty ? question.prompts : current.prompts)
            }
        }
    }

    /// Clears exactly these questions on an answer, dismissal, or session end, for good.
    public mutating func resolve(questions identities: [QuestionIdentity]) {
        for identity in identities {
            answeredQuestions.insert(identity)
            questions.removeValue(forKey: identity)
        }
    }

    /// A turn that ended in the rollout resolves its questions and its handed-back requests
    /// whichever surface posed them; the source on either is only a navigation label. Ended turns
    /// include those of a sub-agent thread credited to its parent session by the reader.
    private mutating func resolve(endedTurns turns: Set<TurnIdentity>) {
        guard !turns.isEmpty else { return }
        endedTurns.formUnion(turns)
        questions = questions.filter { !turns.contains(TurnIdentity(session: $0.value.session, turn: $0.value.turn)) }
        requests = requests.filter { !turns.contains(TurnIdentity(session: $0.value.session, turn: $0.value.turn)) }
    }

    /// Records the receipts this process issued; only these may show decision controls.
    public mutating func recordReceipts(_ receipted: [AttentionRequest], now: Double) {
        liveReceipts.formUnion(receipted.map(\.identity))
        apply(requests: receipted, now: now)
    }

    /// Applies current evidence. Completions that arrived before observation began enter as
    /// uncertain. Returns requests the reader found actionable on disk without a receipt from
    /// this process; they enter as handed back and the caller releases them to Codex.
    ///
    /// Hook events of a `codex exec` run (`scan.execSessions`, #409) are ignored, and rows already
    /// held for one (restored, or queued before its rollout was readable) are dropped without being
    /// acknowledged, except a live request, which keeps its deadline and hand-back.
    @discardableResult
    public mutating func apply(scan: ReminderScan, desktopEvents allDesktopEvents: [DesktopEvent], now: Double) -> [AttentionRequest] {
        let exec = scan.execSessions
        let desktopEvents = exec.isEmpty ? allDesktopEvents : allDesktopEvents.filter { !exec.contains($0.session) }
        if !exec.isEmpty {
            requests = requests.filter { !exec.contains($0.value.session) || $0.value.state == .actionable }
            questions = questions.filter { !exec.contains($0.value.session) }
            completions = completions.filter { !exec.contains($0.value.session) }
        }
        let cliCompletions = scan.cliCompletions.map {
            AttentionCompletion(source: .cli, session: $0.session, turn: $0.turn,
                                arrivedAt: timestamp($0.receivedAt), uncertain: timestamp($0.receivedAt) < observingSince)
        }
        let eventState = DesktopState.replay(desktopEvents, toolEventsSince: observingSince)
        let desktopState = DesktopState.replay(desktopEvents.filter { !scan.cliSessions.contains($0.session) },
                                               toolEventsSince: observingSince)
        let eventRunning = Dictionary(eventState.running.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let desktopCompletions = desktopState.completed.map {
            AttentionCompletion(source: .desktop, session: $0.session, turn: $0.turn,
                                arrivedAt: timestamp($0.receivedAt), uncertain: timestamp($0.receivedAt) < observingSince)
        }
        var released: [AttentionRequest] = []
        let requests = scan.attentionRequests.map { request -> AttentionRequest in
            guard request.state == .actionable, !liveReceipts.contains(request.identity) else { return request }
            let handedBack = request.with(state: .handedBack)
            if !decidedRequests.contains(request.identity), self.requests[request.identity] == nil { released.append(handedBack) }
            return handedBack
        }
        // The rollout's own turn end outranks a missing Stop hook for a desktop-labelled session too.
        let rolloutEnded = scan.completed.union(scan.canceled)
        let desktopRunning = desktopState.running.filter { !rolloutEnded.contains($0.id) }.map {
            AttentionRunning(source: .desktop, session: $0.session, turn: $0.turn,
                             arrivedAt: timestamp($0.startedAt), prompt: $0.prompt, action: $0.action)
        }
        let cliRunning = scan.cliState.running.map {
            let event = eventRunning[$0.id]
            return AttentionRunning(source: .cli, session: $0.session, turn: $0.turn,
                                    arrivedAt: timestamp($0.startedAt), prompt: event?.prompt, action: event?.action)
        }
        runningBySession.removeAll()
        resolve(questions: Array(scan.answeredQuestions))
        resolve(endedTurns: scan.completed.union(scan.canceled))
        resolve(scan.completed.union(scan.canceled), source: .cli)
        let bySource = Dictionary(requests.map { ($0.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        resolve(requests: scan.resolvedRequests.compactMap { resolution in
            (bySource[resolution.requestID] ?? self.requests.values.first { $0.id == resolution.requestID }?.source)
                .map { RequestIdentity(source: $0, request: resolution.requestID) }
        })
        apply(requests: requests,
              completions: desktopCompletions + cliCompletions,
              running: desktopRunning + cliRunning, now: now)
        resolve(requests: self.requests.values.filter { request in
            guard let ended = scan.sessionEnds[request.session] else { return false }
            return ended >= request.arrivedAt
        }.map(\.identity))
        apply(questions: scan.questions)
        resolve(questions: self.questions.values.filter { question in
            guard let ended = scan.sessionEnds[question.session] else { return false }
            return ended >= question.arrivedAt
        }.map(\.id))
        return released.filter { self.requests[$0.identity] != nil }
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

    /// Moves a live request's deadline later for a hover hold (ADR 0020); never earlier, and never
    /// for a handed-back request. The caller bounds it with `ApprovalTiming.heldDeadline`.
    public mutating func hold(_ identity: RequestIdentity, until deadline: Double) {
        guard let current = requests[identity], current.state == .actionable,
              deadline.isFinite, deadline > current.expiresAt else { return }
        requests[identity] = AttentionRequest(id: current.id, source: current.source, session: current.session,
                                              turn: current.turn, arrivedAt: current.arrivedAt, expiresAt: deadline,
                                              state: current.state, details: current.details)
    }

    /// Drops the desktop copy of a finished turn that also has a terminal completion, for sessions
    /// known to be terminal ones. A daemon-run Codex TUI labels its rollout like the desktop app
    /// (`source: vscode`), so before Herdly knew it was a terminal session the same turn could be
    /// queued once under each source. Only an exact duplicate (same session and turn) is dropped;
    /// the terminal completion stays queued, so no turn loses its card. A terminal completion already
    /// acknowledged (a later prompt, a visit, Dismiss) still makes its desktop copy a duplicate.
    @discardableResult
    public mutating func dropDesktopDuplicates(terminalSessions: Set<UUID>) -> [CompletionIdentity] {
        let terminalTurns = Set(Set(completions.keys).union(acknowledged).filter { $0.source == .cli }
            .map { TurnIdentity(session: $0.session, turn: $0.turn) })
        let duplicates = completions.keys.filter {
            $0.source == .desktop && terminalSessions.contains($0.session)
                && terminalTurns.contains(TurnIdentity(session: $0.session, turn: $0.turn))
        }
        for id in duplicates { dismiss(.completion(id)) }
        return Array(duplicates)
    }

    public mutating func dismiss(_ id: AttentionItemID) {
        switch id {
        case let .request(id):
            resolve(requests: [id])
        case let .question(id):
            resolve(questions: [id])
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
                          completion: nil, running: nil, question: nil)
        }
        let questionItems = questions.values.map { question in
            AttentionItem(id: .question(question.id), kind: .question, session: question.session,
                          arrivedAt: question.arrivedAt, request: nil, completion: nil, running: nil, question: question)
        }
        let completionItems = completions.values.map { completion in
            AttentionItem(id: .completion(completion.id), kind: .completion, session: completion.session,
                          arrivedAt: completion.arrivedAt, request: nil, completion: completion, running: nil, question: nil)
        }
        // A session waiting on an answer is blocked, not working: its running row is withheld.
        let waiting = Set(questions.values.map { SourceSession(source: $0.source, session: $0.session) })
        let runningItems = runningBySession.filter { !waiting.contains($0.key) }.values.map { active in
            AttentionItem(id: .running(active.id), kind: .running, session: active.session,
                          arrivedAt: active.arrivedAt, request: nil, completion: nil, running: active, question: nil)
        }
        return (requestItems + questionItems + completionItems + runningItems).sorted {
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
        case let .question(id): return "question:\(id.source.rawValue):\(id.session.uuidString):\(id.callID)"
        case let .completion(id): return "completion:\(id.source.rawValue):\(id.session.uuidString):\(id.turn.uuidString)"
        case let .running(id): return "running:\(id.source.rawValue):\(id.session.uuidString):\(id.turn.uuidString)"
        }
    }
}

private func timestamp(_ value: String) -> Double {
    RolloutTimestamp.parse(value) ?? 0
}
