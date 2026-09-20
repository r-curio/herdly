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

    let scan = scanClaude(root)
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

    let scan = scanClaude(root)
    let running = try #require(scan.observations.compactMap { observation -> AgentRunning? in
        if case let .running(value) = observation { return value }
        return nil
    }.first)

    #expect(running.toolName == "Bash")
    #expect(running.toolInput["command"] == "new")
    #expect(scan.observations.contains { if case .approval = $0 { return true }; return false } == false)
}

@Test func claudeBashApprovalKeepsTheHelperTokenAndCommandDetails() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "call",
                     toolInput: ["command": "touch marker"]),
        claudeRecord("PermissionRequest", at: 3, promptID: "p1", toolName: "Bash",
                     approvalRequestID: "request-1")
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let approval = try #require(scanClaude(root).observations.compactMap { observation -> AgentApproval? in
        if case let .approval(value) = observation { return value }
        return nil
    }.first)
    #expect(approval.hookRequestID == "request-1")
    #expect(approval.details?.action == "Bash")
    #expect(approval.details?.command == "touch marker")
}

@Test func claudePermissionBeforeItsPreToolCandidateCannotCreateApproval() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PermissionRequest", at: 2, promptID: "p1", toolName: "Bash"),
        claudeRecord("PreToolUse", at: 3, promptID: "p1", toolName: "Bash", toolUseID: "late",
                     toolInput: ["command": "late"])
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(scanClaude(root).observations.contains { if case .approval = $0 { return true }; return false } == false)
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

    let scan = scanClaude(root)
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

    let scan = scanClaude(root)

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

    let scan = scanClaude(root)

    #expect(scan.observations.count == 1)
    guard case let .outcome(outcome) = scan.observations[0] else {
        Issue.record("StopFailure should be the only observation for its terminal turn")
        return
    }
    #expect(outcome.status == .failed)
}

@Test func claudeStopFailureClearsRequestsWithoutASeparateStop() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "AskUserQuestion", toolUseID: "q1",
                     toolInput: ["questions": [["question": "Choose"]]]),
        claudeRecord("PreToolUse", at: 2.5, promptID: "p1", toolName: "Bash", toolUseID: "a1",
                     toolInput: ["command": "touch marker"]),
        claudeRecord("PermissionRequest", at: 2.75, promptID: "p1", toolName: "Bash")
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = AgentAttentionQueue()
    queue.apply(scanClaude(root))
    #expect(queue.items.contains { $0.kind == .question })
    #expect(queue.items.contains { $0.kind == .actionableApproval })

    try appendClaudeEvent(claudeRecord("StopFailure", at: 3, promptID: "p1"), to: root)
    queue.apply(scanClaude(root))

    #expect(queue.items.filter { $0.session.source == .claude }.map(\.kind) == [.outcome])
    #expect(queue.items.first?.outcome?.status == .failed)
}

@Test func claudeMatchingPostClearsOnlyTheQuestionOrApprovalCall() throws {
    let questionRoot = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "AskUserQuestion", toolUseID: "question-call",
                     toolInput: ["questions": [["question": "Choose"]]]),
        claudeRecord("PreToolUse", at: 3, promptID: "p1", toolName: "Bash", toolUseID: "other-call",
                     toolInput: ["command": "run"]),
        claudeRecord("PostToolUse", at: 4, promptID: "p1", toolUseID: "question-call")
    ])
    let approvalRoot = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "approval-call",
                     toolInput: ["command": "approval"]),
        claudeRecord("PermissionRequest", at: 3, promptID: "p1", toolName: "Bash"),
        claudeRecord("PostToolUseFailure", at: 4, promptID: "p1", toolUseID: "approval-call")
    ])
    defer {
        try? FileManager.default.removeItem(at: questionRoot)
        try? FileManager.default.removeItem(at: approvalRoot)
    }

    let questionObservations = scanClaude(questionRoot).observations
    #expect(questionObservations.contains { if case .question = $0 { return true }; return false } == false)
    #expect(questionObservations.contains { observation in
        if case let .running(value) = observation { return value.toolInput["command"] == "run" }
        return false
    })
    let approvalObservations = scanClaude(approvalRoot).observations
    #expect(approvalObservations.contains { if case .approval = $0 { return true }; return false } == false)
}

@Test func claudeSessionEndReconcilesQuestionAndHiddenRunningState() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "AskUserQuestion", toolUseID: "question-call",
                     toolInput: ["questions": [["question": "Choose"]]])
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = AgentAttentionQueue()
    queue.apply(scanClaude(root))
    #expect(queue.items.contains { $0.kind == .question })
    #expect(queue.workingCount == 1)

    try appendClaudeEvent(claudeRecord("SessionEnd", at: 3), to: root)
    queue.apply(scanClaude(root))
    #expect(queue.items.filter { $0.session.source == .claude }.isEmpty)
    #expect(queue.workingCount == 0)
}

@Test func claudeToolTextFallsBackAfterTheInjectedFreshnessBound() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "Keep working"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                     toolInput: ["command": "run"])
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let fresh = scanClaude(root, now: 31).observations
    let stale = scanClaude(root, now: 33).observations
    #expect(fresh.contains { if case let .running(value) = $0 { return value.fullAction == "run" }; return false })
    #expect(stale.contains { if case let .running(value) = $0 { return value.fullAction == nil && value.prompt == "Keep working" }; return false })
}

@Test func claudeQuestionCarriesBoundedPromptsAndLiveHelperIdentity() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "AskUserQuestion", toolUseID: "q1",
                     helperRequestID: "request-1",
                     toolInput: ["questions": [["question": "Which?",
                                                  "options": [["label": "Red"], ["label": "Blue"]],
                                                  "multiSelect": false]]])
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let question = try #require(scanClaude(root).observations.compactMap { observation -> AgentQuestion? in
        if case let .question(value) = observation { return value }
        return nil
    }.first)
    #expect(question.helperRequestID == "request-1")
    #expect(question.prompts.first?.question == "Which?")
    #expect(question.prompts.first?.options == ["Red", "Blue"])
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

    let scanA = scanClaude(rootA)
    let scanB = scanClaude(rootB)
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

@Test func claudeDelayedStopFailureCannotClearNewerActivityDuringReplay() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "Keep working"),
        claudeRecord("PreToolUse", at: 10, promptID: "p1", toolName: "Bash", toolUseID: "new-tool",
                     toolInput: ["command": "new"])
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = AgentAttentionQueue()
    queue.apply(scanClaude(root, now: 20))
    #expect(queue.items.first?.running?.fullAction == "new")

    try appendClaudeEvent(claudeRecord("StopFailure", at: 5, promptID: "p1"), to: root)
    queue.apply(scanClaude(root, now: 20))

    #expect(queue.items.filter { $0.session.source == .claude }.map(\.kind) == [.running])
    #expect(queue.items.first?.running?.fullAction == "new")
}

@Test func claudeDelayedSessionEndCannotClearNewerActivityDuringReplay() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "Keep working"),
        claudeRecord("PreToolUse", at: 10, promptID: "p1", toolName: "Bash", toolUseID: "new-tool",
                     toolInput: ["command": "new"])
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = AgentAttentionQueue()
    queue.apply(scanClaude(root, now: 20))
    #expect(queue.items.first?.running?.fullAction == "new")

    try appendClaudeEvent(claudeRecord("SessionEnd", at: 5), to: root)
    queue.apply(scanClaude(root, now: 20))

    #expect(queue.items.filter { $0.session.source == .claude }.map(\.kind) == [.running])
    #expect(queue.items.first?.running?.fullAction == "new")
}

@Test func claudeDelayedFailureCannotReintroduceAnOlderPromptAfterALaterPrompt() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "First"),
        claudeRecord("UserPromptSubmit", at: 10, promptID: "p2", prompt: "Second")
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = AgentAttentionQueue()
    queue.apply(scanClaude(root, now: 20))
    #expect(queue.items.filter { $0.session.source == .claude }.map(\.running?.identity.turn) == ["p2"])

    try appendClaudeEvent(claudeRecord("StopFailure", at: 5, promptID: "p1"), to: root)
    queue.apply(scanClaude(root, now: 20))

    #expect(queue.items.filter { $0.session.source == .claude }.map(\.kind) == [.outcome, .running])
    #expect(queue.items.first?.outcome?.status == .failed)
    #expect(queue.items.compactMap(\.running).first?.identity.turn == "p2")
}

@Test func claudeRepeatedPromptCannotReopenAVerifiedFailureDuringReplay() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "First"),
        claudeRecord("StopFailure", at: 5, promptID: "p1")
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = AgentAttentionQueue()
    queue.apply(scanClaude(root, now: 20))
    #expect(queue.items.first?.outcome?.status == .failed)

    try appendClaudeEvent(claudeRecord("UserPromptSubmit", at: 10, promptID: "p1", prompt: "First"), to: root)
    queue.apply(scanClaude(root, now: 20))

    #expect(queue.items.filter { $0.session.source == .claude }.map(\.kind) == [.outcome])
    #expect(queue.items.first?.outcome?.status == .failed)
}

@Test func claudeQueueUpdatesToolDetailAndClearsItAfterStop() throws {
    let root = try makeClaudeEvents([claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "Inspect")])
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = AgentAttentionQueue()

    queue.apply(scanClaude(root))
    #expect(queue.items.first?.running?.toolName == nil)

    try appendClaudeEvent(claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                                       toolInput: ["command": "swift test"]), to: root)
    queue.apply(scanClaude(root))
    #expect(queue.items.first?.running?.fullAction == "swift test")

    try appendClaudeEvent(claudeRecord("Stop", at: 3, promptID: "p1"), to: root)
    queue.apply(scanClaude(root))
    #expect(queue.items.first?.running?.toolName == nil)
}

@Test func claudeQueueClearsToolDetailWhenFreshnessExpires() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "Keep working"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                     toolInput: ["command": "swift test"])
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = AgentAttentionQueue()

    queue.apply(scanClaude(root, now: 10))
    #expect(queue.items.first?.running?.fullAction == "swift test")

    queue.apply(scanClaude(root, now: 33))
    #expect(queue.items.first?.running?.fullAction == nil)
    #expect(queue.items.first?.running?.prompt == "Keep working")
}

@Test func claudeLaterPromptClosesOlderTurnWithoutInventingOutcome() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "First"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                     toolInput: ["command": "old"]),
        claudeRecord("PreToolUse", at: 2.5, promptID: "p1", toolName: "AskUserQuestion", toolUseID: "q1",
                     toolInput: ["questions": [["question": "Choose"]]]),
        claudeRecord("PreToolUse", at: 2.75, promptID: "p1", toolName: "Write", toolUseID: "a1",
                     toolInput: ["file_path": "/tmp/file"]),
        claudeRecord("PermissionRequest", at: 2.8, promptID: "p1", toolName: "Write"),
        claudeRecord("UserPromptSubmit", at: 3, promptID: "p2", prompt: "Second")
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let observations = scanClaude(root, now: 10).observations
    let running = try #require(observations.compactMap { observation -> AgentRunning? in
        if case let .running(value) = observation { return value }
        return nil
    }.first)

    #expect(running.identity.turn == "p2")
    #expect(observations.contains { if case .question = $0 { return true }; return false } == false)
    #expect(observations.contains { if case .approval = $0 { return true }; return false } == false)
    #expect(observations.contains { if case .outcome = $0 { return true }; return false } == false)
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

private func scanClaude(_ root: URL, now: Double = 10) -> ClaudeObservationScan {
    ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install", now: now)
}

private func claudeRecord(_ event: String, at capturedAt: Double, promptID: String? = nil,
                          prompt: String? = nil, toolName: String? = nil, toolUseID: String? = nil,
                          helperRequestID: String? = nil,
                          toolInput: [String: Any] = [:], approvalRequestID: String? = nil) -> [String: Any] {
    var record: [String: Any] = ["hook_event_name": event, "session_id": "session-1", "captured_at": capturedAt]
    if let promptID { record["prompt_id"] = promptID }
    if let prompt { record["prompt"] = prompt }
    if let toolName { record["tool_name"] = toolName }
    if let toolUseID { record["tool_use_id"] = toolUseID }
    if let helperRequestID { record["helper_request_id"] = helperRequestID }
    if let approvalRequestID { record["approval_request_id"] = approvalRequestID }
    if !toolInput.isEmpty { record["tool_input"] = toolInput }
    return record
}
