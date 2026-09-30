import Foundation
import Testing
@testable import SteerCore

private let interactiveID = "11111111-1111-4111-8111-111111111111"
private let backgroundID = "22222222-2222-4222-8222-222222222222"

@Test func claudeInventoryDecodesSeparateLifecycleFields() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        ["sessionId": interactiveID, "kind": "interactive", "cwd": "/tmp/one", "name": "one",
         "status": "waiting", "startedAt": "2026-09-20T00:00:00Z"],
        ["sessionId": backgroundID, "kind": "background", "cwd": "/tmp/two", "name": "two",
         "status": "busy", "state": "done", "startedAt": 1_758_326_400]
    ])

    let scan = ClaudeInventoryDecoder.decode(data, sourceScope: "/tmp/root", observedAt: 10)
    #expect(scan.available)
    #expect(scan.sessions[0].name == "one")
    #expect(scan.sessions[1].name == "two")
    #expect(scan.sessions[0].lifecycle == .interactive(status: "waiting"))
    #expect(scan.sessions[1].lifecycle == .background(state: "done"))
    #expect(scan.sessions[1].lifecycle.isActive == false)
}

@Test func backgroundKindIsKnownOnlyFromACompleteInventory() {
    let scan = ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 1, sessions: [
        ClaudeInventorySession(sessionID: backgroundID, kind: .background, startedAt: 1,
                               lifecycle: .background(state: "blocked")),
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: "busy"))
    ])
    let unavailable = ClaudeInventoryScan.unavailable(sourceScope: "/tmp/root", observedAt: 2,
                                                       reason: "timed out")

    #expect(scan.isBackgroundSession(backgroundID))
    #expect(!scan.isBackgroundSession(interactiveID))
    #expect(!unavailable.isBackgroundSession(backgroundID))
}

@Test func missingClaudeNameFallsBackToSourceAndShortenedIdentity() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        ["sessionId": interactiveID, "kind": "interactive", "cwd": "/tmp/one",
         "status": "busy", "startedAt": 1]
    ])
    let scan = ClaudeInventoryDecoder.decode(data, sourceScope: "/tmp/root", observedAt: 1)
    #expect(scan.available)
    #expect(scan.sessions.first?.name == "")
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    #expect(AgentStripSummary.sessionLabel(identity) == "Claude session 11111111")
}

@Test func malformedOrDuplicateInventoryIsUnavailable() throws {
    let duplicate = try JSONSerialization.data(withJSONObject: [
        ["sessionId": interactiveID, "kind": "interactive", "cwd": "/tmp/one", "name": "one",
         "status": "idle", "startedAt": 1],
        ["sessionId": interactiveID, "kind": "interactive", "cwd": "/tmp/one", "name": "one",
         "status": "busy", "startedAt": 1]
    ])
    let scan = ClaudeInventoryDecoder.decode(duplicate, sourceScope: "/tmp/root", observedAt: 10)
    #expect(scan.available == false)
    #expect(scan.failure == ClaudeInventoryDecoder.incompleteMessage)
}

@Test func duplicateInteractiveInventorySignalsUnavailableTargetUntilUnique() throws {
    let duplicate = try JSONSerialization.data(withJSONObject: [
        ["sessionId": interactiveID, "kind": "interactive", "cwd": "/tmp/one", "name": "one",
         "status": "busy", "startedAt": 1],
        ["sessionId": interactiveID, "kind": "interactive", "cwd": "/tmp/one", "name": "one",
         "status": "waiting", "startedAt": 1]
    ])
    let ambiguous = ClaudeInventoryDecoder.decode(duplicate, sourceScope: "/tmp/root", observedAt: 2)
    var queue = AgentAttentionQueue()
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 1, sessions: [
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: "busy"))
    ]))
    queue.apply(ambiguous)
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    #expect(queue.items.filter { $0.session == identity }.count == 1)
    #expect(queue.isClaudeSessionUnavailable(identity))

    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 3, sessions: [
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: "idle"))
    ]))
    #expect(queue.isClaudeSessionUnavailable(identity) == false)
}

@Test func inventoryRejectsCrossKindSessionCollision() throws {
    let collision = try JSONSerialization.data(withJSONObject: [
        ["sessionId": interactiveID, "kind": "interactive", "cwd": "/tmp/one", "name": "one",
         "status": "idle", "startedAt": 1],
        ["sessionId": interactiveID, "kind": "background", "cwd": "/tmp/one", "name": "one",
         "status": "busy", "state": "working", "startedAt": 1]
    ])
    let scan = ClaudeInventoryDecoder.decode(collision, sourceScope: "/tmp/root", observedAt: 1)
    #expect(scan.available == false)
    #expect(scan.ambiguousSessionIDs.isEmpty)
}

@Test func inventoryRejectsBooleanStartedAt() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        ["sessionId": interactiveID, "kind": "interactive", "cwd": "/tmp/one", "name": "one",
         "status": "idle", "startedAt": true]
    ])
    #expect(ClaudeInventoryDecoder.decode(data, sourceScope: "/tmp/root", observedAt: 1).available == false)
}

@Test func inventoryCannotClearHookEvidenceAndIdleConfirmsStop() throws {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: identity, turn: "prompt", arrivedAt: 2)))

    let active = ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 3, sessions: [
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: "idle"))
    ])
    queue.apply(active)
    #expect(queue.items.compactMap(\.running).first?.identity.turn == "prompt")

    queue.apply(.provisionalStop(AgentProvisionalStop(identity: AgentTurnIdentity(session: identity, turn: "prompt"),
                                                       arrivedAt: 4)))
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 5, sessions: [
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: "idle"))
    ]))
    #expect(queue.items.compactMap(\.outcome).first?.status == .finished)
}

@Test func hookStopThenLaterIdleInventoryConfirmsFinishedOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-inventory-hook-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (index, event) in [
        ["hook_event_name": "UserPromptSubmit", "session_id": interactiveID, "prompt_id": "prompt", "captured_at": 1],
        ["hook_event_name": "Stop", "session_id": interactiveID, "prompt_id": "prompt", "captured_at": 2]
    ].enumerated() {
        var event = event
        event["source"] = ClaudeSetupRequirements.helperSource
        event["installation_id"] = "install"
        try JSONSerialization.data(withJSONObject: event).write(to: root.appendingPathComponent("event-\(index).json"))
    }

    let scan = ClaudeObservationReader.scan(events: root, sourceScope: "/tmp/root", installationID: "install", now: 3)
    var queue = AgentAttentionQueue()
    queue.apply(scan)
    #expect(queue.items.compactMap(\.running).count == 1)
    #expect(queue.items.compactMap(\.outcome).isEmpty)

    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 4, sessions: [
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: "idle"))
    ]))
    #expect(queue.items.compactMap(\.outcome).count == 1)
    #expect(queue.items.first?.outcome?.status == .finished)

    queue.apply(scan)
    #expect(queue.items.compactMap(\.outcome).count == 1)

    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 5, sessions: [
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: "idle"))
    ]))
    #expect(queue.items.compactMap(\.outcome).count == 1)
    #expect(queue.items.first?.outcome?.arrivedAt == 4)
}

@Test func unavailableInventoryPreservesExistingGenericStateAndRootsStaySeparate() {
    let rootB = ClaudeInventorySession(sessionID: backgroundID, kind: .background, startedAt: 1,
                                       lifecycle: .background(state: "working"))
    var queue = AgentAttentionQueue()
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/a", observedAt: 1, sessions: [
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: "busy"))
    ]))
    queue.apply(.unavailable(sourceScope: "/tmp/a", observedAt: 2, reason: "timed out"))
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/b", observedAt: 3, sessions: [rootB]))

    let running = queue.items.compactMap(\.running)
    #expect(running.contains { $0.identity.session.sourceScope == "/tmp/a" })
    #expect(!running.contains { $0.identity.session.sourceScope == "/tmp/b" })
}

@Test func olderValidInventoryCannotEraseNewerGenericStateAndEmptyNewerPollDoes() {
    let session = ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                                         lifecycle: .interactive(status: "busy"))
    var queue = AgentAttentionQueue()
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 10, sessions: [session]))
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 9))
    #expect(queue.workingCount == 1)
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 11))
    #expect(queue.workingCount == 0)
}

@Test func activeInventoryCancelsProvisionalStopWithoutCreatingOutcome() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.provisionalStop(AgentProvisionalStop(identity: AgentTurnIdentity(session: identity, turn: "prompt"),
                                                       arrivedAt: 2)))
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 3, sessions: [
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: "busy"))
    ]))
    #expect(queue.items.compactMap(\.outcome).isEmpty)
    #expect(queue.items.compactMap(\.running).count == 1)
}

@Test func backgroundTerminalInventoryRetiresLifecycleWithoutCreatingOutcome() {
    let session = ClaudeInventorySession(sessionID: backgroundID, kind: .background, startedAt: 1,
                                         lifecycle: .background(state: "done"))
    var queue = AgentAttentionQueue()
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 1, sessions: [
        ClaudeInventorySession(sessionID: backgroundID, kind: .background, startedAt: 1,
                               lifecycle: .background(state: "working"))
    ]))
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 2, sessions: [session]))

    #expect(queue.items.compactMap(\.outcome).isEmpty)
    #expect(queue.items.compactMap(\.running).isEmpty)
    #expect(queue.toCheckCount == 0)
}

@Test func backgroundBlockedInventoryAloneDoesNotCreateQueueRows() {
    var queue = AgentAttentionQueue()
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 1, sessions: [
        ClaudeInventorySession(sessionID: backgroundID, kind: .background, startedAt: 1,
                               lifecycle: .background(state: "blocked"))
    ]))

    #expect(queue.items.isEmpty)
    #expect(queue.workingCount == 0)
    #expect(queue.toCheckCount == 0)
}
