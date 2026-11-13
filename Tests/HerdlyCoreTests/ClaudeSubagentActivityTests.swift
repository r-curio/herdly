import Foundation
import Testing
@testable import HerdlyCore

// Claude's SubagentStart/SubagentStop and the PreToolUse/PostToolUse fired inside a subagent carry
// `agent_id` and `agent_type` (#395). These checks read them through the public scan.

private func events(_ records: [[String: Any]]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-subagents-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (index, var record) in records.enumerated() {
        record["source"] = ClaudeSetupRequirements.helperSource
        record["installation_id"] = "install"
        try JSONSerialization.data(withJSONObject: record).write(to: root.appendingPathComponent("event-\(index).json"))
    }
    return root
}

private func record(_ event: String, at capturedAt: Double, prompt: String? = "p1", agent: Any? = nil,
                    type: Any? = nil, tool: String? = nil, call: String? = nil,
                    input: [String: Any] = [:], session: String = "session-1") -> [String: Any] {
    var value: [String: Any] = ["hook_event_name": event, "session_id": session, "captured_at": capturedAt]
    if let prompt { value["prompt_id"] = prompt }
    if let agent { value["agent_id"] = agent }
    if let type { value["agent_type"] = type }
    if let tool { value["tool_name"] = tool }
    if let call { value["tool_use_id"] = call }
    if !input.isEmpty { value["tool_input"] = input }
    return value
}

private var promptSubmit: [String: Any] { record("UserPromptSubmit", at: 1) }

private func running(_ records: [[String: Any]], now: Double = 10) throws -> AgentRunning? {
    let root = try events(records)
    defer { try? FileManager.default.removeItem(at: root) }
    return ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install", now: now)
        .observations.compactMap { observation -> AgentRunning? in
            if case let .running(value) = observation { return value }
            return nil
        }.first
}

@Test func claudeSubagentShowsItsLatestActionUntilItStops() throws {
    let started = [promptSubmit,
                   record("SubagentStart", at: 2, agent: "a1", type: "Explore"),
                   record("PreToolUse", at: 3, agent: "a1", type: "Explore", tool: "Bash", call: "t1",
                          input: ["command": "rg subagent"])]
    let subagent = try #require(try running(started)?.subagents.first)
    #expect(subagent.id == "a1")
    #expect(subagent.name == "Explore")
    #expect(subagent.role == nil)
    #expect(subagent.asked == nil)
    #expect(subagent.startedAt == 2)
    #expect(subagent.latestAction == RunningRowDetails.Now(text: "$ rg subagent", full: nil, disclosureTitle: nil,
                                                           isUnknown: false))

    let finishedTool = started + [record("PostToolUse", at: 4, agent: "a1", type: "Explore", call: "t1")]
    #expect(try running(finishedTool)?.subagents.first?.latestAction == nil)
    #expect(try running(finishedTool)?.subagents.count == 1)

    let stopped = finishedTool + [record("SubagentStop", at: 5, agent: "a1", type: "Explore")]
    #expect(try running(stopped)?.subagents.isEmpty == true)
}

@Test func claudeParallelSubagentsOfOneTypeAreNumberedByStartOrder() throws {
    let records = [promptSubmit,
                   // Written out of order on disk; the capture time decides the start order.
                   record("SubagentStart", at: 4, agent: "late", type: "Explore"),
                   record("SubagentStart", at: 2, agent: "early", type: "Explore"),
                   record("SubagentStart", at: 3, agent: "plan", type: "Plan"),
                   record("SubagentStart", at: 5, agent: "blank", type: ""),
                   record("SubagentStart", at: 6, agent: "untyped")]
    let subagents = try #require(try running(records)?.subagents)
    #expect(subagents.map(\.id) == ["early", "plan", "late", "blank", "untyped"])
    #expect(subagents.map(\.name) == ["Explore", "Plan", "Explore 2", "Subagent", "Subagent 2"])
    #expect(subagents.map(\.startedAt) == [2, 3, 4, 5, 6])
}

@Test func claudeNestedSubagentsAreListedFlatUnderTheSession() throws {
    // A subagent's own subagent fires the same hooks in the same session.
    let records = [promptSubmit,
                   record("SubagentStart", at: 2, agent: "outer", type: "general-purpose"),
                   record("PreToolUse", at: 3, agent: "outer", type: "general-purpose", tool: "Agent", call: "spawn"),
                   record("SubagentStart", at: 4, agent: "inner", type: "Explore"),
                   record("PreToolUse", at: 5, agent: "inner", type: "Explore", tool: "Read", call: "r1",
                          input: ["file_path": "/tmp/lab/a.swift"])]
    let subagents = try #require(try running(records)?.subagents)
    #expect(subagents.map(\.name) == ["general-purpose", "Explore"])
    #expect(subagents.last?.latestAction?.text == "Read /tmp/lab/a.swift")
}

@Test func claudeSubagentToolCallLeavesTheSessionsOwnNowUnchanged() throws {
    let records = [promptSubmit,
                   record("PreToolUse", at: 2, tool: "Bash", call: "own", input: ["command": "swift build"]),
                   record("SubagentStart", at: 3, agent: "a1", type: "Explore"),
                   record("PreToolUse", at: 4, agent: "a1", type: "Explore", tool: "Bash", call: "sub",
                          input: ["command": "rg foo"])]
    let row = try #require(try running(records))
    #expect(row.toolName == "Bash")
    #expect(row.toolInput["command"] == "swift build")
    #expect(row.subagents.first?.latestAction?.text == "$ rg foo")

    // The session's own call finishing leaves no "now"; the subagent's call never takes it over.
    let ownDone = records + [record("PostToolUse", at: 5, call: "own")]
    let after = try #require(try running(ownDone))
    #expect(after.toolName == nil)
    #expect(after.subagents.first?.latestAction?.text == "$ rg foo")

    // Without SubagentStart (pruned, or before Herdly started), the call is still kept off "now".
    let unknown = [promptSubmit, record("PreToolUse", at: 4, agent: "a9", tool: "Bash", call: "sub", input: ["command": "ls"])]
    let unknownRow = try #require(try running(unknown))
    #expect(unknownRow.toolName == nil)
    #expect(unknownRow.subagents.isEmpty)
}

@Test func claudeSubagentCallsStillMatchTheirApproval() throws {
    let records = [promptSubmit,
                   record("SubagentStart", at: 2, agent: "a1", type: "Explore"),
                   record("PreToolUse", at: 3, agent: "a1", type: "Explore", tool: "Bash", call: "sub",
                          input: ["command": "touch marker"]),
                   record("PermissionRequest", at: 3.5, agent: "a1", type: "Explore", tool: "Bash",
                          input: ["command": "touch marker"])]
    let root = try events(records)
    defer { try? FileManager.default.removeItem(at: root) }
    let approvals = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install", now: 10)
        .observations.compactMap { observation -> AgentApproval? in
            if case let .approval(value) = observation { return value }
            return nil
        }
    #expect(approvals.map(\.identity.call) == ["sub"])
}

@Test func claudeSessionEndClearsEverySubagent() throws {
    let started = [promptSubmit,
                   record("SubagentStart", at: 2, agent: "a1", type: "Explore"),
                   record("SubagentStart", at: 3, agent: "a2", type: "Plan"),
                   record("PreToolUse", at: 4, agent: "a1", type: "Explore", tool: "Bash", call: "t1",
                          input: ["command": "ls"])]
    #expect(try running(started)?.subagents.count == 2)
    // After SessionEnd the turn shows no running row at all; a new prompt in the session starts with none.
    #expect(try running(started + [record("SessionEnd", at: 5, prompt: nil)]) == nil)
    let resumed = started + [record("SessionEnd", at: 5, prompt: nil), record("UserPromptSubmit", at: 6, prompt: "p2")]
    #expect(try running(resumed)?.subagents.isEmpty == true)
    // The same holds for a background subagent that already outlived its parent's Stop.
    let background = started + [record("Stop", at: 4.5), record("SessionEnd", at: 5, prompt: nil),
                                record("UserPromptSubmit", at: 6, prompt: "p2")]
    #expect(try running(background)?.subagents.isEmpty == true)
}

// A background subagent (`run_in_background`) keeps running after its parent's turn ends: Claude sends
// the parent's Stop first and the subagent's own SubagentStop later, and the subagent's tool events keep
// the parent turn's prompt id (recorded 2026-11-10, #404).
@Test func claudeBackgroundSubagentOutlivesItsParentsStopUntilItsOwnStop() throws {
    let stopped = [promptSubmit,
                   record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                   record("SubagentStart", at: 2.5, agent: "a2", type: "Explore"),
                   record("Stop", at: 3)]
    #expect(try running(stopped)?.subagents.map(\.id) == ["a1", "a2"])

    let working = stopped + [record("PreToolUse", at: 4, agent: "a1", type: "general-purpose", tool: "Read",
                                    call: "r1", input: ["file_path": "/tmp/lab/a.swift"])]
    let row = try #require(try running(working))
    #expect(row.subagents.first?.latestAction?.text == "Read /tmp/lab/a.swift")
    // The subagent's call is still never the session's own "now".
    #expect(row.toolName == nil)

    // Its own stop removes it; the other background subagent stays.
    let one = working + [record("SubagentStop", at: 5, agent: "a1", type: "general-purpose")]
    #expect(try running(one)?.subagents.map(\.id) == ["a2"])
    // A later prompt in the session still lists the subagent still running.
    let next = one + [record("UserPromptSubmit", at: 6, prompt: "p2"), record("Stop", at: 7, prompt: "p2")]
    #expect(try running(next)?.subagents.map(\.id) == ["a2"])
    #expect(try running(next + [record("SubagentStop", at: 8, agent: "a2")])?.subagents.isEmpty == true)
}

@Test func claudeSubagentWithALostStopExpiresAtTheBoundAfterItsParentsStop() throws {
    let bound = ClaudeObservationReader.maximumSubagentAge
    #expect(bound == 30 * 60)
    let stopped = [promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "Explore"), record("Stop", at: 3)]
    #expect(try running(stopped, now: 2 + bound - 0.001)?.subagents.map(\.id) == ["a1"])
    #expect(try running(stopped, now: 2 + bound)?.subagents.isEmpty == true)
    // StopFailure ends the parent turn the same way; a later prompt's row shows what is left.
    let failed = [promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "Explore"),
                  record("StopFailure", at: 3), record("UserPromptSubmit", at: 4, prompt: "p2")]
    #expect(try running(failed, now: 2 + bound - 0.001)?.subagents.map(\.id) == ["a1"])
    #expect(try running(failed, now: 2 + bound)?.subagents.isEmpty == true)
    // A Stop before the subagent started does not bound it: that subagent belongs to a live turn.
    let laterTurn = [promptSubmit, record("Stop", at: 1.5), record("UserPromptSubmit", at: 1.8, prompt: "p2"),
                     record("SubagentStart", at: 2, prompt: "p2", agent: "a1", type: "Explore")]
    #expect(try running(laterTurn, now: 2 + bound * 4)?.subagents.map(\.id) == ["a1"])
}

@Test func claudeSubagentStartingAfterItsPromptsStopExpiresAtTheBound() throws {
    // #426: a subagent that (re)starts in a prompt whose Stop already came has outlived its parent's turn
    // from its start, so a lost stop of its own cannot keep it listed past the bound.
    let bound = ClaudeObservationReader.maximumSubagentAge
    for end in ["Stop", "StopFailure"] {
        let records = [promptSubmit, record(end, at: 3), record("UserPromptSubmit", at: 4, prompt: "p2"),
                       record("SubagentStart", at: 24, agent: "a1", type: "general-purpose")]
        #expect(try running(records, now: 24 + bound - 0.001)?.subagents.map(\.id) == ["a1"], "\(end)")
        #expect(try running(records, now: 24 + bound)?.subagents.isEmpty == true, "\(end)")
    }
    // Another prompt's Stop before the start does not bound a subagent of a live prompt.
    let live = [promptSubmit, record("Stop", at: 3), record("UserPromptSubmit", at: 4, prompt: "p2"),
                record("SubagentStart", at: 24, prompt: "p2", agent: "a1")]
    #expect(try running(live, now: 24 + bound * 4)?.subagents.map(\.id) == ["a1"])
}

@Test func claudeForegroundSubagentInALiveTurnHasNoAgeBound() throws {
    // A foreground subagent may run longer than the bound inside its parent's live turn.
    let records = [promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "Explore")]
    let long = 2 + ClaudeObservationReader.maximumSubagentAge * 4
    #expect(try running(records, now: long)?.subagents.map(\.id) == ["a1"])
    // Foreground subagents stop before their turn ends, as before.
    let finished = records + [record("SubagentStop", at: 3, agent: "a1"), record("Stop", at: 4)]
    #expect(try running(finished)?.subagents.isEmpty == true)
    #expect(try running(records + [record("SubagentStop", at: 3, agent: "a1"), record("StopFailure", at: 4)]) == nil)
}

@Test func claudeCachedScanStillExpiresASubagentAtTheBound() throws {
    let bound = ClaudeObservationReader.maximumSubagentAge
    let root = try events([promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "Explore"),
                           record("Stop", at: 3)])
    defer { try? FileManager.default.removeItem(at: root) }
    func subagents(_ scan: ClaudeObservationScan) -> [String]? {
        scan.observations.compactMap { observation -> AgentRunning? in
            if case let .running(value) = observation { return value }
            return nil
        }.first?.subagents.map(\.id)
    }
    let first = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                             now: 2 + bound - 1, cache: ClaudeRecordCache())
    #expect(subagents(first.scan) == ["a1"])
    // The directory is unchanged and was checked a second ago, so the cache is reused; the bound still applies.
    let second = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                              now: 2 + bound, cache: first.cache)
    #expect(subagents(second.scan) == [])
}

// #404 (owner decision: option A): while a Claude session's working row lists running subagents, an idle
// registry reading neither confirms its provisional Stop nor ends the row after `idleRunningGrace`. The
// switcher lives only in an opened working row (`AgentAttentionItem.running`).
private struct HeldSession {
    var records: [[String: Any]]
    var queue = AgentAttentionQueue()

    init(_ records: [[String: Any]]) { self.records = records }

    mutating func scan(now: Double) throws {
        let root = try events(records)
        defer { try? FileManager.default.removeItem(at: root) }
        // One scope across scans, so the queue reconciles the same root.
        let observations = ClaudeObservationReader.scan(events: root, sourceScope: "/tmp/root", installationID: "install",
                                                        now: now).observations
        queue.apply(ClaudeObservationScan(sourceScope: "/tmp/root", observations: observations), now: now)
    }

    mutating func idle(at observedAt: Double) {
        queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: observedAt, sessions: [
            ClaudeInventorySession(sessionID: "session-1", kind: .interactive, startedAt: 0,
                                   lifecycle: .interactive(status: "idle"), statusUpdatedAt: 3)
        ]), now: observedAt)
    }

    /// A registry reading that reports the session active (`busy`), which adds the inventory placeholder
    /// when no hook evidence gives the session a working row.
    mutating func busy(at observedAt: Double) {
        queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: observedAt, sessions: [
            ClaudeInventorySession(sessionID: "session-1", kind: .interactive, startedAt: 0,
                                   lifecycle: .interactive(status: "busy"), statusUpdatedAt: observedAt)
        ]), now: observedAt)
    }

    var kinds: [AgentAttentionKind] { queue.items.map(\.kind) }
    var subagents: [String]? { queue.items.first?.running?.subagents.map(\.id) }
}

@Test func claudeRowStaysWorkingAfterTheParentsStopWhileABackgroundSubagentRuns() throws {
    let grace = AgentAttentionQueue.idleRunningGrace
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                               record("Stop", at: 3)])
    try session.scan(now: 4)
    #expect(session.kinds == [.running])
    #expect(session.subagents == ["a1"])

    // The registry reads idle after the Stop: the row stays working with its switcher.
    session.idle(at: 5)
    #expect(session.kinds == [.running])
    #expect(session.subagents == ["a1"])

    // The subagent's call keeps the parent turn's prompt id; it updates the switcher in the same single
    // row, without reopening the turn or dropping its pending Stop.
    session.records.append(record("PreToolUse", at: 6, agent: "a1", type: "general-purpose", tool: "Bash", call: "b1",
                                  input: ["command": "swift test"]))
    try session.scan(now: 7)
    #expect(session.kinds == [.running])
    #expect(session.queue.items.first?.running?.subagents.first?.latestAction?.text == "$ swift test")
    #expect(session.queue.items.first?.running?.updatedAt == 3)

    // Past the idle grace, the row is still held.
    session.idle(at: 6 + grace + 60)
    #expect(session.kinds == [.running])
    #expect(session.subagents == ["a1"])

    // The subagent stops: the next idle reading confirms the parent's Stop as the to-check result.
    session.records.append(record("PostToolUse", at: 200, agent: "a1", type: "general-purpose", call: "b1"))
    session.records.append(record("PostToolBatch", at: 200.5, agent: "a1", input: ["tool_use_ids": ["b1"]]))
    session.records.append(record("SubagentStop", at: 201, agent: "a1", type: "general-purpose"))
    try session.scan(now: 202)
    #expect(session.kinds == [.running])
    #expect(session.subagents == [])
    session.idle(at: 203)
    #expect(session.kinds == [.outcome])
    #expect(session.queue.items.first?.outcome?.turn == "p1")
    #expect(session.queue.toCheckCount == 1 && session.queue.workingCount == 0)
}

@Test func claudeBackgroundSubagentsFinishingTurnGivesOneResultCard() throws {
    // Recorded shape: when a background subagent finishes, Claude starts a short turn of its own right after
    // the SubagentStop. Only that turn's result is carded; the held turn adds no second card or row.
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                               record("Stop", at: 3)])
    try session.scan(now: 4)
    session.idle(at: 5)
    session.records += [record("PreToolUse", at: 6, agent: "a1", tool: "Read", call: "r1",
                               input: ["file_path": "/tmp/lab/a.swift"]),
                        record("SubagentStop", at: 300, agent: "a1"),
                        record("UserPromptSubmit", at: 300, prompt: "p2"),
                        record("Stop", at: 302, prompt: "p2")]
    try session.scan(now: 303)
    #expect(session.kinds == [.running])
    #expect(session.queue.items.first?.running?.identity.turn == "p2")
    session.idle(at: 304)
    #expect(session.kinds == [.outcome])
    #expect(session.queue.items.first?.outcome?.turn == "p2")
}

@Test func claudeSubagentCallAfterANewPromptDoesNotReviveTheOldTurn() throws {
    // The old turn's background subagent keeps the old prompt id. Its calls neither reopen that turn as a
    // second working row nor take the session's row from the current prompt, whose switcher lists it.
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                               record("Stop", at: 3), record("UserPromptSubmit", at: 4, prompt: "p2"),
                               record("PreToolUse", at: 5, prompt: "p2", tool: "Bash", call: "own",
                                      input: ["command": "make"]),
                               record("PreToolUse", at: 6, agent: "a1", tool: "Bash", call: "sub",
                                      input: ["command": "rg foo"])])
    try session.scan(now: 7)
    let root = try events(session.records)
    defer { try? FileManager.default.removeItem(at: root) }
    let running = ClaudeObservationReader.scan(events: root, sourceScope: "/tmp/root", installationID: "install", now: 7)
        .observations.compactMap { observation -> AgentRunning? in
            if case let .running(value) = observation { return value }
            return nil
        }
    #expect(running.map(\.identity.turn) == ["p2"])
    #expect(session.kinds == [.running])
    #expect(session.queue.items.first?.running?.identity.turn == "p2")
    #expect(session.queue.items.first?.running?.subagents.first?.latestAction?.text == "$ rg foo")
}

@Test func claudeBackgroundSubagentsPermissionRequestAfterItsParentsTurnStillReachesTheQueue() throws {
    // The subagent's call does not reopen the closed turn but stays matchable, so its request is decidable
    // from Herdly as before, whether or not a newer prompt has started.
    for newer in [false, true] {
        var records = [promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                       record("Stop", at: 3)]
        if newer { records.append(record("UserPromptSubmit", at: 4, prompt: "p2")) }
        records += [record("PreToolUse", at: 5, agent: "a1", tool: "Bash", call: "sub", input: ["command": "touch marker"]),
                    record("PermissionRequest", at: 5.5, agent: "a1", tool: "Bash", input: ["command": "touch marker"])]
        let root = try events(records)
        defer { try? FileManager.default.removeItem(at: root) }
        let approvals = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install", now: 6)
            .observations.compactMap { observation -> AgentApproval? in
                if case let .approval(value) = observation { return value }
                return nil
            }
        #expect(approvals.map(\.identity.call) == ["sub"], "newer prompt: \(newer)")
    }
}

@Test func claudeHoldIsReleasedAtTheSubagentsAgeBound() throws {
    let bound = ClaudeObservationReader.maximumSubagentAge
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                               record("Stop", at: 3)])
    try session.scan(now: 2 + bound - 1)
    session.idle(at: 2 + bound - 1)
    #expect(session.kinds == [.running])
    #expect(session.subagents == ["a1"])
    try session.scan(now: 2 + bound)
    #expect(session.subagents == [])
    session.idle(at: 2 + bound)
    #expect(session.kinds == [.outcome])
}

@Test func claudeSessionEndDuringTheHoldEndsTheRow() throws {
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                               record("Stop", at: 3)])
    try session.scan(now: 4)
    session.idle(at: 5)
    #expect(session.kinds == [.running])
    session.records.append(record("SessionEnd", at: 6, prompt: nil))
    try session.scan(now: 7)
    #expect(session.kinds.isEmpty)
    #expect(session.queue.workingCount == 0)
}

@Test func claudeSessionWithoutSubagentsIsNotHeld() throws {
    // A Stop is confirmed by the next idle reading, as before.
    var stopped = HeldSession([promptSubmit, record("Stop", at: 3)])
    try stopped.scan(now: 4)
    stopped.idle(at: 5)
    #expect(stopped.kinds == [.outcome])
    // With no Stop, the idle fallback ends the row after the grace, with no card, as before.
    var quiet = HeldSession([promptSubmit])
    try quiet.scan(now: 4)
    quiet.idle(at: 1 + AgentAttentionQueue.idleRunningGrace - 1)
    #expect(quiet.kinds == [.running])
    quiet.idle(at: 1 + AgentAttentionQueue.idleRunningGrace)
    #expect(quiet.kinds.isEmpty)
    // A subagent that already stopped holds nothing either.
    var finished = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1"),
                                record("SubagentStop", at: 2.5, agent: "a1"), record("Stop", at: 3)])
    try finished.scan(now: 4)
    finished.idle(at: 5)
    #expect(finished.kinds == [.outcome])
}

@Test func claudeStopFailureIsNotHeldWhileASubagentRuns() throws {
    // A failure is a result the user must see: the Failed card shows at once, without waiting for the
    // registry or for the background subagent the failed turn started.
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                               record("StopFailure", at: 3)])
    try session.scan(now: 4)
    #expect(session.kinds == [.outcome])
    #expect(session.queue.items.first?.outcome?.status == .failed)
    #expect(session.queue.workingCount == 0)
}

@Test func claudeBackgroundSubagentsPermissionRequestAfterItsParentsFailureStaysInTheQueue() throws {
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                               record("StopFailure", at: 3),
                               record("PreToolUse", at: 5, agent: "a1", tool: "Bash", call: "sub",
                                      input: ["command": "touch marker"]),
                               record("PermissionRequest", at: 5.5, agent: "a1", tool: "Bash",
                                      input: ["command": "touch marker"])])
    try session.scan(now: 6)
    let approval = try #require(session.queue.items.first { $0.kind == .actionableApproval }?.approval)
    #expect(approval.identity.call == "sub")
    // The deadline runs from the request's own arrival, not from the failure.
    #expect(approval.arrivedAt == 5.5)
    #expect(session.queue.items.contains { $0.kind == .outcome && $0.outcome?.status == .failed })
    // A rescan repeats the failure; the turn's outcome does not resolve the later request.
    try session.scan(now: 7)
    #expect(session.queue.items.filter { $0.kind == .actionableApproval }.map(\.approval?.identity.call) == ["sub"])
}

@Test func claudeSessionsOwnLateRequestBehavesAsBefore() throws {
    // The session's own call in an older prompt, or after a failure, still reopens that turn, so its
    // request comes with the reopened working row (not through the closed-turn subagent path).
    for closing in ["UserPromptSubmit", "StopFailure"] {
        var records = [promptSubmit]
        records.append(closing == "StopFailure" ? record("StopFailure", at: 3) : record("UserPromptSubmit", at: 3, prompt: "p2"))
        records += [record("PreToolUse", at: 5, tool: "Bash", call: "own", input: ["command": "touch marker"]),
                    record("PermissionRequest", at: 5.5, tool: "Bash", input: ["command": "touch marker"])]
        let root = try events(records)
        defer { try? FileManager.default.removeItem(at: root) }
        let observations = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install", now: 6)
            .observations
        let approvals = observations.compactMap { observation -> AgentApproval? in
            if case let .approval(value) = observation { return value }
            return nil
        }
        let running = observations.compactMap { observation -> AgentRunning? in
            if case let .running(value) = observation { return value }
            return nil
        }
        #expect(approvals.map(\.identity.call) == ["own"], "\(closing)")
        #expect(running.contains { $0.identity.turn == "p1" }, "\(closing): p1 reopened")
        #expect(!observations.contains { if case .outcome = $0 { return true }; return false }, "\(closing)")
    }
}

@Test func claudeHoldNeverKeepsASessionTheRegistryNoLongerLists() throws {
    // The hold only skips what an idle reading of a listed session would do. A session no live Claude
    // process holds is never read idle, and its working row is offered for removal as before.
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                               record("Stop", at: 3)])
    try session.scan(now: 4)
    session.idle(at: 5)
    let held = try #require(session.queue.items.first)
    #expect(held.running?.subagents.map(\.id) == ["a1"])
    #expect(!session.queue.isRemovable(held, at: 6))
    session.queue.apply(ClaudeInventoryScan(sourceScope: "/tmp/root", observedAt: 6, sessions: []), now: 6)
    let gone = try #require(session.queue.items.first)
    #expect(session.queue.isRemovable(gone, at: 6))
}

// A background subagent's request whose subagent ends with no completion of the call (a native "No",
// which fires no hook, or a killed subagent) is resolved by that subagent's own end (#404, review 2).
private func subagentRequest(at: Double = 5, agent: String = "a1", prompt: String = "p1", call: String = "sub") -> [[String: Any]] {
    [record("PreToolUse", at: at, prompt: prompt, agent: agent, tool: "Bash", call: call, input: ["command": "touch \(call)"]),
     record("PermissionRequest", at: at + 0.5, prompt: prompt, agent: agent, tool: "Bash", input: ["command": "touch \(call)"])]
}

private func approvalCalls(_ session: HeldSession) -> [String] {
    session.queue.items.compactMap { $0.kind == .actionableApproval || $0.kind == .handedBackApproval ? $0.approval?.identity.call : nil }.sorted()
}

@Test func claudeSubagentsOwnStopResolvesItsHandedBackRequest() throws {
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1"), record("Stop", at: 3)]
                              + subagentRequest())
    try session.scan(now: 6)
    #expect(session.queue.items.first { $0.approval != nil }?.approval?.subagentID == "a1")
    try session.scan(now: 40)
    #expect(session.queue.items.contains { $0.kind == .handedBackApproval })
    // No PostToolUse and no registry status change: only the subagent's stop.
    session.records.append(record("SubagentStop", at: 50, agent: "a1"))
    try session.scan(now: 51)
    #expect(approvalCalls(session).isEmpty)
}

@Test func anotherSubagentsStopLeavesTheRequestAndTheSessionsOwn() throws {
    // Identity isolation: only the requesting subagent's own stop resolves its request.
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1"),
                               record("SubagentStart", at: 2.5, agent: "a2"), record("Stop", at: 3)]
                              + subagentRequest())
    try session.scan(now: 6)
    session.records.append(record("SubagentStop", at: 7, agent: "a2"))
    try session.scan(now: 8)
    #expect(approvalCalls(session) == ["sub"])
    session.records.append(record("SubagentStop", at: 9, agent: "a1"))
    try session.scan(now: 10)
    #expect(approvalCalls(session).isEmpty)

    // The session's own request (one prompt per session at a time) is untouched by a subagent's stop.
    var own = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1"),
                           record("PreToolUse", at: 3, agent: "a1", tool: "Read", call: "r1",
                                  input: ["file_path": "/tmp/lab/a.swift"]),
                           record("PreToolUse", at: 4, tool: "Bash", call: "own", input: ["command": "touch own"]),
                           record("PermissionRequest", at: 4.5, tool: "Bash", input: ["command": "touch own"]),
                           record("SubagentStop", at: 5, agent: "a1")])
    try own.scan(now: 6)
    #expect(approvalCalls(own) == ["own"])
    #expect(own.queue.items.first { $0.approval != nil }?.approval?.subagentID == nil)
}

@Test func olderClosedTurnsSubagentRequestEndsWithItsSubagentNotWithLaterPrompts() throws {
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1"), record("Stop", at: 3),
                               record("UserPromptSubmit", at: 4, prompt: "p2"), record("Stop", at: 4.5, prompt: "p2")]
                              + subagentRequest()
                              + [record("UserPromptSubmit", at: 10, prompt: "p3"), record("Stop", at: 11, prompt: "p3")])
    try session.scan(now: 12)
    #expect(approvalCalls(session) == ["sub"])
    session.records.append(record("SubagentStop", at: 20, agent: "a1"))
    try session.scan(now: 21)
    #expect(approvalCalls(session).isEmpty)
}

@Test func subagentDroppedAtTheBoundTakesItsRequestWithIt() throws {
    let bound = ClaudeObservationReader.maximumSubagentAge
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1"), record("Stop", at: 3)]
                              + subagentRequest())
    try session.scan(now: 2 + bound - 1)
    #expect(approvalCalls(session) == ["sub"])
    try session.scan(now: 2 + bound)
    #expect(approvalCalls(session).isEmpty)
}

@Test func unnamedSubagentsRequestIsResolvedByItsTurnsResultAsBefore() throws {
    // A request from a call with a missing or malformed agent_id names no subagent, so no SubagentStop can
    // ever resolve it: the turn's result does, as before #404. A named subagent's request is not.
    for (agent, kept) in [("a1", true), ("bad\nid", false)] {
        var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: agent), record("StopFailure", at: 3)]
                                  + subagentRequest(agent: agent))
        try session.scan(now: 6)
        try session.scan(now: 7)
        #expect(approvalCalls(session) == (kept ? ["sub"] : []), "agent \(agent)")
        #expect(session.queue.items.contains { $0.outcome?.status == .failed })
    }
    // After a Stop, the confirmed result resolves an unnamed subagent's request that arrived before it.
    var stopped = HeldSession([promptSubmit, record("Stop", at: 3)] + subagentRequest(agent: "bad\nid"))
    try stopped.scan(now: 6)
    #expect(approvalCalls(stopped) == ["sub"])
    #expect(stopped.queue.items.first { $0.approval != nil }?.approval?.subagentID == nil)
    stopped.idle(at: 7)
    #expect(approvalCalls(stopped).isEmpty)
    #expect(stopped.kinds == [.outcome])
}

@Test func subagentWhoseStartWasNeverSeenIsNotShielded() throws {
    // A named agent whose SubagentStart is pruned, before launch, or outside the window is treated as not
    // running: its request is not shielded from its turn's result.
    var session = HeldSession([promptSubmit, record("StopFailure", at: 3)] + subagentRequest(agent: "a9"))
    try session.scan(now: 6)
    try session.scan(now: 7)
    #expect(approvalCalls(session).isEmpty)
    // After a Stop it reaches the queue unshielded, like the session's own request.
    var stopped = HeldSession([promptSubmit, record("Stop", at: 3)] + subagentRequest(agent: "a9"))
    try stopped.scan(now: 6)
    #expect(approvalCalls(stopped) == ["sub"])
    #expect(stopped.queue.items.first { $0.approval != nil }?.approval?.subagentID == nil)
}

@Test func laterPromptKeepsARunningSubagentsRequestUntilItsOwnStop() throws {
    // Review 4 probe: a new prompt ends the previous turn's own activity, not a running subagent's request.
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1"), record("Stop", at: 3)]
                              + subagentRequest()
                              + [record("UserPromptSubmit", at: 7, prompt: "p2")])
    try session.scan(now: 8)
    #expect(approvalCalls(session) == ["sub"])
    session.records.append(record("SubagentStop", at: 9, agent: "a1"))
    try session.scan(now: 10)
    #expect(approvalCalls(session).isEmpty)
}

@Test func parentsStopKeepsARunningSubagentsEarlierRequest() throws {
    // The request came while the parent was still working; the parent's Stop and StopFailure leave it.
    for end in ["Stop", "StopFailure"] {
        var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1")]
                                  + subagentRequest(at: 3)
                                  + [record(end, at: 4)])
        try session.scan(now: 5)
        try session.scan(now: 6)
        #expect(approvalCalls(session) == ["sub"], "\(end)")
        session.records.append(record("SubagentStop", at: 7, agent: "a1"))
        try session.scan(now: 8)
        #expect(approvalCalls(session).isEmpty, "\(end)")
    }
}

@Test func sessionsOwnRequestStillEndsWithItsTurn() throws {
    // The session's own request is cleared by a new prompt or the turn's Stop, as before.
    for closing in [record("UserPromptSubmit", at: 7, prompt: "p2"), record("Stop", at: 7)] {
        var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1"),
                                   record("PreToolUse", at: 5, tool: "Bash", call: "own", input: ["command": "touch own"]),
                                   record("PermissionRequest", at: 5.5, tool: "Bash", input: ["command": "touch own"]),
                                   closing])
        try session.scan(now: 8)
        #expect(approvalCalls(session).isEmpty)
    }
}

@Test func newerPromptStartsTheSubagentsAgeBound() throws {
    // A newer prompt ends the parent turn as a Stop does, so the bound applies to its subagent's run.
    let bound = ClaudeObservationReader.maximumSubagentAge
    let records = [promptSubmit, record("SubagentStart", at: 2, agent: "a1")] + subagentRequest(at: 3)
        + [record("UserPromptSubmit", at: 7, prompt: "p2")]
    for (now, present) in [(2 + bound - 1, true), (2 + bound, false)] {
        var session = HeldSession(records)
        try session.scan(now: now)
        #expect(approvalCalls(session) == (present ? ["sub"] : []), "now \(now)")
        #expect(try running(records, now: now)?.subagents.map(\.id) == (present ? ["a1"] : []), "now \(now)")
    }
    // A repeated submit of the subagent's own prompt (Claude records some twice) does not.
    let repeated = [promptSubmit, record("SubagentStart", at: 2, agent: "a1"), record("UserPromptSubmit", at: 7)]
    #expect(try running(repeated, now: 2 + bound * 2)?.subagents.map(\.id) == ["a1"])
}

@Test func switcherFollowsTheSharedRunRuleOnATie() throws {
    // A stop and a start captured together, the stop's file first: the reader's own order would list the
    // subagent, but its run (the stop is at or after the start) has ended, and the switcher follows that.
    let root = try events([promptSubmit])
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, value) in [("0-stop", record("SubagentStop", at: 2, agent: "a1")),
                          ("1-start", record("SubagentStart", at: 2, agent: "a1"))] {
        var value = value
        value["source"] = ClaudeSetupRequirements.helperSource
        value["installation_id"] = "install"
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name + ".json"))
    }
    let scan = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install", now: 10)
    let row = scan.observations.compactMap { observation -> AgentRunning? in
        if case let .running(value) = observation { return value }
        return nil
    }.first
    #expect(row?.subagents.isEmpty == true)
    var lifetimes = ClaudeSubagentLifetimes()
    lifetimes.note(event: "SubagentStop", session: "session-1", agent: "a1", prompt: "p1", at: 2)
    lifetimes.note(event: "SubagentStart", session: "session-1", agent: "a1", prompt: "p1", at: 2)
    #expect(lifetimes.call(session: "session-1", agent: "a1", at: 2, now: 10) == .ended)
}

@Test func sessionPartIsRebuiltWhenItsSubagentReachesTheBound() throws {
    // #405 reuses each session's part until its records change. Another session's new record changes the
    // directory, so only the per-session reuse applies; session-1's subagent must still go at its bound.
    let bound = ClaudeObservationReader.maximumSubagentAge
    let root = try events([promptSubmit, record("SubagentStart", at: 2, agent: "a1"), record("Stop", at: 3)])
    defer { try? FileManager.default.removeItem(at: root) }
    func subagents(_ scan: ClaudeObservationScan) -> [String] {
        scan.observations.flatMap { observation -> [String] in
            if case let .running(value) = observation, value.identity.session.session == "session-1" {
                return value.subagents.map(\.id)
            }
            return []
        }
    }
    let first = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                             now: 2 + bound - 1, cache: ClaudeRecordCache())
    #expect(subagents(first.scan) == ["a1"])
    var other = record("UserPromptSubmit", at: 2 + bound - 0.5, prompt: "q1", session: "session-2")
    other["source"] = ClaudeSetupRequirements.helperSource
    other["installation_id"] = "install"
    try JSONSerialization.data(withJSONObject: other).write(to: root.appendingPathComponent("other.json"))
    let second = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                              now: 2 + bound, cache: first.cache)
    #expect(subagents(second.scan) == [])
    #expect(second.scan == ClaudeObservationReader.referenceScan(events: root, sourceScope: root.path,
                                                                  installationID: "install", now: 2 + bound))
}

// #426: Claude's Stop came while no subagent was listed, so the next idle reading finished the turn, and
// then a subagent started (or restarted) inside that same turn. Its calls keep the turn's prompt id.
// The session's working row lists that subagent, as #404's hold does, instead of the inventory
// placeholder; the finished result and its acknowledgment stay as they are, and no new result follows.
private func finishedTurn() throws -> HeldSession {
    var session = HeldSession([promptSubmit, record("Stop", at: 3)])
    try session.scan(now: 4)
    session.idle(at: 5)
    #expect(session.kinds == [.outcome])
    return session
}

private var restartedSubagent: [[String: Any]] { [
    record("SubagentStart", at: 24, agent: "a1", type: "general-purpose"),
    record("PreToolUse", at: 25, agent: "a1", type: "general-purpose", tool: "Bash", call: "b1",
           input: ["command": "swift test"]),
] }

private var restartedSubagentStops: [[String: Any]] { [
    record("PostToolUse", at: 400, agent: "a1", type: "general-purpose", call: "b1"),
    record("SubagentStop", at: 401, agent: "a1", type: "general-purpose"),
] }

@Test func claudeSubagentStartingAfterItsAcknowledgedTurnShowsItsRowWithoutANewResult() throws {
    var session = try finishedTurn()
    let turn = try #require(session.queue.items.first?.outcome?.id)
    session.queue.dismiss(.outcome(turn))
    #expect(session.kinds.isEmpty)

    session.records += restartedSubagent
    try session.scan(now: 26)
    session.busy(at: 26)
    let row = try #require(session.queue.items.first?.running)
    #expect(session.kinds == [.running])
    #expect(row.identity.turn == "p1")
    #expect(row.subagents.map(\.id) == ["a1"])
    #expect(row.subagents.first?.latestAction?.text == "$ swift test")
    #expect(row.toolName == nil)
    #expect(session.queue.acknowledgedOutcomes.contains(turn))
    #expect(session.queue.workingCount == 1 && session.queue.toCheckCount == 0)

    // The parent's prompt stays idle while the subagent runs: the row is held, as #404's is.
    session.idle(at: 27 + AgentAttentionQueue.idleRunningGrace)
    try session.scan(now: 28 + AgentAttentionQueue.idleRunningGrace)
    #expect(session.kinds == [.running])
    #expect(session.subagents == ["a1"])

    // The subagent stops: the row ends with no new result, and the turn stays acknowledged.
    session.records += restartedSubagentStops
    try session.scan(now: 402)
    session.idle(at: 403)
    try session.scan(now: 404)
    #expect(session.kinds.isEmpty)
    #expect(session.queue.toCheckCount == 0 && session.queue.workingCount == 0)
    #expect(session.queue.acknowledgedOutcomes.contains(turn))

    // With no hook evidence left, an active registry reading still gives the inventory placeholder.
    session.busy(at: 405)
    #expect(session.kinds == [.running])
    #expect(session.queue.items.first?.running?.identity.turn == "")
}

@Test func claudeSubagentStartingAfterItsUnacknowledgedTurnKeepsTheOneResult() throws {
    var session = try finishedTurn()
    session.records += restartedSubagent
    try session.scan(now: 26)
    session.busy(at: 26)
    // The result card stays beside the subagent's working row; nothing is reopened.
    var outcomes: [AgentOutcome] { session.queue.items.compactMap(\.outcome) }
    #expect(outcomes.map(\.arrivedAt) == [5])
    #expect(session.queue.items.compactMap(\.running).map { $0.subagents.map(\.id) } == [["a1"]])
    #expect(session.queue.toCheckCount == 1 && session.queue.workingCount == 1)

    session.records += restartedSubagentStops
    try session.scan(now: 402)
    session.idle(at: 403)
    #expect(session.queue.items.count == 1)
    #expect(outcomes.map(\.arrivedAt) == [5])
    #expect(session.queue.toCheckCount == 1 && session.queue.workingCount == 0)
}

@Test func claudeSubagentStartingAfterItsTurnEndsAtTheAgeBound() throws {
    let bound = ClaudeObservationReader.maximumSubagentAge
    var session = try finishedTurn()
    session.queue.dismiss(.outcome(try #require(session.queue.items.first?.outcome?.id)))
    session.records.append(restartedSubagent[0])
    try session.scan(now: 24 + bound - 1)
    #expect(session.subagents == ["a1"])
    try session.scan(now: 24 + bound)
    session.idle(at: 24 + bound)
    #expect(session.kinds.isEmpty)
    #expect(session.queue.toCheckCount == 0)
}

@Test func claudeRemovedSubagentRowStaysRemovedUntilAnotherSubagentStarts() throws {
    var session = try finishedTurn()
    session.queue.dismiss(.outcome(try #require(session.queue.items.first?.outcome?.id)))
    session.records += restartedSubagent
    try session.scan(now: 26)
    let row = try #require(session.queue.items.first)
    session.queue.remove(row.id)
    #expect(session.kinds.isEmpty)
    // Neither a rescan nor an idle reading (which ends the session's removal) brings it back.
    try session.scan(now: 27)
    session.idle(at: 28)
    try session.scan(now: 29)
    #expect(session.kinds.isEmpty)
    // A subagent starting after the removal is newer activity, so the row shows again.
    session.records.append(record("SubagentStart", at: 30, agent: "a2", type: "Explore"))
    try session.scan(now: 31)
    #expect(session.subagents == ["a1", "a2"])
}

@Test func claudeRemovedBackgroundSubagentHoldStaysRemoved() throws {
    // #404's held row: removing it still sticks across rescans, as before #426.
    var session = HeldSession([promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                               record("Stop", at: 3)])
    try session.scan(now: 4)
    session.idle(at: 5)
    session.queue.remove(try #require(session.queue.items.first).id)
    try session.scan(now: 6)
    session.idle(at: 7)
    try session.scan(now: 8)
    #expect(session.kinds.isEmpty)
}

@Test func claudeSameSubagentRestartingInsideItsFinishedTurnShowsItsRow() throws {
    // The recorded incident: background agent a1 ran in an earlier turn and reported back, Claude submitted
    // the notification as a new prompt and stopped, the queue finished that turn, and a1 started again in it.
    var session = HeldSession([promptSubmit,
                               record("SubagentStart", at: 2, agent: "a1", type: "general-purpose"),
                               record("Stop", at: 3),
                               record("SubagentStop", at: 10, agent: "a1", type: "general-purpose"),
                               record("UserPromptSubmit", at: 11, prompt: "p2"),
                               record("Stop", at: 13, prompt: "p2")])
    try session.scan(now: 14)
    session.idle(at: 15)
    let turn = try #require(session.queue.items.first?.outcome?.id)
    #expect(turn.turn == "p2")
    session.queue.dismiss(.outcome(turn))
    #expect(session.kinds.isEmpty)

    session.records += [record("SubagentStart", at: 34, prompt: "p2", agent: "a1", type: "general-purpose"),
                        record("PreToolUse", at: 35, prompt: "p2", agent: "a1", type: "general-purpose", tool: "Bash",
                               call: "b2", input: ["command": "swift build"])]
    try session.scan(now: 36)
    session.busy(at: 36)
    let row = try #require(session.queue.items.first?.running)
    #expect(session.kinds == [.running])
    #expect(row.identity.turn == "p2")
    #expect(row.subagents.map(\.id) == ["a1"])
    #expect(row.subagents.first?.startedAt == 34)
    #expect(row.subagents.first?.latestAction?.text == "$ swift build")
    #expect(session.queue.acknowledgedOutcomes.contains(turn) && session.queue.toCheckCount == 0)

    // Its new run is bounded from its own start, not from the earlier run's.
    let bound = ClaudeObservationReader.maximumSubagentAge
    try session.scan(now: 34 + bound - 1)
    #expect(session.subagents == ["a1"])
    try session.scan(now: 34 + bound)
    session.idle(at: 34 + bound)
    #expect(session.kinds.isEmpty)
    #expect(session.queue.toCheckCount == 0)
}

// MARK: Activity for the quiet rule (#419)

@Test func claudeActivityIsTheTurnsPromptAndToolEventsNotItsStop() throws {
    let prompted = [promptSubmit]
    #expect(try running(prompted)?.activityAt == 1)
    #expect(try running(prompted)?.toolStartedAt == nil)

    let toolStarted = prompted + [record("PreToolUse", at: 3, tool: "Bash", call: "c1", input: ["command": "npm test"])]
    let started = try #require(try running(toolStarted, now: 5))
    #expect(started.activityAt == 3)
    #expect(started.toolName == "Bash")
    #expect(started.toolStartedAt == 3)

    let finished = toolStarted + [record("PostToolUse", at: 7, call: "c1")]
    #expect(try running(finished, now: 8)?.activityAt == 7)
    #expect(try running(finished, now: 8)?.toolStartedAt == nil)

    // A Stop moves the turn's update time but is not activity.
    let stopped = finished + [record("Stop", at: 9)]
    let afterStop = try #require(try running(stopped, now: 10))
    #expect(afterStop.updatedAt == 9)
    #expect(afterStop.activityAt == 7)
}

@Test func claudeAToolCallThatIsNoLongerFreshKeepsItsActivityButNamesNoStart() throws {
    let records = [promptSubmit, record("PreToolUse", at: 3, tool: "Bash", call: "c1", input: ["command": "npm test"])]
    let stale = try #require(try running(records, now: 3 + ClaudeObservationReader.maximumToolFreshness + 1))
    #expect(stale.toolName == nil)
    #expect(stale.toolStartedAt == nil)
    #expect(stale.activityAt == 3)
}

@Test func claudeASubagentsStartAndToolEventsAreItsActivity() throws {
    let started = [promptSubmit, record("SubagentStart", at: 2, agent: "a1", type: "Explore")]
    #expect(try running(started)?.subagents.first?.lastActivityAt == 2)
    let called = started + [record("PreToolUse", at: 4, agent: "a1", type: "Explore", tool: "Bash", call: "s1",
                                   input: ["command": "rg x"])]
    #expect(try running(called)?.subagents.first?.lastActivityAt == 4)
    let done = called + [record("PostToolUse", at: 6, agent: "a1", type: "Explore", call: "s1")]
    let row = try #require(try running(done, now: 7))
    #expect(row.subagents.first?.lastActivityAt == 6)
    #expect(row.lastActivityAt == 6)
}

@Test func claudeLateSubagentActivityKeepsAnEndedTurnsRowFromGoingQuiet() throws {
    // The turn's own activity ends at its last tool event; a background subagent keeps working after the Stop.
    let records = [promptSubmit,
                   record("SubagentStart", at: 2, agent: "bg", type: "Explore"),
                   record("Stop", at: 3),
                   record("PreToolUse", at: 700, agent: "bg", type: "Explore", tool: "Bash", call: "s1",
                          input: ["command": "rg y"])]
    let row = try #require(try running(records, now: 701))
    #expect(row.activityAt == 1)
    #expect(row.lastActivityAt == 700)
    #expect(!QuietRule.isQuiet(lastActivity: row.lastActivityAt, now: 701))
}
