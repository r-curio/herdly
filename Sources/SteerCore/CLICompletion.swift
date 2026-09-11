import Foundation

public struct CLICompletion: Identifiable, Equatable, Sendable {
    public let session: UUID
    public let turn: UUID
    public let receivedAt: String
    public var id: TurnIdentity { TurnIdentity(session: session, turn: turn) }
}

public struct CLIQueue: Sendable {
    public private(set) var items: [CLICompletion] = []
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
