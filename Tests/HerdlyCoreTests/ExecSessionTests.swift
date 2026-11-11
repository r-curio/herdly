import Foundation
import Testing
@testable import HerdlyCore

// #409: a headless `codex exec` run fires the global hook too, so its records reached the queue as
// rows with nothing to open. Shapes follow the run recorded on 2026-11-11 (CLI 0.164.0): the
// rollout's `session_meta` carries `"source":"exec"`, `"originator":"codex_exec"`, and the hook
// records are the ordinary `herdly-hook-v1` ones (SessionStart, UserPromptSubmit, PreToolUse,
// PostToolUse, Stop, SessionEnd) keyed by `session_id`.

private struct Lab {
    let root: URL
    var events: URL { root.appendingPathComponent("events", isDirectory: true) }
    var rollouts: URL { root.appendingPathComponent("sessions", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-exec-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/2026/11/11"),
                                                withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func rolloutURL(_ session: UUID) -> URL {
        rollouts.appendingPathComponent("2026/11/11/rollout-2026-11-11T12-12-13-\(session.uuidString.lowercased()).jsonl")
    }

    @discardableResult
    func writeRollout(_ session: UUID, header: String?, lines: String = "") throws -> URL {
        let url = rolloutURL(session)
        try Data(((header.map { $0 + "\n" } ?? "") + lines).utf8).write(to: url)
        return url
    }

    /// One turn's hook records: start, prompt, a tool call, and (when `stopped`) its Stop.
    func writeTurn(_ session: UUID, turn: UUID, stopped: Bool) throws {
        let common: [String: Any] = ["session_id": session.uuidString.lowercased(), "source": "herdly-hook-v1",
                                     "herdr_pane_id": "w3:p43"]
        var records: [[String: Any]] = [
            ["hook_event_name": "SessionStart", "received_at": "2026-11-11T04:12:14Z", "captured_at": 1_794_370_334.0],
            ["hook_event_name": "UserPromptSubmit", "received_at": "2026-11-11T04:12:15Z", "captured_at": 1_794_370_335.0,
             "turn_id": turn.uuidString.lowercased(), "prompt": "Summarise the feedback pack."],
            ["hook_event_name": "PreToolUse", "received_at": "2026-11-11T04:14:03Z", "captured_at": 1_794_370_443.0,
             "turn_id": turn.uuidString.lowercased(), "tool_name": "Bash", "tool_use_id": "exec-1",
             "tool_input": ["command": "ls packs"]],
            ["hook_event_name": "PostToolUse", "received_at": "2026-11-11T04:14:04Z", "captured_at": 1_794_370_444.0,
             "turn_id": turn.uuidString.lowercased(), "tool_name": "Bash", "tool_use_id": "exec-1"]
        ]
        if stopped {
            records.append(["hook_event_name": "Stop", "received_at": "2026-11-11T04:19:08Z", "captured_at": 1_794_370_748.0,
                            "turn_id": turn.uuidString.lowercased()])
        }
        for (index, record) in records.enumerated() {
            try JSONSerialization.data(withJSONObject: record.merging(common) { own, _ in own })
                .write(to: events.appendingPathComponent("\(session.uuidString.lowercased())-\(index).json"))
        }
    }

    func scan(cache: RolloutCache = RolloutCache()) -> ReminderScan {
        ReminderReader.scan(events: events, rollouts: rollouts, rolloutCache: cache)
    }

    /// The queue as the app builds it from one scan.
    func queue(_ scan: ReminderScan, into queue: AttentionQueue = AttentionQueue(observingSince: 0)) -> AttentionQueue {
        var queue = queue
        queue.apply(scan: scan, desktopEvents: DesktopEventReader.read(from: events), now: 1_794_370_800)
        queue.apply(questions: scan.questions)
        return queue
    }
}

private func header(_ session: UUID, source: String, originator: String) -> String {
    "{\"timestamp\":\"2026-11-11T04:12:14.356Z\",\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"session_id\":\"\(session.uuidString.lowercased())\",\"id\":\"\(session.uuidString.lowercased())\",\"timestamp\":\"2026-11-11T04:12:13.980Z\",\"cwd\":\"/tmp/feedback-2026-11\",\"originator\":\"\(originator)\",\"cli_version\":\"0.164.0\",\"source\":\"\(source)\",\"thread_source\":\"user\"}}"
}

private func execHeader(_ session: UUID) -> String { header(session, source: "exec", originator: "codex_exec") }

private func turnEvent(_ kind: String, _ turn: UUID, at: String) -> String {
    "{\"timestamp\":\"\(at)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"\(turn.uuidString.lowercased())\"}}\n"
}

private func questionCall(_ turn: UUID, call: String) throws -> String {
    let arguments = "{\"questions\":[{\"id\":\"scope\",\"header\":\"Scope\",\"question\":\"Which pack?\",\"options\":[{\"label\":\"All\",\"description\":\"Every pack.\"}]}]}"
    let payload: [String: Any] = ["type": "function_call", "name": "request_user_input", "arguments": arguments, "id": "fc_1",
                                  "call_id": call,
                                  "internal_chat_message_metadata_passthrough": ["turn_id": turn.uuidString.lowercased()]]
    let bytes = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-11-11T04:13:00.000Z", "type": "response_item",
                                                             "payload": payload])
    return String(decoding: bytes, as: UTF8.self) + "\n"
}

/// Rewrites `url` in place with `text` of the same length and restores its stamp, so only a reader
/// that reuses its memo still sees the old contents.
private func overwriteKeepingStamp(_ url: URL, with text: String) throws {
    var info = stat()
    #expect(stat(url.path, &info) == 0)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
    var times = [info.st_atimespec, info.st_mtimespec]
    #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
}

@Test func anExecRunsWorkingTurnProducesNoRow() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let session = UUID(), turn = UUID()
    try lab.writeTurn(session, turn: turn, stopped: false)
    try lab.writeRollout(session, header: execHeader(session), lines: turnEvent("task_started", turn, at: "2026-11-11T04:12:15.000Z"))

    let scan = lab.scan()
    #expect(scan.execSessions == [session])
    #expect(scan.cliSessions.isEmpty)
    let queue = lab.queue(scan)
    #expect(queue.items.isEmpty)
    #expect(queue.workingCount == 0)
    #expect(queue.toCheckCount == 0)
}

@Test func anExecRunsFinishedTurnProducesNoCompletion() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let session = UUID(), turn = UUID()
    try lab.writeTurn(session, turn: turn, stopped: true)
    try lab.writeRollout(session, header: execHeader(session),
                         lines: turnEvent("task_started", turn, at: "2026-11-11T04:12:15.000Z")
                            + turnEvent("task_complete", turn, at: "2026-11-11T04:19:08.000Z"))

    let scan = lab.scan()
    #expect(scan.execSessions == [session])
    let queue = lab.queue(scan)
    #expect(queue.items.isEmpty)
    #expect(queue.toCheckCount == 0)
}

@Test func anExecRunsPendingQuestionProducesNoRow() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let session = UUID(), turn = UUID()
    try lab.writeTurn(session, turn: turn, stopped: false)
    try lab.writeRollout(session, header: execHeader(session),
                         lines: turnEvent("task_started", turn, at: "2026-11-11T04:12:15.000Z") + (try questionCall(turn, call: "call_1")))

    let scan = lab.scan()
    #expect(scan.questions.isEmpty)
    #expect(lab.queue(scan).items.isEmpty)
}

@Test func anExecRunsHandedBackAndAwaitingApprovalsProduceNoRowAndNoReceipt() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let session = UUID(), turn = UUID()
    try lab.writeTurn(session, turn: turn, stopped: false)
    try lab.writeRollout(session, header: execHeader(session))
    let handedBack = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: turn,
                                     details: ApprovalDetails(command: "rm -rf build"),
                                     receivedAt: 1_794_370_400, expiresAt: 1_794_370_430, outcome: .noDecision)
    // Freshly published, not yet receipted: the helper is still within its connection timeout.
    let awaiting = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: turn,
                                   details: ApprovalDetails(command: "touch MARKER"), receivedAt: 0, outcome: .pending)
    #expect(ApprovalStore.publish(handedBack, in: lab.events))
    #expect(ApprovalStore.publish(awaiting, in: lab.events))

    let scan = lab.scan()
    #expect(scan.execSessions == [session])
    #expect(scan.attentionRequests.isEmpty)
    #expect(scan.reminders.isEmpty)
    // No receipt is issued, so the helper hands back with no decision after its connection timeout.
    #expect(scan.awaitingReceipt.isEmpty)
    #expect(lab.queue(scan).items.isEmpty)
}

@Test func anAwaitingApprovalWhoseOnlyEvidenceIsTheRequestIsStillRecognisedAsExec() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let session = UUID(), turn = UUID()
    try lab.writeRollout(session, header: execHeader(session))
    let awaiting = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: turn,
                                   details: ApprovalDetails(command: "touch MARKER"), receivedAt: 0, outcome: .pending)
    #expect(ApprovalStore.publish(awaiting, in: lab.events))

    let scan = lab.scan()
    #expect(scan.execSessions == [session])
    #expect(scan.awaitingReceipt.isEmpty)
}

@Test func aReceiptedLiveApprovalInAnExecRunStaysVisibleAndIsHandedBack() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let session = UUID(), turn = UUID()
    try lab.writeTurn(session, turn: turn, stopped: false)
    try lab.writeRollout(session, header: execHeader(session))
    // Receipted by an earlier launch: its helper waits on the user until the deadline.
    // A receipted request is actionable by its receipt alone; the reader checks no clock for it.
    let now = 1_794_370_800.0
    let live = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: turn,
                               details: ApprovalDetails(command: "git push"), receivedAt: now, expiresAt: now + 30,
                               outcome: .pending)
    #expect(ApprovalStore.publish(live, in: lab.events))
    #expect(ApprovalStore.publish(ApprovalReceiptRecord(requestID: live.id, receivedAt: now), in: lab.events))

    let scan = lab.scan()
    #expect(scan.execSessions == [session])
    #expect(scan.attentionRequests.map(\.id) == [live.id])
    var queue = AttentionQueue(observingSince: 0)
    let released = queue.apply(scan: scan, desktopEvents: DesktopEventReader.read(from: lab.events), now: now)
    // Not receipted by this launch: it is handed back, never decided, and released to Codex.
    #expect(released.map(\.id) == [live.id])
    #expect(queue.items.map(\.kind) == [.handedBackRequest])
}

@Test func cliAndDesktopHookSessionsAreUnchanged() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let desktop = UUID(), cli = UUID(), turn = UUID(), cliTurn = UUID()
    try lab.writeTurn(desktop, turn: turn, stopped: true)
    try lab.writeRollout(desktop, header: header(desktop, source: "vscode", originator: "Codex Desktop"),
                         lines: turnEvent("task_started", turn, at: "2026-11-11T04:12:15.000Z")
                            + turnEvent("task_complete", turn, at: "2026-11-11T04:19:08.000Z"))
    try lab.writeTurn(cli, turn: cliTurn, stopped: true)
    try lab.writeRollout(cli, header: header(cli, source: "cli", originator: "codex_cli_rs"),
                         lines: turnEvent("task_started", cliTurn, at: "2026-11-11T04:12:15.000Z")
                            + turnEvent("task_complete", cliTurn, at: "2026-11-11T04:19:08.000Z"))

    let scan = lab.scan()
    #expect(scan.execSessions.isEmpty)
    #expect(scan.cliSessions == [cli])
    let completions = Set(lab.queue(scan).items.compactMap(\.completion).map { "\($0.source)-\($0.session)" })
    #expect(completions == ["desktop-\(desktop)", "cli-\(cli)"])
}

@Test func anUnknownRolloutLeavesTheSessionShown() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let missing = UUID(), malformed = UUID(), headerless = UUID(), other = UUID()
    for session in [missing, malformed, headerless, other] { try lab.writeTurn(session, turn: UUID(), stopped: false) }
    try lab.writeRollout(malformed, header: "{\"type\":\"session_meta\",\"payload\":{\"id\":")
    try lab.writeRollout(headerless, header: nil, lines: turnEvent("task_started", UUID(), at: "2026-11-11T04:12:15.000Z"))
    // An `exec` header naming another session is not this session's header.
    try lab.writeRollout(other, header: execHeader(UUID()))

    let scan = lab.scan()
    #expect(scan.execSessions.isEmpty)
    let running = Set(lab.queue(scan).items.compactMap(\.running).map(\.session))
    #expect(running == [missing, malformed, headerless, other])
}

@Test func aSubagentRolloutKeepsItsExistingTreatment() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let session = UUID(), turn = UUID()
    try lab.writeTurn(session, turn: turn, stopped: false)
    let subagent = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session.uuidString.lowercased())\",\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(UUID().uuidString.lowercased())\",\"depth\":1}}}}}"
    try lab.writeRollout(session, header: subagent)

    let scan = lab.scan()
    #expect(scan.execSessions.isEmpty)
    #expect(lab.queue(scan).items.compactMap(\.running).map(\.session) == [session])
}

@Test func rowsAlreadyHeldForAnExecRunAreDroppedOnceItsRolloutReadsExec() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let session = UUID(), turn = UUID()
    try lab.writeTurn(session, turn: turn, stopped: true)
    // Before the rollout is readable the session is unknown, so its completion is shown.
    let before = lab.queue(lab.scan())
    #expect(before.items.compactMap(\.completion).map(\.session) == [session])

    try lab.writeRollout(session, header: execHeader(session),
                         lines: turnEvent("task_complete", turn, at: "2026-11-11T04:19:08.000Z"))
    let after = lab.queue(lab.scan(), into: before)
    #expect(after.items.isEmpty)
    // Dropped, not acknowledged: acknowledgment needs the user's dismissal or source evidence.
    #expect(after.acknowledgedCompletions.isEmpty)
}

@Test func theExecHeaderIsReadOnceAndReusedWhileTheRolloutIsUnchanged() throws {
    let lab = try Lab()
    defer { lab.remove() }
    let session = UUID(), turn = UUID()
    try lab.writeTurn(session, turn: turn, stopped: false)
    let header = execHeader(session)
    let url = try lab.writeRollout(session, header: header)

    let first = lab.scan()
    #expect(first.execSessions == [session])
    #expect(first.rolloutCache.count == 1)

    // Same stamp, now a CLI header: the memo stands, so the file was not reread.
    let cliHeader = header.replacingOccurrences(of: "\"source\":\"exec\"", with: "\"source\":\"cli\" ")
    #expect(cliHeader.utf8.count == header.utf8.count)
    try overwriteKeepingStamp(url, with: cliHeader + "\n")
    let reused = lab.scan(cache: first.rolloutCache)
    #expect(reused.execSessions == [session])
    #expect(reused.rolloutCache.count == 1)
    // Without the memo the new bytes are read and the session is no longer exec.
    #expect(lab.scan().execSessions.isEmpty)
}
