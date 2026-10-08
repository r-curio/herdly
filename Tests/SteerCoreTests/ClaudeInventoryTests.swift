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

@Test func claudeSessionRegistrySkipsOtherHoldersAndMapsShellToBusy() throws {
    let scan = decodeRegistry([
        entry(20, try registryRow(pid: 20, sessionID: interactiveID, status: "shell")),
        entry(21, try registryRow(pid: 21, sessionID: interactiveID, kind: "bg", status: "idle")),
        entry(22, try registryRow(pid: 22, sessionID: backgroundID, kind: "daemon", status: "idle")),
        entry(23, try registryRow(pid: 23, sessionID: backgroundID, kind: "daemon-worker", status: "busy")),
        entry(24, try registryRow(pid: 24, sessionID: backgroundID, extra: ["parkedJobId": "j1"]))
    ])
    #expect(scan.available)
    #expect(scan.sessions.map(\.sessionID) == [interactiveID])
    #expect(scan.sessions[0].lifecycle == .interactive(status: "busy"))
    // A session with an interactive row is not background, even with a background holder.
    #expect(!scan.isBackgroundSession(interactiveID))
    #expect(!scan.isBackgroundSession(backgroundID))
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
