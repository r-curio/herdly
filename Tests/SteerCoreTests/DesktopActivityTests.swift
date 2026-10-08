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
    #expect(DesktopVisibility.isVisible(hasActivity: !state.running.isEmpty, codexForeground: true))
    #expect(DesktopVisibility.isVisible(hasActivity: !state.running.isEmpty, codexForeground: nil))

    state.apply(.turnCompleted(session: session, turn: turn, receivedAt: "03"))
    #expect(state.running.isEmpty)
    #expect(state.completed.map(\.id) == [TurnIdentity(session: session, turn: turn)])
    #expect(DesktopVisibility.isVisible(hasActivity: !state.completed.isEmpty, codexForeground: false))
    #expect(DesktopVisibility.isVisible(hasActivity: !state.completed.isEmpty, codexForeground: true))
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

@Test func fullPromptIsOfferedOnlyWhenThePromptWasShortened() {
    let session = UUID(), turn = UUID()
    var state = DesktopState()

    state.apply(.promptSubmitted(session: session, turn: turn, prompt: "  A short prompt  ", receivedAt: "01"))
    #expect(state.running.first?.rowText == "A short prompt")
    #expect(state.running.first?.promptIsTruncated == false)

    state.apply(.promptSubmitted(session: session, turn: turn,
                                 prompt: String(repeating: "x", count: 161), receivedAt: "02"))
    #expect(state.running.first?.rowText?.hasSuffix("…") == true)
    #expect(state.running.first?.promptIsTruncated == true)

    let queued = AttentionRunning(source: .desktop, session: session, turn: turn, arrivedAt: 2,
                                  prompt: "  A short prompt  ")
    #expect(queued.promptIsTruncated == false)
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

@Test func notchStaysVisibleInEveryAppEvenWhenIdle() {
    for activity in [false, true] {
        for foreground: Bool? in [false, true, nil] {
            #expect(DesktopVisibility.isVisible(hasActivity: activity, codexForeground: foreground))
        }
    }
}

@Test func codexMemoryConsolidationIsNeverShownAsTheUsersWork() {
    let job = UUID(), jobTurn = UUID(), user = UUID(), userTurn = UUID()
    let memoryPrompt = "## Memory Writing Agent: Phase 2 (Consolidation)\n\nYou are a Memory Writing Agent."
    var state = DesktopState()

    state.apply(.sessionStarted(session: job, receivedAt: "01"))
    state.apply(.promptSubmitted(session: job, turn: jobTurn, prompt: memoryPrompt, receivedAt: "02"))
    state.apply(.promptSubmitted(session: user, turn: userTurn, prompt: "Fix the notch", receivedAt: "03"))
    state.apply(.toolStarted(session: job, turn: jobTurn, useID: "tool-1",
                             action: ToolAction(name: "Bash", input: ["command": "ls"]), capturedAt: 4))
    #expect(state.running.map(\.session) == [user])

    // A later Stop for the job is not a completion for the user to check.
    state.apply(.turnCompleted(session: job, turn: jobTurn, receivedAt: "05"))
    #expect(state.completed.isEmpty)
    #expect(state.running.map(\.session) == [user])
}

@Test func onlyAPromptThatOpensWithTheMemoryHeadingIsTreatedAsCodexsOwn() {
    let session = UUID(), turn = UUID()
    var state = DesktopState()
    state.apply(.promptSubmitted(session: session, turn: turn,
                                 prompt: "Why does Steer show ## Memory Writing Agent: Phase 2 (Consolidation)?",
                                 receivedAt: "01"))
    #expect(state.running.map(\.session) == [session])
}

@Test func aMemoryJobThatNeverSendsStopOrSessionEndIsNotLeftWorking() throws {
    // The shapes recorded on 2026-10-08 for session 01a11757-16e6-7c91-b937-4e67f83d3163: Codex shut the
    // job down at 01:17:18 local time without a Stop or SessionEnd hook, and wrote no rollout for it.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID()
    let common: [String: Any] = ["session_id": session.uuidString, "source": "steer-hook-v1"]
    let records: [[String: Any]] = [
        ["hook_event_name": "SessionStart", "received_at": "2026-10-07T17:09:08Z", "captured_at": 1_791_392_948.786],
        ["hook_event_name": "UserPromptSubmit", "received_at": "2026-10-07T17:09:08Z", "captured_at": 1_791_392_948.854,
         "turn_id": turn.uuidString,
         "prompt": "## Memory Writing Agent: Phase 2 (Consolidation)\n\nYou are a Memory Writing Agent.\n"],
        ["hook_event_name": "PreToolUse", "received_at": "2026-10-07T17:16:58Z", "captured_at": 1_791_393_418.807,
         "turn_id": turn.uuidString, "tool_name": "Bash", "tool_use_id": "exec-1", "tool_input": ["command": "git status"]],
        ["hook_event_name": "PostToolUse", "received_at": "2026-10-07T17:16:59Z", "captured_at": 1_791_393_419.010,
         "turn_id": turn.uuidString, "tool_name": "Bash", "tool_use_id": "exec-1"]
    ]
    for (index, record) in records.enumerated() {
        try JSONSerialization.data(withJSONObject: record.merging(common) { own, _ in own })
            .write(to: root.appendingPathComponent("\(index).json"))
    }

    var queue = AttentionQueue(observingSince: 0)
    queue.apply(scan: ReminderScan(), desktopEvents: DesktopEventReader.read(from: root), now: 1_791_393_440)
    #expect(queue.workingCount == 0)
    #expect(queue.toCheckCount == 0)
    #expect(!queue.items.contains { $0.session == session })
}

@Test func anInterruptedDesktopTurnStopsWorkingWhenItsRolloutHoldsImages() throws {
    // The shapes recorded on 2026-10-08 for an image-generating desktop session. The user
    // interrupted a turn (no Stop hook); the next turn sent tool events and Stop but no
    // UserPromptSubmit, so only the rollout's turn_aborted ends the interrupted one. Image outputs
    // made several rollout lines larger than 1 MiB, and the rollout itself larger than 32 MiB.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let events = root.appendingPathComponent("events"), rollouts = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), finished = UUID(), interrupted = UUID(), later = UUID()
    let common: [String: Any] = ["session_id": session.uuidString, "source": "steer-hook-v1"]
    let records: [[String: Any]] = [
        ["hook_event_name": "SessionStart", "received_at": "2026-10-08T06:10:52Z", "captured_at": 1_791_439_852.0],
        ["hook_event_name": "UserPromptSubmit", "received_at": "2026-10-08T06:10:54Z", "captured_at": 1_791_439_854.0,
         "turn_id": finished.uuidString, "prompt": "Draw some icons"],
        ["hook_event_name": "Stop", "received_at": "2026-10-08T06:11:40Z", "captured_at": 1_791_439_900.0,
         "turn_id": finished.uuidString],
        ["hook_event_name": "UserPromptSubmit", "received_at": "2026-10-08T06:16:10Z", "captured_at": 1_791_440_170.0,
         "turn_id": interrupted.uuidString, "prompt": "Make them larger"],
        ["hook_event_name": "PreToolUse", "received_at": "2026-10-08T06:55:19Z", "captured_at": 1_791_442_519.0,
         "turn_id": later.uuidString, "tool_name": "Bash", "tool_use_id": "exec-1", "tool_input": ["command": "ls"]],
        ["hook_event_name": "PostToolUse", "received_at": "2026-10-08T06:55:20Z", "captured_at": 1_791_442_520.0,
         "turn_id": later.uuidString, "tool_name": "Bash", "tool_use_id": "exec-1"],
        ["hook_event_name": "Stop", "received_at": "2026-10-08T06:57:01Z", "captured_at": 1_791_442_621.0,
         "turn_id": later.uuidString]
    ]
    for (index, record) in records.enumerated() {
        try JSONSerialization.data(withJSONObject: record.merging(common) { own, _ in own })
            .write(to: events.appendingPathComponent("\(index).json"))
    }
    func event(_ kind: String, _ turn: UUID, _ at: String) -> String {
        "{\"timestamp\":\"\(at)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"\(turn.uuidString.lowercased())\"}}\n"
    }
    let image = try JSONSerialization.data(withJSONObject: [
        "timestamp": "2026-10-08T06:16:14.850Z", "type": "response_item",
        // Larger than the 32 MiB a rollout may keep, so the scan must stream and drop it.
        "payload": ["type": "custom_tool_call_output", "call_id": "image-1", "output": String(repeating: "A", count: 34 * 1024 * 1024)]
    ])
    let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session.uuidString.lowercased())\",\"source\":\"vscode\",\"originator\":\"Codex Desktop\"}}\n"
    let rollout = header + event("task_started", finished, "2026-10-08T06:10:54.055Z")
        + event("task_complete", finished, "2026-10-08T06:11:40.285Z")
        + event("task_started", interrupted, "2026-10-08T06:16:10.015Z")
        + String(decoding: image, as: UTF8.self) + "\n"
        + event("turn_aborted", interrupted, "2026-10-08T06:16:19.218Z")
        + event("task_started", later, "2026-10-08T06:54:49.089Z")
        + event("task_complete", later, "2026-10-08T06:57:02.001Z")
    try rollout.write(to: rollouts.appendingPathComponent("rollout-2026-10-08T14-10-52-\(session.uuidString.lowercased()).jsonl"),
                      atomically: true, encoding: .utf8)

    var queue = AttentionQueue(observingSince: 0)
    queue.apply(scan: ReminderReader.scan(events: events, rollouts: rollouts),
                desktopEvents: DesktopEventReader.read(from: events), now: 1_791_445_200)
    #expect(!queue.items.contains { $0.session == session && $0.kind == .running })
    #expect(queue.workingCount == 0)
}
