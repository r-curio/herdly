import Foundation

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
