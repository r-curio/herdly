import Foundation
import Testing
@testable import SteerCore

@Test func claudePostHookAndStopCleanupKeepToolIdentityBounded() throws {
    let root = try makeClaudeEvents([
        claudeRecord("SessionStart", at: 0),
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "Inspect"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                     toolInput: ["command": "old"]),
        claudeRecord("PostToolUse", at: 3, promptID: "p1", toolUseID: "other"),
        claudeRecord("Stop", at: 4, promptID: "p1"),
        claudeRecord("PostToolUseFailure", at: 5, promptID: "p1", toolUseID: "t1")
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let scan = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install")
    let running = try #require(scan.observations.compactMap { observation -> AgentRunning? in
        if case let .running(value) = observation { return value }
        return nil
    }.first)

    #expect(running.prompt == "Inspect")
    #expect(running.toolName == nil)
    #expect(scan.observations.contains { if case .outcome = $0 { return true }; return false } == false)
}

@Test func claudeLatePostCannotClearNewerToolAndAmbiguousApprovalIsIgnored() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                     toolInput: ["command": "old"]),
        claudeRecord("PreToolUse", at: 3, promptID: "p1", toolName: "Bash", toolUseID: "t2",
                     toolInput: ["command": "new"]),
        claudeRecord("PermissionRequest", at: 3.5, promptID: "p1", toolName: "Bash"),
        claudeRecord("PostToolUse", at: 4, promptID: "p1", toolUseID: "t1")
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let scan = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install")
    let running = try #require(scan.observations.compactMap { observation -> AgentRunning? in
        if case let .running(value) = observation { return value }
        return nil
    }.first)

    #expect(running.toolName == "Bash")
    #expect(running.toolInput["command"] == "new")
    #expect(scan.observations.contains { if case .approval = $0 { return true }; return false } == false)
}

@Test func claudeMalformedRepeatedAndMismatchedEventsCannotCreateTerminalState() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                     toolInput: ["command": "run"]),
        claudeRecord("UserPromptSubmit", at: 3, promptID: "p1"),
        claudeRecord("PostToolUse", at: 4, promptID: "p1", toolUseID: "other")
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var foreign = claudeRecord("StopFailure", at: 5, promptID: "p1")
    foreign["source"] = "foreign-helper"
    try JSONSerialization.data(withJSONObject: foreign, options: [])
        .write(to: root.appendingPathComponent("foreign.json"), options: .atomic)
    try Data("{ malformed".utf8).write(to: root.appendingPathComponent("malformed.json"), options: .atomic)

    let scan = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install")
    let running = try #require(scan.observations.compactMap { observation -> AgentRunning? in
        if case let .running(value) = observation { return value }
        return nil
    }.first)

    #expect(running.toolInput["command"] == "run")
    #expect(scan.observations.contains { if case .outcome = $0 { return true }; return false } == false)
}

@Test func claudeSessionEndDropsSpecificityWithoutInventingTerminalOutcome() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                     toolInput: ["command": "run"]),
        claudeRecord("SessionEnd", at: 3)
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let scan = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install")

    #expect(scan.observations.isEmpty)
}

@Test func claudeStopFailureResolvesPendingRequestsAndStopCannotReopenItsTurn() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                     toolInput: ["command": "run"]),
        claudeRecord("PermissionRequest", at: 2.5, promptID: "p1", toolName: "Bash"),
        claudeRecord("Stop", at: 3, promptID: "p1"),
        claudeRecord("PreToolUse", at: 4, promptID: "p1", toolName: "Bash", toolUseID: "late",
                     toolInput: ["command": "late"]),
        claudeRecord("StopFailure", at: 5, promptID: "p1")
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let scan = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install")

    #expect(scan.observations.count == 1)
    guard case let .outcome(outcome) = scan.observations[0] else {
        Issue.record("StopFailure should be the only observation for its terminal turn")
        return
    }
    #expect(outcome.status == .failed)
}

@Test func claudeRootsAndInstallationIDsCannotClearEachOther() throws {
    let rootA = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "a"),
        claudeRecord("PreToolUse", at: 2, promptID: "a", toolName: "Bash", toolUseID: "a-tool",
                     toolInput: ["command": "a"])
    ])
    let rootB = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "b"),
        claudeRecord("PreToolUse", at: 2, promptID: "b", toolName: "Bash", toolUseID: "b-tool",
                     toolInput: ["command": "b"])
    ])
    var wrongInstallation = claudeRecord("PreToolUse", at: 3, promptID: "ignored", toolName: "Bash",
                                         toolUseID: "wrong-install", toolInput: ["command": "wrong"])
    wrongInstallation["source"] = ClaudeSetupRequirements.helperSource
    wrongInstallation["installation_id"] = "other-install"
    try JSONSerialization.data(withJSONObject: wrongInstallation, options: [])
        .write(to: rootB.appendingPathComponent("wrong-install.json"), options: .atomic)
    defer {
        try? FileManager.default.removeItem(at: rootA)
        try? FileManager.default.removeItem(at: rootB)
    }

    let scanA = ClaudeObservationReader.scan(events: rootA, sourceScope: rootA.path, installationID: "install")
    let scanB = ClaudeObservationReader.scan(events: rootB, sourceScope: rootB.path, installationID: "install")
    var queue = AgentAttentionQueue()
    queue.apply(scanB)
    queue.apply(scanA)

    let running = queue.items.compactMap { $0.running }
    #expect(Set(running.map { $0.identity.session.sourceScope }) == [rootA.path, rootB.path])
    #expect(running.filter { $0.identity.session.sourceScope == rootB.path }.first?.toolInput["command"] == "b")
}

@Test func claudeLateOutcomeCannotReplaceNewerRunningActivity() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "root", session: "s", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: identity, turn: "p", arrivedAt: 10)))
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "p", status: .stopped, arrivedAt: 9)))

    #expect(queue.items.compactMap { $0.running }.count == 1)
    #expect(queue.items.compactMap { $0.outcome }.isEmpty)
}

@Test func claudeQueueUpdatesToolDetailAndClearsItAfterStop() throws {
    let root = try makeClaudeEvents([claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "Inspect")])
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = AgentAttentionQueue()

    queue.apply(ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install"))
    #expect(queue.items.first?.running?.toolName == nil)

    try appendClaudeEvent(claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                                       toolInput: ["command": "swift test"]), to: root)
    queue.apply(ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install"))
    #expect(queue.items.first?.running?.fullAction == "swift test")

    try appendClaudeEvent(claudeRecord("Stop", at: 3, promptID: "p1"), to: root)
    queue.apply(ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install"))
    #expect(queue.items.first?.running?.toolName == nil)
}

private func makeClaudeEvents(_ records: [[String: Any]], installationID: String = "install") throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-events-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (index, var record) in records.enumerated() {
        record["source"] = ClaudeSetupRequirements.helperSource
        record["installation_id"] = installationID
        let data = try JSONSerialization.data(withJSONObject: record, options: [])
        try data.write(to: root.appendingPathComponent("event-\(index).json"), options: .atomic)
    }
    return root
}

private func appendClaudeEvent(_ record: [String: Any], to root: URL, installationID: String = "install") throws {
    var record = record
    record["source"] = ClaudeSetupRequirements.helperSource
    record["installation_id"] = installationID
    let data = try JSONSerialization.data(withJSONObject: record, options: [])
    try data.write(to: root.appendingPathComponent("event-\(UUID().uuidString).json"), options: .atomic)
}

private func claudeRecord(_ event: String, at capturedAt: Double, promptID: String? = nil,
                          prompt: String? = nil, toolName: String? = nil, toolUseID: String? = nil,
                          toolInput: [String: Any] = [:]) -> [String: Any] {
    var record: [String: Any] = ["hook_event_name": event, "session_id": "session-1", "captured_at": capturedAt]
    if let promptID { record["prompt_id"] = promptID }
    if let prompt { record["prompt"] = prompt }
    if let toolName { record["tool_name"] = toolName }
    if let toolUseID { record["tool_use_id"] = toolUseID }
    if !toolInput.isEmpty { record["tool_input"] = toolInput }
    return record
}
