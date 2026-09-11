import Foundation
import Testing
@testable import SteerCore

@Test func cliLifecycleKeepsSessionStartTurnCompletionAndEndDistinct() {
    let session = UUID(), turn = UUID()
    var state = CLIState()
    state.apply(.sessionStarted(session: session, receivedAt: "01"))
    #expect(state.liveSessions == [session])
    #expect(state.running.isEmpty)

    state.apply(.turnStarted(session: session, turn: turn, receivedAt: "02"))
    #expect(state.liveSessions == [session])
    #expect(state.running == [CLIRunningTurn(session: session, turn: turn, startedAt: "02")])

    state.apply(.turnCompleted(session: session, turn: turn, receivedAt: "03"))
    #expect(state.liveSessions == [session])
    #expect(state.running.isEmpty)

    state.apply(.sessionEnded(session: session, receivedAt: "04"))
    #expect(state.liveSessions.isEmpty)
    #expect(state.endedSessions == [session])
    state.apply(.turnStarted(session: session, turn: UUID(), receivedAt: "05"))
    #expect(state.liveSessions.isEmpty)
    #expect(state.running.isEmpty)
}

@Test func cliEventsQueueOnlyVerifiedCLITurns() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = UUID(), b = UUID(), desktop = UUID(), turn = UUID(), next = UUID()
    func hook(_ session: UUID, _ event: String, _ turn: UUID?, _ time: String) throws {
        var object: [String: Any] = ["session_id":session.uuidString, "hook_event_name":event, "received_at":time]
        if let turn { object["turn_id"] = turn.uuidString }
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent(UUID().uuidString + ".json"))
    }
    func rollout(_ session: UUID, _ source: String, _ done: [UUID]) throws {
        var text = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"\(source)\"}}\n"
        for turn in done { text += "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turn)\"}}\n" }
        try Data(text.utf8).write(to: root.appendingPathComponent("rollout-" + session.uuidString.lowercased() + ".jsonl"))
    }
    for session in [a, b, desktop] {
        try hook(session, "SessionStart", nil, "01")
        try hook(session, "Stop", turn, "02")
        try rollout(session, session == desktop ? "vscode" : "cli", [turn])
    }
    try hook(a, "Stop", next, "03") // Stop alone must not imply completed turn.
    var scan = ReminderReader.scan(events: root, rollouts: root)
    #expect(Set(scan.cliCompletions.map(\.session)) == [a, b])
    #expect(scan.cliCompletions.count == 2)
    #expect(scan.liveCLISessions == [a, b])
    let cliState = CLIState.replay(scan.cliEvents)
    #expect(cliState.liveSessions == [a, b])
    #expect(cliState.running.isEmpty)
    var queue = CLIQueue()
    queue.apply(scan.cliCompletions)
    let first = try #require(queue.items.first(where: { $0.session == a }))
    queue.dismiss(first.id)
    var restored = CLIQueue(acknowledged: try JSONDecoder().decode(Set<TurnIdentity>.self, from: JSONEncoder().encode(queue.acknowledged)))
    restored.apply(scan.cliCompletions)
    #expect(restored.items.map(\.session) == [b])
    try rollout(a, "cli", [turn, next])
    try hook(b, "SessionEnd", nil, "04")
    scan = ReminderReader.scan(events: root, rollouts: root)
    restored.apply(scan.cliCompletions)
    #expect(restored.items.count == 2) // A later completion is not dismissed with the earlier one.
    #expect(scan.liveCLISessions == [a])
    #expect(CLIState.replay(scan.cliEvents).endedSessions == [b])
}

@Test func ghosttyMatchesExactUniqueUnsplitSession() throws {
    let a = UUID(uuidString: "01a09046-5590-7882-adad-6b7f4ec91925")!
    let b = UUID()
    func snapshot(_ tabs: [[String: Any]]) throws -> GhosttySnapshot {
        try JSONDecoder().decode(GhosttySnapshot.self, from: JSONSerialization.data(withJSONObject:
            ["status":"ok", "windows":[["id":"w", "tabs":tabs]], "selected":NSNull()]))
    }
    let tab: [String: Any] = ["id":"a", "terminals":[["id":"p", "name":GhosttyMatch.title(a)]]]
    let valid = try snapshot([tab])
    #expect(GhosttyMatch.title(a) == "01a09046-5590-7882-adad-6b7f4...")
    #expect(GhosttyMatch.target(session:a, live:[a,b], snapshot:valid)?.tab_id == "a")
    #expect(GhosttyMatch.target(session:a, live:[b], snapshot:valid) == nil)
    #expect(GhosttyMatch.target(session:a, live:[a], snapshot:try snapshot([tab,tab])) == nil)
    let collision = UUID(uuidString: "01a09046-5590-7882-adad-6b7f4ec91926")!
    #expect(GhosttyMatch.target(session:a, live:[a,collision], snapshot:valid) == nil)
    let split: [String: Any] = ["id":"a", "terminals":[["id":"p", "name":GhosttyMatch.title(a)], ["id":"p2", "name":"shell"]]]
    #expect(GhosttyMatch.target(session:a, live:[a], snapshot:try snapshot([split])) == nil)
}

@Test func ghosttyKeepsSameProjectSessionsDistinctAcrossWindows() throws {
    let a = UUID(uuidString: "01a09046-5590-7882-adad-6b7f4ec91925")!
    let b = UUID(uuidString: "01a09046-56da-7d83-9a38-02e59d7441ec")!
    let data: [String: Any] = [
        "status": "ok",
        "windows": [
            ["id": "window-a", "tabs": [["id": "tab-a", "terminals": [["id": "pane-a", "name": GhosttyMatch.title(a)]]]]],
            ["id": "window-b", "tabs": [["id": "tab-b", "terminals": [["id": "pane-b", "name": GhosttyMatch.title(b)]]]]]
        ],
        "selected": NSNull()
    ]
    let snapshot = try JSONDecoder().decode(GhosttySnapshot.self, from: JSONSerialization.data(withJSONObject: data))
    #expect(GhosttyMatch.target(session: a, live: [a, b], snapshot: snapshot) == GhosttyTarget(window_id: "window-a", tab_id: "tab-a", terminal_id: "pane-a"))
    #expect(GhosttyMatch.target(session: b, live: [a, b], snapshot: snapshot) == GhosttyTarget(window_id: "window-b", tab_id: "tab-b", terminal_id: "pane-b"))
}


@Test func completedRepliesGroupBySessionWithoutLosingTurnAcknowledgments() {
    let a = UUID(), b = UUID()
    let first = CLICompletion(session: a, turn: UUID(), receivedAt: "01")
    let second = CLICompletion(session: a, turn: UUID(), receivedAt: "02")
    let other = CLICompletion(session: b, turn: UUID(), receivedAt: "03")
    var queue = CLIQueue()
    queue.apply([first, second, other, first])
    #expect(queue.groups.map(\.session) == [a, b])
    #expect(queue.groups[0].completions.count == 2)
    let displayed = queue.groups[0]
    let newer = CLICompletion(session: a, turn: UUID(), receivedAt: "04")
    queue.apply([newer])
    for item in displayed.completions { queue.dismiss(item.id) }
    #expect(queue.items == [other, newer])
    var restored = CLIQueue(acknowledged: queue.acknowledged)
    restored.apply([first, second, other, newer])
    #expect(restored.items == [other, newer])
}
