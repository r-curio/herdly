import Foundation
import Testing
@testable import HerdlyCore

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

/// Codex desktop spawns sub-agent threads whose permission hooks name the parent session and the
/// sub-agent's turn; that turn ends only in the sub-agent's rollout, whose `session_meta` carries
/// `parent_thread_id`. Recorded 2026-09-14 from a desktop thread with two spawned agents.
@Test func aRequestFromASubAgentTurnClearsWhenTheChildRolloutEndsThatTurn() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = UUID(), child = UUID(), stranger = UUID(), parentTurn = UUID(), childTurn = UUID(), openTurn = UUID()
    let fromChild = Reminder(request_id: UUID(), session_id: parent, turn_id: childTurn, outcome: "no_decision")
    let stillOpen = Reminder(request_id: UUID(), session_id: parent, turn_id: openTurn, outcome: "no_decision")
    for item in [fromChild, stillOpen] {
        try JSONEncoder().encode(item).write(to: root.appendingPathComponent(item.id.uuidString + ".approval"))
    }
    // Recorded shape: a sub-agent rollout's `id` is its own thread and its `session_id` is the parent's.
    func meta(_ id: UUID, parent: UUID? = nil, key: String = "parent_thread_id") -> String {
        var payload: [String: Any] = ["id": id.uuidString.lowercased(), "source": "vscode",
                                      "session_id": (parent ?? id).uuidString.lowercased()]
        if let parent { payload[key] = parent.uuidString.lowercased() }
        let bytes = try! JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload])
        return String(decoding: bytes, as: UTF8.self) + "\n"
    }
    func done(_ turn: UUID) -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turn.uuidString.lowercased())\"}}\n"
    }
    let day = root.appendingPathComponent("2026/09/14")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    try Data((meta(parent) + done(parentTurn)).utf8)
        .write(to: day.appendingPathComponent("rollout-2026-09-14T13-14-39-\(parent.uuidString.lowercased()).jsonl"))
    // A rollout that is not a child of this session ends the same turn id; it must not count.
    try Data((meta(stranger, parent: UUID()) + done(childTurn)).utf8)
        .write(to: day.appendingPathComponent("rollout-2026-09-14T13-30-00-\(stranger.uuidString.lowercased()).jsonl"))
    var queue = ReminderQueue()
    queue.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(Set(queue.items.map(\.id)) == [fromChild.id, stillOpen.id])

    let childFile = day.appendingPathComponent("rollout-2026-09-14T13-30-55-\(child.uuidString.lowercased()).jsonl")
    // A forked rollout repeats the parent's header as its second line; a foreign header is corruption.
    try Data((meta(child, parent: parent) + meta(stranger) + done(childTurn)).utf8).write(to: childFile)
    queue.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(Set(queue.items.map(\.id)) == [fromChild.id, stillOpen.id])
    // A partial child rollout is no evidence.
    try Data((meta(child, parent: parent) + meta(parent) + done(childTurn) + "{partial").utf8).write(to: childFile)
    queue.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(Set(queue.items.map(\.id)) == [fromChild.id, stillOpen.id])
    try Data((meta(child, parent: parent) + meta(parent) + done(childTurn)).utf8).write(to: childFile)
    let scan = ReminderReader.scan(events: root, rollouts: root)
    #expect(scan.completed.contains(TurnIdentity(session: parent, turn: childTurn)))
    queue.apply(scan)
    #expect(queue.items.map(\.id) == [stillOpen.id])
    // The same through the attention queue, which is what the notch renders.
    var attention = AttentionQueue()
    attention.apply(scan: ReminderReader.scan(events: root, rollouts: root), desktopEvents: [], now: 0)
    #expect(attention.items.compactMap(\.request).map(\.turn) == [openTurn])
    // `forked_from_id` names the parent as well.
    try Data((meta(child, parent: parent, key: "forked_from_id") + done(openTurn)).utf8).write(to: childFile)
    queue.apply(ReminderReader.scan(events: root, rollouts: root))
    #expect(queue.items.isEmpty)
}
@Test func terminalCompletionCarriesOnlyItsExactBoundedFinalResponsePreview() throws {
    let session = UUID(), completed = UUID(), other = UUID()
    let json = [
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"cwd\":\"/tmp/project\",\"originator\":\"Codex Desktop\"}}",
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"\(other)\"}}",
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(other)\",\"last_agent_message\":\"other response\"}}",
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"\(completed)\"}}",
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"fix the hover\"}}",
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(completed)\",\"completed_at\":1789459200,\"last_agent_message\":\"  exact response  \"}}",
        ""
    ].joined(separator: "\n")
    let evidence = ReminderReader.evidence(in: Data(json.utf8), session: session)
    #expect(evidence.completionPreviews[TurnIdentity(session: session, turn: completed)]?.text == "exact response")
    #expect(evidence.completionPreviews[TurnIdentity(session: session, turn: other)]?.text == "other response")
    #expect(evidence.completionPreviews.count == 2)
    #expect(evidence.turnContexts[TurnIdentity(session: session, turn: completed)]
        == SpotlightRecordContext(workingDirectory: "/tmp/project", prompt: "fix the hover"))
}

@Test func malformedOrOversizedCompletionRecordsExposeNoPreviewOrContext() {
    let session = UUID(), turn = UUID()
    let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\"}}\n"
    let malformed = meta + "{not json}\n"
    #expect(ReminderReader.evidence(in: Data(malformed.utf8), session: session).completionPreviews.isEmpty)

    let huge = String(repeating: "x", count: 1024 * 1024 + 1)
    let oversized = meta + huge + "\n"
    let evidence = ReminderReader.evidence(in: Data(oversized.utf8), session: session)
    #expect(evidence.completionPreviews.isEmpty)
    #expect(evidence.turnContexts.isEmpty)

    let mismatch = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(UUID())\"}}\n"
        + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turn)\",\"last_agent_message\":\"wrong\"}}\n"
    #expect(ReminderReader.evidence(in: Data(mismatch.utf8), session: session).completionPreviews.isEmpty)
}
