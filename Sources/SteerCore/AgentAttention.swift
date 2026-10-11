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

public enum AgentRunningStatus: String, Codable, Sendable {
    case working
    case waiting
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
    /// The source helper's live request token, when the source has one. The call identity remains
    /// the upstream tool call so matching cleanup cannot be confused with the helper transport.
    public let hookRequestID: String?
    public let arrivedAt: Double
    public let expiresAt: Double
    public let state: AgentApprovalState
    public let details: ApprovalDetails?

    public var id: AgentCallIdentity { identity }

    public init(session: AgentSessionIdentity, turn: String = "", call: String, arrivedAt: Double,
                handoffAfter: Double = 30, state: AgentApprovalState = .actionable,
                details: ApprovalDetails? = nil, hookRequestID: String? = nil) {
        self.init(session: session, turn: turn, call: call, arrivedAt: arrivedAt,
                  expiresAt: arrivedAt + handoffAfter, state: state, details: details,
                  hookRequestID: hookRequestID)
    }

    public init(session: AgentSessionIdentity, turn: String = "", call: String, arrivedAt: Double, expiresAt: Double,
                state: AgentApprovalState = .actionable, details: ApprovalDetails? = nil,
                hookRequestID: String? = nil) {
        self.identity = AgentCallIdentity(session: session, turn: turn, call: call)
        self.hookRequestID = hookRequestID
        self.arrivedAt = arrivedAt
        self.expiresAt = expiresAt
        self.state = state
        self.details = details
    }

    public func with(state: AgentApprovalState) -> AgentApproval {
        AgentApproval(session: identity.session, turn: identity.turn, call: identity.call, arrivedAt: arrivedAt,
                      expiresAt: expiresAt, state: state, details: details, hookRequestID: hookRequestID)
    }
}

public struct AgentQuestion: Identifiable, Equatable, Sendable {
    public let identity: AgentCallIdentity
    public let turn: String
    public let arrivedAt: Double
    public let prompts: [QuestionPrompt]
    /// Claude's memory-only helper invocation. Codex questions do not have one.
    public let helperRequestID: String?

    public var id: AgentCallIdentity { identity }

    public var questionCount: Int { prompts.count }

    public init(session: AgentSessionIdentity, turn: String, call: String, arrivedAt: Double,
                prompts: [QuestionPrompt] = [], helperRequestID: String? = nil) {
        self.identity = AgentCallIdentity(session: session, turn: turn, call: call)
        self.turn = turn
        self.arrivedAt = arrivedAt
        self.prompts = prompts
        self.helperRequestID = helperRequestID
    }
}

public struct AgentRunning: Identifiable, Equatable, Codable, Sendable {
    public let identity: AgentTurnIdentity
    /// When the turn first arrived; orders the queue, so later activity never moves the row.
    public let arrivedAt: Double
    /// The latest evidence for the turn; decides which observation wins. Defaults to `arrivedAt`.
    public let updatedAt: Double
    public let prompt: String?
    /// True when Steer kept only the start of the prompt; the full text stays in the agent.
    public let promptShortened: Bool
    public let toolName: String?
    public let toolInput: [String: String]
    public let status: AgentRunningStatus

    public var id: AgentTurnIdentity { identity }
    public var action: ToolAction? {
        guard let toolName else { return nil }
        return ToolAction(name: toolName, input: toolInput)
    }
    public var rowText: String? { action?.rowText ?? QuestionPrompt.display(prompt, limit: 160) }
    public var fullAction: String? { action?.fullText }
    public var fullPrompt: String? { prompt }

    public init(session: AgentSessionIdentity, turn: String, arrivedAt: Double, updatedAt: Double? = nil,
                prompt: String? = nil, promptShortened: Bool = false, toolName: String? = nil,
                toolInput: [String: String] = [:], status: AgentRunningStatus = .working) {
        self.identity = AgentTurnIdentity(session: session, turn: turn)
        self.arrivedAt = arrivedAt
        self.updatedAt = updatedAt ?? arrivedAt
        self.prompt = prompt
        self.promptShortened = promptShortened
        self.toolName = toolName
        self.toolInput = toolInput
        self.status = status
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
    case unavailable(AgentSessionIdentity)
}

public enum AgentAttentionKind: Int, Equatable, Sendable {
    case actionableApproval
    case question
    case handedBackApproval
    case waiting
    case outcome
    case earlierOutcome
    case statusUnavailable
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
    public let unavailableReason: String?

    /// The latest evidence for this row: a running turn's newest observation, otherwise its arrival.
    /// Used only by the optional "Last update" sort.
    public var lastUpdate: Double { running?.updatedAt ?? arrivedAt }
}

public enum AgentObservation: Equatable, Sendable {
    case approval(AgentApproval)
    case question(AgentQuestion)
    case outcome(AgentOutcome)
    case running(AgentRunning)
    case provisionalStop(AgentProvisionalStop)
    /// The user submitted prompt `turn` at `submittedAt`. Replying in a session is evidence the user saw
    /// that session's earlier outcomes, so it acknowledges outcomes of other turns that arrived before it.
    case replied(AgentTurnIdentity, submittedAt: Double)
    case resolved(AgentAttentionID)
}

public typealias AgentAttentionSnapshot = AttentionSnapshot

/// One source-qualified queue. Native adapters only need to emit observations; ordering and
/// deadline/decay rules stay here.
public struct AgentAttentionQueue: Sendable {
    /// The default "Earlier" delay; the user can choose another `EarlierDelay`.
    public static let earlierAfter: Double = 5 * 60
    /// How long a hook-observed Claude turn must be quiet before an idle inventory reading ends its
    /// running row. Claude's registry can still read idle for a moment after a prompt is submitted;
    /// a session doing long work without hooks reads busy, so it never qualifies.
    public static let idleRunningGrace: Double = 2 * 60

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
    /// Turns whose running row ended without a new card: an acknowledged turn's confirmed Stop, or the
    /// idle fallback below. Hook events stay on disk, so every scan repeats a turn's running evidence;
    /// evidence no newer than this cannot reopen the row.
    private var endedTurns: [AgentTurnIdentity: Double] = [:]
    /// Each session's latest prompt submission, so an outcome observed after the reply is still acknowledged.
    private var latestReplies: [AgentSessionIdentity: (turn: String, at: Double)] = [:]
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
    public var workingCount: Int {
        let active = Array(running.values) + Array(inventoryRunning.values)
        return Set(active
            .filter { $0.status == .working && !ambiguousClaudeSessions.contains($0.identity.session) }
            .map(\.identity.session)).count
    }
    public var toCheckCount: Int {
        let covered = Set(approvals.keys.map(\.session)).union(questions.keys.map(\.session))
        let waiting = Set((Array(running.values) + Array(inventoryRunning.values))
            .filter { $0.status == .waiting }
            .map(\.identity.session))
            .subtracting(covered)
            .subtracting(ambiguousClaudeSessions)
        let unavailable = ambiguousClaudeSessions.subtracting(covered)
        return approvals.count + questions.count + outcomes.count + unavailable.count + waiting.count
    }
    /// The count the strip badge and settings show: `toCheckCount` without results that have
    /// moved under "Earlier" by `now`.
    public func toCheckCount(at now: Double, earlier: EarlierDelay) -> Int {
        guard let delay = earlier.seconds else { return toCheckCount }
        return toCheckCount - outcomes.values.filter { now - $0.arrivedAt >= delay }.count
    }
    public var acknowledgedOutcomes: Set<AgentTurnIdentity> { acknowledged }
    public var unavailableClaudeSessions: Set<AgentSessionIdentity> { ambiguousClaudeSessions }
    public func isClaudeSessionUnavailable(_ identity: AgentSessionIdentity) -> Bool {
        ambiguousClaudeSessions.contains(identity)
    }

    public var snapshot: AgentAttentionSnapshot {
        AgentAttentionSnapshot(outcomes: outcomes.values.sorted(by: Self.older), acknowledged: acknowledged)
    }

    /// Rows in display order. `earlier` decides when outcomes move under "Earlier"; `sort` chooses
    /// between queue priority and newest activity for everything below live approvals and questions.
    public func items(at now: Double, earlier: EarlierDelay = .fiveMinutes,
                      sort: QueueSort = .needsAttention) -> [AgentAttentionItem] {
        let approvalItems = approvals.values.map { approval in
            let expired = approval.state == .actionable && approval.expiresAt <= now
            let current = expired ? approval.with(state: .handedBack) : approval
            return AgentAttentionItem(id: .approval(approval.id),
                                      kind: current.state == .actionable ? .actionableApproval : .handedBackApproval,
                                      session: approval.identity.session, arrivedAt: approval.arrivedAt,
                                      approval: current, question: nil, outcome: nil, running: nil, unavailableReason: nil)
        }
        let questionItems = questions.values.map { question in
            AgentAttentionItem(id: .question(question.id), kind: .question, session: question.identity.session,
                               arrivedAt: question.arrivedAt, approval: nil, question: question, outcome: nil, running: nil,
                               unavailableReason: nil)
        }
        let outcomeItems = outcomes.values.map { outcome in
            let isEarlier = earlier.seconds.map { now - outcome.arrivedAt >= $0 } ?? false
            return AgentAttentionItem(id: .outcome(outcome.id), kind: isEarlier ? .earlierOutcome : .outcome,
                                      session: outcome.session, arrivedAt: outcome.arrivedAt,
                                      approval: nil, question: nil, outcome: outcome, running: nil, unavailableReason: nil)
        }
        let covered = Set(approvals.keys.map(\.session)).union(questions.keys.map(\.session))
        let inventoryItems = inventoryRunning.values.filter { running[$0.identity.session] == nil }
        let unavailableItems = ambiguousClaudeSessions.subtracting(covered).map { identity in
            AgentAttentionItem(id: .unavailable(identity), kind: .statusUnavailable, session: identity,
                               arrivedAt: now, approval: nil, question: nil, outcome: nil, running: nil,
                               unavailableReason: "Claude session status unavailable; continue in Claude to inspect it.")
        }
        let activeItems = (running.values + inventoryItems).filter {
            !covered.contains($0.identity.session) && !ambiguousClaudeSessions.contains($0.identity.session)
        }.map { active in
            AgentAttentionItem(id: .running(active.id),
                               kind: active.status == .waiting ? .waiting : .running,
                               session: active.identity.session,
                               arrivedAt: active.arrivedAt, approval: nil, question: nil, outcome: nil, running: active,
                               unavailableReason: nil)
        }
        let byPriority = (approvalItems + questionItems + outcomeItems + unavailableItems + activeItems).sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.arrivedAt != $1.arrivedAt { return $0.arrivedAt < $1.arrivedAt }
            return Self.sortKey($0.id) < Self.sortKey($1.id)
        }
        guard sort == .lastUpdate else { return byPriority }
        // A live request keeps its place while its deadline runs, so newer activity cannot bury it.
        // Earlier outcomes stay together at the end so they fold under one "Earlier" heading.
        let pinned = byPriority.filter { $0.kind == .actionableApproval || $0.kind == .question }
        let newestFirst: (AgentAttentionItem, AgentAttentionItem) -> Bool = {
            if $0.lastUpdate != $1.lastUpdate { return $0.lastUpdate > $1.lastUpdate }
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return Self.sortKey($0.id) < Self.sortKey($1.id)
        }
        let rest = byPriority.filter {
            $0.kind != .actionableApproval && $0.kind != .question && $0.kind != .earlierOutcome
        }.sorted(by: newestFirst)
        let earlierItems = byPriority.filter { $0.kind == .earlierOutcome }.sorted(by: newestFirst)
        return pinned + rest + earlierItems
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
                                                       expiresAt: min(current.expiresAt, approval.expiresAt), state: state,
                                                       details: current.details ?? approval.details,
                                                       hookRequestID: current.hookRequestID ?? approval.hookRequestID)
            } else {
                approvals[approval.id] = approval
            }
        case let .question(question):
            guard !resolved.contains(.question(question.id)) else { return }
            questions[question.id] = questions[question.id].map { current in
                current.arrivedAt <= question.arrivedAt ? current : question
            } ?? question
        case let .outcome(outcome):
            guard outcome.arrivedAt.isFinite else { return }
            if acknowledged.contains(outcome.id) {
                // No new card for an acknowledged turn, but the turn has still ended, so its running row ends too.
                endedTurns[outcome.id] = max(endedTurns[outcome.id] ?? -.infinity, outcome.arrivedAt)
                if let active = running[outcome.session], active.id == outcome.id,
                   active.updatedAt <= outcome.arrivedAt {
                    running.removeValue(forKey: outcome.session)
                }
                return
            }
            if outcome.session.source == .claude,
               let current = outcomes[outcome.id], current.arrivedAt > outcome.arrivedAt { return }
            if outcome.session.source == .claude,
               let active = running[outcome.session], active.id == outcome.id, active.updatedAt > outcome.arrivedAt {
                return
            }
            if let reply = latestReplies[outcome.session], Self.reply(reply, acknowledges: outcome) {
                dismiss(.outcome(outcome.id))
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
            if let endedAt = endedTurns[active.id], active.updatedAt <= endedAt { return }
            if active.identity.session.source == .claude, acknowledged.contains(active.id),
               endedTurns[active.id] != nil {
                // Activity newer than an acknowledged turn's end reopens it, so its next completion is
                // not already acknowledged.
                acknowledged.remove(active.id)
                resolved.remove(.outcome(active.id))
                endedTurns.removeValue(forKey: active.id)
            }
            if let outcome = outcomes[active.id] {
                guard active.identity.session.source == .claude, active.updatedAt > outcome.arrivedAt else { return }
                outcomes.removeValue(forKey: active.id)
            }
            if let current = running[active.identity.session] {
                guard active.updatedAt > current.updatedAt || (active.id == current.id && active != current) else { return }
            }
            running[active.identity.session] = active
            inventoryRunning.removeValue(forKey: active.identity.session)
            provisionalStops = provisionalStops.filter { $0.key != active.identity.session }
        case let .provisionalStop(stop):
            guard stop.arrivedAt.isFinite else { return }
            guard outcomes[stop.identity] == nil else { return }
            if let endedAt = endedTurns[stop.identity], stop.arrivedAt <= endedAt { return }
            if let current = provisionalStops[stop.identity.session], current.arrivedAt >= stop.arrivedAt { return }
            provisionalStops[stop.identity.session] = stop
        case let .replied(prompt, submittedAt):
            guard submittedAt.isFinite else { return }
            if let current = latestReplies[prompt.session], current.at >= submittedAt { return }
            let reply = (turn: prompt.turn, at: submittedAt)
            latestReplies[prompt.session] = reply
            for outcome in outcomes.values where outcome.session == prompt.session
                && Self.reply(reply, acknowledges: outcome) {
                dismiss(.outcome(outcome.id))
            }
        case let .resolved(id):
            dismiss(id)
        }
        if let now { expire(at: now) }
    }

    public mutating func apply(_ observations: [AgentObservation], now: Double? = nil) {
        observations.forEach { apply($0, now: now) }
    }

    /// Applies a valid root inventory as weaker lifecycle evidence. It can add a generic running
    /// row or confirm a previously observed Stop. It clears hook evidence only by ending a running
    /// row whose session reads idle after `idleRunningGrace` without hooks; it never creates an outcome.
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
        let incoming = Set(sessions.filter { $0.kind == .interactive }.map {
            AgentSessionIdentity(source: .claude, sourceScope: scope, session: $0.sessionID, surface: .cli)
        })
        inventoryRunning = inventoryRunning.filter { identity, _ in
            identity.source != .claude || identity.sourceScope != scope || incoming.contains(identity)
        }
        for session in sessions {
            let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                session: session.sessionID, surface: .cli)
            if session.kind == .interactive, let changedAt = session.statusUpdatedAt {
                handBackAnsweredClaudeApprovals(in: identity, statusChangedAt: changedAt)
            }
            if session.lifecycle.isIdleInteractive {
                if let stop = provisionalStops[identity], scan.observedAt > stop.arrivedAt {
                    provisionalStops.removeValue(forKey: identity)
                    apply(.outcome(AgentOutcome(session: identity, turn: stop.identity.turn,
                                                status: .finished, arrivedAt: scan.observedAt)), now: now)
                }
                // Fallback when no Stop can end the row (missed, pruned, or never sent): Claude reports
                // the session idle and its hooks have been quiet past the grace. No outcome is created.
                if let active = running[identity], scan.observedAt - active.updatedAt >= Self.idleRunningGrace {
                    endedTurns[active.id] = max(endedTurns[active.id] ?? -.infinity, active.updatedAt)
                    running.removeValue(forKey: identity)
                }
                inventoryRunning.removeValue(forKey: identity)
                continue
            }
            if case let .background(state) = session.lifecycle,
               ["done", "failed", "stopped"].contains(state) {
                // Inventory describes lifecycle only. It cannot prove a user-facing turn result;
                // Claude hook evidence remains the sole source for finished/failed/stopped cards.
                provisionalStops.removeValue(forKey: identity)
                inventoryRunning.removeValue(forKey: identity)
                continue
            }
            guard session.kind == .interactive else { continue }
            guard session.lifecycle.isActive else {
                inventoryRunning.removeValue(forKey: identity)
                provisionalStops.removeValue(forKey: identity)
                continue
            }
            if let stop = provisionalStops[identity], scan.observedAt > stop.arrivedAt {
                provisionalStops.removeValue(forKey: identity)
            }
            guard running[identity] == nil else { continue }
            let status: AgentRunningStatus = switch session.lifecycle {
            case .interactive(status: "waiting"), .background(state: "blocked"): .waiting
            default: .working
            }
            // Keep the first sighting so each scan does not move the row to the end of its group.
            inventoryRunning[identity] = AgentRunning(session: identity, turn: "",
                                                      arrivedAt: inventoryRunning[identity]?.arrivedAt ?? scan.observedAt,
                                                      updatedAt: scan.observedAt, status: status)
        }
        if let now { self.now = now }
    }

    /// Claude shows one permission prompt per session at a time and sets the registry status to
    /// `waiting` before the PermissionRequest hook record is captured, then changes it as soon as the
    /// prompt is answered, by Claude's native dialog or by a hook. A native "No" fires no hook at all,
    /// so a status change after the request arrived is the only prompt evidence that it is closed.
    /// It says nothing about the outcome, so the request is handed back (Open in Claude only), never
    /// resolved. If Claude ever rewrote the status without closing the prompt, direct controls would
    /// only disappear early while Claude's own prompt stays available.
    private mutating func handBackAnsweredClaudeApprovals(in session: AgentSessionIdentity, statusChangedAt: Double) {
        guard statusChangedAt.isFinite else { return }
        for (id, approval) in approvals where id.session == session && approval.state == .actionable
            && approval.arrivedAt < statusChangedAt {
            approvals[id] = approval.with(state: .handedBack)
        }
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

    /// Drops the desktop copy of a finished Codex turn that also has a terminal outcome, for
    /// sessions known to be terminal ones (`AttentionQueue.dropDesktopDuplicates`). Outcomes are
    /// kept across launches here rather than re-derived, so copies restored from a snapshot taken
    /// before Steer knew the session's surface are merged here too. The terminal outcome stays.
    @discardableResult
    public mutating func dropDesktopDuplicates(codexTerminalSessions sessions: Set<String>) -> [AgentTurnIdentity] {
        let terminalTurns = Set(outcomes.keys.filter { $0.session.source == .codex && $0.session.surface == .cli }
            .map { "\($0.session.sourceScope)|\($0.session.session)|\($0.turn)" })
        let duplicates = outcomes.keys.filter {
            $0.session.source == .codex && $0.session.surface == .desktop && sessions.contains($0.session.session)
                && terminalTurns.contains("\($0.session.sourceScope)|\($0.session.session)|\($0.turn)")
        }
        for id in duplicates { dismiss(.outcome(id)) }
        return Array(duplicates)
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
            // Claude's reader keeps reporting the prompt as running after `Stop`, and a parked session
            // never confirms it again, so the acknowledged outcome itself ends the turn.
            if identity.session.source == .claude, let outcome = outcomes[identity] {
                endedTurns[identity] = max(endedTurns[identity] ?? -.infinity, outcome.arrivedAt)
            }
            outcomes.removeValue(forKey: identity)
        case let .running(identity):
            running.removeValue(forKey: identity.session)
            inventoryRunning.removeValue(forKey: identity.session)
        case let .unavailable(identity):
            ambiguousClaudeSessions.remove(identity)
        }
    }

    /// A reply acknowledges an outcome of another turn that arrived strictly before it was submitted. An
    /// outcome arriving after the prompt (a turn still finishing when the user typed) stays queued.
    private static func reply(_ reply: (turn: String, at: Double), acknowledges outcome: AgentOutcome) -> Bool {
        outcome.turn != reply.turn && outcome.arrivedAt.isFinite && outcome.arrivedAt < reply.at
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
        case let .unavailable(value): return "unavailable:\(value.source.rawValue):\(value.sourceScope):\(value.session)"
        }
    }
}

public enum CodexAttentionAdapter {
    public static let sourceScope = "codex"

    public static func session(_ id: UUID, surface: AgentSurface) -> AgentSessionIdentity {
        AgentSessionIdentity(source: .codex, sourceScope: sourceScope, session: id.uuidString, surface: surface)
    }

    /// Whether a Codex card belongs to a terminal session, so Open takes the terminal route (ADR 0012
    /// "Surface"). A card filed as desktop counts once its session is among `cliSessions`, the
    /// sessions now known to be terminal ones: a daemon-run TUI labels its rollout like the desktop
    /// app (`source: vscode`), so its cards were filed as desktop before the daemon or its pane
    /// proved otherwise. A desktop session is never in `cliSessions`. A Claude card is never a Codex
    /// terminal session.
    public static func isTerminalSession(_ identity: AgentSessionIdentity, cliSessions: Set<UUID>) -> Bool {
        guard identity.source == .codex else { return false }
        if identity.surface == .cli { return true }
        return UUID(uuidString: identity.session).map(cliSessions.contains) == true
    }

    public static func outcome(from completion: AttentionCompletion, status: AgentOutcomeStatus? = nil) -> AgentOutcome {
        AgentOutcome(session: session(completion.session, surface: completion.source == .cli ? .cli : .desktop),
                     turn: completion.turn.uuidString, status: status ?? completion.status, arrivedAt: completion.arrivedAt,
                     uncertain: completion.uncertain)
    }

    /// The shared-queue outcome a Codex completion is mirrored as, for acknowledging it in both queues.
    public static func outcomeID(for completion: CompletionIdentity) -> AgentTurnIdentity {
        AgentTurnIdentity(session: session(completion.session, surface: completion.source == .cli ? .cli : .desktop),
                          turn: completion.turn.uuidString)
    }

    public static func approval(from request: AttentionRequest) -> AgentApproval {
        AgentApproval(session: session(request.session, surface: request.source == .cli ? .cli : .desktop),
                      turn: request.turn.uuidString, call: request.id.uuidString, arrivedAt: request.arrivedAt,
                      expiresAt: request.expiresAt,
                      state: request.state == .actionable ? .actionable : .handedBack,
                      details: request.details)
    }

    public static func question(from question: AttentionQuestion) -> AgentQuestion {
        AgentQuestion(session: session(question.session, surface: question.source == .cli ? .cli : .desktop),
                      turn: question.turn.uuidString, call: question.callID, arrivedAt: question.arrivedAt,
                      prompts: question.prompts)
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
