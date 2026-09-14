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

private func questionOutput(turn: UUID, call: String, at: String, answer: String = "Flexible paths (Recommended)") -> String {
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
    ("Nested choices", "Should different variant paths support different levels of choices?",
     ["Flexible paths (Recommended)", "Same levels throughout"]),
    ("First release", "Should the first release also support checkout?", ["Stock lookup only (Recommended)", "Include checkout"])
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
    #expect(question?.prompts[0] == QuestionPrompt(id: "nested choices", header: "Nested choices",
                                                   question: "Should different variant paths support different levels of choices?",
                                                   options: ["Flexible paths (Recommended)", "Same levels throughout"]))
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
    #expect(before.pendingQuestions.first?.prompts.first?.header == "Nested choices")
    #expect(before.pendingQuestions.first?.prompts.first?.options == ["Flexible paths (Recommended)", "Same levels throughout"])
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
