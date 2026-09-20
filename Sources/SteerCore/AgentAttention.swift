import Foundation

public enum AgentSource: String, Codable, Sendable {
    case codex
    case claude
}

public enum AgentSurface: String, Codable, Sendable {
    case desktop
    case cli
}

/// Identity supplied by one agent's local installation or configuration root.
public struct AgentSessionIdentity: Hashable, Codable, Sendable {
    public let source: AgentSource
    public let sourceScope: String
    public let session: String
    public let surface: AgentSurface

    public init(source: AgentSource, sourceScope: String, session: String, surface: AgentSurface) {
        self.source = source
        self.sourceScope = sourceScope
        self.session = session
        self.surface = surface
    }
}

public struct AgentTurnIdentity: Hashable, Codable, Sendable {
    public let session: AgentSessionIdentity
    public let turn: String

    public init(session: AgentSessionIdentity, turn: String) {
        self.session = session
        self.turn = turn
    }
}

public struct AgentCallIdentity: Hashable, Codable, Sendable {
    public let session: AgentSessionIdentity
    public let turn: String
    public let call: String

    public init(session: AgentSessionIdentity, turn: String = "", call: String) {
        self.session = session
        self.turn = turn
        self.call = call
    }
}

public enum AgentOutcomeStatus: String, Codable, Sendable {
    case finished
    case failed
    case stopped
    case unavailable
}

public struct AgentOutcome: Identifiable, Equatable, Codable, Sendable {
    public let identity: AgentTurnIdentity
    public let status: AgentOutcomeStatus
    public let arrivedAt: Double
    public let uncertain: Bool

    public var id: AgentTurnIdentity { identity }
    public var session: AgentSessionIdentity { identity.session }
    public var turn: String { identity.turn }

    public init(session: AgentSessionIdentity, turn: String, status: AgentOutcomeStatus,
                arrivedAt: Double, uncertain: Bool = false) {
        self.identity = AgentTurnIdentity(session: session, turn: turn)
        self.status = status
        self.arrivedAt = arrivedAt
        self.uncertain = uncertain
    }
}

public enum AgentApprovalState: String, Codable, Sendable {
    case actionable
    case handedBack
}

public struct AgentApproval: Identifiable, Equatable, Codable, Sendable {
    public let identity: AgentCallIdentity
    public let arrivedAt: Double
    public let expiresAt: Double
    public let state: AgentApprovalState

    public var id: AgentCallIdentity { identity }

    public init(session: AgentSessionIdentity, turn: String = "", call: String, arrivedAt: Double,
                handoffAfter: Double = 30, state: AgentApprovalState = .actionable) {
        self.init(session: session, turn: turn, call: call, arrivedAt: arrivedAt,
                  expiresAt: arrivedAt + handoffAfter, state: state)
    }

    public init(session: AgentSessionIdentity, turn: String = "", call: String, arrivedAt: Double, expiresAt: Double,
                state: AgentApprovalState = .actionable) {
        self.identity = AgentCallIdentity(session: session, turn: turn, call: call)
        self.arrivedAt = arrivedAt
        self.expiresAt = expiresAt
        self.state = state
    }

    public func with(state: AgentApprovalState) -> AgentApproval {
        AgentApproval(session: identity.session, turn: identity.turn, call: identity.call, arrivedAt: arrivedAt,
                      expiresAt: expiresAt, state: state)
    }
}

public struct AgentQuestion: Identifiable, Equatable, Codable, Sendable {
    public let identity: AgentCallIdentity
    public let turn: String
    public let arrivedAt: Double

    public var id: AgentCallIdentity { identity }

    public init(session: AgentSessionIdentity, turn: String, call: String, arrivedAt: Double) {
        self.identity = AgentCallIdentity(session: session, turn: turn, call: call)
        self.turn = turn
        self.arrivedAt = arrivedAt
    }
}

public struct AgentRunning: Identifiable, Equatable, Codable, Sendable {
    public let identity: AgentTurnIdentity
    public let arrivedAt: Double
    public let prompt: String?
    public let toolName: String?
    public let toolInput: [String: String]

    public var id: AgentTurnIdentity { identity }
    public var action: ToolAction? {
        guard let toolName else { return nil }
        return ToolAction(name: toolName, input: toolInput)
    }
    public var rowText: String? { action?.rowText ?? QuestionPrompt.display(prompt, limit: 160) }
    public var fullAction: String? { action?.fullText }
    public var fullPrompt: String? { prompt }

    public init(session: AgentSessionIdentity, turn: String, arrivedAt: Double, prompt: String? = nil,
                toolName: String? = nil, toolInput: [String: String] = [:]) {
        self.identity = AgentTurnIdentity(session: session, turn: turn)
        self.arrivedAt = arrivedAt
        self.prompt = prompt
        self.toolName = toolName
        self.toolInput = toolInput
    }
}

public struct AgentProvisionalStop: Equatable, Sendable {
    public let identity: AgentTurnIdentity
    public let arrivedAt: Double

    public init(identity: AgentTurnIdentity, arrivedAt: Double) {
        self.identity = identity
        self.arrivedAt = arrivedAt
    }
}

public enum AgentAttentionID: Hashable, Codable, Sendable {
    case approval(AgentCallIdentity)
    case question(AgentCallIdentity)
    case outcome(AgentTurnIdentity)
    case running(AgentTurnIdentity)
}

public enum AgentAttentionKind: Int, Equatable, Sendable {
    case actionableApproval
    case question
    case handedBackApproval
    case outcome
    case earlierOutcome
    case running
}

public struct AgentAttentionItem: Identifiable, Equatable, Sendable {
    public let id: AgentAttentionID
    public let kind: AgentAttentionKind
    public let session: AgentSessionIdentity
    public let arrivedAt: Double
    public let approval: AgentApproval?
    public let question: AgentQuestion?
    public let outcome: AgentOutcome?
    public let running: AgentRunning?
}

public enum AgentObservation: Equatable, Sendable {
    case approval(AgentApproval)
    case question(AgentQuestion)
    case outcome(AgentOutcome)
    case running(AgentRunning)
    case provisionalStop(AgentProvisionalStop)
    case resolved(AgentAttentionID)
}

public typealias AgentAttentionSnapshot = AttentionSnapshot

/// One source-qualified queue. Native adapters only need to emit observations; ordering and
/// deadline/decay rules stay here.
public struct AgentAttentionQueue: Sendable {
    public static let earlierAfter: Double = 5 * 60

    private var approvals: [AgentCallIdentity: AgentApproval] = [:]
    private var questions: [AgentCallIdentity: AgentQuestion] = [:]
    private var outcomes: [AgentTurnIdentity: AgentOutcome] = [:]
    private var running: [AgentSessionIdentity: AgentRunning] = [:]
    private var inventoryRunning: [AgentSessionIdentity: AgentRunning] = [:]
    private var provisionalStops: [AgentSessionIdentity: AgentProvisionalStop] = [:]
    private var inventoryObservedAt: [String: Double] = [:]
    private var ambiguousClaudeSessions: Set<AgentSessionIdentity> = []
    private var resolved: Set<AgentAttentionID> = []
    private var acknowledged: Set<AgentTurnIdentity>
    private var now: Double = 0

    public init(acknowledged: Set<AgentTurnIdentity> = []) {
        self.acknowledged = acknowledged
    }

    public init(snapshot: AgentAttentionSnapshot) {
        acknowledged = snapshot.acknowledgedOutcomes
        for outcome in snapshot.outcomes where !acknowledged.contains(outcome.id) {
            outcomes[outcome.id] = AgentOutcome(session: outcome.session, turn: outcome.turn,
                                                 status: outcome.status, arrivedAt: outcome.arrivedAt, uncertain: true)
        }
    }

    public var items: [AgentAttentionItem] { items(at: now) }
    public var workingCount: Int { Set(running.keys).union(inventoryRunning.keys).count }
    public var toCheckCount: Int { approvals.count + questions.count + outcomes.count }
    public var acknowledgedOutcomes: Set<AgentTurnIdentity> { acknowledged }
    public var unavailableClaudeSessions: Set<AgentSessionIdentity> { ambiguousClaudeSessions }
    public func isClaudeSessionUnavailable(_ identity: AgentSessionIdentity) -> Bool {
        ambiguousClaudeSessions.contains(identity)
    }

    public var snapshot: AgentAttentionSnapshot {
        AgentAttentionSnapshot(outcomes: outcomes.values.sorted(by: Self.older), acknowledged: acknowledged)
    }

    public func items(at now: Double) -> [AgentAttentionItem] {
        let approvalItems = approvals.values.map { approval in
            let expired = approval.state == .actionable && approval.expiresAt <= now
            let current = expired ? approval.with(state: .handedBack) : approval
            return AgentAttentionItem(id: .approval(approval.id),
                                      kind: current.state == .actionable ? .actionableApproval : .handedBackApproval,
                                      session: approval.identity.session, arrivedAt: approval.arrivedAt,
                                      approval: current, question: nil, outcome: nil, running: nil)
        }
        let questionItems = questions.values.map { question in
            AgentAttentionItem(id: .question(question.id), kind: .question, session: question.identity.session,
                               arrivedAt: question.arrivedAt, approval: nil, question: question, outcome: nil, running: nil)
        }
        let outcomeItems = outcomes.values.map { outcome in
            let earlier = now - outcome.arrivedAt >= Self.earlierAfter
            return AgentAttentionItem(id: .outcome(outcome.id), kind: earlier ? .earlierOutcome : .outcome,
                                      session: outcome.session, arrivedAt: outcome.arrivedAt,
                                      approval: nil, question: nil, outcome: outcome, running: nil)
        }
        let waiting = Set(questions.values.map(\.identity.session))
        let inventoryItems = inventoryRunning.values.filter { running[$0.identity.session] == nil }
        let runningItems = (running.values + inventoryItems).filter { !waiting.contains($0.identity.session) }.map { active in
            AgentAttentionItem(id: .running(active.id), kind: .running, session: active.identity.session,
                               arrivedAt: active.arrivedAt, approval: nil, question: nil, outcome: nil, running: active)
        }
        return (approvalItems + questionItems + outcomeItems + runningItems).sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.arrivedAt != $1.arrivedAt { return $0.arrivedAt < $1.arrivedAt }
            return Self.sortKey($0.id) < Self.sortKey($1.id)
        }
    }

    public mutating func apply(_ observation: AgentObservation, now: Double? = nil) {
        if let now { self.now = now }
        switch observation {
        case let .approval(approval):
            guard !resolved.contains(.approval(approval.id)) else { return }
            if let current = approvals[approval.id] {
                let state: AgentApprovalState = current.state == .handedBack || approval.state == .handedBack
                    ? .handedBack : .actionable
                approvals[approval.id] = AgentApproval(session: approval.identity.session, turn: approval.identity.turn,
                                                       call: approval.identity.call,
                                                       arrivedAt: min(current.arrivedAt, approval.arrivedAt),
                                                       expiresAt: min(current.expiresAt, approval.expiresAt), state: state)
            } else {
                approvals[approval.id] = approval
            }
        case let .question(question):
            guard !resolved.contains(.question(question.id)) else { return }
            questions[question.id] = questions[question.id].map { current in
                current.arrivedAt <= question.arrivedAt ? current : question
            } ?? question
        case let .outcome(outcome):
            guard !acknowledged.contains(outcome.id), outcome.arrivedAt.isFinite else { return }
            if outcome.session.source == .claude,
               let current = outcomes[outcome.id], current.arrivedAt > outcome.arrivedAt { return }
            if outcome.session.source == .claude,
               let active = running[outcome.session], active.id == outcome.id, active.arrivedAt > outcome.arrivedAt {
                return
            }
            outcomes[outcome.id] = outcome
            let turn = outcome.id
            for identity in approvals.keys where identity.session == turn.session
                && (identity.turn.isEmpty || identity.turn == turn.turn) {
                resolved.insert(.approval(identity))
            }
            approvals = approvals.filter { !resolved.contains(.approval($0.key)) }
            for identity in questions.keys where identity.session == turn.session && identity.turn == turn.turn {
                resolved.insert(.question(identity))
            }
            questions = questions.filter { !resolved.contains(.question($0.key)) }
            if running[turn.session]?.id == turn { running.removeValue(forKey: turn.session) }
            inventoryRunning.removeValue(forKey: turn.session)
        case let .running(active):
            guard !resolved.contains(.running(active.id)) else { return }
            if let outcome = outcomes[active.id] {
                guard active.identity.session.source == .claude, active.arrivedAt > outcome.arrivedAt else { return }
                outcomes.removeValue(forKey: active.id)
            }
            if let current = running[active.identity.session] {
                guard active.arrivedAt > current.arrivedAt || (active.id == current.id && active != current) else { return }
            }
            running[active.identity.session] = active
            inventoryRunning.removeValue(forKey: active.identity.session)
            provisionalStops = provisionalStops.filter { $0.key != active.identity.session }
        case let .provisionalStop(stop):
            guard stop.arrivedAt.isFinite else { return }
            guard outcomes[stop.identity] == nil else { return }
            if let current = provisionalStops[stop.identity.session], current.arrivedAt >= stop.arrivedAt { return }
            provisionalStops[stop.identity.session] = stop
        case let .resolved(id):
            dismiss(id)
        }
        if let now { expire(at: now) }
    }

    public mutating func apply(_ observations: [AgentObservation], now: Double? = nil) {
        observations.forEach { apply($0, now: now) }
    }

    /// Applies a valid root inventory as weaker lifecycle evidence. It can add a generic running
    /// row or confirm a previously observed Stop, but it never clears hook observations.
    public mutating func apply(_ scan: ClaudeInventoryScan, now: Double? = nil) {
        guard scan.observedAt.isFinite else { return }
        let scope = scan.sourceScope
        guard scan.observedAt >= (inventoryObservedAt[scope] ?? -.infinity) else { return }
        inventoryObservedAt[scope] = scan.observedAt
        let ambiguous = Set(scan.ambiguousSessionIDs.map {
            AgentSessionIdentity(source: .claude, sourceScope: scope, session: $0, surface: .cli)
        })
        if scan.available {
            ambiguousClaudeSessions = ambiguousClaudeSessions.filter { $0.sourceScope != scope }
        }
        ambiguousClaudeSessions.formUnion(ambiguous)
        guard scan.available else { return }
        let sessions = scan.sessions.filter { $0.sessionID.isEmpty == false }
        let incoming = Set(sessions.map { AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                              session: $0.sessionID, surface: .cli) })
        inventoryRunning = inventoryRunning.filter { identity, _ in
            identity.source != .claude || identity.sourceScope != scope || incoming.contains(identity)
        }
        for session in sessions {
            let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                session: session.sessionID, surface: .cli)
            if session.lifecycle.isIdleInteractive {
                if let stop = provisionalStops[identity], scan.observedAt > stop.arrivedAt {
                    provisionalStops.removeValue(forKey: identity)
                    apply(.outcome(AgentOutcome(session: identity, turn: stop.identity.turn,
                                                status: .finished, arrivedAt: scan.observedAt)), now: now)
                }
                inventoryRunning.removeValue(forKey: identity)
                continue
            }
            guard session.lifecycle.isActive else {
                inventoryRunning.removeValue(forKey: identity)
                provisionalStops.removeValue(forKey: identity)
                continue
            }
            if let stop = provisionalStops[identity], scan.observedAt > stop.arrivedAt {
                provisionalStops.removeValue(forKey: identity)
            }
            guard running[identity] == nil else { continue }
            inventoryRunning[identity] = AgentRunning(session: identity, turn: "", arrivedAt: scan.observedAt)
        }
        if let now { self.now = now }
    }

    /// Drops source-scoped actionable and running state absent from a complete source scan.
    /// Outcomes stay until the user acknowledges them. Raw stores are used so a running row hidden
    /// behind a question is reconciled too.
    public mutating func reconcile(source: AgentSource, sourceScope: String,
                                   keeping incoming: Set<AgentAttentionID>) {
        let current = Set(approvals.keys.filter { $0.session.source == source && $0.session.sourceScope == sourceScope }
            .map(AgentAttentionID.approval)
            + questions.keys.filter { $0.session.source == source && $0.session.sourceScope == sourceScope }
            .map(AgentAttentionID.question)
            + running.values.filter { $0.identity.session.source == source && $0.identity.session.sourceScope == sourceScope }
            .map { AgentAttentionID.running($0.id) })
        for id in current where !incoming.contains(id) { dismiss(id) }
    }

    public mutating func expire(at now: Double) {
        self.now = now
        for id in approvals.keys where approvals[id]?.state == .actionable && approvals[id]!.expiresAt <= now {
            approvals[id] = approvals[id]!.with(state: .handedBack)
        }
    }

    public mutating func dismiss(_ id: AgentAttentionID) {
        switch id {
        case let .approval(identity):
            resolved.insert(id)
            approvals.removeValue(forKey: identity)
        case let .question(identity):
            resolved.insert(id)
            questions.removeValue(forKey: identity)
        case let .outcome(identity):
            resolved.insert(id)
            acknowledged.insert(identity)
            outcomes.removeValue(forKey: identity)
        case let .running(identity):
            running.removeValue(forKey: identity.session)
            inventoryRunning.removeValue(forKey: identity.session)
        }
    }

    private static func older(_ lhs: AgentOutcome, _ rhs: AgentOutcome) -> Bool {
        lhs.arrivedAt == rhs.arrivedAt ? sortKey(.outcome(lhs.id)) < sortKey(.outcome(rhs.id)) : lhs.arrivedAt < rhs.arrivedAt
    }

    private static func sortKey(_ id: AgentAttentionID) -> String {
        switch id {
        case let .approval(value): return "approval:\(value.session.source.rawValue):\(value.session.sourceScope):\(value.session.session):\(value.turn):\(value.call)"
        case let .question(value): return "question:\(value.session.source.rawValue):\(value.session.sourceScope):\(value.session.session):\(value.turn):\(value.call)"
        case let .outcome(value): return "outcome:\(value.session.source.rawValue):\(value.session.sourceScope):\(value.session.session):\(value.turn)"
        case let .running(value): return "running:\(value.session.source.rawValue):\(value.session.sourceScope):\(value.session.session):\(value.turn)"
        }
    }
}

public enum CodexAttentionAdapter {
    public static let sourceScope = "codex"

    public static func session(_ id: UUID, surface: AgentSurface) -> AgentSessionIdentity {
        AgentSessionIdentity(source: .codex, sourceScope: sourceScope, session: id.uuidString, surface: surface)
    }

    public static func outcome(from completion: AttentionCompletion, status: AgentOutcomeStatus? = nil) -> AgentOutcome {
        AgentOutcome(session: session(completion.session, surface: completion.source == .cli ? .cli : .desktop),
                     turn: completion.turn.uuidString, status: status ?? completion.status, arrivedAt: completion.arrivedAt,
                     uncertain: completion.uncertain)
    }

    public static func approval(from request: AttentionRequest) -> AgentApproval {
        AgentApproval(session: session(request.session, surface: request.source == .cli ? .cli : .desktop),
                      turn: request.turn.uuidString, call: request.id.uuidString, arrivedAt: request.arrivedAt,
                      expiresAt: request.expiresAt,
                      state: request.state == .actionable ? .actionable : .handedBack)
    }

    public static func question(from question: AttentionQuestion) -> AgentQuestion {
        AgentQuestion(session: session(question.session, surface: question.source == .cli ? .cli : .desktop),
                      turn: question.turn.uuidString, call: question.callID, arrivedAt: question.arrivedAt)
    }

    public static func running(from running: AttentionRunning) -> AgentRunning {
        AgentRunning(session: session(running.session, surface: running.source == .cli ? .cli : .desktop),
                     turn: running.turn.uuidString, arrivedAt: running.arrivedAt)
    }

    public static func observations(requests: [AttentionRequest] = [], questions: [AttentionQuestion] = [],
                                    completions: [AttentionCompletion] = [], running active: [AttentionRunning] = []) -> [AgentObservation] {
        requests.map { .approval(approval(from: $0)) }
            + questions.map { .question(question(from: $0)) }
            + completions.map { .outcome(outcome(from: $0)) }
            + active.map { .running(running(from: $0)) }
    }
}
