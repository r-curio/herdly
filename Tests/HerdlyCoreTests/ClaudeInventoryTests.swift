import Foundation
import Testing
@testable import HerdlyCore

private let interactiveID = "11111111-1111-4111-8111-111111111111"
private let backgroundID = "22222222-2222-4222-8222-222222222222"
private let otherBackgroundID = "44444444-4444-4444-8444-444444444444"

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

@Test func inventoryRescanKeepsTheRunningRowAtItsFirstSighting() {
    let hooked = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "hooked", surface: .cli)
    let busy = ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 0,
                                      lifecycle: .interactive(status: "busy"))
    var queue = AgentAttentionQueue()
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 1, sessions: [busy]))
    queue.apply(.running(AgentRunning(session: hooked, turn: "prompt", arrivedAt: 2)))
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 3, sessions: [busy]))

    #expect(queue.items.map(\.session.session) == [interactiveID, "hooked"])
    #expect(queue.items.first?.running?.arrivedAt == 1)
    #expect(queue.items.first?.running?.updatedAt == 3)
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-inventory-hook-" + UUID().uuidString)
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

private func writeStoppedTurn(to root: URL, prompt: String = "prompt", submittedAt: Double = 1,
                              stoppedAt: Double = 2) throws {
    for (index, event) in [
        ["hook_event_name": "UserPromptSubmit", "session_id": interactiveID, "prompt_id": prompt,
         "captured_at": submittedAt],
        ["hook_event_name": "Stop", "session_id": interactiveID, "prompt_id": prompt, "captured_at": stoppedAt]
    ].enumerated() {
        var event = event
        event["source"] = ClaudeSetupRequirements.helperSource
        event["installation_id"] = "install"
        try JSONSerialization.data(withJSONObject: event)
            .write(to: root.appendingPathComponent("event-\(prompt)-\(index).json"))
    }
}

private func idleInventory(at observedAt: Double) -> ClaudeInventoryScan {
    ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: observedAt, sessions: [
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: "idle"))
    ])
}

@Test func dismissedClaudeResultDoesNotReturnAsRunningOnLaterScans() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-inventory-dismiss-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStoppedTurn(to: root)
    let scan = ClaudeObservationReader.scan(events: root, sourceScope: "/tmp/root", installationID: "install", now: 3)

    var queue = AgentAttentionQueue()
    queue.apply(scan)
    queue.apply(idleInventory(at: 4))
    let outcome = try #require(queue.items.compactMap(\.outcome).first)
    queue.dismiss(.outcome(outcome.id))

    // The hook events stay on disk, so each scan repeats the stopped turn's running evidence.
    for observedAt in [6.0, 8.0] {
        queue.apply(scan)
        queue.apply(idleInventory(at: observedAt))
        #expect(queue.items.isEmpty)
    }
}

@Test func restoredAcknowledgedClaudeTurnIsNotShownAsRunning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-inventory-restore-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStoppedTurn(to: root)
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)

    var queue = AgentAttentionQueue(acknowledged: [AgentTurnIdentity(session: identity, turn: "prompt")])
    queue.apply(ClaudeObservationReader.scan(events: root, sourceScope: "/tmp/root", installationID: "install", now: 3))
    queue.apply(idleInventory(at: 4))
    #expect(queue.items.isEmpty)
    #expect(queue.workingCount == 0)
}

@Test func acknowledgedClaudeTurnThatContinuesAfterStopStillShowsRunning() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    let turn = AgentTurnIdentity(session: identity, turn: "prompt")
    var queue = AgentAttentionQueue(acknowledged: [turn])
    queue.apply(.running(AgentRunning(session: identity, turn: "prompt", arrivedAt: 1, updatedAt: 2)))
    queue.apply(.provisionalStop(AgentProvisionalStop(identity: turn, arrivedAt: 2)))
    queue.apply(idleInventory(at: 4))
    #expect(queue.items.isEmpty)

    // A Stop hook can keep the same prompt going; newer tool evidence is live work again.
    queue.apply(.running(AgentRunning(session: identity, turn: "prompt", arrivedAt: 1, updatedAt: 5)))
    #expect(queue.items.compactMap(\.running).first?.updatedAt == 5)
}

private func inventory(_ status: String, at observedAt: Double) -> ClaudeInventoryScan {
    ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: observedAt, sessions: [
        ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: status))
    ])
}

@Test func quietRunningRowEndsWhenClaudeReportsTheSessionIdle() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    let grace = AgentAttentionQueue.idleRunningGrace
    var queue = AgentAttentionQueue()
    // No Stop ever arrives, so there is nothing for inventory to confirm.
    let stale = AgentRunning(session: identity, turn: "prompt", arrivedAt: 1, updatedAt: 10)
    queue.apply(.running(stale))

    // A prompt can be submitted just before Claude's registry flips to busy.
    queue.apply(inventory("idle", at: 10 + grace - 1))
    #expect(queue.items.compactMap(\.running).count == 1)

    queue.apply(inventory("idle", at: 10 + grace))
    #expect(queue.items.isEmpty)
    #expect(queue.workingCount == 0)
    #expect(queue.toCheckCount == 0)

    // Repeated hook scans carry the same evidence and cannot reopen the row.
    queue.apply(.running(stale))
    #expect(queue.items.isEmpty)

    // New activity on the same prompt is live work again.
    queue.apply(.running(AgentRunning(session: identity, turn: "prompt", arrivedAt: 1, updatedAt: 10 + grace + 5)))
    #expect(queue.items.compactMap(\.running).first?.updatedAt == 10 + grace + 5)
}

@Test func removeIsOfferedOnlyForRowsThatLookStuck() throws {
    let live = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    let gone = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "gone", surface: .cli)
    let stale = AgentAttentionQueue.staleRunningAfter
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: live, turn: "prompt", arrivedAt: 1, updatedAt: 10)))
    queue.apply(.running(AgentRunning(session: gone, turn: "prompt", arrivedAt: 2, updatedAt: 10)))
    func removable(_ session: AgentSessionIdentity, at now: Double) throws -> Bool {
        let item = try #require(queue.items(at: now).first { $0.session == session })
        return queue.isRemovable(item, at: now)
    }

    // Before any registry scan, only time can mark a row stuck.
    #expect(try !removable(gone, at: 11))
    #expect(try removable(gone, at: 10 + stale))

    // A live busy process with a recent status change keeps its quiet hook row; a session no live
    // process holds is stuck at once.
    queue.apply(inventory("busy", at: 20, statusChangedAt: 15))
    #expect(try !removable(live, at: 21))
    #expect(try removable(gone, at: 21))
    #expect(try !removable(live, at: 15 + stale - 1))
    #expect(try removable(live, at: 15 + stale))

    // An unreadable registry proves nothing about which sessions are gone.
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 30, available: false))
    #expect(try !removable(gone, at: 31))

    // Status unavailable is always offered; approvals, outcomes, and Codex rows never are.
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 40, ambiguousSessionIDs: [interactiveID]))
    #expect(try removable(live, at: 41))
    let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex", surface: .cli)
    queue.apply(.running(AgentRunning(session: codex, turn: "turn", arrivedAt: 1)))
    queue.apply(.approval(AgentApproval(session: gone, turn: "prompt", call: "write", arrivedAt: 42)))
    #expect(try !removable(codex, at: 10 * stale))
    #expect(try !removable(gone, at: 10 * stale))
}

@Test func removedStaleRunningRowStaysGoneUntilNewActivity() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    let other = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "other", surface: .cli)
    var queue = AgentAttentionQueue()
    // A session whose terminal closed mid-turn: the registry still reads busy and no Stop arrives.
    let stale = AgentRunning(session: identity, turn: "prompt", arrivedAt: 1, updatedAt: 10, prompt: "close it")
    queue.apply(.running(stale))
    queue.apply(.running(AgentRunning(session: other, turn: "other-prompt", arrivedAt: 2)))
    queue.apply(.outcome(AgentOutcome(session: identity, turn: "earlier", status: .finished, arrivedAt: 0)))
    queue.apply(inventory("busy", at: 20))

    queue.remove(.running(stale.id))
    #expect(queue.items.compactMap(\.running).map(\.identity.session) == [other])
    #expect(queue.workingCount == 1)
    // Removal acknowledges nothing and creates no outcome.
    #expect(queue.items.compactMap(\.outcome).map(\.turn) == ["earlier"])
    #expect(queue.acknowledgedOutcomes.isEmpty)

    // Repeated hook evidence and a still-busy registry cannot bring it back.
    queue.apply(.running(stale))
    queue.apply(inventory("busy", at: 30))
    #expect(queue.items.compactMap(\.running).map(\.identity.session) == [other])

    // Newer hook activity is live work again.
    queue.apply(.running(AgentRunning(session: identity, turn: "prompt", arrivedAt: 1, updatedAt: 40)))
    #expect(queue.items.compactMap(\.running).first { $0.identity.session == identity }?.updatedAt == 40)
}

@Test func removedInventoryRowReturnsOnlyAfterTheSessionReadsIdle() throws {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(inventory("busy", at: 1))
    let row = try #require(queue.items.first)
    #expect(row.kind == .running)

    queue.remove(row.id)
    queue.apply(inventory("busy", at: 2))
    #expect(queue.items.isEmpty)
    // An unavailable scan keeps the removal.
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 3, available: false))
    queue.apply(inventory("busy", at: 4))
    #expect(queue.items.isEmpty)

    queue.apply(inventory("idle", at: 5))
    queue.apply(inventory("busy", at: 6))
    #expect(queue.items.map(\.session) == [identity])
}

@Test func removedStatusUnavailableRowStaysGoneWhileAmbiguous() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    let ambiguous = ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 1, ambiguousSessionIDs: [interactiveID])
    var queue = AgentAttentionQueue()
    queue.apply(ambiguous)
    #expect(queue.items.map(\.kind) == [.statusUnavailable])

    queue.remove(.unavailable(identity))
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 2, ambiguousSessionIDs: [interactiveID]))
    #expect(queue.items.isEmpty)
    #expect(queue.toCheckCount == 0)

    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 3))
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 4, ambiguousSessionIDs: [interactiveID]))
    #expect(queue.items.map(\.kind) == [.statusUnavailable])
}

@Test func removeIgnoresCodexAndActionableRows() {
    let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex", surface: .cli)
    let claude = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    var queue = AgentAttentionQueue()
    let running = AgentRunning(session: codex, turn: "turn", arrivedAt: 1)
    let approval = AgentApproval(session: claude, turn: "prompt", call: "write", arrivedAt: 2)
    queue.apply(.running(running), now: 2)
    queue.apply(.approval(approval), now: 2)
    queue.remove(.running(running.id))
    queue.remove(.approval(approval.id))
    #expect(queue.items(at: 2).count == 2)
}

@Test func quietRunningRowStaysWhileClaudeReportsTheSessionBusyOrWaiting() {
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: identity, turn: "prompt", arrivedAt: 1, updatedAt: 10)))

    // A long tool call or a long answer fires no hooks while Claude stays busy.
    queue.apply(inventory("busy", at: 10 + 60 * 60))
    queue.apply(inventory("waiting", at: 10 + 2 * 60 * 60))
    #expect(queue.items.compactMap(\.running).count == 1)
}

@Test func acknowledgedConfirmedStopDoesNotReturnAsWorking() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-inventory-ack-" + UUID().uuidString)
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
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    let idle = { (at: Double) in
        ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: at, sessions: [
            ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                                   lifecycle: .interactive(status: "idle"))
        ])
    }
    let scan = { (now: Double) in
        ClaudeObservationReader.scan(events: root, sourceScope: "/tmp/root", installationID: "install", now: now)
    }

    var queue = AgentAttentionQueue()
    queue.apply(scan(3), now: 3)
    queue.apply(idle(4), now: 4)
    #expect(queue.items.compactMap(\.outcome).count == 1)

    queue.dismiss(.outcome(AgentTurnIdentity(session: identity, turn: "prompt")))
    #expect(queue.items.isEmpty)

    // Later polls still see the same Stop records. Whether the inventory keeps listing the idle
    // session or stops listing it (Claude skips a parked entry), the finished turn stays gone.
    queue.apply(scan(5), now: 5)
    queue.apply(idle(6), now: 6)
    #expect(queue.items.isEmpty)
    #expect(queue.workingCount == 0)

    queue.apply(scan(7), now: 7)
    queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 8), now: 8)
    #expect(queue.items.isEmpty)
    #expect(queue.workingCount == 0)
}

@Test func acknowledgedClaudeTurnThatResumesCompletesAgain() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-inventory-resume-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ events: [[String: Any]], from start: Int) throws {
        for (index, event) in events.enumerated() {
            var event = event
            event["source"] = ClaudeSetupRequirements.helperSource
            event["installation_id"] = "install"
            try JSONSerialization.data(withJSONObject: event).write(to: root.appendingPathComponent("event-\(start + index).json"))
        }
    }
    try write([
        ["hook_event_name": "UserPromptSubmit", "session_id": interactiveID, "prompt_id": "prompt", "captured_at": 1],
        ["hook_event_name": "Stop", "session_id": interactiveID, "prompt_id": "prompt", "captured_at": 2]
    ], from: 0)
    let identity = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    let turn = AgentTurnIdentity(session: identity, turn: "prompt")
    let idle = { (at: Double) in
        ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: at, sessions: [
            ClaudeInventorySession(sessionID: interactiveID, kind: .interactive, startedAt: 1,
                                   lifecycle: .interactive(status: "idle"))
        ])
    }
    let scan = { (now: Double) in
        ClaudeObservationReader.scan(events: root, sourceScope: "/tmp/root", installationID: "install", now: now)
    }

    var queue = AgentAttentionQueue()
    queue.apply(scan(3), now: 3)
    queue.apply(idle(4), now: 4)
    queue.dismiss(.outcome(turn))

    // The same turn runs a tool after its acknowledged completion: that is new work.
    try write([
        ["hook_event_name": "PreToolUse", "session_id": interactiveID, "prompt_id": "prompt", "captured_at": 5,
         "tool_name": "Bash", "tool_use_id": "t1"]
    ], from: 2)
    queue.apply(scan(6), now: 6)
    #expect(queue.items.compactMap(\.running).map(\.identity) == [turn])
    #expect(queue.workingCount == 1)

    try write([
        ["hook_event_name": "PostToolUse", "session_id": interactiveID, "prompt_id": "prompt", "captured_at": 7,
         "tool_use_id": "t1"],
        ["hook_event_name": "Stop", "session_id": interactiveID, "prompt_id": "prompt", "captured_at": 8]
    ], from: 3)
    queue.apply(scan(9), now: 9)
    queue.apply(idle(10), now: 10)
    #expect(queue.items.compactMap(\.outcome).map(\.arrivedAt) == [10])
    #expect(queue.items.compactMap(\.running).isEmpty)
    #expect(!queue.acknowledgedOutcomes.contains(turn))

    queue.dismiss(.outcome(turn))
    queue.apply(scan(11), now: 11)
    #expect(queue.items.isEmpty)
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

// MARK: - Session registry (Claude Code 2.1.292+)

private func registryRow(pid: Int, sessionID: String, kind: String = "interactive", status: String = "busy",
                         procStart: String? = "Wed Oct  7 06:00:02 2026",
                         extra: [String: Any] = [:]) throws -> Data {
    var row: [String: Any] = ["pid": pid, "sessionId": sessionID, "cwd": "/tmp/one", "name": "one",
                              "startedAt": 1_791_352_804_684, "kind": kind, "status": status]
    if let procStart { row["procStart"] = procStart }
    row.merge(extra) { $1 }
    return try JSONSerialization.data(withJSONObject: row)
}

private func entry(_ pid: Int32, _ data: Data?) -> ClaudeSessionRegistry.Entry { .init(pid: pid, data: data) }

private func decodeRegistry(_ entries: [ClaudeSessionRegistry.Entry],
                            running: @escaping (ClaudeSessionRegistry.Process) -> Bool = { _ in true }) -> ClaudeInventoryScan {
    ClaudeSessionRegistry.decode(entries, sourceScope: "/tmp/root", observedAt: 10, isRunning: running)
}

@Test func claudeSessionRegistryKeepsOnlyRunningInteractiveProcesses() throws {
    let scan = decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: interactiveID)),
                               entry(30, try registryRow(pid: 30, sessionID: backgroundID, status: "idle"))]) { $0.pid == 20 }

    #expect(scan.available)
    #expect(scan.sessions.map(\.sessionID) == [interactiveID])
    #expect(scan.sessions[0].lifecycle == .interactive(status: "busy"))
    #expect(scan.sessions[0].startedAt == 1_791_352_804.684)
    #expect(scan.sessions[0].pid == 20)
    // The registered start time travels with the PID, so a tab binding can revalidate it (ADR 0013).
    #expect(scan.sessions[0].procStart == "Wed Oct  7 06:00:02 2026")
    // The CLI inventory does not identify a process.
    #expect(ClaudeInventoryDecoder.decode(try JSONSerialization.data(withJSONObject: [
        ["sessionId": interactiveID, "kind": "interactive", "cwd": "/tmp/one", "status": "busy", "startedAt": 1, "pid": 20]
    ]), sourceScope: "/tmp/root", observedAt: 1).sessions.first?.pid == nil)
}

@Test func claudeSessionRegistryPassesRecordedProcessIdentity() throws {
    var seen: [ClaudeSessionRegistry.Process] = []
    _ = decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: interactiveID)),
                        entry(30, try registryRow(pid: 30, sessionID: backgroundID, procStart: nil))]) {
        seen.append($0); return true
    }
    // The name's PID is checked first; the recorded start time then rules out a reused PID.
    #expect(seen == [.init(pid: 20, procStart: nil), .init(pid: 20, procStart: "Wed Oct  7 06:00:02 2026"),
                     .init(pid: 30, procStart: nil), .init(pid: 30, procStart: nil)])
}

@Test func claudeSessionRegistrySkipsOtherHoldersAndMapsShellToIdle() throws {
    let scan = decodeRegistry([
        entry(20, try registryRow(pid: 20, sessionID: interactiveID, status: "shell")),
        entry(21, try registryRow(pid: 21, sessionID: interactiveID, kind: "bg", status: "idle")),
        entry(22, try registryRow(pid: 22, sessionID: backgroundID, kind: "daemon", status: "idle")),
        entry(23, try registryRow(pid: 23, sessionID: backgroundID, kind: "daemon-worker", status: "busy")),
        entry(24, try registryRow(pid: 24, sessionID: backgroundID, extra: ["parkedJobId": "j1"]))
    ])
    #expect(scan.available)
    #expect(scan.sessions.map(\.sessionID) == [interactiveID])
    #expect(scan.sessions[0].lifecycle == .interactive(status: "idle"))
    // A session with an interactive row is not background, even with a background holder.
    #expect(!scan.isBackgroundSession(interactiveID))
    #expect(!scan.isBackgroundSession(backgroundID))
}

@Test func claudeShellStatusIsAnIdleSessionWithABackgroundShell() throws {
    // Claude writes `shell` when the prompt is idle while a background Bash task, such as a dev
    // server, keeps running. The turn has ended, so it confirms Stop and adds no working row.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-registry-shell-" + UUID().uuidString)
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
    let shell = decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: interactiveID, status: "shell"))])
    #expect(shell.sessions.map(\.lifecycle) == [.interactive(status: "idle")])

    var queue = AgentAttentionQueue()
    queue.apply(ClaudeObservationReader.scan(events: root, sourceScope: "/tmp/root", installationID: "install", now: 3), now: 3)
    queue.apply(shell, now: 10)
    #expect(queue.items.compactMap(\.outcome).map(\.status) == [.finished])
    #expect(queue.items.compactMap(\.running).isEmpty)
    #expect(queue.workingCount == 0)

    // Without hook evidence, such as after `/clear` starts a new session, it adds no row at all.
    let cleared = "33333333-3333-4333-8333-333333333333"
    var empty = AgentAttentionQueue()
    empty.apply(decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: cleared, status: "shell"))]), now: 10)
    #expect(empty.items.isEmpty)
    #expect(empty.workingCount == 0)
}

@Test func claudeSessionRegistryBackgroundHolderMarksSessionBackground() throws {
    let scan = decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: interactiveID)),
                               entry(21, try registryRow(pid: 21, sessionID: backgroundID.uppercased(), kind: "bg"))])
    #expect(scan.available)
    #expect(scan.sessions.map(\.sessionID) == [interactiveID])
    #expect(scan.isBackgroundSession(backgroundID))
    #expect(!scan.isBackgroundSession(interactiveID))

    let malformed = decodeRegistry([entry(21, try registryRow(pid: 21, sessionID: "nope", kind: "bg"))])
    #expect(!malformed.available)
    #expect(!malformed.isBackgroundSession(backgroundID))
}

@Test func claudeSessionRegistryLinksABackgroundJobToTheProcessThatParkedIt() throws {
    // Claude 2.1.296: the interactive process parks its session as job `j1`, which a `bg` process
    // continues under a new session ID while the interactive process keeps displaying it.
    let parked = entry(20, try registryRow(pid: 20, sessionID: interactiveID, extra: ["parkedJobId": "j1"]))
    let job = entry(30, try registryRow(pid: 30, sessionID: backgroundID.uppercased(), kind: "bg", extra: ["jobId": "j1"]))
    let scan = decodeRegistry([parked, job])
    #expect(scan.available)
    #expect(scan.sessions.isEmpty)
    #expect(scan.isBackgroundSession(backgroundID))
    #expect(scan.parkedJobProcesses == [backgroundID: .identified(pid: 20)])

    // No link without a matching job, a live parking process, or an interactive parking entry.
    let spare = entry(31, try registryRow(pid: 31, sessionID: otherBackgroundID, kind: "bg", extra: ["jobId": "j2"]))
    #expect(decodeRegistry([parked, spare]).parkedJobProcesses.isEmpty)
    #expect(decodeRegistry([parked, job]) { $0.pid != 20 }.parkedJobProcesses.isEmpty)
    let parkedDaemon = entry(20, try registryRow(pid: 20, sessionID: interactiveID, kind: "daemon", extra: ["parkedJobId": "j1"]))
    #expect(decodeRegistry([parkedDaemon, job]).parkedJobProcesses.isEmpty)
    let malformedJob = entry(30, try registryRow(pid: 30, sessionID: backgroundID, kind: "bg", extra: ["jobId": 7]))
    #expect(decodeRegistry([parked, malformedJob]).parkedJobProcesses.isEmpty)

    // A job parked by two processes, or held by two background sessions, identifies no one.
    let secondParked = entry(21, try registryRow(pid: 21, sessionID: otherBackgroundID, extra: ["parkedJobId": "j1"]))
    #expect(decodeRegistry([parked, secondParked, job]).parkedJobProcesses == [backgroundID: .ambiguous])
    let secondJob = entry(31, try registryRow(pid: 31, sessionID: otherBackgroundID, kind: "bg", extra: ["jobId": "j1"]))
    #expect(decodeRegistry([parked, job, secondJob]).parkedJobProcesses
        == [backgroundID: .ambiguous, otherBackgroundID: .ambiguous])
    // An unavailable scan carries no link.
    #expect(decodeRegistry([parked, job, entry(40, Data("{".utf8))]).parkedJobProcesses.isEmpty)
}

@Test func claudeSessionRegistryKindDefaultsToInteractiveAndUnknownKindIsUnavailable() throws {
    var row = try JSONSerialization.jsonObject(with: registryRow(pid: 20, sessionID: interactiveID)) as! [String: Any]
    row.removeValue(forKey: "kind")
    let missing = decodeRegistry([entry(20, try JSONSerialization.data(withJSONObject: row))])
    #expect(missing.available)
    #expect(missing.sessions.map(\.kind) == [.interactive])

    let unknown = decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: interactiveID, kind: "remote"))])
    #expect(!unknown.available)
    #expect(unknown.failure == ClaudeInventoryDecoder.unsupportedKindMessage)
}

@Test func claudeSessionRegistryIgnoresAnyEntryOfAnExitedProcess() throws {
    let good = entry(20, try registryRow(pid: 20, sessionID: interactiveID))
    let stale: [Data] = [try registryRow(pid: 99, sessionID: backgroundID), try registryRow(pid: 31, sessionID: "bad"),
                         try registryRow(pid: 31, sessionID: backgroundID, kind: "remote"),
                         try JSONSerialization.data(withJSONObject: ["pid": "31"])]
    for data in stale {
        let scan = decodeRegistry([good, entry(31, data)]) { $0.pid == 20 }
        #expect(scan.available)
        #expect(scan.sessions.map(\.sessionID) == [interactiveID])
    }
}

@Test func claudeSessionRegistryTornEntryDependsOnItsProcess() throws {
    let good = entry(20, try registryRow(pid: 20, sessionID: interactiveID))
    for torn in [Data(), Data("{\"pid\":".utf8)] {
        let dead = decodeRegistry([good, entry(31, torn)]) { $0.pid == 20 }
        #expect(dead.available)
        #expect(dead.sessions.map(\.sessionID) == [interactiveID])
        #expect(!decodeRegistry([good, entry(31, torn)]).available)
    }
    // A vanished file is an ended session, never a failure.
    #expect(decodeRegistry([good, entry(31, nil)]).sessions.count == 1)
}

@Test func claudeSessionRegistryIsUnavailableForMalformedLiveEntries() throws {
    let good = entry(20, try registryRow(pid: 20, sessionID: interactiveID))
    let cases: [ClaudeSessionRegistry.Entry] = [
        entry(21, try JSONSerialization.data(withJSONObject: ["sessionId": interactiveID])),
        entry(21, try JSONSerialization.data(withJSONObject: ["pid": true])),
        entry(21, try JSONSerialization.data(withJSONObject: ["pid": 21, "procStart": 5])),
        entry(21, try registryRow(pid: 22, sessionID: backgroundID)),
        entry(21, try registryRow(pid: 21, sessionID: backgroundID, status: "thinking")),
        entry(21, try registryRow(pid: 21, sessionID: "not-a-session")),
        entry(21, Data(repeating: 0x20, count: ClaudeSessionRegistry.maximumEntrySize + 1))
    ]
    for bad in cases {
        let scan = decodeRegistry([good, bad])
        #expect(!scan.available)
        #expect(scan.sessions.isEmpty)
    }
}

@Test func claudeSessionRegistryTwoLiveInteractiveHoldersAreAmbiguous() throws {
    let scan = decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: interactiveID)),
                               entry(21, try registryRow(pid: 21, sessionID: interactiveID))])
    #expect(!scan.available)
    #expect(scan.ambiguousSessionIDs == [interactiveID])

    let row = entry(20, try registryRow(pid: 20, sessionID: interactiveID))
    #expect(!decodeRegistry(Array(repeating: row, count: ClaudeSessionRegistry.maximumEntries + 1)).available)
}

@Test func claudeProcStartMatchesCtimeLayout() {
    #expect(ClaudeSessionRegistry.procStart(weekday: 3, month: 9, day: 7, hour: 6, minute: 0, second: 2,
                                            year: 2026) == "Wed Oct  7 06:00:02 2026")
    #expect(ClaudeSessionRegistry.procStart(weekday: 0, month: 0, day: 25, hour: 23, minute: 59, second: 9,
                                            year: 2026) == "Sun Jan 25 23:59:09 2026")
    #expect(ClaudeSessionRegistry.procStart(weekday: 7, month: 0, day: 1, hour: 0, minute: 0, second: 0,
                                            year: 2026) == nil)
}

@Test func claudeSessionRegistryRunningCheckUsesProcessStart() {
    let pid = getpid()
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    #expect(sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0)
    var seconds = info.kp_proc.p_starttime.tv_sec
    var utc = tm()
    _ = gmtime_r(&seconds, &utc)
    let start = ClaudeSessionRegistry.procStart(weekday: Int(utc.tm_wday), month: Int(utc.tm_mon), day: Int(utc.tm_mday),
                                                hour: Int(utc.tm_hour), minute: Int(utc.tm_min),
                                                second: Int(utc.tm_sec), year: Int(utc.tm_year) + 1900)

    #expect(ClaudeSessionRegistry.isRunning(.init(pid: pid, procStart: nil)))
    #expect(ClaudeSessionRegistry.isRunning(.init(pid: pid, procStart: start)))
    #expect(!ClaudeSessionRegistry.isRunning(.init(pid: pid, procStart: "Thu Jan  1 00:00:00 1970")))
    #expect(!ClaudeSessionRegistry.isRunning(.init(pid: Int32.max, procStart: nil)))
}

@Test func claudeSessionRegistryReadsFilesSafely() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let fm = FileManager.default
    #expect(ClaudeSessionRegistry.read(root: root, observedAt: 1) == nil)

    let sessions = root.appendingPathComponent("sessions")
    try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
    try registryRow(pid: 20, sessionID: interactiveID).write(to: sessions.appendingPathComponent("20.json"))
    try Data("ignored".utf8).write(to: sessions.appendingPathComponent("notes.txt"))
    try Data("ignored".utf8).write(to: sessions.appendingPathComponent("20.abc.key"))
    let live: (ClaudeSessionRegistry.Process) -> Bool = { $0.pid == 20 || $0.pid == 21 }
    let ok = try #require(ClaudeSessionRegistry.read(root: root, observedAt: 1, isRunning: live, retryDelay: 0))
    #expect(ok.available)
    #expect(ok.sessions.map(\.sessionID) == [interactiveID])

    // A dead process's torn file is ignored; a live one's is retried, then unavailable.
    try Data().write(to: sessions.appendingPathComponent("31.json"))
    #expect(ClaudeSessionRegistry.read(root: root, observedAt: 1, isRunning: live, retryDelay: 0)?.available == true)
    try Data().write(to: sessions.appendingPathComponent("21.json"))
    #expect(ClaudeSessionRegistry.read(root: root, observedAt: 1, isRunning: live, retryDelay: 0)?.available == false)
    try fm.removeItem(at: sessions.appendingPathComponent("21.json"))

    // Symlinks, directories, and FIFOs are never read as entries.
    let target = root.appendingPathComponent("elsewhere.json")
    try registryRow(pid: 21, sessionID: backgroundID).write(to: target)
    try fm.createSymbolicLink(at: sessions.appendingPathComponent("21.json"), withDestinationURL: target)
    #expect(ClaudeSessionRegistry.read(root: root, observedAt: 1, isRunning: live, retryDelay: 0)?.available == false)
    try fm.removeItem(at: sessions.appendingPathComponent("21.json"))
    try fm.createDirectory(at: sessions.appendingPathComponent("21.json"), withIntermediateDirectories: false)
    #expect(ClaudeSessionRegistry.read(root: root, observedAt: 1, isRunning: live, retryDelay: 0)?.available == false)
    try fm.removeItem(at: sessions.appendingPathComponent("21.json"))
    #expect(mkfifo(sessions.appendingPathComponent("21.json").path, 0o600) == 0)
    #expect(ClaudeSessionRegistry.read(root: root, observedAt: 1, isRunning: live, retryDelay: 0)?.available == false)
}

@Test func claudeInventoryKeepsEachSessionsWorkingDirectoryFromBothSources() throws {
    let cli = ClaudeInventoryDecoder.decode(try JSONSerialization.data(withJSONObject: [
        ["sessionId": interactiveID, "kind": "interactive", "cwd": "/tmp/one", "status": "busy", "startedAt": 1]
    ]), sourceScope: "/tmp/root", observedAt: 1)
    #expect(cli.sessions.first?.directory == "/tmp/one")

    let registry = decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: interactiveID))])
    #expect(registry.sessions.first?.directory == "/tmp/one")
}

// MARK: - Prompt answered outside Herdly

private func inventory(_ status: String, at observedAt: Double, statusChangedAt: Double?,
                       session: String = interactiveID) -> ClaudeInventoryScan {
    ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: observedAt, sessions: [
        ClaudeInventorySession(sessionID: session, kind: .interactive, startedAt: 1,
                               lifecycle: .interactive(status: status), statusUpdatedAt: statusChangedAt)
    ])
}

private func claudeApproval(_ call: String, arrivedAt: Double, session: String = interactiveID,
                            scope: String = "/tmp/root") -> AgentApproval {
    AgentApproval(session: AgentSessionIdentity(source: .claude, sourceScope: scope, session: session, surface: .cli),
                  turn: "prompt", call: call, arrivedAt: arrivedAt)
}

private func approvalStates(_ queue: AgentAttentionQueue) -> [String: AgentApprovalState] {
    Dictionary(uniqueKeysWithValues: queue.items(at: 12).compactMap(\.approval).map { ($0.identity.call, $0.state) })
}

@Test func claudeApprovalStaysDecidableWhileItsPromptIsOpen() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(claudeApproval("write", arrivedAt: 10)))
    // Claude marks the session waiting just before the PermissionRequest record is captured.
    queue.apply(inventory("waiting", at: 11, statusChangedAt: 9.93))
    #expect(approvalStates(queue) == ["write": .actionable])
}

@Test(arguments: ["idle", "busy"])
func claudeApprovalAnsweredInClaudeLeavesTheQueue(status: String) {
    // A native No fires no hook (idle); a native Yes runs the tool (busy) before any post-tool scan.
    var queue = AgentAttentionQueue()
    queue.apply(.approval(claudeApproval("write", arrivedAt: 10)))
    queue.apply(inventory(status, at: 11, statusChangedAt: 10.4))
    #expect(approvalStates(queue).isEmpty)

    // The next hook scan still carries the same request until the tool ends; it cannot bring it back.
    queue.apply(.approval(claudeApproval("write", arrivedAt: 10)))
    #expect(approvalStates(queue).isEmpty)
}

@Test(arguments: ["idle", "busy"])
func handedBackClaudeApprovalLeavesOnceItsPromptIsAnswered(status: String) {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(claudeApproval("write", arrivedAt: 10).with(state: .handedBack)))
    #expect(approvalStates(queue) == ["write": .handedBack])
    queue.apply(inventory(status, at: 50, statusChangedAt: 48))
    #expect(approvalStates(queue).isEmpty)
}

@Test func handedBackClaudeApprovalStaysWhileItsPromptIsOpen() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(claudeApproval("write", arrivedAt: 10).with(state: .handedBack)))
    // Past the deadline, Claude's prompt is still waiting from before the request was captured.
    queue.apply(inventory("waiting", at: 50, statusChangedAt: 9.93))
    #expect(approvalStates(queue) == ["write": .handedBack])
}

@Test func answeredClaudeApprovalGivesWayToTheSessionsRunningRow() {
    let session = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: interactiveID, surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: session, turn: "prompt", arrivedAt: 5, updatedAt: 10)))
    queue.apply(.approval(claudeApproval("write", arrivedAt: 10).with(state: .handedBack)))
    #expect(queue.items(at: 12).map(\.kind) == [.handedBackApproval])
    queue.apply(inventory("busy", at: 11, statusChangedAt: 10.4))
    #expect(queue.items(at: 12).map(\.kind) == [.running])
}

@Test func nextPromptInTheSameSessionRemovesOnlyTheEarlierRequest() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(claudeApproval("first", arrivedAt: 10)))
    queue.apply(.approval(claudeApproval("second", arrivedAt: 10.6)))
    // waiting again for the second prompt, set before the second request arrived
    queue.apply(inventory("waiting", at: 11, statusChangedAt: 10.5))
    #expect(approvalStates(queue) == ["second": .actionable])
}

@Test func statusWithoutAChangeTimeKeepsTodaysApprovalBehavior() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(claudeApproval("write", arrivedAt: 10)))
    // `claude agents --json` reports no change time.
    queue.apply(inventory("idle", at: 11, statusChangedAt: nil))
    #expect(approvalStates(queue) == ["write": .actionable])

    var handedBack = AgentAttentionQueue()
    handedBack.apply(.approval(claudeApproval("write", arrivedAt: 10).with(state: .handedBack)))
    handedBack.apply(inventory("idle", at: 11, statusChangedAt: nil))
    #expect(approvalStates(handedBack) == ["write": .handedBack])
}

@Test func statusChangeLeavesOtherSessionsAndRootsDecidable() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(claudeApproval("other-session", arrivedAt: 10, session: backgroundID)))
    queue.apply(.approval(claudeApproval("other-root", arrivedAt: 10, scope: "/tmp/other-root")))
    queue.apply(inventory("idle", at: 11, statusChangedAt: 10.4))
    #expect(approvalStates(queue) == ["other-session": .actionable, "other-root": .actionable])
}

@Test func claudeSessionRegistryKeepsTheStatusChangeTime() throws {
    let scan = decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: interactiveID, status: "waiting",
                                                         extra: ["statusUpdatedAt": 1_791_650_747_057]))])
    #expect(scan.sessions.first?.statusUpdatedAt == 1_791_650_747.057)

    // A malformed or missing value is advisory and never makes the inventory unavailable.
    let malformed = decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: interactiveID,
                                                              extra: ["statusUpdatedAt": true]))])
    #expect(malformed.available)
    #expect(malformed.sessions.first?.statusUpdatedAt == nil)
    #expect(decodeRegistry([entry(20, try registryRow(pid: 20, sessionID: interactiveID))])
        .sessions.first?.statusUpdatedAt == nil)
}
