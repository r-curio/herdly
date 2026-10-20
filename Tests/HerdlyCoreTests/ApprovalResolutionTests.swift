import Foundation
import Testing
@testable import HerdlyCore

// Fixture lines follow the shapes recorded from real Codex rollouts (CLI 0.145.0 and the desktop
// engine): a `custom_tool_call` named `exec`, its `custom_tool_call_output`, and `wait` follow-ups.

private func meta(_ session: UUID, source: String = "cli") -> String {
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"\(source)\"}}\n"
}

private func execCall(turn: UUID, call: String, command: String, at: String, jsKeys: Bool = false) -> String {
    let cmd = jsKeys ? "cmd:\\\"\(command)\\\"" : "\\\"cmd\\\":\\\"\(command)\\\""
    return "{\"timestamp\":\"\(at)\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"name\":\"exec\",\"call_id\":\"\(call)\",\"input\":\"const r = await tools.exec_command({\(cmd),\\\"sandbox_permissions\\\":\\\"require_escalated\\\"});\",\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"\(turn)\"}}}\n"
}

private func output(turn: UUID, call: String, kind: String, at: String, cell: Int = 1) -> String {
    let text: String
    switch kind {
    case "completed": text = "[{\"type\":\"input_text\",\"text\":\"Script completed\\nWall time 1.7 seconds\\nOutput:\\n\"},{\"type\":\"input_text\",\"text\":\"{\\\"chunk_id\\\":\\\"d11573\\\",\\\"exit_code\\\":0,\\\"output\\\":\\\"\\\"}\"}]"
    case "rejected": text = "[{\"type\":\"input_text\",\"text\":\"Script failed\\nWall time 0.0 seconds\\nOutput:\\n\"},{\"type\":\"input_text\",\"text\":\"Script error:\\nexec_command failed: CreateProcess { message: \\\"Rejected(\\\\\\\"rejected by user\\\\\\\")\\\" }\"}]"
    case "running": text = "\"Script running with cell ID \(cell)\\nWall time 31.0 seconds\\nOutput:\\n\""
    case "aborted": text = "\"aborted by user after 39.4s\""
    default: text = "\"Rejected( appears inside ordinary command output\""
    }
    return "{\"timestamp\":\"\(at)\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call_output\",\"call_id\":\"\(call)\",\"output\":\(text),\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"\(turn)\"}}}\n"
}

private func waitCall(turn: UUID, call: String, cell: Int, at: String) -> String {
    "{\"timestamp\":\"\(at)\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"wait\",\"arguments\":\"{\\\"cell_id\\\":\\\"\(cell)\\\",\\\"yield_time_ms\\\":1000}\",\"call_id\":\"\(call)\",\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"\(turn)\"}}}\n"
}

private func waitOutput(turn: UUID, call: String, kind: String, at: String) -> String {
    output(turn: turn, call: call, kind: kind, at: at).replacingOccurrences(of: "custom_tool_call_output", with: "function_call_output")
}

private func probe(_ id: UUID = UUID(), turn: UUID, command: String?, notBefore: Double) -> ApprovalResolutionProbe {
    ApprovalResolutionProbe(requestID: id, turn: turn, command: command, notBefore: notBefore)
}

private let t0 = RolloutTimestamp.parse("2026-09-12T04:23:07.000Z")!

@Test func rolloutTimestampsParseWithAndWithoutFractions() {
    #expect(RolloutTimestamp.parse("2026-09-12T04:23:07.201Z") == 1789186987.201)
    #expect(RolloutTimestamp.parse("2026-09-12T04:23:07Z") == 1789186987)
    #expect(RolloutTimestamp.parse("yesterday") == nil)
}

@Test func nativeDenyAfterYieldIsMatchedThroughTheCellFollowUp() {
    let session = UUID(), turn = UUID()
    let data = Data((meta(session, source: "vscode")
        + execCall(turn: turn, call: "c1", command: "touch MARKER", at: "2026-09-12T04:23:07.000Z", jsKeys: true)
        + output(turn: turn, call: "c1", kind: "running", at: "2026-09-12T04:23:38.000Z", cell: 2)
        + waitCall(turn: turn, call: "w1", cell: 2, at: "2026-09-12T04:23:40.000Z")
        + waitOutput(turn: turn, call: "w1", kind: "rejected", at: "2026-09-12T04:23:41.000Z")).utf8)
    let request = probe(turn: turn, command: "touch MARKER", notBefore: t0 + 0.3)
    let found = ApprovalResolutionReader.resolutions(in: data, session: session, probes: [request])
    #expect(found.map(\.requestID) == [request.requestID])
    #expect(found.first?.kind == .rejected)
    #expect(found.first?.callID == "w1")
    #expect(found.first?.observedAt == RolloutTimestamp.parse("2026-09-12T04:23:41.000Z"))
}

@Test func nativeAllowIsMatchedFromTheDirectOutput() {
    let session = UUID(), turn = UUID()
    let data = Data((meta(session)
        + execCall(turn: turn, call: "c1", command: "touch MARKER", at: "2026-09-12T04:23:07.000Z")
        + output(turn: turn, call: "c1", kind: "completed", at: "2026-09-12T04:23:08.900Z")).utf8)
    let found = ApprovalResolutionReader.resolutions(in: data, session: session,
                                                     probes: [probe(turn: turn, command: "touch MARKER", notBefore: t0 + 0.3)])
    #expect(found.first?.kind == .executed && found.first?.callID == "c1")
}

@Test func aStillRunningPromptAndAnEarlierIdenticalCommandAreNotResolutionEvidence() {
    let session = UUID(), turn = UUID()
    var text = meta(session)
        + execCall(turn: turn, call: "old", command: "touch MARKER", at: "2026-09-12T04:22:00.000Z")
        + output(turn: turn, call: "old", kind: "completed", at: "2026-09-12T04:22:01.000Z")
        + execCall(turn: turn, call: "c1", command: "touch MARKER", at: "2026-09-12T04:23:07.000Z")
        + output(turn: turn, call: "c1", kind: "running", at: "2026-09-12T04:23:38.000Z")
    let request = probe(turn: turn, command: "touch MARKER", notBefore: t0 + 0.3)
    #expect(ApprovalResolutionReader.resolutions(in: Data(text.utf8), session: session, probes: [request]).isEmpty)
    text += waitCall(turn: turn, call: "w1", cell: 1, at: "2026-09-12T04:23:40.000Z")
        + waitOutput(turn: turn, call: "w1", kind: "running", at: "2026-09-12T04:23:41.000Z")
    #expect(ApprovalResolutionReader.resolutions(in: Data(text.utf8), session: session, probes: [request]).isEmpty)
    text += waitCall(turn: turn, call: "w2", cell: 1, at: "2026-09-12T04:23:50.000Z")
        + waitOutput(turn: turn, call: "w2", kind: "completed", at: "2026-09-12T04:23:51.000Z")
    let found = ApprovalResolutionReader.resolutions(in: Data(text.utf8), session: session, probes: [request])
    #expect(found.first?.kind == .executed && found.first?.callID == "w2")
}

@Test func simultaneousRequestsResolveIndependentlyByCommandAndOrder() {
    let session = UUID(), turn = UUID()
    let a = probe(turn: turn, command: "touch A", notBefore: t0 + 0.2)
    let b = probe(turn: turn, command: "touch B", notBefore: t0 + 0.3)
    let twinFirst = probe(turn: turn, command: "touch TWIN", notBefore: t0 + 0.4)
    let twinSecond = probe(turn: turn, command: "touch TWIN", notBefore: t0 + 0.5)
    var text = meta(session)
        + execCall(turn: turn, call: "ca", command: "touch A", at: "2026-09-12T04:23:07.000Z")
        + execCall(turn: turn, call: "cb", command: "touch B", at: "2026-09-12T04:23:07.000Z")
        + execCall(turn: turn, call: "t1", command: "touch TWIN", at: "2026-09-12T04:23:07.000Z")
        + execCall(turn: turn, call: "t2", command: "touch TWIN", at: "2026-09-12T04:23:07.000Z")
        + output(turn: turn, call: "cb", kind: "rejected", at: "2026-09-12T04:23:20.000Z")
        + output(turn: turn, call: "t2", kind: "completed", at: "2026-09-12T04:23:21.000Z")
    var found = ApprovalResolutionReader.resolutions(in: Data(text.utf8), session: session, probes: [b, a, twinSecond, twinFirst])
    #expect(found.map(\.requestID) == [b.requestID, twinFirst.requestID])
    #expect(found.map(\.kind) == [.rejected, .executed])
    text += output(turn: turn, call: "ca", kind: "completed", at: "2026-09-12T04:23:30.000Z")
    // Every recorded request stays a probe on later scans, so one output keeps answering the same twin.
    found = ApprovalResolutionReader.resolutions(in: Data(text.utf8), session: session, probes: [a, b, twinSecond, twinFirst])
    #expect(Set(found.map(\.requestID)) == [a.requestID, b.requestID, twinFirst.requestID])
}

@Test func resolutionNeedsTurnCommandAndSessionIdentity() {
    let session = UUID(), turn = UUID()
    let text = meta(session)
        + execCall(turn: turn, call: "c1", command: "touch MARKER", at: "2026-09-12T04:23:07.000Z")
        + output(turn: turn, call: "c1", kind: "completed", at: "2026-09-12T04:23:08.900Z")
    let data = Data(text.utf8)
    #expect(ApprovalResolutionReader.resolutions(in: data, session: session,
                                                 probes: [probe(turn: UUID(), command: "touch MARKER", notBefore: 0)]).isEmpty)
    #expect(ApprovalResolutionReader.resolutions(in: data, session: session,
                                                 probes: [probe(turn: turn, command: "touch MARKERS", notBefore: 0)]).isEmpty)
    #expect(ApprovalResolutionReader.resolutions(in: data, session: session,
                                                 probes: [probe(turn: turn, command: nil, notBefore: 0)]).isEmpty)
    #expect(ApprovalResolutionReader.resolutions(in: data, session: UUID(),
                                                 probes: [probe(turn: turn, command: "touch MARKER", notBefore: 0)]).isEmpty)
    let noTurn = text.replacingOccurrences(of: "\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"\(turn)\"}", with: "\"x\":1")
    #expect(ApprovalResolutionReader.resolutions(in: Data(noTurn.utf8), session: session,
                                                 probes: [probe(turn: turn, command: "touch MARKER", notBefore: 0)]).isEmpty)
}

@Test func malformedAndPartialLinesAreSkippedAndUnrecognizedWrappersAreNotEvidence() {
    let session = UUID(), turn = UUID()
    let text = meta(session)
        + "{not json\n"
        + execCall(turn: turn, call: "c1", command: "cat notes", at: "2026-09-12T04:23:07.000Z")
        + output(turn: turn, call: "c1", kind: "weird", at: "2026-09-12T04:23:09.000Z")
        + execCall(turn: turn, call: "c2", command: "touch LATER", at: "2026-09-12T04:23:10.000Z")
        + String(output(turn: turn, call: "c2", kind: "completed", at: "2026-09-12T04:23:11.000Z").dropLast(20))
    let found = ApprovalResolutionReader.resolutions(in: Data(text.utf8), session: session, probes: [
        probe(turn: turn, command: "cat notes", notBefore: t0),
        probe(turn: turn, command: "touch LATER", notBefore: t0)
    ])
    #expect(found.isEmpty) // arbitrary output text is never evidence; the partial line is ignored
    let failed = output(turn: turn, call: "c1", kind: "rejected", at: "2026-09-12T04:23:09.000Z")
        .replacingOccurrences(of: "Rejected(", with: "Other(")
    let unclassified = ApprovalResolutionReader.resolutions(in: Data((meta(session) + execCall(turn: turn, call: "c1", command: "cat notes", at: "2026-09-12T04:23:07.000Z") + failed).utf8),
                                                            session: session, probes: [probe(turn: turn, command: "cat notes", notBefore: t0)])
    #expect(unclassified.first?.kind == .unclassified) // a runtime failure wrapper without a rejection
}

@Test func interruptedOutputCountsAsResolution() {
    let session = UUID(), turn = UUID()
    let text = meta(session)
        + execCall(turn: turn, call: "c1", command: "touch MARKER", at: "2026-09-12T04:23:07.000Z")
        + output(turn: turn, call: "c1", kind: "aborted", at: "2026-09-12T04:23:50.000Z")
    let found = ApprovalResolutionReader.resolutions(in: Data(text.utf8), session: session,
                                                     probes: [probe(turn: turn, command: "touch MARKER", notBefore: t0)])
    #expect(found.first?.kind == .interrupted)
}

@Test func oneExecScriptWithSeveralCommandsResolvesEachRequestSeparately() {
    let session = UUID(), turn = UUID()
    let script = "const calls = [{cmd: \\\"touch A\\\", sandbox_permissions: \\\"require_escalated\\\"}, {cmd: \\\"touch B\\\"}];"
    let call = "{\"timestamp\":\"2026-09-12T04:23:07.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"name\":\"exec\",\"call_id\":\"multi\",\"input\":\"\(script)\",\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"\(turn)\"}}}\n"
    let a = probe(turn: turn, command: "touch A", notBefore: t0 + 0.2)
    let b = probe(turn: turn, command: "touch B", notBefore: t0 + 0.3)
    let pending = Data((meta(session) + call).utf8)
    #expect(ApprovalResolutionReader.resolutions(in: pending, session: session, probes: [a, b]).isEmpty)
    let finished = Data((meta(session) + call + output(turn: turn, call: "multi", kind: "aborted", at: "2026-09-12T04:24:30.000Z")).utf8)
    let found = ApprovalResolutionReader.resolutions(in: finished, session: session, probes: [a, b])
    #expect(Set(found.map(\.requestID)) == [a.requestID, b.requestID])
    #expect(found.allSatisfy { $0.kind == .interrupted && $0.callID == "multi" })
}

@Test func identicalCommandsInOneScriptEachAnswerOneRequest() {
    let session = UUID(), turn = UUID()
    let script = "await tools.exec_command({cmd: \\\"touch TWIN\\\"}); await tools.exec_command({cmd: \\\"touch TWIN\\\"});"
    let call = "{\"timestamp\":\"2026-09-12T04:23:07.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"name\":\"exec\",\"call_id\":\"multi\",\"input\":\"\(script)\",\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"\(turn)\"}}}\n"
    let first = probe(turn: turn, command: "touch TWIN", notBefore: t0 + 0.2)
    let second = probe(turn: turn, command: "touch TWIN", notBefore: t0 + 0.3)
    let third = probe(turn: turn, command: "touch TWIN", notBefore: t0 + 0.4)
    let data = Data((meta(session) + call + output(turn: turn, call: "multi", kind: "completed", at: "2026-09-12T04:24:30.000Z")).utf8)
    let found = ApprovalResolutionReader.resolutions(in: data, session: session, probes: [third, second, first])
    #expect(Set(found.map(\.requestID)) == [first.requestID, second.requestID]) // two slots, three requests
}

@Test func abandonedRequestArrivesAtItsFileTimeNotAtZero() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                  receivedAt: 0, expiresAt: 0, outcome: .noDecision)
    #expect(ApprovalStore.publish(request, in: root))
    let scan = ReminderReader.scan(events: root, rollouts: root)
    let arrived = try #require(scan.attentionRequests.first?.arrivedAt)
    #expect(abs(arrived - Date().timeIntervalSince1970) < 60)
    var ended = scan
    ended.sessionEnds = [request.sessionID: arrived - 3600] // an old SessionEnd for a resumed session
    var queue = AttentionQueue()
    queue.apply(scan: ended, desktopEvents: [], now: arrived + 1)
    #expect(queue.items.count == 1)
}

@Test func legacyFunctionCallShapeIsMatchedByCommandArguments() {
    let session = UUID(), turn = UUID()
    let call = "{\"timestamp\":\"2026-09-12T04:23:07.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"name\":\"exec_command\",\"arguments\":\"{\\\"cmd\\\":\\\"touch MARKER\\\",\\\"workdir\\\":\\\"/tmp\\\"}\",\"call_id\":\"f1\",\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"\(turn)\"}}}\n"
    let out = "{\"timestamp\":\"2026-09-12T04:23:09.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"f1\",\"output\":\"exec_command failed for `/bin/zsh -lc 'touch MARKER'`: CreateProcess { message: \\\"Rejected(\\\\\\\"rejected by user\\\\\\\")\\\" }\",\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"\(turn)\"}}}\n"
    let found = ApprovalResolutionReader.resolutions(in: Data((meta(session) + call + out).utf8), session: session,
                                                     probes: [probe(turn: turn, command: "touch MARKER", notBefore: t0)])
    #expect(found.first?.kind == .rejected && found.first?.callID == "f1")
}

// MARK: - Reader and queue integration

private func handedBackRequest(session: UUID, turn: UUID, command: String, at: Double) throws -> (ApprovalRequest, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let request = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: turn,
                                  details: ApprovalDetails(command: command), receivedAt: at, outcome: .noDecision)
    #expect(ApprovalStore.publish(request, in: root))
    return (request, root)
}

@Test func scanReportsNativeResolutionAndTheQueueClearsOnlyThatRequest() throws {
    let session = UUID(), turn = UUID()
    let (request, root) = try handedBackRequest(session: session, turn: turn, command: "touch MARKER", at: t0 + 0.3)
    defer { try? FileManager.default.removeItem(at: root) }
    let other = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: turn,
                                details: ApprovalDetails(command: "touch OTHER"), receivedAt: t0 + 0.4, outcome: .noDecision)
    #expect(ApprovalStore.publish(other, in: root))
    let rollout = root.appendingPathComponent("rollout-\(session.uuidString.lowercased()).jsonl")
    try Data((meta(session)
        + execCall(turn: turn, call: "c1", command: "touch MARKER", at: "2026-09-12T04:23:07.000Z")
        + execCall(turn: turn, call: "c2", command: "touch OTHER", at: "2026-09-12T04:23:07.000Z")
        + output(turn: turn, call: "c1", kind: "rejected", at: "2026-09-12T04:23:20.000Z")).utf8).write(to: rollout)
    let completion = AttentionCompletion(source: .cli, session: UUID(), turn: UUID(), arrivedAt: 1)
    var queue = AttentionQueue()
    queue.apply(completions: [completion])
    let scan = ReminderReader.scan(events: root, rollouts: root)
    #expect(scan.resolvedRequests.map(\.requestID) == [request.id])
    #expect(scan.resolvedRequests.first?.kind == .rejected)
    queue.apply(scan: scan, desktopEvents: [], now: t0 + 60)
    #expect(queue.items.compactMap(\.request).map(\.id) == [other.id])
    #expect(queue.items.contains { $0.id == .completion(completion.id) })
    var stale = ReminderScan()
    stale.attentionRequests = scan.attentionRequests
    queue.apply(scan: stale, desktopEvents: [], now: t0 + 61) // a scan that lost the rollout cannot resurrect it
    #expect(queue.items.compactMap(\.request).map(\.id) == [other.id])
}

@Test func sessionEndAfterArrivalResolvesTheRequestButAnEarlierEndDoesNot() {
    let session = UUID()
    let early = AttentionRequest(id: UUID(), source: .cli, session: session, turn: UUID(), arrivedAt: 100, state: .handedBack)
    let late = AttentionRequest(id: UUID(), source: .cli, session: session, turn: UUID(), arrivedAt: 300, state: .handedBack)
    var scan = ReminderScan()
    scan.attentionRequests = [early, late]
    scan.sessionEnds = [session: 200]
    var queue = AttentionQueue()
    queue.apply(scan: scan, desktopEvents: [], now: 400)
    #expect(queue.items.compactMap(\.request).map(\.id) == [late.id])
}

@Test func readerReportsSessionEndTimesFromHookRecords() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID()
    let end: [String: String] = ["session_id": session.uuidString, "hook_event_name": "SessionEnd",
                                 "received_at": "2026-09-12T04:23:41.000Z"]
    try JSONSerialization.data(withJSONObject: end).write(to: root.appendingPathComponent("end.json"))
    let scan = ReminderReader.scan(events: root, rollouts: root)
    #expect(scan.sessionEnds[session] == RolloutTimestamp.parse("2026-09-12T04:23:41.000Z"))
}

@Test func regainedFocusKnowledgeNeverReactivatesAHandedBackRequest() {
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 100, state: .actionable)
    var queue = AttentionQueue()
    queue.apply(requests: [request], now: 101)
    let handedBack = AttentionRequest(id: request.id, source: .cli, session: request.session, turn: request.turn,
                                      arrivedAt: 100, state: .handedBack)
    queue.apply(requests: [handedBack], now: 102)
    queue.apply(requests: [request], now: 103) // a later scan still sees pending + receipt
    #expect(queue.items.first?.kind == .handedBackRequest)
}

@Test func savedDecisionRecordsRevalidateRequestsOnRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date().timeIntervalSince1970
    let handedBack = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                     receivedAt: 0, expiresAt: 0, outcome: .pending)
    let answered = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                   receivedAt: 0, expiresAt: 0, outcome: .pending)
    for request in [handedBack, answered] {
        #expect(ApprovalStore.publish(request, in: root))
        #expect(ApprovalStore.publish(ApprovalReceiptRecord(requestID: request.id, receivedAt: now), in: root))
    }
    #expect(ApprovalStore.publish(ApprovalDecisionRecord(requestID: handedBack.id, decision: .noDecision, decidedAt: now), in: root))
    #expect(ApprovalStore.publish(ApprovalDecisionRecord(requestID: answered.id, decision: .allowOnce, decidedAt: now), in: root))
    let scan = ReminderReader.scan(events: root, rollouts: root)
    #expect(scan.attentionRequests.map(\.id) == [handedBack.id])
    #expect(scan.attentionRequests.first?.state == .handedBack)
    #expect(scan.awaitingReceipt.isEmpty)
    // A helper that already handed back (companion gone) outranks a late allow record for its request.
    let abandoned = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                    receivedAt: now, expiresAt: now + 30, outcome: .noDecision)
    #expect(ApprovalStore.publish(abandoned, in: root))
    #expect(ApprovalStore.publish(ApprovalDecisionRecord(requestID: abandoned.id, decision: .allowOnce, decidedAt: now + 40), in: root))
    let again = ReminderReader.scan(events: root, rollouts: root)
    #expect(again.attentionRequests.first { $0.id == abandoned.id }?.state == .handedBack)
}

@Test func decisionPolicyAcceptsOnlyLiveActionableCLIRequests() {
    let live = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 100)
    #expect(ApprovalDecisionPolicy.accepts(live, decision: .allowOnce, now: 129))
    #expect(!ApprovalDecisionPolicy.accepts(live, decision: .allowOnce, now: 130))
    #expect(!ApprovalDecisionPolicy.accepts(live, decision: .noDecision, now: 101))
    let handedBack = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 100, state: .handedBack)
    #expect(!ApprovalDecisionPolicy.accepts(handedBack, decision: .deny, now: 101))
    let desktop = AttentionRequest(id: UUID(), source: .desktop, session: UUID(), turn: UUID(), arrivedAt: 100)
    #expect(!ApprovalDecisionPolicy.accepts(desktop, decision: .deny, now: 101))
}

@Test func aLateDecisionForAnOlderRequestNeverAnswersANewerOne() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID()
    let older = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: UUID(), details: ApprovalDetails(), receivedAt: 100)
    let newer = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: UUID(), details: ApprovalDetails(), receivedAt: 150)
    #expect(ApprovalStore.publish(ApprovalDecisionRecord(requestID: older.id, decision: .noDecision, decidedAt: 130), in: root))
    #expect(!ApprovalStore.publish(ApprovalDecisionRecord(requestID: older.id, decision: .allowOnce, decidedAt: 131), in: root))
    #expect(ApprovalHelper.awaitDecision(for: newer, in: root, handoffTimeout: 0.1, waitBound: 0.2) == .noDecision)
    #expect(!FileManager.default.fileExists(atPath: ApprovalStore.decisionURL(in: root, id: newer.id).path))
}
