import Foundation

public struct Reminder: Codable, Equatable, Identifiable, Sendable {
    public let request_id: UUID
    public let session_id: UUID
    public let turn_id: UUID
    public let outcome: String
    public var id: UUID { request_id }
}

public struct TurnIdentity: Hashable, Sendable {
    public let session: UUID
    public let turn: UUID
}

public struct ReminderScan: Sendable {
    public var reminders: [Reminder] = []
    public var completed: Set<TurnIdentity> = []
}

public struct ReminderQueue: Sendable {
    public private(set) var items: [Reminder] = []
    private var completed: Set<TurnIdentity> = []
    public init() {}
    public mutating func apply(_ scan: ReminderScan) {
        completed.formUnion(scan.completed)
        for item in scan.reminders where item.outcome == "no_decision" && !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
        items.removeAll { completed.contains(TurnIdentity(session: $0.session_id, turn: $0.turn_id)) }
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
        guard data.last == 10, data.count <= 32 * 1024 * 1024 else { return [] }
        var result: Set<TurnIdentity> = []
        for (index, line) in data.split(separator: 10, omittingEmptySubsequences: false).dropLast().enumerated() {
            guard line.count <= 1024 * 1024,
                  let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = event["payload"] as? [String: Any] else { return [] }
            if index == 0 {
                guard event["type"] as? String == "session_meta",
                      let id = payload["id"] as? String, UUID(uuidString: id) == session else { return [] }
                if let explicit = payload["session_id"],
                   (explicit as? String).flatMap(UUID.init(uuidString:)) != session { return [] }
            } else if event["type"] as? String == "session_meta" { return [] }
            if event["type"] as? String == "event_msg", payload["type"] as? String == "task_complete" {
                guard let id = payload["turn_id"] as? String, let turn = UUID(uuidString: id) else { return [] }
                result.insert(TurnIdentity(session: session, turn: turn))
            }
        }
        return result
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
        for url in ordered where url.pathExtension == "approval" {
            if let bytes = bounded(url, limit: 65536), let item = try? JSONDecoder().decode(Reminder.self, from: bytes),
               item.outcome == "no_decision" { result.reminders.append(item) }
        }
        let sessions = Set(result.reminders.map(\.session_id))
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
                result.completed.formUnion(completed(in: bytes, session: session))
            }
        }
        return result
    }
}
