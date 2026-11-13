import Foundation
import Testing
@testable import HerdlyCore

private struct EventLab {
    let root: URL
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Writes one hook record whose file was created `age` seconds before `now`.
    @discardableResult
    func record(_ event: String, session: String, age: TimeInterval, source: String = "herdly-hook-v1",
                fields: [String: Any] = [:], name: String = UUID().uuidString, dated: Bool = true) throws -> URL {
        var value: [String: Any] = ["hook_event_name": event, "session_id": session, "source": source,
                                    "installation_id": "lab",
                                    "received_at": RolloutTimestamp.format(now.timeIntervalSince1970 - age),
                                    "captured_at": now.timeIntervalSince1970 - age]
        value.merge(fields) { _, new in new }
        let url = root.appendingPathComponent(name + ".json")
        try JSONSerialization.data(withJSONObject: value).write(to: url)
        if dated { try date(url, age: age) }
        return url
    }

    func date(_ url: URL, age: TimeInterval) throws {
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-age),
                                               .modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86400

@Test func retentionDeletesOnlyExpiredRecordsByKind() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let session = UUID().uuidString, turn = UUID().uuidString
    let freshPrompt = try lab.record("UserPromptSubmit", session: session, age: 10, fields: ["turn_id": turn])
    let weekOldPrompt = try lab.record("UserPromptSubmit", session: session, age: 6 * day, fields: ["turn_id": turn])
    let expiredPrompt = try lab.record("UserPromptSubmit", session: session, age: 8 * day, fields: ["turn_id": turn])
    let recentTool = try lab.record("PreToolUse", session: session, age: 30 * 60,
                                    fields: ["turn_id": turn, "tool_use_id": "recent"])
    let recentDone = try lab.record("PostToolUse", session: session, age: 29 * 60,
                                    fields: ["turn_id": turn, "tool_use_id": "recent"])
    let oldTool = try lab.record("PreToolUse", session: session, age: 2 * hour,
                                 fields: ["turn_id": turn, "tool_use_id": "old"])
    let oldDone = try lab.record("PostToolUse", session: session, age: 2 * hour - 5,
                                 fields: ["turn_id": turn, "tool_use_id": "old"])

    let outcome = HookEventRetention.prune(lab.root, now: lab.now)

    #expect(outcome.removed == 3)
    #expect(lab.exists(freshPrompt) && lab.exists(weekOldPrompt))
    #expect(!lab.exists(expiredPrompt))
    #expect(lab.exists(recentTool) && lab.exists(recentDone))
    #expect(!lab.exists(oldTool) && !lab.exists(oldDone))
}

@Test func retentionExpiresSubagentRecordsAfterAnHourEvenInAProtectedSession() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let reminded = UUID(), session = reminded.uuidString, turn = UUID().uuidString
    let request = ApprovalRequest(requestID: UUID(), sessionID: reminded, turnID: UUID(),
                                  details: ApprovalDetails(command: "make"),
                                  receivedAt: lab.now.timeIntervalSince1970 - 9 * day,
                                  expiresAt: lab.now.timeIntervalSince1970 - 9 * day + 30, outcome: .noDecision)
    try JSONEncoder().encode(request).write(to: ApprovalStore.requestURL(in: lab.root, id: request.id))
    let recentStart = try lab.record("SubagentStart", session: session, age: 30 * 60, fields: ["turn_id": turn])
    let recentStop = try lab.record("SubagentStop", session: session, age: 29 * 60, fields: ["turn_id": turn])
    let oldStart = try lab.record("SubagentStart", session: session, age: 2 * hour, fields: ["turn_id": turn])
    let oldStop = try lab.record("SubagentStop", session: session, age: 2 * hour - 5, fields: ["turn_id": turn])
    let prompt = try lab.record("UserPromptSubmit", session: session, age: 2 * hour, fields: ["turn_id": turn])
    let weekOldEnd = try lab.record("SessionEnd", session: session, age: 8 * day)
    let weekOldStop = try lab.record("SubagentStop", session: session, age: 8 * day, fields: ["turn_id": turn])

    HookEventRetention.prune(lab.root, now: lab.now)

    #expect(lab.exists(recentStart) && lab.exists(recentStop))
    #expect(!lab.exists(oldStart) && !lab.exists(oldStop))
    #expect(lab.exists(prompt))
    // The reminder keeps the session's lifecycle records past a week, but not its subagent records.
    #expect(lab.exists(weekOldEnd))
    #expect(!lab.exists(weekOldStop))
}

@Test func retentionKeepsARunningSubagentsStartUntilItStopsOrItsSessionEnds() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let claude = "herdly-claude-hook-v1"
    let running = UUID().uuidString, stopped = UUID().uuidString, ended = UUID().uuidString, closed = UUID().uuidString
    // A subagent running past the tool window keeps its start, so the row keeps its start time and name.
    let longRunning = try lab.record("SubagentStart", session: running, age: 3 * hour, source: claude,
                                     fields: ["prompt_id": "p1", "agent_id": "a1", "agent_type": "Explore"])
    // Finished by its own stop, past its age bound after a later Stop in the session, or by the
    // session's end: prunable.
    let finished = try lab.record("SubagentStart", session: stopped, age: 3 * hour, source: claude,
                                  fields: ["prompt_id": "p1", "agent_id": "a2"])
    let finishedStop = try lab.record("SubagentStop", session: stopped, age: 2 * hour, source: claude,
                                      fields: ["prompt_id": "p1", "agent_id": "a2"])
    let otherAgent = try lab.record("SubagentStart", session: stopped, age: 3 * hour, source: claude,
                                    fields: ["prompt_id": "p1", "agent_id": "a3"])
    let byTurn = try lab.record("SubagentStart", session: closed, age: 3 * hour, source: claude,
                                fields: ["prompt_id": "p1", "agent_id": "a4"])
    try lab.record("Stop", session: closed, age: 2 * hour, source: claude, fields: ["prompt_id": "p0"])
    let bySession = try lab.record("SubagentStart", session: ended, age: 3 * hour, source: claude,
                                   fields: ["prompt_id": "p1", "agent_id": "a5"])
    try lab.record("SessionEnd", session: ended, age: 2 * hour, source: claude)
    // An open start still expires with everything else after a week.
    let weekOld = try lab.record("SubagentStart", session: running, age: 8 * day, source: claude,
                                 fields: ["prompt_id": "p0", "agent_id": "a6"])

    HookEventRetention.prune(lab.root, now: lab.now)

    #expect(lab.exists(longRunning))
    #expect(!lab.exists(finished) && !lab.exists(finishedStop))
    // Another subagent's stop does not close this one.
    #expect(lab.exists(otherAgent))
    #expect(!lab.exists(byTurn) && !lab.exists(bySession))
    #expect(!lab.exists(weekOld))
}

@Test func retentionBoundsASubagentStartedAfterItsPromptsStopLikeTheReader() throws {
    // #426: a subagent restarting in a prompt whose Stop already came is bounded from its start, on both sides.
    let lab = try EventLab()
    defer { lab.remove() }
    let claude = "herdly-claude-hook-v1"
    let past = UUID().uuidString, live = UUID().uuidString
    for session in [past, live] {
        try lab.record("UserPromptSubmit", session: session, age: 4 * hour, source: claude, fields: ["prompt_id": "p1"])
        try lab.record("Stop", session: session, age: 4 * hour - 2, source: claude, fields: ["prompt_id": "p1"])
    }
    try lab.record("UserPromptSubmit", session: live, age: 4 * hour - 1, source: claude, fields: ["prompt_id": "p2"])
    let expired = try lab.record("SubagentStart", session: past, age: 3 * hour, source: claude,
                                 fields: ["prompt_id": "p1", "agent_id": "a1"])
    let foreground = try lab.record("SubagentStart", session: live, age: 3 * hour, source: claude,
                                    fields: ["prompt_id": "p2", "agent_id": "a1"])

    HookEventRetention.prune(lab.root, now: lab.now)

    #expect(!lab.exists(expired))
    // A subagent of the live prompt p2 has no bound, as before.
    #expect(lab.exists(foreground))
}

@Test func retentionExpiresASubagentStartWhoseAgentIDTheReaderWouldIgnore() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let claude = "herdly-claude-hook-v1", session = UUID().uuidString
    // The reader lists no subagent for these ids, so nothing is running to keep them for.
    let ids: [Any] = ["", String(repeating: "a", count: ClaudeObservationReader.maximumIdentifier + 1), "bad\nid", 42]
    let starts = try ids.map { id in
        try lab.record("SubagentStart", session: session, age: 3 * hour, source: claude,
                       fields: ["prompt_id": "p1", "agent_id": id])
    }
    let exact = try lab.record("SubagentStart", session: session, age: 3 * hour, source: claude,
                               fields: ["prompt_id": "p1",
                                        "agent_id": String(repeating: "a", count: ClaudeObservationReader.maximumIdentifier)])

    HookEventRetention.prune(lab.root, now: lab.now)

    #expect(starts.allSatisfy { !lab.exists($0) })
    #expect(lab.exists(exact))
}

@Test func retentionKeepsABackgroundSubagentsStartExactlyWhileTheReaderListsIt() throws {
    // A subagent that outlived its parent's turn end, with no stop of its own, is listed until its age
    // bound; retention keeps its start for exactly as long. The file is past the hour; the record's
    // capture time decides the bound, as it does for the reader.
    let bound = ClaudeObservationReader.maximumSubagentAge
    for event in ClaudeObservationReader.turnEndingEvents {
        for (startedAgo, listed) in [(bound - 1, true), (bound, false)] {
            let lab = try EventLab()
            defer { lab.remove() }
            let claude = "herdly-claude-hook-v1", session = UUID().uuidString
            let startedAt = lab.now.timeIntervalSince1970 - startedAgo
            try lab.record("UserPromptSubmit", session: session, age: 2 * hour, source: claude,
                           fields: ["prompt_id": "p1", "captured_at": startedAt - 1])
            let start = try lab.record("SubagentStart", session: session, age: 2 * hour, source: claude,
                                       fields: ["prompt_id": "p1", "agent_id": "a1", "agent_type": "Explore",
                                                "captured_at": startedAt])
            try lab.record(event, session: session, age: 2 * hour, source: claude,
                           fields: ["prompt_id": "p1", "captured_at": startedAt + 1])
            // A later prompt gives the session a working row even after StopFailure's failed outcome.
            try lab.record("UserPromptSubmit", session: session, age: 2 * hour, source: claude,
                           fields: ["prompt_id": "p2", "captured_at": startedAt + 2])
            let scan = ClaudeObservationReader.scan(events: lab.root, sourceScope: lab.root.path, installationID: "lab",
                                                    now: lab.now.timeIntervalSince1970)
            let reader = scan.observations.contains {
                if case let .running(value) = $0 { return value.subagents.map(\.id) == ["a1"] }
                return false
            }
            #expect(reader == listed, "\(event), started \(startedAgo)s ago: reader")
            HookEventRetention.prune(lab.root, now: lab.now)
            #expect(lab.exists(start) == listed, "\(event), started \(startedAgo)s ago: retention")
        }
    }
}

@Test func retentionAndReaderEndARunningSubagentOnTheSameEvents() throws {
    // Each session-wide event that ends the reader's subagents also lets retention prune their start.
    for event in ClaudeObservationReader.subagentsEndingEvents {
        let lab = try EventLab()
        defer { lab.remove() }
        let claude = "herdly-claude-hook-v1", session = UUID().uuidString
        let start = try lab.record("SubagentStart", session: session, age: 3 * hour, source: claude,
                                   fields: ["prompt_id": "p1", "agent_id": "a1", "agent_type": "Explore"])
        try lab.record("UserPromptSubmit", session: session, age: 3 * hour + 1, source: claude, fields: ["prompt_id": "p1"])
        let before = ClaudeObservationReader.scan(events: lab.root, sourceScope: lab.root.path, installationID: "lab",
                                                  now: lab.now.timeIntervalSince1970)
        #expect(before.observations.contains { if case let .running(value) = $0 { return value.subagents.count == 1 }; return false })
        try lab.record(event, session: session, age: 2 * hour, source: claude, fields: ["prompt_id": "p1"])
        let after = ClaudeObservationReader.scan(events: lab.root, sourceScope: lab.root.path, installationID: "lab",
                                                 now: lab.now.timeIntervalSince1970)
        #expect(!after.observations.contains { if case let .running(value) = $0 { return !value.subagents.isEmpty }; return false },
                "\(event) should end the reader's subagents")
        HookEventRetention.prune(lab.root, now: lab.now)
        #expect(!lab.exists(start), "\(event) should let retention prune the start")
    }
}

@Test func retentionKeepsAnUnansweredToolCallUntilItsTurnOrSessionEnds() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let session = UUID().uuidString
    // A Claude question waits in a PreToolUse with no completion: it must outlive the tool window.
    let question = try lab.record("PreToolUse", session: session, age: 3 * hour, source: "herdly-claude-hook-v1",
                                  fields: ["prompt_id": "p1", "tool_use_id": "ask", "tool_name": "AskUserQuestion"])
    // An interrupted tool closed by its turn's Stop is prunable.
    let interrupted = try lab.record("PreToolUse", session: session, age: 5 * hour, source: "herdly-claude-hook-v1",
                                     fields: ["prompt_id": "p0", "tool_use_id": "cut"])
    try lab.record("Stop", session: session, age: 4 * hour, source: "herdly-claude-hook-v1", fields: ["prompt_id": "p0"])
    // A batch completion closes every tool it lists.
    let batched = try lab.record("PreToolUse", session: session, age: 2 * hour, source: "herdly-claude-hook-v1",
                                 fields: ["prompt_id": "p1", "tool_use_id": "b1"])
    let batch = try lab.record("PostToolBatch", session: session, age: 2 * hour - 1, source: "herdly-claude-hook-v1",
                               fields: ["prompt_id": "p1", "tool_input": ["tool_use_ids": ["b1"]]])
    // An open tool still expires with everything else after a week.
    let abandoned = try lab.record("PreToolUse", session: UUID().uuidString, age: 8 * day,
                                   fields: ["turn_id": UUID().uuidString, "tool_use_id": "gone"])

    HookEventRetention.prune(lab.root, now: lab.now)

    #expect(lab.exists(question))
    #expect(!lab.exists(interrupted))
    #expect(!lab.exists(batched) && !lab.exists(batch))
    #expect(!lab.exists(abandoned))
}

@Test func retentionKeepsLifecycleRecordsOfSessionsWithRetainedRequests() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let reminded = UUID(), other = UUID(), turn = UUID()
    let request = ApprovalRequest(requestID: UUID(), sessionID: reminded, turnID: turn,
                                  details: ApprovalDetails(command: "make"),
                                  receivedAt: lab.now.timeIntervalSince1970 - 9 * day,
                                  expiresAt: lab.now.timeIntervalSince1970 - 9 * day + 30, outcome: .noDecision)
    try JSONEncoder().encode(request).write(to: ApprovalStore.requestURL(in: lab.root, id: request.id))
    try lab.date(ApprovalStore.requestURL(in: lab.root, id: request.id), age: 9 * day)
    let remindedEnd = try lab.record("SessionEnd", session: reminded.uuidString, age: 8 * day)
    let remindedTool = try lab.record("PreToolUse", session: reminded.uuidString, age: 8 * day,
                                      fields: ["turn_id": turn.uuidString, "tool_use_id": "t"])
    let otherEnd = try lab.record("SessionEnd", session: other.uuidString, age: 8 * day)

    HookEventRetention.prune(lab.root, now: lab.now)

    #expect(lab.exists(ApprovalStore.requestURL(in: lab.root, id: request.id)))
    #expect(lab.exists(remindedEnd))
    #expect(!lab.exists(remindedTool))
    #expect(!lab.exists(otherEnd))
}

@Test func retentionStopsProtectingASessionOnceItsRequestIsDecided() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let decided = UUID(), legacy = UUID()
    let request = ApprovalRequest(requestID: UUID(), sessionID: decided, turnID: UUID(),
                                  details: ApprovalDetails(command: "make"),
                                  receivedAt: lab.now.timeIntervalSince1970 - 9 * day,
                                  expiresAt: lab.now.timeIntervalSince1970 - 9 * day + 30, outcome: .pending)
    try JSONEncoder().encode(request).write(to: ApprovalStore.requestURL(in: lab.root, id: request.id))
    try JSONEncoder().encode(ApprovalDecisionRecord(requestID: request.id, decision: .allowOnce,
                                                    decidedAt: lab.now.timeIntervalSince1970 - 9 * day))
        .write(to: ApprovalStore.decisionURL(in: lab.root, id: request.id))
    // The older reminder format the reader still accepts protects its session too.
    let reminder = Reminder(request_id: UUID(), session_id: legacy, turn_id: UUID(), outcome: "no_decision")
    try JSONEncoder().encode(reminder).write(to: lab.root.appendingPathComponent(reminder.id.uuidString + ".approval"))
    let decidedEnd = try lab.record("SessionEnd", session: decided.uuidString, age: 8 * day)
    let legacyEnd = try lab.record("SessionEnd", session: legacy.uuidString.lowercased(), age: 8 * day)

    HookEventRetention.prune(lab.root, now: lab.now)

    #expect(!lab.exists(decidedEnd))
    #expect(lab.exists(legacyEnd))
}

@Test func retentionLeavesUnrecognizedMalformedAndNonRecordEntriesAlone() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let foreign = try lab.record("SessionEnd", session: UUID().uuidString, age: 30 * day, source: "someone-else")
    let malformed = lab.root.appendingPathComponent("broken.json")
    try Data("{\"hook_event_name\":".utf8).write(to: malformed)
    try lab.date(malformed, age: 30 * day)
    let receipt = lab.root.appendingPathComponent(UUID().uuidString + ".receipt")
    try Data("{}".utf8).write(to: receipt)
    try lab.date(receipt, age: 30 * day)
    let rendezvous = lab.root.appendingPathComponent(".herdly-claude-questions", isDirectory: true)
    try FileManager.default.createDirectory(at: rendezvous, withIntermediateDirectories: true)
    let target = try lab.record("SessionEnd", session: UUID().uuidString, age: 30 * day, name: "target")
    let link = lab.root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let staleTemporary = lab.root.appendingPathComponent(".herdly-" + UUID().uuidString)
    try Data("{}".utf8).write(to: staleTemporary)
    try lab.date(staleTemporary, age: 8 * day)
    let freshTemporary = lab.root.appendingPathComponent(".herdly-" + UUID().uuidString)
    try Data("{}".utf8).write(to: freshTemporary)
    try lab.date(freshTemporary, age: 60)

    HookEventRetention.prune(lab.root, now: lab.now)

    #expect(lab.exists(foreign) && lab.exists(malformed) && lab.exists(receipt) && lab.exists(rendezvous))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    #expect(!lab.exists(target))
    #expect(!lab.exists(staleTemporary) && lab.exists(freshTemporary))
}

@Test func retentionRefusesASymlinkedOrMissingDirectory() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let real = lab.root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let old = try EventLab.recordIn(real, lab: lab)
    let link = lab.root.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    #expect(HookEventRetention.prune(link, now: lab.now) == HookEventRetention.Outcome(available: false, removed: 0))
    #expect(HookEventRetention.prune(lab.root.appendingPathComponent("missing"), now: lab.now).available == false)
    #expect(lab.exists(old))
}

private extension EventLab {
    static func recordIn(_ directory: URL, lab: EventLab) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionEnd", "session_id": UUID().uuidString,
                                                    "source": "herdly-hook-v1", "received_at": "x"]).write(to: url)
        try lab.date(url, age: 30 * day)
        return url
    }
}

// MARK: - Readers above the old 4,096-entry cap

/// Fills the lab with `count` closed tool-call pairs (2 × count records) captured before `age`. Files
/// keep their real creation order, so records written afterwards are the newest.
private func flood(_ lab: EventLab, session: String, turnKey: String, turn: String, count: Int, age: TimeInterval,
                   source: String = "herdly-hook-v1") throws {
    for index in 0..<count {
        let id = "flood-\(index)"
        try lab.record("PreToolUse", session: session, age: age + Double(count - index) * 2 + 1, source: source,
                       fields: [turnKey: turn, "tool_use_id": id, "tool_name": "Read"], dated: false)
        try lab.record("PostToolUse", session: session, age: age + Double(count - index) * 2, source: source,
                       fields: [turnKey: turn, "tool_use_id": id, "tool_name": "Read"], dated: false)
    }
}

@Test func codexReadersStayAvailableAboveTheOldCapAndSeeTheCurrentSession() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let old = UUID(), current = UUID(), turn = UUID()
    try flood(lab, session: old.uuidString, turnKey: "turn_id", turn: UUID().uuidString, count: 2100, age: hour)
    try lab.record("SessionStart", session: current.uuidString, age: 20)
    try lab.record("UserPromptSubmit", session: current.uuidString, age: 10, fields: ["turn_id": turn.uuidString])

    let events = DesktopEventReader.read(from: lab.root)
    let state = DesktopState.replay(events)
    #expect(state.running.map(\.id) == [TurnIdentity(session: current, turn: turn)])
    #expect(events.count <= HookEventListing.maximumRecords)
}

@Test func claudeReaderStaysAvailableAboveTheOldCap() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let source = "herdly-claude-hook-v1"
    try flood(lab, session: "old", turnKey: "prompt_id", turn: "p-old", count: 2100, age: hour, source: source)
    try lab.record("SessionStart", session: "current", age: 20, source: source)
    try lab.record("UserPromptSubmit", session: "current", age: 10, source: source, fields: ["prompt_id": "p-now"])

    let scan = ClaudeObservationReader.scan(events: lab.root, sourceScope: "/claude", installationID: "lab",
                                            now: lab.now.timeIntervalSince1970)
    #expect(scan.available)
    #expect(scan.observations.contains { observation in
        if case let .running(value) = observation { return value.identity.session.session == "current" }
        return false
    })
}

@Test func reminderReaderFindsAnOldSessionEndForARetainedRequestOutsideTheWindow() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let reminded = UUID(), turn = UUID()
    let request = ApprovalRequest(requestID: UUID(), sessionID: reminded, turnID: turn,
                                  details: ApprovalDetails(command: "make"),
                                  receivedAt: lab.now.timeIntervalSince1970 - 2 * day,
                                  expiresAt: lab.now.timeIntervalSince1970 - 2 * day + 30, outcome: .noDecision)
    try JSONEncoder().encode(request).write(to: ApprovalStore.requestURL(in: lab.root, id: request.id))
    try lab.date(ApprovalStore.requestURL(in: lab.root, id: request.id), age: 2 * day)
    try lab.record("SessionEnd", session: reminded.uuidString, age: day)
    try flood(lab, session: UUID().uuidString, turnKey: "turn_id", turn: UUID().uuidString, count: 2100, age: 10)
    let rollouts = lab.root.appendingPathComponent("rollouts", isDirectory: true)

    let scan = ReminderReader.scan(events: lab.root, rollouts: rollouts)

    #expect(scan.reminders.map(\.id) == [request.id])
    #expect(scan.sessionEnds[reminded] != nil)
}

@Test func listingFailsClosedBeyondItsBoundAndReadersReportUnavailable() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    for _ in 0..<4 {
        FileManager.default.createFile(atPath: lab.root.appendingPathComponent(UUID().uuidString + ".json").path,
                                       contents: nil)
    }
    #expect(HookEventListing.entries(in: lab.root, limit: 4)?.count == 4)
    #expect(HookEventListing.entries(in: lab.root, limit: 3) == nil)

    let notADirectory = lab.root.appendingPathComponent("plain.json")
    try Data("{}".utf8).write(to: notADirectory)
    #expect(!ClaudeObservationReader.scan(events: notADirectory, sourceScope: "/claude", installationID: "lab").available)
    #expect(DesktopEventReader.read(from: notADirectory).isEmpty)
    #expect(ReminderReader.scan(events: notADirectory, rollouts: lab.root).reminders.isEmpty)
}

// #404 review 3: a background subagent's request must stay resolved after pruning and a restart. The end
// state is checked with a fresh reader and queue over the pruned directory, as after a Herdly relaunch.
private func requestsAfterRestart(_ lab: EventLab) -> [AgentApproval] {
    let now = lab.now.timeIntervalSince1970
    let scan = ClaudeObservationReader.scan(events: lab.root, sourceScope: lab.root.path, installationID: "lab", now: now)
    var queue = AgentAttentionQueue()
    queue.apply(scan, now: now)
    return queue.items.compactMap(\.approval)
}

/// A background subagent started `startedAgo` seconds before `lab.now`, outliving its parent's Stop, then
/// asking for permission; with `stoppedAgo`, it stopped then with no completion of the call (a native "No").
@discardableResult
private func backgroundRequest(_ lab: EventLab, session: String, startedAgo: TimeInterval, stoppedAgo: TimeInterval?,
                               withStart: Bool = true) throws -> (call: URL, start: URL?) {
    let claude = "herdly-claude-hook-v1"
    func at(_ ago: TimeInterval, _ event: String, _ fields: [String: Any]) throws -> URL {
        try lab.record(event, session: session, age: ago, source: claude, fields: fields)
    }
    try at(startedAgo + 2, "UserPromptSubmit", ["prompt_id": "p1"])
    let start = withStart ? try at(startedAgo, "SubagentStart", ["prompt_id": "p1", "agent_id": "a1", "agent_type": "Explore"]) : nil
    try at(startedAgo - 1, "Stop", ["prompt_id": "p1"])
    let call = try at(startedAgo - 5, "PreToolUse", ["prompt_id": "p1", "agent_id": "a1", "tool_name": "Bash",
                                                     "tool_use_id": "sub", "tool_input": ["command": "touch marker"]])
    try at(startedAgo - 5.5, "PermissionRequest", ["prompt_id": "p1", "agent_id": "a1", "tool_name": "Bash",
                                                   "tool_input": ["command": "touch marker"]])
    if let stoppedAgo { try at(stoppedAgo, "SubagentStop", ["prompt_id": "p1", "agent_id": "a1"]) }
    return (call, start)
}

@Test func retentionKeepsASubagentRequestResolvedByItsOwnStopAfterPruning() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let (call, start) = try backgroundRequest(lab, session: UUID().uuidString, startedAgo: 2 * hour, stoppedAgo: 2 * hour - 60)
    #expect(requestsAfterRestart(lab).isEmpty)
    HookEventRetention.prune(lab.root, now: lab.now)
    // The stopped subagent's call is closed, so it goes on the tool schedule with its start.
    #expect(!lab.exists(call))
    #expect(start.map(lab.exists) == false)
    #expect(requestsAfterRestart(lab).isEmpty)
}

@Test func retentionKeepsASubagentRequestResolvedByTheBoundAfterPruning() throws {
    let lab = try EventLab()
    defer { lab.remove() }
    let (call, start) = try backgroundRequest(lab, session: UUID().uuidString, startedAgo: 2 * hour, stoppedAgo: nil)
    #expect(requestsAfterRestart(lab).isEmpty)
    HookEventRetention.prune(lab.root, now: lab.now)
    #expect(!lab.exists(call))
    #expect(start.map(lab.exists) == false)
    #expect(requestsAfterRestart(lab).isEmpty)
}

@Test func retentionKeepsASubagentsStartWhileOneOfItsCallsIsKept() throws {
    // Past the bound and past the hour, but its call is not: the start stays so the reader still sees the
    // subagent ended, and the request stays resolved between pruning passes.
    let lab = try EventLab()
    defer { lab.remove() }
    let bound = ClaudeObservationReader.maximumSubagentAge
    let (call, start) = try backgroundRequest(lab, session: UUID().uuidString, startedAgo: hour + 3, stoppedAgo: nil)
    #expect(hour + 3 > bound)
    HookEventRetention.prune(lab.root, now: lab.now)
    #expect(lab.exists(call))
    #expect(start.map(lab.exists) == true)
    #expect(requestsAfterRestart(lab).isEmpty)
}

@Test func retentionKeepsARunningSubagentsRequestOpen() throws {
    // Still listed (within the bound): its call stays open and its request stays.
    let lab = try EventLab()
    defer { lab.remove() }
    let (call, _) = try backgroundRequest(lab, session: UUID().uuidString, startedAgo: 20 * 60, stoppedAgo: nil)
    HookEventRetention.prune(lab.root, now: lab.now)
    #expect(lab.exists(call))
    #expect(requestsAfterRestart(lab).map(\.identity.call) == ["sub"])
}

private func readerRequests(_ lab: EventLab) -> [AgentApproval] {
    ClaudeObservationReader.scan(events: lab.root, sourceScope: lab.root.path, installationID: "lab",
                                 now: lab.now.timeIntervalSince1970).observations.compactMap {
        if case let .approval(value) = $0 { return value }
        return nil
    }
}

@Test func readerAndRetentionAgreeOnACallAfterItsSubagentsStop() throws {
    // A call captured after its subagent's stop belongs to no run of that subagent: neither side ends it by
    // that stop. The reader shows its request unshielded, and retention keeps the open call.
    let lab = try EventLab()
    defer { lab.remove() }
    let claude = "herdly-claude-hook-v1", session = UUID().uuidString
    let base = lab.now.timeIntervalSince1970 - 2 * hour
    func at(_ offset: Double, _ event: String, _ fields: [String: Any]) throws -> URL {
        var fields = fields
        fields["captured_at"] = base + offset
        return try lab.record(event, session: session, age: 2 * hour - offset, source: claude, fields: fields)
    }
    try at(0, "UserPromptSubmit", ["prompt_id": "p1"])
    try at(1, "SubagentStart", ["prompt_id": "p1", "agent_id": "a1"])
    try at(2, "SubagentStop", ["prompt_id": "p1", "agent_id": "a1"])
    let call = try at(3, "PreToolUse", ["prompt_id": "p1", "agent_id": "a1", "tool_name": "Bash", "tool_use_id": "sub",
                                        "tool_input": ["command": "touch marker"]])
    try at(3.5, "PermissionRequest", ["prompt_id": "p1", "agent_id": "a1", "tool_name": "Bash",
                                      "tool_input": ["command": "touch marker"]])
    #expect(readerRequests(lab).map(\.identity.call) == ["sub"])
    #expect(readerRequests(lab).first?.subagentID == nil)
    HookEventRetention.prune(lab.root, now: lab.now)
    #expect(lab.exists(call))
    #expect(readerRequests(lab).map(\.identity.call) == ["sub"])
}

@Test func readerAndRetentionStartASubagentsLifetimeOverAfterSessionEnd() throws {
    // The same agent id started again after the session ended and resumed: its call belongs to the new
    // run, which is still listed, so both sides keep it (the earlier run's end does not close it).
    let lab = try EventLab()
    defer { lab.remove() }
    let claude = "herdly-claude-hook-v1", session = UUID().uuidString
    let base = lab.now.timeIntervalSince1970 - 2 * hour
    func at(_ offset: Double, _ event: String, _ fields: [String: Any], age: TimeInterval? = nil) throws -> URL {
        var fields = fields
        fields["captured_at"] = base + offset
        return try lab.record(event, session: session, age: age ?? 2 * hour - offset, source: claude, fields: fields)
    }
    try at(0, "UserPromptSubmit", ["prompt_id": "p1"])
    try at(1, "SubagentStart", ["prompt_id": "p1", "agent_id": "a1"])
    try at(2, "SessionEnd", [:])
    // The new run started recently by capture time; its records' files are over an hour old.
    let resumed = 2 * hour - 10 * 60
    try at(resumed, "UserPromptSubmit", ["prompt_id": "p2"], age: 90 * 60)
    let start = try at(resumed + 1, "SubagentStart", ["prompt_id": "p2", "agent_id": "a1"], age: 90 * 60)
    let call = try at(resumed + 2, "PreToolUse", ["prompt_id": "p2", "agent_id": "a1", "tool_name": "Bash",
                                                  "tool_use_id": "sub", "tool_input": ["command": "touch marker"]],
                      age: 90 * 60)
    try at(resumed + 2.5, "PermissionRequest", ["prompt_id": "p2", "agent_id": "a1", "tool_name": "Bash",
                                                "tool_input": ["command": "touch marker"]], age: 90 * 60)
    try at(resumed + 3, "Stop", ["prompt_id": "p2"], age: 90 * 60)
    #expect(readerRequests(lab).first?.subagentID == "a1")
    HookEventRetention.prune(lab.root, now: lab.now)
    #expect(lab.exists(call))
    #expect(lab.exists(start))
    #expect(readerRequests(lab).map(\.identity.call) == ["sub"])
}

@Test func retentionEndsASubagentsCallAtTheBoundAfterANewerPrompt() throws {
    // With no Stop, a newer prompt starts the bound for retention as for the reader.
    let lab = try EventLab()
    defer { lab.remove() }
    let claude = "herdly-claude-hook-v1", session = UUID().uuidString
    try lab.record("UserPromptSubmit", session: session, age: 2 * hour + 2, source: claude, fields: ["prompt_id": "p1"])
    let start = try lab.record("SubagentStart", session: session, age: 2 * hour, source: claude,
                               fields: ["prompt_id": "p1", "agent_id": "a1"])
    let call = try lab.record("PreToolUse", session: session, age: 2 * hour - 5, source: claude,
                              fields: ["prompt_id": "p1", "agent_id": "a1", "tool_name": "Bash", "tool_use_id": "sub",
                                       "tool_input": ["command": "touch marker"]])
    try lab.record("UserPromptSubmit", session: session, age: 2 * hour - 10, source: claude, fields: ["prompt_id": "p2"])
    HookEventRetention.prune(lab.root, now: lab.now)
    #expect(!lab.exists(call))
    #expect(!lab.exists(start))
}

@Test func readerAndRetentionBoundAStartsPromptIDTheSameWay() throws {
    // Review 6: a start whose prompt_id is empty, oversized or line-broken has no prompt for either side,
    // so a newer prompt does not start its bound: the reader keeps listing it and retention keeps its start.
    for bad in ["", String(repeating: "x", count: ClaudeObservationReader.maximumIdentifier + 44), "a\nb"] {
        let lab = try EventLab()
        defer { lab.remove() }
        let claude = "herdly-claude-hook-v1", session = UUID().uuidString
        try lab.record("UserPromptSubmit", session: session, age: 2 * hour + 2, source: claude, fields: ["prompt_id": "p1"])
        let start = try lab.record("SubagentStart", session: session, age: 2 * hour, source: claude,
                                   fields: ["prompt_id": bad, "agent_id": "a1"])
        try lab.record("UserPromptSubmit", session: session, age: 2 * hour - 10, source: claude, fields: ["prompt_id": "p2"])
        func listed() -> [String] {
            ClaudeObservationReader.scan(events: lab.root, sourceScope: lab.root.path, installationID: "lab",
                                         now: lab.now.timeIntervalSince1970).observations.flatMap { observation -> [String] in
                if case let .running(value) = observation { return value.subagents.map(\.id) }
                return []
            }
        }
        #expect(listed() == ["a1"], "\(bad.prefix(5).debugDescription) before")
        HookEventRetention.prune(lab.root, now: lab.now)
        #expect(lab.exists(start), "\(bad.prefix(5).debugDescription) start")
        #expect(listed() == ["a1"], "\(bad.prefix(5).debugDescription) after")
    }
}
