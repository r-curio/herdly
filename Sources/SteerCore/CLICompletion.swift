import Foundation

public enum CLIEvent: Equatable, Sendable {
    case sessionStarted(session: UUID, receivedAt: String)
    case turnStarted(session: UUID, turn: UUID, receivedAt: String)
    case turnCompleted(session: UUID, turn: UUID, receivedAt: String)
    case sessionEnded(session: UUID, receivedAt: String)

    public var receivedAt: String {
        switch self {
        case let .sessionStarted(_, receivedAt), let .turnStarted(_, _, receivedAt),
             let .turnCompleted(_, _, receivedAt), let .sessionEnded(_, receivedAt): return receivedAt
        }
    }
}

public struct CLIRunningTurn: Equatable, Identifiable, Sendable {
    public let session: UUID
    public let turn: UUID
    public let startedAt: String
    public var id: TurnIdentity { TurnIdentity(session: session, turn: turn) }
}

/// Lifecycle state for local CLI sessions; completions remain in CLIQueue.
public struct CLIState: Sendable {
    public private(set) var liveSessions: Set<UUID> = []
    public private(set) var endedSessions: Set<UUID> = []
    public private(set) var running: [CLIRunningTurn] = []

    public init() {}

    public mutating func apply(_ event: CLIEvent) {
        switch event {
        case let .sessionStarted(session, _):
            liveSessions.insert(session)
            endedSessions.remove(session)
        case let .turnStarted(session, turn, receivedAt):
            guard !endedSessions.contains(session) else { return }
            liveSessions.insert(session)
            running.removeAll { $0.session == session }
            running.append(CLIRunningTurn(session: session, turn: turn, startedAt: receivedAt))
        case let .turnCompleted(session, turn, _):
            running.removeAll { $0.id == TurnIdentity(session: session, turn: turn) }
        case let .sessionEnded(session, _):
            liveSessions.remove(session)
            endedSessions.insert(session)
            running.removeAll { $0.session == session }
        }
    }

    public static func replay(_ events: [CLIEvent]) -> CLIState {
        var state = CLIState()
        events.forEach { state.apply($0) }
        return state
    }
}

public struct CLICompletion: Identifiable, Equatable, Sendable {
    public let session: UUID
    public let turn: UUID
    public let receivedAt: String
    public var id: TurnIdentity { TurnIdentity(session: session, turn: turn) }
}

public struct CLICompletionGroup: Identifiable, Sendable {
    public let session: UUID
    public let completions: [CLICompletion]
    public var id: UUID { session }
}

public struct CLIQueue: Sendable {
    public private(set) var items: [CLICompletion] = []
    // ponytail: small lab queue; index groups if the queue becomes large.
    public var groups: [CLICompletionGroup] {
        var sessions: [UUID] = []
        for item in items where !sessions.contains(item.session) { sessions.append(item.session) }
        return sessions.map { session in CLICompletionGroup(session: session, completions: items.filter { $0.session == session }) }
    }
    public private(set) var acknowledged: Set<TurnIdentity>
    public init(acknowledged: Set<TurnIdentity> = []) { self.acknowledged = acknowledged }
    public mutating func apply(_ incoming: [CLICompletion]) {
        for item in incoming where !acknowledged.contains(item.id) && !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
    }
    public mutating func dismiss(_ id: TurnIdentity) {
        acknowledged.insert(id)
        items.removeAll { $0.id == id }
    }
}
