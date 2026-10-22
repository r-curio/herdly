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
