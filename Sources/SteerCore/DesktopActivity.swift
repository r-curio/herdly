import Foundation

public enum DesktopEvent: Equatable, Sendable {
    case sessionStarted(session: UUID, receivedAt: String)
    case turnStarted(session: UUID, turn: UUID, receivedAt: String)
    case turnCompleted(session: UUID, turn: UUID, receivedAt: String)
    case sessionEnded(session: UUID, receivedAt: String)

    public var session: UUID {
        switch self {
        case let .sessionStarted(session, _), let .turnStarted(session, _, _),
             let .turnCompleted(session, _, _), let .sessionEnded(session, _): return session
        }
    }
}

public struct DesktopRunningTurn: Equatable, Identifiable, Sendable {
    public let session: UUID
    public let turn: UUID
    public let startedAt: String
    public var id: TurnIdentity { TurnIdentity(session: session, turn: turn) }
}

public struct DesktopCompletion: Equatable, Identifiable, Sendable {
    public let session: UUID
    public let turn: UUID
    public let receivedAt: String
    public var id: TurnIdentity { TurnIdentity(session: session, turn: turn) }
}

public struct DesktopState: Sendable {
    public private(set) var running: [DesktopRunningTurn] = []
    public private(set) var completed: [DesktopCompletion] = []

    public init() {}

    public mutating func apply(_ event: DesktopEvent) {
        switch event {
        case let .sessionStarted(session, _):
            running.removeAll { $0.session == session }
        case let .turnStarted(session, turn, receivedAt):
            running.removeAll { $0.session == session }
            running.append(DesktopRunningTurn(session: session, turn: turn, startedAt: receivedAt))
        case let .turnCompleted(session, turn, receivedAt):
            running.removeAll { $0.id == TurnIdentity(session: session, turn: turn) }
            guard !completed.contains(where: { $0.id == TurnIdentity(session: session, turn: turn) }) else { return }
            completed.append(DesktopCompletion(session: session, turn: turn, receivedAt: receivedAt))
        case let .sessionEnded(session, _):
            running.removeAll { $0.session == session }
        }
    }

    public static func replay(_ events: [DesktopEvent]) -> DesktopState {
        var state = DesktopState()
        events.forEach { state.apply($0) }
        return state
    }
}

public enum DesktopEventReader {
    private struct Record: Decodable {
        let hook_event_name: String
        let session_id: UUID
        let turn_id: UUID?
        let received_at: String
    }

    private static func bounded(_ url: URL, limit: Int) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }

    public static func read(from directory: URL) -> [DesktopEvent] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              files.count <= 4096 else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url -> (Record, String)? in
                guard let data = bounded(url, limit: 64 * 1024),
                      let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
                return (record, url.lastPathComponent)
            }
            .sorted {
                $0.0.received_at == $1.0.received_at ? $0.1 < $1.1 : $0.0.received_at < $1.0.received_at
            }
            .compactMap { source in
                let record = source.0
                switch record.hook_event_name {
                case "SessionStart": return .sessionStarted(session: record.session_id, receivedAt: record.received_at)
                case "UserPromptSubmit":
                    guard let turn = record.turn_id else { return nil }
                    return .turnStarted(session: record.session_id, turn: turn, receivedAt: record.received_at)
                case "Stop":
                    guard let turn = record.turn_id else { return nil }
                    return .turnCompleted(session: record.session_id, turn: turn, receivedAt: record.received_at)
                case "SessionEnd": return .sessionEnded(session: record.session_id, receivedAt: record.received_at)
                default: return nil
                }
            }
    }
}
