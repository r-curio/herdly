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

@Test func claudeLongPromptIsShortenedForTheWorkingRowInsteadOfDropped() throws {
    let long = String(repeating: "Refactor the queue so ", count: 30) + "it stays ordered."
    let wide = String(repeating: "整理", count: 100)
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: long, session: "long"),
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: wide, session: "wide"),
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "Inspect", session: "short")
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let running = Dictionary(uniqueKeysWithValues: scanClaude(root).observations.compactMap { observation -> (String, AgentRunning)? in
        if case let .running(value) = observation { return (value.identity.session.session, value) }
        return nil
    })

    let longRow = try #require(running["long"])
    #expect(longRow.prompt == String(long.prefix(ClaudeObservationReader.maximumPrompt)) + "…")
    #expect(longRow.promptShortened)
    #expect(longRow.rowText == String(long.prefix(160)) + "…")
    // 200 characters but 600 bytes: within the character cap, so kept whole.
    #expect(running["wide"]?.prompt == wide)
    #expect(running["wide"]?.promptShortened == false)
    #expect(running["short"]?.prompt == "Inspect")
    #expect(running["short"]?.promptShortened == false)
}

@Test func claudeHelperShortenedPromptKeepsItsTextAndMark() throws {
    let stored = try #require(ClaudeObservationReader.promptFallback(String(repeating: "a", count: 500)))
    #expect(stored.shortened)
    #expect(stored.text.count == ClaudeObservationReader.maximumPrompt + 1)
    var record = claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: stored.text)
    record[ClaudeObservationReader.promptShortenedKey] = true
    let root = try makeClaudeEvents([record])
    defer { try? FileManager.default.removeItem(at: root) }

    let running = try #require(scanClaude(root).observations.compactMap { observation -> AgentRunning? in
        if case let .running(value) = observation { return value }
        return nil
    }.first)

    #expect(running.prompt == stored.text)
    #expect(running.promptShortened)
}

@Test func claudePromptFallbackKeepsBoundedTextAndRejectsTerminalControls() {
    let exact = String(repeating: "b", count: ClaudeObservationReader.maximumPrompt)
    #expect(ClaudeObservationReader.promptFallback(exact)?.text == exact)
    #expect(ClaudeObservationReader.promptFallback(exact)?.shortened == false)
    #expect(ClaudeObservationReader.promptFallback(exact + "c")?.text == exact + "…")
    #expect(ClaudeObservationReader.promptFallback(exact + "c")?.shortened == true)
    #expect(ClaudeObservationReader.promptFallback("First line\nsecond line")?.text == "First line\nsecond line")
    #expect(ClaudeObservationReader.promptFallback("  \n ") == nil)
    #expect(ClaudeObservationReader.promptFallback("clear \u{1b}[2J") == nil)
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

    // Only the prompt's reply evidence remains; no running row or outcome is invented.
    #expect(scan.observations == [.replied(AgentTurnIdentity(session: AgentSessionIdentity(
        source: .claude, sourceScope: root.path, session: "session-1", surface: .cli), turn: "p1"), submittedAt: 1)])
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

    let observations = scan.observations.filter { if case .replied = $0 { return false }; return true }
    #expect(observations.count == 1)
    guard case let .outcome(outcome) = observations[0] else {
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

@Test func claudeToolActivityKeepsRunningSessionsInTurnArrivalOrder() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", session: "session-1"),
        claudeRecord("UserPromptSubmit", at: 2, promptID: "p2", session: "session-2")
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = AgentAttentionQueue()
    queue.apply(scanClaude(root, now: 3))
    #expect(queue.items.map(\.session.session) == ["session-1", "session-2"])

    // Each tool event is newer evidence for its turn, but neither moves its session in the queue.
    try appendClaudeEvent(claudeRecord("PreToolUse", at: 4, promptID: "p1", toolName: "Bash", toolUseID: "t1",
                                       toolInput: ["command": "first"], session: "session-1"), to: root)
    queue.apply(scanClaude(root, now: 5))
    #expect(queue.items.map(\.session.session) == ["session-1", "session-2"])
    #expect(queue.items.first?.running?.fullAction == "first")

    try appendClaudeEvent(claudeRecord("PreToolUse", at: 6, promptID: "p2", toolName: "Bash", toolUseID: "t2",
                                       toolInput: ["command": "second"], session: "session-2"), to: root)
    try appendClaudeEvent(claudeRecord("PostToolUse", at: 7, promptID: "p1", toolUseID: "t1",
                                       session: "session-1"), to: root)
    queue.apply(scanClaude(root, now: 8))
    #expect(queue.items.map(\.session.session) == ["session-1", "session-2"])
    #expect(queue.items.map { $0.running?.arrivedAt } == [1, 2])
    #expect(queue.items.map { $0.running?.updatedAt } == [7, 6])
    #expect(queue.items.last?.running?.fullAction == "second")
}

@Test func claudeFreshnessRulesCompareLatestEvidenceNotArrival() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "root", session: "s", surface: .cli)
    // The turn arrived at 1 and its latest tool event was at 10: an outcome from 9 is older evidence.
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: identity, turn: "p", arrivedAt: 1, updatedAt: 10)))
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "p", status: .stopped, arrivedAt: 9)))
    #expect(queue.items.compactMap { $0.running }.map(\.arrivedAt) == [1])
    #expect(queue.items.compactMap { $0.outcome }.isEmpty)

    // An outcome at 5 after activity up to 4 stands, and activity at 6 reopens the same turn.
    var reopened = AgentAttentionQueue()
    reopened.apply(.running(AgentRunning(session: identity, turn: "p", arrivedAt: 1, updatedAt: 4)))
    reopened.apply(.outcome(AgentOutcome(session: identity, turn: "p", status: .stopped, arrivedAt: 5)))
    #expect(reopened.items.compactMap { $0.outcome }.count == 1)
    reopened.apply(.running(AgentRunning(session: identity, turn: "p", arrivedAt: 1, updatedAt: 6)))
    #expect(reopened.items.compactMap { $0.running }.map(\.arrivedAt) == [1])
    #expect(reopened.items.compactMap { $0.outcome }.isEmpty)
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

    // The failure happened before the user submitted p2, so that reply acknowledges it; p2 keeps running.
    #expect(queue.items.filter { $0.session.source == .claude }.map(\.kind) == [.running])
    #expect(queue.snapshot.acknowledgedOutcomes.map(\.turn) == ["p1"])
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

// Replying in a Claude session is evidence the user saw that session's earlier outcomes.
@Test func claudeReplyAcknowledgesEarlierOutcomesOfThatSessionOnly() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "root", session: "s", surface: .cli)
    let other = AgentSessionIdentity(source: .claude, sourceScope: "root", session: "other", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "p1", status: .finished, arrivedAt: 10)))
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "p2", status: .finished, arrivedAt: 20)))
    queue.apply(.outcome(AgentOutcome(session: other, turn: "o1", status: .finished, arrivedAt: 5)))

    queue.apply(.replied(AgentTurnIdentity(session: identity, turn: "p3"), submittedAt: 25))

    #expect(queue.items.compactMap { $0.outcome?.id } == [AgentTurnIdentity(session: other, turn: "o1")])
    #expect(queue.snapshot.acknowledgedOutcomes.contains(AgentTurnIdentity(session: identity, turn: "p1")))
    #expect(queue.snapshot.acknowledgedOutcomes.contains(AgentTurnIdentity(session: identity, turn: "p2")))
}

@Test func claudeReplyKeepsOutcomesThatArriveAfterItAndItsOwnTurn() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "root", session: "s", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.replied(AgentTurnIdentity(session: identity, turn: "p2"), submittedAt: 20))
    // An earlier turn still finishing when the user typed, and the reply's own turn finishing later.
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "p1", status: .finished, arrivedAt: 21)))
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "p2", status: .finished, arrivedAt: 30)))
    // The boundary: an outcome arriving at the submission instant is not before it.
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "p0", status: .finished, arrivedAt: 20)))

    #expect(Set(queue.items.compactMap { $0.outcome?.turn }) == ["p0", "p1", "p2"])
}

@Test func claudeReplyObservedBeforeAnOlderOutcomeStillAcknowledgesIt() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "root", session: "s", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.replied(AgentTurnIdentity(session: identity, turn: "p2"), submittedAt: 20))
    queue.apply(.replied(AgentTurnIdentity(session: identity, turn: "p1"), submittedAt: 5))
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "p1", status: .finished, arrivedAt: 10)))

    #expect(queue.items.compactMap { $0.outcome }.isEmpty)
    #expect(queue.snapshot.acknowledgedOutcomes.contains(AgentTurnIdentity(session: identity, turn: "p1")))
}

@Test func claudeReplyWithANonFiniteTimeAcknowledgesNothing() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "root", session: "s", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "p1", status: .finished, arrivedAt: 10)))
    queue.apply(.replied(AgentTurnIdentity(session: identity, turn: "p2"), submittedAt: .infinity))
    queue.apply(.replied(AgentTurnIdentity(session: identity, turn: "p2"), submittedAt: .nan))

    #expect(queue.items.compactMap { $0.outcome?.turn } == ["p1"])
}

@Test func claudeScanReplyClearsTheRestoredOutcomeTheUserAnswered() throws {
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1", prompt: "First"),
        claudeRecord("StopFailure", at: 2, promptID: "p1"),
        claudeRecord("UserPromptSubmit", at: 3, promptID: "p2", prompt: "Second"),
        claudeRecord("StopFailure", at: 4, promptID: "p2")
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let scan = scanClaude(root)
    var queue = AgentAttentionQueue()
    queue.apply(scan, now: 10)

    // p1 was answered by p2; p2's outcome has no later reply yet.
    #expect(queue.items.compactMap { $0.outcome?.turn } == ["p2"])
    #expect(scan.observations.contains { if case .replied(let prompt, 3) = $0 { return prompt.turn == "p2" }; return false })

    // Rescanning the same records (as every poll does) cannot bring p1 back.
    queue.apply(scanClaude(root), now: 11)
    #expect(queue.items.compactMap { $0.outcome?.turn } == ["p2"])

    // The acknowledgment survives a restart from the persisted snapshot.
    var restored = AgentAttentionQueue(snapshot: queue.snapshot)
    restored.apply(scanClaude(root), now: 12)
    #expect(restored.items.compactMap { $0.outcome?.turn } == ["p2"])
}

@Test func claudeReplyInAnotherRootOrSourceCannotAcknowledge() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "root", session: "s", surface: .cli)
    let otherRoot = AgentSessionIdentity(source: .claude, sourceScope: "alternate", session: "s", surface: .cli)
    let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s", surface: .desktop)
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "p1", status: .finished, arrivedAt: 10)))
    queue.apply(.outcome(AgentOutcome(session: codex, turn: "c1", status: .finished, arrivedAt: 10)))
    queue.apply(.replied(AgentTurnIdentity(session: otherRoot, turn: "p2"), submittedAt: 20))

    #expect(queue.items.compactMap { $0.outcome }.count == 2)
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
                          toolInput: [String: Any] = [:], approvalRequestID: String? = nil,
                          session: String = "session-1") -> [String: Any] {
    var record: [String: Any] = ["hook_event_name": event, "session_id": session, "captured_at": capturedAt]
    if let promptID { record["prompt_id"] = promptID }
    if let prompt { record["prompt"] = prompt }
    if let toolName { record["tool_name"] = toolName }
    if let toolUseID { record["tool_use_id"] = toolUseID }
    if let helperRequestID { record["helper_request_id"] = helperRequestID }
    if let approvalRequestID { record["approval_request_id"] = approvalRequestID }
    if !toolInput.isEmpty { record["tool_input"] = toolInput }
    return record
}

// MARK: - File-family approvals

private func fileDetails(_ tool: String, _ input: [String: Any]) -> [String: Any] {
    let details = ClaudeDirectApproval.details(toolName: tool, toolInput: input)!
    let data = try! JSONEncoder().encode(details)
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

private func filePermission(at: Double, tool: String = "Edit", input: [String: Any], requestID: String? = "request-1",
                            details: [String: Any]? = nil) -> [String: Any] {
    var record = claudeRecord("PermissionRequest", at: at, promptID: "p1", toolName: tool,
                              toolInput: ["file_path": input["file_path"] as Any], approvalRequestID: requestID)
    if let details = details ?? (ClaudeDirectApproval.details(toolName: tool, toolInput: input) != nil
                                  ? fileDetails(tool, input) : nil) {
        record["approval_details"] = details
    }
    return record
}

private func approvals(_ root: URL) -> [AgentApproval] {
    scanClaude(root).observations.compactMap { observation -> AgentApproval? in
        if case let .approval(value) = observation { return value }
        return nil
    }
}

@Test func claudeEditApprovalShowsTheHelpersValidatedDetails() throws {
    let input: [String: Any] = ["file_path": "/tmp/lab/target.txt", "old_string": "alpha", "new_string": "beta",
                                "replace_all": false]
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Edit", toolUseID: "call",
                     toolInput: ["file_path": "/tmp/lab/target.txt"]),
        filePermission(at: 3, input: input)
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let approval = try #require(approvals(root).first)
    #expect(approval.identity.call == "call")
    #expect(approval.hookRequestID == "request-1")
    #expect(approval.details?.action == "Edit file")
    #expect(approval.details?.command == "/tmp/lab/target.txt")
    #expect(approval.details?.commandLabel == "path")
    #expect(approval.details?.longText == "Replace:\nalpha\n\nWith:\nbeta")
}

@Test func claudeFileApprovalNeedsTheHelpersDetailsAndOneCallOnThatPath() throws {
    let input: [String: Any] = ["file_path": "/tmp/a", "old_string": "x", "new_string": "y", "replace_all": false]
    // No validated details: an older helper, or a shape the helper refused. Claude's dialog stays in charge.
    let undecidable = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Edit", toolUseID: "call", toolInput: ["file_path": "/tmp/a"]),
        claudeRecord("PermissionRequest", at: 3, promptID: "p1", toolName: "Edit", toolInput: ["file_path": "/tmp/a"])
    ])
    defer { try? FileManager.default.removeItem(at: undecidable) }
    #expect(approvals(undecidable).isEmpty)

    // The request names a different path from the only open Edit call.
    let otherPath = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Edit", toolUseID: "call", toolInput: ["file_path": "/tmp/b"]),
        filePermission(at: 3, input: input)
    ])
    defer { try? FileManager.default.removeItem(at: otherPath) }
    #expect(approvals(otherPath).isEmpty)

    // Two open Edit calls on the same path cannot be told apart.
    let ambiguous = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Edit", toolUseID: "c1", toolInput: ["file_path": "/tmp/a"]),
        claudeRecord("PreToolUse", at: 2.5, promptID: "p1", toolName: "Edit", toolUseID: "c2", toolInput: ["file_path": "/tmp/a"]),
        filePermission(at: 3, input: input)
    ])
    defer { try? FileManager.default.removeItem(at: ambiguous) }
    #expect(approvals(ambiguous).isEmpty)

    // An open Edit call on another path does not make the request ambiguous.
    let distinct = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Edit", toolUseID: "other", toolInput: ["file_path": "/tmp/b"]),
        claudeRecord("PreToolUse", at: 2.5, promptID: "p1", toolName: "Edit", toolUseID: "mine", toolInput: ["file_path": "/tmp/a"]),
        filePermission(at: 3, input: input)
    ])
    defer { try? FileManager.default.removeItem(at: distinct) }
    #expect(approvals(distinct).map(\.identity.call) == ["mine"])
}

@Test func claudeFileApprovalRejectsTamperedOrUnboundedDetails() throws {
    let input: [String: Any] = ["file_path": "/tmp/a", "content": "x"]
    for details: [String: Any] in [
        ["action": "Write file", "command": "relative/path", "command_label": "path"],
        ["action": "Write file", "command": "/tmp/a", "long_text": "clear \u{1b}[2J"],
        ["action": "Write file\nInjected", "command": "/tmp/a"],
        ["action": "Write file", "command": "/tmp/a",
         "long_text": String(repeating: "x", count: ClaudeDirectApproval.maximumPreview * 3)],
    ] {
        let root = try makeClaudeEvents([
            claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
            claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "Write", toolUseID: "call", toolInput: ["file_path": "/tmp/a"]),
            filePermission(at: 3, tool: "Write", input: input, details: details)
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(approvals(root).isEmpty, "\(details)")
    }
}

@Test func claudeFileApprovalClearsOnItsOwnPostToolUse() throws {
    let input: [String: Any] = ["notebook_path": "/tmp/nb.ipynb", "cell_id": "c1", "new_source": "print(2)", "edit_mode": "replace"]
    var request = claudeRecord("PermissionRequest", at: 3, promptID: "p1", toolName: "NotebookEdit",
                               toolInput: ["notebook_path": "/tmp/nb.ipynb"], approvalRequestID: "request-1")
    request["approval_details"] = fileDetails("NotebookEdit", input)
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "NotebookEdit", toolUseID: "call",
                     toolInput: ["notebook_path": "/tmp/nb.ipynb"]),
        request
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(approvals(root).first?.details?.action == "Edit notebook")

    try appendClaudeEvent(claudeRecord("PostToolUse", at: 4, promptID: "p1", toolUseID: "call"), to: root)
    #expect(approvals(root).isEmpty)
}

@Test func claudeWebFetchApprovalMatchesTheCallOnTheSameURL() throws {
    let input: [String: Any] = ["url": "https://example.com/", "prompt": "title?"]
    var request = claudeRecord("PermissionRequest", at: 3, promptID: "p1", toolName: "WebFetch",
                               toolInput: ["url": "https://example.com/"], approvalRequestID: "request-1")
    request["approval_details"] = fileDetails("WebFetch", input)
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 1.5, promptID: "p1", toolName: "WebFetch", toolUseID: "other",
                     toolInput: ["url": "https://httpbin.org/redirect-to"]),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "WebFetch", toolUseID: "call",
                     toolInput: ["url": "https://example.com/"]),
        request
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let approval = try #require(approvals(root).first)
    #expect(approval.identity.call == "call")
    #expect(approval.details?.action == "Fetch web page")
    #expect(approval.details?.commandLabel == "url")
}

@Test func claudeWebSearchApprovalNeedsAValidQueryLabel() throws {
    var request = claudeRecord("PermissionRequest", at: 3, promptID: "p1", toolName: "WebSearch",
                               toolInput: [:], approvalRequestID: "request-1")
    // Details whose command does not fit its label are dropped by the reader.
    request["approval_details"] = ["action": "Search the web", "command": "two\nlines", "command_label": "query"]
    let root = try makeClaudeEvents([
        claudeRecord("UserPromptSubmit", at: 1, promptID: "p1"),
        claudeRecord("PreToolUse", at: 2, promptID: "p1", toolName: "WebSearch", toolUseID: "call", toolInput: [:]),
        request
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(approvals(root).isEmpty)
}
