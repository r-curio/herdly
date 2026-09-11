import Foundation
import Testing
@testable import SteerCore

@Test func desktopReplayShowsRunningTurnThenRetainsCompletion() {
    let session = UUID(), turn = UUID()
    var state = DesktopState()

    state.apply(.sessionStarted(session: session, receivedAt: "01"))
    state.apply(.turnStarted(session: session, turn: turn, receivedAt: "02"))
    #expect(state.running.map(\.session) == [session])
    #expect(state.completed.isEmpty)
    #expect(DesktopVisibility.isVisible(hasActivity: !state.running.isEmpty, codexForeground: false))
    #expect(!DesktopVisibility.isVisible(hasActivity: !state.running.isEmpty, codexForeground: true))
    #expect(DesktopVisibility.isVisible(hasActivity: !state.running.isEmpty, codexForeground: nil))

    state.apply(.turnCompleted(session: session, turn: turn, receivedAt: "03"))
    #expect(state.running.isEmpty)
    #expect(state.completed.map(\.id) == [TurnIdentity(session: session, turn: turn)])
    #expect(DesktopVisibility.isVisible(hasActivity: !state.completed.isEmpty, codexForeground: false))
    #expect(!DesktopVisibility.isVisible(hasActivity: !state.completed.isEmpty, codexForeground: true))
    #expect(DesktopVisibility.isVisible(hasActivity: !state.completed.isEmpty, codexForeground: nil))

    state.apply(.sessionEnded(session: session, receivedAt: "04"))
    #expect(state.completed.count == 1)
}

@Test func desktopReaderReplaysMetadataOnlyHookFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID()
    func write(_ name: String, _ event: String, _ turn: UUID? = nil) throws {
        var value: [String: Any] = ["hook_event_name": event, "session_id": session.uuidString, "received_at": name]
        if let turn { value["turn_id"] = turn.uuidString }
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name + ".json"))
    }
    try write("01", "SessionStart")
    try write("02", "UserPromptSubmit", turn)
    try write("03", "Stop", turn)
    try write("04", "SessionEnd")

    let replay = DesktopEventReader.read(from: root)
    #expect(replay == [
        .sessionStarted(session: session, receivedAt: "01"),
        .turnStarted(session: session, turn: turn, receivedAt: "02"),
        .turnCompleted(session: session, turn: turn, receivedAt: "03"),
        .sessionEnded(session: session, receivedAt: "04")
    ])
}

@Test func steerHookMetadataFeedsDesktopAndReminderReaders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID()
    func write(_ name: String, _ event: String, _ turn: UUID? = nil) throws {
        var value: [String: Any] = [
            "hook_event_name": event,
            "session_id": session.uuidString,
            "source": CodexSetupRequirements.helperSource,
            "received_at": "2026-09-12T00:00:0\(name)Z",
            "captured_at": 1_800_000_000.0
        ]
        if let turn { value["turn_id"] = turn.uuidString }
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name + ".json"))
    }
    try write("1", "SessionStart")
    try write("2", "UserPromptSubmit", turn)
    try write("3", "Stop", turn)
    let rollout = root.appendingPathComponent("rollout-\(session.uuidString.lowercased()).jsonl")
    let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"cli\"}}\n"
    let done = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turn)\"}}\n"
    try Data((meta + done).utf8).write(to: rollout)

    let desktop = DesktopEventReader.read(from: root)
    #expect(desktop.count == 3)
    #expect(desktop.last == .turnCompleted(session: session, turn: turn, receivedAt: "2026-09-12T00:00:03Z"))
    let reminders = ReminderReader.scan(events: root, rollouts: root)
    #expect(reminders.cliSessions == [session])
    #expect(reminders.cliCompletions.count == 1)
    #expect(reminders.cliCompletions.first?.session == session)
    #expect(reminders.cliCompletions.first?.turn == turn)
}

@Test func checkedDesktopEvidenceReplaysToCompletion() {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/evidence")
    let events = DesktopEventReader.read(from: fixture)
    let state = DesktopState.replay(events)
    #expect(events.count == 2)
    #expect(state.running.isEmpty)
    #expect(state.completed.count == 1)
}
