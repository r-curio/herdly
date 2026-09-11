import Foundation
import Testing
@testable import SteerCore

@Test func remindersFollowOnlyTheirOwnCompletedTurn() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID(), newer = UUID()
    let a = Reminder(request_id: UUID(), session_id: session, turn_id: turn, outcome: "no_decision")
    let b = Reminder(request_id: UUID(), session_id: session, turn_id: newer, outcome: "no_decision")
    let direct = Reminder(request_id: UUID(), session_id: session, turn_id: turn, outcome: "allow")
    for item in [a, b, direct] {
        try JSONEncoder().encode(item).write(to: root.appendingPathComponent(item.id.uuidString + ".approval"))
    }
    let rollout = root.appendingPathComponent("rollout-" + session.uuidString.lowercased() + ".jsonl")
    let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\"}}\n"
    let done = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turn)\"}}\n"
    try Data(meta.utf8).write(to: rollout)
    var queue = ReminderQueue()
    queue.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(Set(queue.items.map(\.id)) == Set([a.id, b.id]))
    try Data((meta + done + "{partial").utf8).write(to: rollout)
    queue.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(queue.items.count == 2)
    try Data((meta + done).utf8).write(to: rollout)
    queue.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(queue.items.map(\.id) == [b.id])
    try FileManager.default.removeItem(at: rollout)
    queue.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(queue.items.map(\.id) == [b.id]) // Cannot resurrect a cleared reminder.
    #expect(ReminderReader.completed(in: Data((meta + done).utf8), session: UUID()).isEmpty)
    #expect(ReminderReader.completed(in: Data((meta + done + "garbage\n").utf8), session: session).isEmpty)
    var restored = ReminderQueue()
    try Data((meta + done).utf8).write(to: rollout)
    restored.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(restored.items.map(\.id) == [b.id])
}
