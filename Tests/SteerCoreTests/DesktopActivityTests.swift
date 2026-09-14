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
        .promptSubmitted(session: session, turn: turn, prompt: nil, receivedAt: "02"),
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

@Test func toolEventsShowTheLatestActionThenFallBackToThePrompt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID()
    func write(_ name: String, _ value: [String: Any]) throws {
        var value = value
        value["session_id"] = session.uuidString
        value["turn_id"] = turn.uuidString
        value["received_at"] = "1970-01-01T00:00:01Z"
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name + ".json"))
    }
    try write("m", ["hook_event_name": "UserPromptSubmit", "prompt": "Please fix the current action row", "captured_at": 1.1])
    try write("z", ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "tool-1", "captured_at": 1.2,
                    "tool_input": ["command": "swift test --filter DesktopActivityTests"]])

    var state = DesktopState.replay(DesktopEventReader.read(from: root), toolEventsSince: 0)
    #expect(state.running.first?.rowText == "running `swift test --filter DesktopActivityTests…`")
    #expect(state.running.first?.fullAction == "swift test --filter DesktopActivityTests")
    #expect(DesktopState.replay(DesktopEventReader.read(from: root), toolEventsSince: 1.15).running.first?.fullAction
            == "swift test --filter DesktopActivityTests")

    try write("a", ["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "tool-1", "captured_at": 1.3])
    state = DesktopState.replay(DesktopEventReader.read(from: root), toolEventsSince: 0)
    #expect(state.running.first?.rowText == "Please fix the current action row")
    #expect(state.running.first?.fullAction == nil)
}

@Test func malformedAndRestoredToolEventsNeverInventOrRestoreAnAction() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID()
    let records: [[String: Any]] = [
        ["hook_event_name": "UserPromptSubmit", "session_id": session.uuidString, "turn_id": turn.uuidString,
         "received_at": "1970-01-01T00:00:01Z", "prompt": "Last known prompt"],
        ["hook_event_name": "PreToolUse", "session_id": session.uuidString, "turn_id": turn.uuidString,
         "received_at": "1970-01-01T00:00:02Z", "tool_name": "Bash"]
    ]
    for (index, record) in records.enumerated() {
        try JSONSerialization.data(withJSONObject: record).write(to: root.appendingPathComponent("\(index).json"))
    }

    let events = DesktopEventReader.read(from: root)
    #expect(DesktopState.replay(events, toolEventsSince: 0).running.first?.rowText == "Last known prompt")
    #expect(DesktopState.replay(events, toolEventsSince: 3).running.first?.fullAction == nil)
}

@Test func longCommandsAreExplicitlyShortenedButRemainAvailableInFull() throws {
    let command = "  swift test " + String(repeating: "x", count: 9_000) + "\n"
    let action = try #require(ToolAction(name: "Bash", input: ["command": command]))
    #expect(action.rowText.count < command.count)
    #expect(action.rowText.hasSuffix("…`"))
    #expect(action.fullText == command)
}

@Test func normalizedHookRecordMayExceedTheInputLimitWithoutLosingTheFullCommand() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID(), command = "swift test " + String(repeating: "x", count: 70_000)
    let record: [String: Any] = [
        "hook_event_name": "PreToolUse", "session_id": session.uuidString, "turn_id": turn.uuidString,
        "received_at": "1970-01-01T00:00:02Z", "captured_at": 2, "tool_name": "Bash", "tool_use_id": "tool-1",
        "tool_input": ["command": command]
    ]
    let data = try JSONSerialization.data(withJSONObject: record)
    #expect(data.count > 64 * 1024 && data.count < DesktopEventReader.maximumRecordSize)
    try data.write(to: root.appendingPathComponent("event.json"))
    let event = try #require(DesktopEventReader.read(from: root).first)
    guard case let .toolStarted(_, _, _, action, _) = event else { Issue.record("tool event was not read"); return }
    #expect(action?.fullText == command)
}

@Test func cliRunningRowsReceiveToolActivityWithoutChangingQueueState() throws {
    let session = UUID(), turn = UUID()
    var scan = ReminderScan()
    scan.cliSessions = [session]
    scan.cliState.apply(.turnStarted(session: session, turn: turn, receivedAt: "1970-01-01T00:00:01Z"))
    let events: [DesktopEvent] = [
        .promptSubmitted(session: session, turn: turn, prompt: "Run the checks", receivedAt: "1970-01-01T00:00:01Z"),
        .toolStarted(session: session, turn: turn, useID: "tool-1",
                     action: ToolAction(name: "Read", input: ["file_path": "/tmp/NotchView.swift"]),
                     capturedAt: 2)
    ]
    var queue = AttentionQueue(observingSince: 0)
    queue.apply(scan: scan, desktopEvents: events, now: 3)

    #expect(queue.workingCount == 1)
    #expect(queue.toCheckCount == 0)
    #expect(queue.items.first?.running?.rowText == "reading NotchView.swift")
}

@Test func anOlderPostToolEventCannotClearTheLatestAction() throws {
    let session = UUID(), turn = UUID()
    var state = DesktopState()
    state.apply(.promptSubmitted(session: session, turn: turn, prompt: "Inspect both files", receivedAt: "01"))
    state.apply(.toolStarted(session: session, turn: turn, useID: "first",
                             action: ToolAction(name: "Read", input: ["file_path": "/tmp/First.swift"]), capturedAt: 2))
    state.apply(.toolStarted(session: session, turn: turn, useID: "latest",
                             action: ToolAction(name: "Edit", input: ["file_path": "/tmp/Latest.swift"]), capturedAt: 3))
    state.apply(.toolCompleted(session: session, turn: turn, useID: "first", capturedAt: 4))
    #expect(state.running.first?.rowText == "editing Latest.swift")
    state.apply(.toolCompleted(session: session, turn: turn, useID: "latest", capturedAt: 5))
    #expect(state.running.first?.rowText == "Inspect both files")
}
