import Foundation
import Testing
@testable import SteerCore

// Fixture lines follow the shapes recorded from a real Codex desktop rollout (engine 0.153.4): a
// `function_call` named `request_user_input` and its `function_call_output`, both carrying the turn
// id in `internal_chat_message_metadata_passthrough`. See docs/evidence/desktop-user-input-request.json.

private func meta(_ session: UUID, source: String = "vscode") -> String {
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"\(source)\"}}\n"
}

private func questionArguments(_ questions: [(header: String, question: String, options: [String])]) -> String {
    let entries = questions.map { entry -> [String: Any] in
        ["id": entry.header.lowercased(), "header": entry.header, "question": entry.question,
         "options": entry.options.map { ["label": $0, "description": "More detail from Codex."] }]
    }
    let bytes = try! JSONSerialization.data(withJSONObject: ["questions": entries])
    return String(decoding: bytes, as: UTF8.self)
}

private func questionCall(turn: UUID?, call: String?, at: String, arguments: String, passthrough: Bool = true) -> String {
    var payload: [String: Any] = ["type": "function_call", "name": "request_user_input", "arguments": arguments, "id": "fc_1"]
    if let call { payload["call_id"] = call }
    if passthrough { payload["internal_chat_message_metadata_passthrough"] = ["turn_id": turn?.uuidString.lowercased() ?? "not-a-turn"] }
    let bytes = try! JSONSerialization.data(withJSONObject: ["timestamp": at, "type": "response_item", "payload": payload])
    return String(decoding: bytes, as: UTF8.self) + "\n"
}

private func questionOutput(turn: UUID, call: String, at: String, answer: String = "Nested levels (Recommended)") -> String {
    let payload: [String: Any] = ["type": "function_call_output", "call_id": call,
                                  "output": "{\"answers\":{\"nested\":{\"answers\":[\"\(answer)\"]}}}",
                                  "internal_chat_message_metadata_passthrough": ["turn_id": turn.uuidString.lowercased()]]
    let bytes = try! JSONSerialization.data(withJSONObject: ["timestamp": at, "type": "response_item", "payload": payload])
    return String(decoding: bytes, as: UTF8.self) + "\n"
}

private func turnEvent(_ kind: String, turn: UUID, at: String) -> String {
    "{\"timestamp\":\"\(at)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"\(turn.uuidString.lowercased())\"}}\n"
}

private let sample = questionArguments([
    ("List shape", "Should the list allow nested levels?",
     ["Nested levels (Recommended)", "One level only"]),
    ("First release", "Should the first release also support checkout?", ["View only (Recommended)", "Include export"])
])
private let askedAt = "2026-09-14T02:20:36.895Z"
private let answeredAt = "2026-09-14T02:21:41.908Z"

@Test func pendingQuestionIsReportedWithItsTextAndArrivalTime() {
    let session = UUID(), turn = UUID()
    let data = Data((meta(session) + turnEvent("task_started", turn: turn, at: "2026-09-14T02:20:14.383Z")
        + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)).utf8)
    let evidence = ReminderReader.evidence(in: data, session: session)
    #expect(evidence.answeredQuestions.isEmpty)
    #expect(evidence.completed.isEmpty)
    let question = try? #require(evidence.pendingQuestions.first)
    #expect(evidence.pendingQuestions.count == 1)
    #expect(question?.id == QuestionIdentity(source: .desktop, session: session, callID: "call_1"))
    #expect(question?.turn == turn)
    #expect(question?.arrivedAt == RolloutTimestamp.parse(askedAt))
    #expect(question?.prompts.count == 2)
    #expect(question?.prompts[0] == QuestionPrompt(id: "nested choices", header: "List shape",
                                                   question: "Should the list allow nested levels?",
                                                   options: ["Nested levels (Recommended)", "One level only"]))
    #expect(question?.prompts[1].header == "First release")
}

@Test func anOutputForTheCallMovesTheQuestionToAnswered() {
    let session = UUID(), turn = UUID()
    let free = Data((meta(session) + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)
        + questionOutput(turn: turn, call: "call_1", at: answeredAt, answer: "assuming each branch has its own module, then only that one")).utf8)
    let evidence = ReminderReader.evidence(in: free, session: session)
    #expect(evidence.pendingQuestions.isEmpty)
    #expect(evidence.answeredQuestions == [QuestionIdentity(source: .desktop, session: session, callID: "call_1")])
    // An output for some other call is not an answer to this one.
    let other = Data((meta(session) + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)
        + questionOutput(turn: turn, call: "call_9", at: answeredAt)).utf8)
    #expect(ReminderReader.evidence(in: other, session: session).pendingQuestions.count == 1)
}

@Test func sequentialCallsInOneTurnLeaveOnlyTheUnansweredOnePending() {
    let session = UUID(), turn = UUID()
    let data = Data((meta(session)
        + questionCall(turn: turn, call: "call_1", at: "2026-09-14T02:10:00.000Z", arguments: sample)
        + questionOutput(turn: turn, call: "call_1", at: "2026-09-14T02:11:00.000Z")
        + questionCall(turn: turn, call: "call_2", at: "2026-09-14T02:12:00.000Z", arguments: sample)
        + questionOutput(turn: turn, call: "call_2", at: "2026-09-14T02:13:00.000Z")
        + questionCall(turn: turn, call: "call_3", at: "2026-09-14T02:14:00.000Z", arguments: sample)).utf8)
    let evidence = ReminderReader.evidence(in: data, session: session)
    #expect(evidence.pendingQuestions.map(\.callID) == ["call_3"])
    #expect(evidence.answeredQuestions.map(\.callID).sorted() == ["call_1", "call_2"])
}

@Test func unreadableArgumentsStillYieldAQuestionAndCapsMarkTruncation() {
    let session = UUID(), turn = UUID()
    for arguments in ["not json", "{\"questions\":\"nope\"}", "[]", String(repeating: "x", count: QuestionPrompt.maximumArguments + 1)] {
        let data = Data((meta(session) + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: arguments)).utf8)
        let evidence = ReminderReader.evidence(in: data, session: session)
        #expect(evidence.pendingQuestions.count == 1, Comment(rawValue: String(arguments.prefix(20))))
        #expect(evidence.pendingQuestions.first?.prompts.isEmpty == true)
    }
    let long = String(repeating: "q", count: QuestionPrompt.maximumQuestion + 5)
    let many = questionArguments([("H", long, (0..<(QuestionPrompt.maximumOptions + 2)).map { "option \($0)" })])
    let prompts = try? #require(QuestionPrompt.parse(arguments: many))
    #expect(prompts?.count == 1)
    #expect(prompts?.first?.truncated == true)
    #expect(prompts?.first?.options.count == QuestionPrompt.maximumOptions)
    #expect(prompts?.first?.question?.count == QuestionPrompt.maximumQuestion + 1)
    // Free-text-only questions have no options and are not truncated.
    let text = questionArguments([("Name", "What should the module be called?", [])])
    #expect(QuestionPrompt.parse(arguments: text) == [QuestionPrompt(id: "name", header: "Name", question: "What should the module be called?", options: [])])
}

@Test func aCallWithoutIdTurnOrTimeIsNotAQuestion() {
    let session = UUID(), turn = UUID()
    let cases = [
        questionCall(turn: turn, call: nil, at: askedAt, arguments: sample),
        questionCall(turn: turn, call: "", at: askedAt, arguments: sample),
        questionCall(turn: turn, call: String(repeating: "c", count: ReminderReader.maximumCallID + 1), at: askedAt, arguments: sample),
        questionCall(turn: nil, call: "call_1", at: askedAt, arguments: sample),
        questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample, passthrough: false),
        questionCall(turn: turn, call: "call_1", at: "yesterday", arguments: sample),
        questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample).replacingOccurrences(of: "request_user_input", with: "other_tool")
    ]
    for line in cases {
        let evidence = ReminderReader.evidence(in: Data((meta(session) + line).utf8), session: session)
        #expect(evidence.pendingQuestions.isEmpty && evidence.answeredQuestions.isEmpty, Comment(rawValue: String(line.prefix(80))))
    }
}

@Test func unreadableRolloutsAreNoEvidenceAndDoNotClearAQueuedQuestion() {
    let session = UUID(), turn = UUID()
    let good = Data((meta(session) + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)).utf8)
    var queue = AttentionQueue()
    var scan = ReminderScan()
    scan.questions = ReminderReader.evidence(in: good, session: session).pendingQuestions
    queue.apply(scan: scan, desktopEvents: [], now: 0)
    #expect(queue.items.map(\.kind) == [.question])

    let partial = Data((meta(session) + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)
        + String(questionOutput(turn: turn, call: "call_1", at: answeredAt).dropLast(3))).utf8)
    let wrongSession = Data((meta(UUID()) + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)).utf8)
    for data in [partial, wrongSession] {
        let evidence = ReminderReader.evidence(in: data, session: session)
        #expect(evidence == ReminderReader.RolloutEvidence())
        var next = ReminderScan()
        next.questions = evidence.pendingQuestions
        next.answeredQuestions = evidence.answeredQuestions
        queue.apply(scan: next, desktopEvents: [], now: 1)
        #expect(queue.items.map(\.kind) == [.question])
    }
}

@Test func questionsInCLISessionsAreLabeledCLIThroughTheScan() throws {
    let session = UUID(), turn = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-question-\(UUID().uuidString)")
    let events = root.appendingPathComponent("events"), rollouts = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (source, expected) in [("cli", AttentionSource.cli), ("vscode", .desktop)] {
        let hook = "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"\(session)\",\"turn_id\":\"\(turn)\",\"received_at\":\"2026-09-14T02:20:14Z\"}"
        try hook.write(to: events.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
        let rollout = rollouts.appendingPathComponent("rollout-2026-09-14T02-20-00-\(session.uuidString.lowercased()).jsonl")
        try (meta(session, source: source) + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)
             + questionCall(turn: turn, call: "call_0", at: "2026-09-14T02:15:00.000Z", arguments: sample)
             + questionOutput(turn: turn, call: "call_0", at: "2026-09-14T02:16:00.000Z"))
            .write(to: rollout, atomically: true, encoding: .utf8)
        let scan = ReminderReader.scan(events: events, rollouts: rollouts)
        #expect(scan.questions.map(\.id) == [QuestionIdentity(source: expected, session: session, callID: "call_1")])
        #expect(scan.answeredQuestions == [QuestionIdentity(source: expected, session: session, callID: "call_0")])
    }
}

@Test func sessionsWithoutHookRecordsAreNotRead() throws {
    let session = UUID(), turn = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-question-\(UUID().uuidString)")
    let events = root.appendingPathComponent("events"), rollouts = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try (meta(session) + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample))
        .write(to: rollouts.appendingPathComponent("rollout-x-\(session.uuidString.lowercased()).jsonl"), atomically: true, encoding: .utf8)
    #expect(ReminderReader.scan(events: events, rollouts: rollouts).questions.isEmpty)
}

/// Replays the committed desktop recording: pending before the answer line, answered after it.
@Test func recordedDesktopQuestionReplaysAsPendingThenAnswered() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/evidence/desktop-user-input-request.json")
    let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
    let session = try #require((record["session"] as? String).flatMap(UUID.init(uuidString:)))
    let turn = try #require((record["turn"] as? String).flatMap(UUID.init(uuidString:)))
    let callID = try #require(record["call_id"] as? String)
    let lines = try #require(record["lines"] as? [[String: Any]])
    let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
    let answerIndex = try #require(lines.firstIndex { ($0["payload"] as? [String: Any])?["type"] as? String == "function_call_output" })
    let identity = QuestionIdentity(source: .desktop, session: session, callID: callID)

    let before = ReminderReader.evidence(in: Data((text[..<answerIndex].joined(separator: "\n") + "\n").utf8), session: session)
    #expect(before.pendingQuestions.map(\.id) == [identity])
    #expect(before.pendingQuestions.first?.turn == turn)
    #expect(before.pendingQuestions.first?.arrivedAt == RolloutTimestamp.parse(record["asked_at"] as! String))
    #expect(before.pendingQuestions.first?.prompts.first?.header == "List shape")
    #expect(before.pendingQuestions.first?.prompts.first?.options == ["Nested levels (Recommended)", "One level only"])
    #expect(before.pendingQuestions.first?.prompts.count == 2)

    let after = ReminderReader.evidence(in: Data((text.joined(separator: "\n") + "\n").utf8), session: session)
    #expect(after.pendingQuestions.isEmpty)
    #expect(after.answeredQuestions == [identity])
    #expect(after.completed == [TurnIdentity(session: session, turn: turn)])
}

@Test func optionPositionsAreKeptWhenALabelIsUnreadable() {
    let root: [String: Any] = ["questions": [["header": "H", "question": "Q",
                                              "options": [["label": "first"], ["description": "no label"], ["label": "third"]]]]]
    let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    let prompts = try? #require(QuestionPrompt.parse(arguments: arguments))
    // The list stops where numbering would drift, so a digit never names the wrong option.
    #expect(prompts?.first?.options == ["first"])
    #expect(prompts?.first?.optionsComplete == false)
    #expect(prompts?.first?.truncated == true)
    let ok = QuestionPrompt.parse(arguments: sample)
    #expect(ok?.allSatisfy { $0.optionsComplete && !$0.isOther } == true)
}

@Test func isOtherIsReadPerQuestion() {
    let root: [String: Any] = ["questions": [["header": "A", "question": "Q", "isOther": true, "options": [["label": "x"]]],
                                             ["header": "B", "question": "Q", "options": [["label": "y"]]]]]
    let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    let prompts = QuestionPrompt.parse(arguments: arguments)
    #expect(prompts?.map(\.isOther) == [true, false])
}

@Test func moreOptionsOrQuestionsThanTheCapAreRecordedAsIncomplete() {
    let many = questionArguments([("H", "Q", (0..<(QuestionPrompt.maximumOptions + 1)).map { "option \($0)" })])
    #expect(QuestionPrompt.parse(arguments: many)?.first?.optionsComplete == false)
    let exact = questionArguments([("H", "Q", (0..<QuestionPrompt.maximumOptions).map { "option \($0)" })])
    #expect(QuestionPrompt.parse(arguments: exact)?.first?.optionsComplete == true)
    let questions = questionArguments((0..<(QuestionPrompt.maximumQuestions + 1)).map { ("H\($0)", "Q", ["a", "b"]) })
    let parsed = QuestionPrompt.parseCall(arguments: questions)
    #expect(parsed?.count == QuestionPrompt.maximumQuestions + 1)
    #expect(parsed?.prompts.count == QuestionPrompt.maximumQuestions)
    let session = UUID(), turn = UUID()
    let data = Data((meta(session) + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: questions)).utf8)
    #expect(ReminderReader.evidence(in: data, session: session).pendingQuestions.first?.questionCount == QuestionPrompt.maximumQuestions + 1)
    #expect(ReminderReader.evidence(in: Data((meta(session) + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: "nope")).utf8),
                                    session: session).pendingQuestions.first?.questionCount == 0)
}

@Test func rolloutURLRequiresExactlyOneMatchingFile() throws {
    let session = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-rollout-\(UUID().uuidString)")
    let nested = root.appendingPathComponent("2026/09/14")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(ReminderReader.rolloutURL(for: session, in: root) == nil)
    let first = nested.appendingPathComponent("rollout-2026-09-14T02-20-00-\(session.uuidString.lowercased()).jsonl")
    try Data(meta(session).utf8).write(to: first)
    try Data("x".utf8).write(to: nested.appendingPathComponent("rollout-other-\(UUID().uuidString.lowercased()).jsonl"))
    #expect(ReminderReader.rolloutURL(for: session, in: root)?.resolvingSymlinksInPath() == first.resolvingSymlinksInPath())
    try Data(meta(session).utf8).write(to: root.appendingPathComponent("rollout-copy-\(session.uuidString.uppercased()).jsonl"))
    #expect(ReminderReader.rolloutURL(for: session, in: root) == nil)
}

@Test func aSessionWhoseIdTitlesAGhosttyTabIsCLIWhateverTheRolloutSays() throws {
    // Through the app-server daemon (CLI 0.154.0) a TUI session is recorded with `source: vscode`,
    // the desktop's value. The session-id tab title Steer configures is the proof it is a CLI session.
    let session = UUID(), turn = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-question-\(UUID().uuidString)")
    let events = root.appendingPathComponent("events"), rollouts = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let hook = "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"\(session)\",\"turn_id\":\"\(turn)\",\"received_at\":\"2026-09-14T02:20:14Z\"}"
    try hook.write(to: events.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
    let rollout = rollouts.appendingPathComponent("rollout-2026-09-14T02-20-00-\(session.uuidString.lowercased()).jsonl")
    try (meta(session, source: "vscode") + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample))
        .write(to: rollout, atomically: true, encoding: .utf8)
    let takenAt = RolloutTimestamp.parse("2026-09-14T02:21:00Z")!
    let titled = ReminderReader.scan(events: events, rollouts: rollouts,
                                     ghostty: GhosttyInventory(titles: [GhosttyMatch.title(session), "other tab"], takenAt: takenAt))
    #expect(titled.cliSessions == [session])
    #expect(titled.titledCLISessions == [session])
    #expect(titled.questions.map(\.id) == [QuestionIdentity(source: .cli, session: session, callID: "call_1")])
    #expect(titled.cliState.liveSessions == [session])
    #expect(titled.sessionEnds.isEmpty)
    // Only an exact title match counts: a prefix, another session's title, or no titles leaves it desktop.
    for titles in [Set<String>(), ["other tab"], [String(GhosttyMatch.title(session).dropLast())], [session.uuidString.lowercased()]] {
        let plain = ReminderReader.scan(events: events, rollouts: rollouts, ghostty: GhosttyInventory(titles: titles, takenAt: takenAt))
        #expect(plain.cliSessions.isEmpty, Comment(rawValue: "\(titles)"))
        #expect(plain.titledCLISessions.isEmpty)
        #expect(plain.questions.map(\.id) == [QuestionIdentity(source: .desktop, session: session, callID: "call_1")])
    }
    // A session proved earlier stays CLI, and its tab's absence from a later inventory ends it,
    // dated at that inventory: the daemon keeps the thread loaded and fires no SessionEnd.
    let gone = ReminderReader.scan(events: events, rollouts: rollouts, ghostty: GhosttyInventory(titles: ["zsh"], takenAt: takenAt),
                                   knownCLISessions: [session])
    #expect(gone.cliSessions == [session] && gone.titledCLISessions.isEmpty)
    #expect(gone.sessionEnds[session] == takenAt)
    #expect(gone.cliState.liveSessions.isEmpty && gone.cliState.endedSessions == [session])
    #expect(gone.questions.map(\.id) == [QuestionIdentity(source: .cli, session: session, callID: "call_1")])
    // Known but the tab is still there: live. Known with no inventory at all (Ghostty unreadable): live.
    let still = ReminderReader.scan(events: events, rollouts: rollouts, ghostty: GhosttyInventory(titles: [GhosttyMatch.title(session)], takenAt: takenAt),
                                    knownCLISessions: [session])
    #expect(still.cliState.liveSessions == [session] && still.sessionEnds.isEmpty)
    let blind = ReminderReader.scan(events: events, rollouts: rollouts, ghostty: nil, knownCLISessions: [session])
    #expect(blind.cliSessions == [session] && blind.cliState.liveSessions == [session] && blind.sessionEnds.isEmpty)
    // A session ended by an absent tab clears its pending question from the queue as a session end does.
    var queue = AttentionQueue()
    _ = queue.apply(scan: titled, desktopEvents: [], now: takenAt - 30)
    #expect(queue.items.contains { $0.question?.callID == "call_1" })
    _ = queue.apply(scan: gone, desktopEvents: [], now: takenAt + 1)
    #expect(!queue.items.contains { $0.question?.callID == "call_1" })
    // The snapshot helper lists every terminal name across windows and tabs.
    let json = #"{"status":"ok","windows":[{"id":"w","tabs":[{"id":"t","terminals":[{"id":"a","name":"\#(GhosttyMatch.title(session))"},{"id":"b","name":"zsh"}]}]}],"selected":null}"#
    let snapshot = try JSONDecoder().decode(GhosttySnapshot.self, from: Data(json.utf8))
    #expect(snapshot.terminalNames == [GhosttyMatch.title(session), "zsh"])
}

@Test func aDaemonThreadIsCLIAndEndsWhenNoTabShowsItAfterTheGrace() throws {
    let session = UUID(), turn = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-question-\(UUID().uuidString)")
    let events = root.appendingPathComponent("events"), rollouts = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let startedAt = "2026-09-14T02:20:00Z"
    for (name, turnID) in [("SessionStart", ""), ("UserPromptSubmit", "\"turn_id\":\"\(turn)\",")] {
        let hook = "{\"hook_event_name\":\"\(name)\",\"session_id\":\"\(session)\",\(turnID)\"received_at\":\"\(startedAt)\"}"
        try hook.write(to: events.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
    }
    let rollout = rollouts.appendingPathComponent("rollout-2026-09-14T02-20-00-\(session.uuidString.lowercased()).jsonl")
    let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"vscode\",\"originator\":\"steer\"}}\n"
    try (header + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)).write(to: rollout, atomically: true, encoding: .utf8)
    let started = RolloutTimestamp.parse(startedAt)!
    // Loaded in the daemon with a non-desktop originator: CLI, with no Ghostty inventory at all.
    let daemon = ReminderReader.scan(events: events, rollouts: rollouts, daemonThreads: [session])
    #expect(daemon.cliSessions == [session] && daemon.cliState.liveSessions == [session] && daemon.sessionEnds.isEmpty)
    #expect(daemon.questions.map(\.id) == [QuestionIdentity(source: .cli, session: session, callID: "call_1")])
    // Not loaded in the daemon: the header's desktop label stands.
    #expect(ReminderReader.scan(events: events, rollouts: rollouts).cliSessions.isEmpty)
    // A desktop-originated thread loaded in the daemon stays desktop.
    let desktopHeader = header.replacingOccurrences(of: "steer", with: ReminderReader.desktopOriginator)
    try (desktopHeader + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)).write(to: rollout, atomically: true, encoding: .utf8)
    #expect(ReminderReader.scan(events: events, rollouts: rollouts, daemonThreads: [session]).cliSessions.isEmpty)
    try (header + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)).write(to: rollout, atomically: true, encoding: .utf8)
    // An inventory without its title inside the grace: still live (the tab may not be listed yet).
    let early = ReminderReader.scan(events: events, rollouts: rollouts,
                                    ghostty: GhosttyInventory(titles: ["zsh"], takenAt: started + ReminderReader.surfaceGrace - 1), daemonThreads: [session])
    #expect(early.cliState.liveSessions == [session] && early.sessionEnds.isEmpty)
    // After the grace with no title: the surface is gone, the session ends at that inventory.
    let late = ReminderReader.scan(events: events, rollouts: rollouts,
                                   ghostty: GhosttyInventory(titles: ["zsh"], takenAt: started + ReminderReader.surfaceGrace), daemonThreads: [session])
    #expect(late.cliSessions == [session] && late.cliState.liveSessions.isEmpty && late.sessionEnds[session] == started + ReminderReader.surfaceGrace)
    // With the title present it is live and remembered.
    let shown = ReminderReader.scan(events: events, rollouts: rollouts,
                                    ghostty: GhosttyInventory(titles: [GhosttyMatch.title(session)], takenAt: started + 100), daemonThreads: [session])
    #expect(shown.cliState.liveSessions == [session] && shown.titledCLISessions == [session] && shown.sessionEnds.isEmpty)
    // In herdr (ADR 0012) its title is on a herdr pane, not a Ghostty tab: still live after the grace,
    // and not Ghostty-titled. Without the daemon, the pane title alone proves it a CLI session.
    let inHerdr = ReminderReader.scan(events: events, rollouts: rollouts,
                                      ghostty: GhosttyInventory(titles: ["herdr"], takenAt: started + 100),
                                      daemonThreads: [session], herdrTitles: .known([GhosttyMatch.title(session), "zsh"]))
    #expect(inHerdr.cliSessions == [session] && inHerdr.cliState.liveSessions == [session] && inHerdr.sessionEnds.isEmpty)
    #expect(inHerdr.titledCLISessions.isEmpty && inHerdr.endedSessions.isEmpty)
    let paneOnly = ReminderReader.scan(events: events, rollouts: rollouts, herdrTitles: .known([GhosttyMatch.title(session)]))
    #expect(paneOnly.cliSessions == [session])
    // Another session's pane title does not stand in for this one.
    let otherPane = ReminderReader.scan(events: events, rollouts: rollouts,
                                        ghostty: GhosttyInventory(titles: ["herdr"], takenAt: started + 100),
                                        daemonThreads: [session], herdrTitles: .known([GhosttyMatch.title(UUID())]))
    #expect(otherPane.cliState.liveSessions.isEmpty && otherPane.endedSessions == [session])
    // herdr in use but its scan failed: a pane may still show the title, so nothing is ended.
    let herdrFailed = ReminderReader.scan(events: events, rollouts: rollouts,
                                          ghostty: GhosttyInventory(titles: ["herdr"], takenAt: started + 100),
                                          daemonThreads: [session], herdrTitles: .unknown)
    #expect(herdrFailed.cliState.liveSessions == [session] && herdrFailed.endedSessions.isEmpty)

    // Ended, then resumed: live again, and a tab that later disappears ends it again after the grace.
    let resumedAt = "2026-09-15T05:00:00Z"
    for (name, at) in [("SessionEnd", "2026-09-14T03:00:00Z"), ("SessionStart", resumedAt)] {
        let hook = "{\"hook_event_name\":\"\(name)\",\"session_id\":\"\(session)\",\"received_at\":\"\(at)\"}"
        try hook.write(to: events.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
    }
    let resumed = RolloutTimestamp.parse(resumedAt)!
    let afterResume = ReminderReader.scan(events: events, rollouts: rollouts,
                                          ghostty: GhosttyInventory(titles: ["zsh"], takenAt: resumed + ReminderReader.surfaceGrace - 1),
                                          daemonThreads: [session])
    #expect(afterResume.cliState.liveSessions == [session] && afterResume.endedSessions.isEmpty)
    let closedAfterResume = ReminderReader.scan(events: events, rollouts: rollouts,
                                                ghostty: GhosttyInventory(titles: ["zsh"], takenAt: resumed + ReminderReader.surfaceGrace),
                                                daemonThreads: [session])
    #expect(closedAfterResume.endedSessions == [session] && closedAfterResume.cliState.liveSessions.isEmpty)
    #expect(closedAfterResume.sessionEnds[session] == resumed + ReminderReader.surfaceGrace)
}

@Test func aDaemonSessionWithoutAGhosttyTabIsNotEndedWhileHerdrTitlesAreUnknown() throws {
    // A daemon-run TUI whose only surface is a herdr pane, past the grace, with a pending question.
    let session = UUID(), turn = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-question-\(UUID().uuidString)")
    let events = root.appendingPathComponent("events"), rollouts = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let startedAt = "2026-09-14T02:20:00Z"
    for (name, turnID) in [("SessionStart", ""), ("UserPromptSubmit", "\"turn_id\":\"\(turn)\",")] {
        let hook = "{\"hook_event_name\":\"\(name)\",\"session_id\":\"\(session)\",\(turnID)\"received_at\":\"\(startedAt)\"}"
        try hook.write(to: events.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
    }
    let rollout = rollouts.appendingPathComponent("rollout-2026-09-14T02-20-00-\(session.uuidString.lowercased()).jsonl")
    let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"vscode\",\"originator\":\"steer\"}}\n"
    try (header + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)).write(to: rollout, atomically: true, encoding: .utf8)
    let inventory = GhosttyInventory(titles: ["herdr"], takenAt: RolloutTimestamp.parse(startedAt)! + 100)
    func scan(_ herdrTitles: HerdrPaneTitles) -> ReminderScan {
        ReminderReader.scan(events: events, rollouts: rollouts, ghostty: inventory, daemonThreads: [session], herdrTitles: herdrTitles)
    }
    let question = QuestionIdentity(source: .cli, session: session, callID: "call_1")
    var queue = AttentionQueue()
    // The first scan to see a Ghostty inventory runs before herdr's gate has opened, with herdr's
    // socket trusted; then the gate opens and the first herdr scan fails. Neither ends the session.
    for titles in [HerdrPaneTitles.from(gateOpen: false, outcome: nil, defaultSocketTrusted: true),
                   .from(gateOpen: true, outcome: nil, defaultSocketTrusted: true),
                   .from(gateOpen: true, outcome: .unavailable(.timeout), defaultSocketTrusted: true)] {
        #expect(titles == .unknown)
        let unknown = scan(titles)
        #expect(unknown.cliState.liveSessions == [session] && unknown.endedSessions.isEmpty && unknown.sessionEnds.isEmpty)
        _ = queue.apply(scan: unknown, desktopEvents: [], now: inventory.takenAt)
        #expect(queue.items.contains { $0.question?.id == question })
    }
    // A successful scan without its title, or no herdr in use, ends it as the Ghostty rules do.
    for titles in [HerdrPaneTitles.known(["zsh"]), .from(gateOpen: false, outcome: nil, defaultSocketTrusted: false)] {
        let ended = scan(titles)
        #expect(ended.endedSessions == [session] && ended.sessionEnds[session] == inventory.takenAt)
    }
}

@Test func aSessionResumedAfterItsEndIsNotEnded() throws {
    let session = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-resume-\(UUID().uuidString)")
    let events = root.appendingPathComponent("events"), rollouts = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func hook(_ name: String, _ at: String) throws {
        let line = "{\"hook_event_name\":\"\(name)\",\"session_id\":\"\(session)\",\"received_at\":\"\(at)\"}"
        try line.write(to: events.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
    }
    let rollout = rollouts.appendingPathComponent("rollout-2026-09-14T02-20-00-\(session.uuidString.lowercased()).jsonl")
    try meta(session, source: "cli").write(to: rollout, atomically: true, encoding: .utf8)
    try hook("SessionStart", "2026-09-14T02:20:00Z")
    try hook("SessionEnd", "2026-09-14T03:00:00Z")
    let ended = ReminderReader.scan(events: events, rollouts: rollouts)
    #expect(ended.endedSessions == [session] && ended.cliState.liveSessions.isEmpty)
    // Resumed later: live again. Its end time is kept for request resolution, but it is not ended.
    try hook("SessionStart", "2026-09-15T01:00:00Z")
    let resumed = ReminderReader.scan(events: events, rollouts: rollouts)
    #expect(resumed.cliState.liveSessions == [session])
    #expect(resumed.sessionEnds[session] != nil && resumed.endedSessions.isEmpty)
}

@Test func aTurnTheRolloutEndedStopsRunningWithoutAStopHook() throws {
    let session = UUID(), turn = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-question-\(UUID().uuidString)")
    let events = root.appendingPathComponent("events"), rollouts = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let hook = "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"\(session)\",\"turn_id\":\"\(turn)\",\"received_at\":\"2026-09-14T02:20:14Z\"}"
    try hook.write(to: events.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
    let rollout = rollouts.appendingPathComponent("rollout-2026-09-14T02-20-00-\(session.uuidString.lowercased()).jsonl")
    let aborted = "{\"timestamp\":\"2026-09-14T02:21:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"\(turn)\"}}\n"
    try meta(session, source: "cli").write(to: rollout, atomically: true, encoding: .utf8)
    #expect(ReminderReader.scan(events: events, rollouts: rollouts).cliState.running.map(\.turn) == [turn])
    try (meta(session, source: "cli") + aborted).write(to: rollout, atomically: true, encoding: .utf8)
    let ended = ReminderReader.scan(events: events, rollouts: rollouts)
    #expect(ended.cliState.running.isEmpty && ended.cliState.liveSessions == [session])
}

@Test func aDesktopLabelledTurnTheRolloutAbortedIsNotShownRunning() throws {
    let session = UUID(), turn = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-question-\(UUID().uuidString)")
    let events = root.appendingPathComponent("events"), rollouts = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let hook = "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"\(session)\",\"turn_id\":\"\(turn)\",\"received_at\":\"2026-09-14T02:20:14Z\"}"
    try hook.write(to: events.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
    let rollout = rollouts.appendingPathComponent("rollout-2026-09-14T02-20-00-\(session.uuidString.lowercased()).jsonl")
    let aborted = "{\"timestamp\":\"2026-09-14T02:21:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"\(turn)\"}}\n"
    try (meta(session, source: "vscode") + aborted).write(to: rollout, atomically: true, encoding: .utf8)
    var queue = AttentionQueue()
    let scan = ReminderReader.scan(events: events, rollouts: rollouts)
    _ = queue.apply(scan: scan, desktopEvents: DesktopEventReader.read(from: events), now: RolloutTimestamp.parse("2026-09-14T02:22:00Z")!)
    #expect(queue.workingCount == 0)
}

/// A tool output carrying an image, the way image generation and `view_image` write them: one line
/// well over the 1 MiB per-record bound.
private func oversizedToolOutput(at: String) -> String {
    let payload: [String: Any] = ["type": "custom_tool_call_output", "call_id": "image-1",
                                  "output": String(repeating: "A", count: 1_100_000)]
    let bytes = try! JSONSerialization.data(withJSONObject: ["timestamp": at, "type": "response_item", "payload": payload])
    return String(decoding: bytes, as: UTF8.self) + "\n"
}

@Test func anOversizedImageLineDoesNotHideHowTurnsEnded() {
    let session = UUID(), finished = UUID(), aborted = UUID()
    let data = Data((meta(session) + turnEvent("task_started", turn: finished, at: "2026-10-08T06:10:54.055Z")
        + oversizedToolOutput(at: "2026-10-08T06:11:36.197Z")
        + turnEvent("task_complete", turn: finished, at: "2026-10-08T06:11:40.285Z")
        + turnEvent("task_started", turn: aborted, at: "2026-10-08T06:16:10.015Z")
        + oversizedToolOutput(at: "2026-10-08T06:16:14.850Z")
        + turnEvent("turn_aborted", turn: aborted, at: "2026-10-08T06:16:19.218Z")).utf8)
    let evidence = ReminderReader.evidence(in: data, session: session)
    #expect(evidence.completed == [TurnIdentity(session: session, turn: finished)])
    #expect(evidence.canceled == [TurnIdentity(session: session, turn: aborted)])
}

@Test func aQuestionAskedBeforeASkippedLineIsNeitherPendingNorAnswered() {
    let session = UUID(), turn = UUID()
    // The skipped line may hold the answer, so call_1 is unknown: never offered for a relay.
    let data = Data((meta(session) + turnEvent("task_started", turn: turn, at: "2026-09-14T02:20:14.383Z")
        + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample)
        + oversizedToolOutput(at: "2026-09-14T02:21:00.000Z")
        + questionCall(turn: turn, call: "call_2", at: answeredAt, arguments: sample)).utf8)
    let evidence = ReminderReader.evidence(in: data, session: session)
    #expect(evidence.pendingQuestions.map(\.callID) == ["call_2"])
    #expect(evidence.answeredQuestions.isEmpty)
}

@Test func aLineOfExactlyTheBoundIsStillRead() {
    let session = UUID(), turn = UUID()
    // Pad a tool output so its whole line, without the newline, is exactly the bound.
    func output(padding: Int) -> String {
        let payload: [String: Any] = ["type": "custom_tool_call_output", "call_id": "image-1",
                                      "output": String(repeating: "A", count: padding)]
        let bytes = try! JSONSerialization.data(withJSONObject: ["timestamp": "2026-10-08T06:16:14.850Z", "type": "response_item", "payload": payload])
        return String(decoding: bytes, as: UTF8.self)
    }
    let line = output(padding: ReminderReader.maximumRecordSize - output(padding: 0).utf8.count)
    #expect(line.utf8.count == ReminderReader.maximumRecordSize)
    // A question before an exactly-bound line is still pending: nothing was skipped.
    let data = Data((meta(session) + turnEvent("task_started", turn: turn, at: "2026-09-14T02:20:14.383Z")
        + questionCall(turn: turn, call: "call_1", at: askedAt, arguments: sample) + line + "\n").utf8)
    #expect(ReminderReader.evidence(in: data, session: session).pendingQuestions.map(\.callID) == ["call_1"])
}

@Test func anOversizedFirstLineStillRejectsTheRollout() {
    let session = UUID(), turn = UUID()
    let data = Data((oversizedToolOutput(at: "2026-10-08T06:10:00.000Z")
        + turnEvent("turn_aborted", turn: turn, at: "2026-10-08T06:16:19.218Z")).utf8)
    #expect(ReminderReader.evidence(in: data, session: session) == ReminderReader.RolloutEvidence())
}

@Test func aCompactedRolloutDropsOversizedLinesWhileStreaming() throws {
    let session = UUID(), turn = UUID()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    // Three image outputs of 14 MiB each: 42 MiB on disk, more than a rollout may keep in memory.
    let image = oversizedToolOutput(at: "2026-10-08T06:16:14.850Z").replacingOccurrences(
        of: String(repeating: "A", count: 1_100_000), with: String(repeating: "A", count: 14 * 1024 * 1024))
    let text = meta(session) + turnEvent("task_started", turn: turn, at: "2026-10-08T06:16:10.015Z")
        + image + image + image + turnEvent("turn_aborted", turn: turn, at: "2026-10-08T06:16:19.218Z")
    try text.write(to: url, atomically: true, encoding: .utf8)
    let compacted = try #require(ReminderReader.compactedRollout(url))
    #expect(compacted.count < 4096)
    #expect(ReminderReader.evidence(in: compacted, session: session).canceled == [TurnIdentity(session: session, turn: turn)])

    // An image output still being written stays unfinished, so the rollout yields nothing this scan.
    let partial = meta(session) + turnEvent("task_started", turn: turn, at: "2026-10-08T06:16:10.015Z")
        + String(image.dropLast())
    try partial.write(to: url, atomically: true, encoding: .utf8)
    let unfinished = try #require(ReminderReader.compactedRollout(url))
    #expect(unfinished.last != 10)
    #expect(ReminderReader.evidence(in: unfinished, session: session) == ReminderReader.RolloutEvidence())
}
