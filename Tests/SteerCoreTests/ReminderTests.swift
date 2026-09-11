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


@Test func cliReminderStaysExpandableWhileDesktopIsForeground() {
    let cli = UUID(), desktop = UUID()
    let cliItem = Reminder(request_id: UUID(), session_id: cli, turn_id: UUID(), outcome: "no_decision")
    let desktopItem = Reminder(request_id: UUID(), session_id: desktop, turn_id: UUID(), outcome: "no_decision")
    var scan = ReminderScan()
    scan.reminders = [cliItem, desktopItem]
    var queue = ReminderQueue()
    queue.apply(scan)
    let visible = queue.visibleItems(cliSessions: [cli], desktopForeground: true)
    #expect(visible == [cliItem])
    var presentation = Attention(restored: true)
    presentation.expand(now: 10)
    _ = presentation.update(codexForeground: visible.isEmpty, hovering: false, now: 10.1)
    #expect(presentation.expanded)
    _ = presentation.update(codexForeground: visible.isEmpty, hovering: false, now: 13.1)
    #expect(!presentation.expanded)
    #expect(queue.visibleItems(cliSessions: [], desktopForeground: true).isEmpty)
    #expect(queue.visibleItems(cliSessions: [], desktopForeground: false).count == 2)
}

@Test func canceledTurnClearsOnlyItsReminderWithoutCreatingCompletion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID(), next = UUID()
    let canceled = Reminder(request_id: UUID(), session_id: session, turn_id: turn, outcome: "no_decision")
    let pending = Reminder(request_id: UUID(), session_id: session, turn_id: next, outcome: "no_decision")
    let other = Reminder(request_id: UUID(), session_id: UUID(), turn_id: turn, outcome: "no_decision")
    for item in [canceled, pending, other] {
        try JSONEncoder().encode(item).write(to: root.appendingPathComponent(item.id.uuidString + ".approval"))
    }
    let path = root.appendingPathComponent("rollout-" + session.uuidString.lowercased() + ".jsonl")
    let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"cli\"}}\n"
    let abort = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"\(turn)\",\"reason\":\"interrupted\"}}\n"
    let stop: [String: String] = ["session_id": session.uuidString, "turn_id": turn.uuidString,
                                "hook_event_name":"Stop", "received_at":"01"]
    try JSONSerialization.data(withJSONObject: stop).write(to: root.appendingPathComponent("stop.json"))
    try Data((meta + abort + "{partial").utf8).write(to: path)
    var queue = ReminderQueue()
    queue.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(queue.items.count == 3)
    try Data((meta + abort).utf8).write(to: path)
    let scan = ReminderReader.scan(events: root, rollouts: root)
    queue.apply(scan)
    #expect(Set(queue.items.map(\.id)) == [pending.id, other.id])
    #expect(scan.completed.isEmpty)
    #expect(scan.cliCompletions.isEmpty)
    var restarted = ReminderQueue()
    restarted.apply(scan)
    #expect(Set(restarted.items.map(\.id)) == [pending.id, other.id])
    try FileManager.default.removeItem(at: path)
    queue.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(Set(queue.items.map(\.id)) == [pending.id, other.id])
}
