import Foundation
import Testing
@testable import SteerCore

@Test func attentionQueuePrioritizesDeduplicatesAndKeepsSessionsIndependent() {
    let firstSession = UUID(), secondSession = UUID()
    let firstTurn = UUID(), secondTurn = UUID()
    let request = AttentionRequest(id: UUID(), session: firstSession, turn: firstTurn, arrivedAt: 10, handoffAfter: 30)
    let completion = AttentionCompletion(source: .cli, session: secondSession, turn: secondTurn, arrivedAt: 5)
    let running = AttentionRunning(source: .desktop, session: firstSession, turn: UUID(), arrivedAt: 1)
    var queue = AttentionQueue()

    queue.apply(requests: [request, request], completions: [completion, completion], running: [running, running], now: 10)

    #expect(queue.workingCount == 1)
    #expect(queue.toCheckCount == 2)
    #expect(queue.items.map(\.id) == [.request(request.identity), .completion(completion.id), .running(running.id)])
    #expect(queue.items(viewing: firstSession).map(\.session) == [secondSession])
}

@Test func expiredRequestMovesOnceWithoutChangingArrivalOrIdentity() {
    let request = AttentionRequest(id: UUID(), session: UUID(), turn: UUID(), arrivedAt: 10, handoffAfter: 30)
    var queue = AttentionQueue()
    queue.apply(requests: [request], now: 20)
    #expect(queue.items.first?.kind == .actionableRequest)

    queue.expire(at: 40)
    queue.expire(at: 80)
    #expect(queue.items.count == 1)
    guard queue.items[0].kind == .handedBackRequest, let value = queue.items[0].request else {
        Issue.record("request did not move to handed-back state")
        return
    }
    #expect(value.id == request.id)
    #expect(value.arrivedAt == request.arrivedAt)
    #expect(queue.toCheckCount == 1)
}

@Test func completionResolvesMatchingRequestAndRejectsStaleRunningEvent() {
    let session = UUID(), turn = UUID()
    let request = AttentionRequest(id: UUID(), session: session, turn: turn, arrivedAt: 1, state: .handedBack)
    let completion = AttentionCompletion(source: .desktop, session: session, turn: turn, arrivedAt: 3)
    let running = AttentionRunning(source: .desktop, session: session, turn: turn, arrivedAt: 2)
    var queue = AttentionQueue()
    queue.apply(requests: [request], running: [running])
    queue.apply(completions: [completion], running: [running])
    #expect(queue.items.map(\.id) == [.completion(completion.id)])
    #expect(queue.workingCount == 0)
    #expect(queue.toCheckCount == 1)
}

@Test func dismissingOneCompletionKeepsALaterTurnInTheSameSession() {
    let session = UUID()
    let first = AttentionCompletion(source: .desktop, session: session, turn: UUID(), arrivedAt: 1)
    let later = AttentionCompletion(source: .desktop, session: session, turn: UUID(), arrivedAt: 2)
    var queue = AttentionQueue()
    queue.apply(completions: [first, later, first])
    queue.dismiss(.completion(first.id))
    queue.apply(completions: [first, later])
    #expect(queue.items.map(\.id) == [.completion(later.id)])
}

@Test func resolutionIsQualifiedBySource() {
    let session = UUID(), turn = UUID()
    let requestID = UUID()
    let cliRequest = AttentionRequest(id: requestID, source: .cli, session: session, turn: turn,
                                      arrivedAt: 1, state: .handedBack)
    let desktopRequest = AttentionRequest(id: requestID, source: .desktop, session: session, turn: turn,
                                          arrivedAt: 1, state: .handedBack)
    let desktopCompletion = AttentionCompletion(source: .desktop, session: session, turn: turn, arrivedAt: 2)
    var queue = AttentionQueue()
    queue.apply(requests: [cliRequest, desktopRequest], completions: [desktopCompletion])
    #expect(queue.items.contains { $0.id == .request(cliRequest.identity) })
    #expect(queue.items.contains { $0.id == .completion(desktopCompletion.id) })
}

@Test func scanPathExpiresActionableReceiptWithoutResettingIt() {
    let request = AttentionRequest(id: UUID(), session: UUID(), turn: UUID(), arrivedAt: 100, handoffAfter: 30)
    var scan = ReminderScan()
    scan.attentionRequests = [request]
    var queue = AttentionQueue()
    queue.recordReceipts([request], now: 100)
    queue.apply(scan: scan, desktopEvents: [], now: 110)
    #expect(queue.items.first?.kind == .actionableRequest)

    queue.apply(scan: scan, desktopEvents: [], now: 129)
    #expect(queue.items.first?.kind == .actionableRequest)
    queue.apply(scan: scan, desktopEvents: [], now: 130.1)
    #expect(queue.items.first?.kind == .handedBackRequest)
    #expect(queue.items.first?.id == .request(request.identity))
    #expect(queue.items.first?.arrivedAt == request.arrivedAt)
}

@Test func readerReportsPendingReceiptButOnlyALiveReceiptKeepsItActionable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let item = Reminder(request_id: UUID(), session_id: UUID(), turn_id: UUID(), outcome: "pending",
                        received_at: "1970-01-01T00:01:40Z", captured_at: 100)
    try JSONEncoder().encode(item).write(to: root.appendingPathComponent("request.approval"))
    let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(item.session_id)\",\"source\":\"cli\"}}\n"
    try Data(meta.utf8).write(to: root.appendingPathComponent("rollout-\(item.session_id.uuidString.lowercased()).jsonl"))
    let scan = ReminderReader.scan(events: root, rollouts: root)
    #expect(scan.attentionRequests.count == 1)
    #expect(scan.attentionRequests.first?.source == .cli)
    #expect(scan.attentionRequests.first?.state == .actionable)
    // Found on disk after a restart: no receipt from this process, so no controls.
    var restarted = AttentionQueue()
    restarted.apply(scan: scan, desktopEvents: [], now: 129)
    #expect(restarted.items.first?.kind == .handedBackRequest)
    // The same request receipted by this process keeps its controls until its own deadline.
    var queue = AttentionQueue()
    queue.recordReceipts(scan.attentionRequests, now: 100)
    queue.apply(scan: scan, desktopEvents: [], now: 129)
    #expect(queue.items.first?.kind == .actionableRequest)
    queue.apply(scan: scan, desktopEvents: [], now: 131)
    #expect(queue.items.first?.kind == .handedBackRequest)
}

@Test func aDecidedRequestIsNotResurrectedByALaterScan() {
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 1)
    var queue = AttentionQueue()
    queue.apply(requests: [request])
    queue.dismiss(.request(request.identity))
    queue.apply(requests: [request])
    #expect(queue.items.isEmpty)
}

// MARK: - Questions (Codex's request_user_input)

private func question(_ session: UUID = UUID(), turn: UUID = UUID(), source: AttentionSource = .desktop,
                      call: String = "call_1", at: Double = 10) -> AttentionQuestion {
    AttentionQuestion(source: source, session: session, turn: turn, callID: call, arrivedAt: at,
                      prompts: [QuestionPrompt(header: "List shape", question: "Which shape?", options: ["A", "B"])])
}

@Test func questionRanksAfterActionableRequestsAndAheadOfHandedBackOnes() {
    let session = UUID()
    let actionable = AttentionRequest(id: UUID(), session: session, turn: UUID(), arrivedAt: 1, handoffAfter: 30)
    let handedBack = AttentionRequest(id: UUID(), session: session, turn: UUID(), arrivedAt: 1, state: .handedBack)
    let completion = AttentionCompletion(source: .desktop, session: UUID(), turn: UUID(), arrivedAt: 1)
    let running = AttentionRunning(source: .desktop, session: UUID(), turn: UUID(), arrivedAt: 1)
    let asked = question(UUID(), at: 1)
    var queue = AttentionQueue()
    queue.apply(requests: [actionable, handedBack], completions: [completion], running: [running], now: 1)
    queue.apply(questions: [asked, asked])
    #expect(queue.items.map(\.kind) == [.actionableRequest, .question, .handedBackRequest, .completion, .running])
    #expect(queue.toCheckCount == 4)
    #expect(queue.items[1].question == asked)
}

@Test func questionClearsOnAnswerTurnEndOrSessionEndButNotBeforeArrival() {
    let session = UUID(), turn = UUID()
    func scanned(_ configure: (inout ReminderScan) -> Void) -> AttentionQueue {
        var queue = AttentionQueue()
        var scan = ReminderScan()
        scan.questions = [question(session, turn: turn, at: 10)]
        queue.apply(scan: scan, desktopEvents: [], now: 10)
        #expect(queue.items.map(\.kind) == [.question])
        configure(&scan)
        queue.apply(scan: scan, desktopEvents: [], now: 11)
        return queue
    }
    #expect(scanned { $0.questions = []; $0.answeredQuestions = [QuestionIdentity(source: .desktop, session: session, callID: "call_1")] }.items.isEmpty)
    #expect(scanned { $0.completed = [TurnIdentity(session: session, turn: turn)] }.items.isEmpty)
    #expect(scanned { $0.canceled = [TurnIdentity(session: session, turn: turn)] }.items.isEmpty)
    #expect(scanned { $0.sessionEnds[session] = 12 }.items.isEmpty)
    #expect(scanned { $0.sessionEnds[session] = 9 }.items.map(\.kind) == [.question])
    // A desktop Stop hook (a completion for the turn) also clears it and the completion stays.
    var queue = AttentionQueue()
    queue.apply(questions: [question(session, turn: turn)])
    queue.apply(completions: [AttentionCompletion(source: .desktop, session: session, turn: turn, arrivedAt: 20)])
    #expect(queue.items.map(\.kind) == [.completion])
}

@Test func dismissedOrAnsweredQuestionIsNotRevivedAndAnEndedTurnRejectsALateOne() {
    let session = UUID(), turn = UUID()
    let asked = question(session, turn: turn)
    var queue = AttentionQueue()
    queue.apply(questions: [asked])
    queue.dismiss(.question(asked.id))
    queue.apply(questions: [asked])
    #expect(queue.items.isEmpty)
    var scan = ReminderScan()
    scan.completed = [TurnIdentity(session: session, turn: turn)]
    scan.questions = [question(session, turn: turn, call: "call_2")]
    queue.apply(scan: scan, desktopEvents: [], now: 1)
    #expect(queue.items.isEmpty)
}

@Test func questionsAreRebuiltFromEvidenceNotRestoredFromTheSnapshot() {
    let asked = question()
    var queue = AttentionQueue()
    queue.apply(questions: [asked])
    var restored = AttentionQueue(snapshot: queue.snapshot)
    #expect(restored.items.isEmpty)
    var scan = ReminderScan()
    scan.questions = [asked]
    restored.apply(scan: scan, desktopEvents: [], now: 1)
    #expect(restored.items.map(\.id) == [.question(asked.id)])
}

@Test func runningRowIsWithheldWhileItsSessionWaitsOnAQuestion() {
    let session = UUID(), turn = UUID()
    let running = AttentionRunning(source: .desktop, session: session, turn: turn, arrivedAt: 1)
    let other = AttentionRunning(source: .cli, session: session, turn: turn, arrivedAt: 1)
    var queue = AttentionQueue()
    queue.apply(running: [running, other])
    queue.apply(questions: [question(session, turn: turn, at: 2)])
    #expect(queue.items.map(\.kind) == [.question, .running])
    #expect(queue.items[1].running?.source == .cli)
    #expect(queue.workingCount == 2)
    queue.dismiss(.question(QuestionIdentity(source: .desktop, session: session, callID: "call_1")))
    #expect(queue.items.filter { $0.kind == .running }.count == 2)
}

@Test func aTerminalSessionsDesktopCopyOfATurnIsDropped() {
    let session = UUID(), other = UUID(), turn = UUID(), soloTurn = UUID()
    var queue = AttentionQueue()
    queue.apply(completions: [
        AttentionCompletion(source: .cli, session: session, turn: turn, arrivedAt: 10),
        AttentionCompletion(source: .desktop, session: session, turn: turn, arrivedAt: 10),
        // A desktop turn with no terminal twin, and another session's duplicate pair, stay.
        AttentionCompletion(source: .desktop, session: session, turn: soloTurn, arrivedAt: 11),
        AttentionCompletion(source: .cli, session: other, turn: turn, arrivedAt: 12),
        AttentionCompletion(source: .desktop, session: other, turn: turn, arrivedAt: 12),
    ])
    let dropped = queue.dropDesktopDuplicates(terminalSessions: [session])
    #expect(dropped == [CompletionIdentity(source: .desktop, session: session, turn: turn)])
    let left = Set(queue.items.compactMap(\.completion).map(\.id))
    #expect(left == [CompletionIdentity(source: .cli, session: session, turn: turn),
                     CompletionIdentity(source: .desktop, session: session, turn: soloTurn),
                     CompletionIdentity(source: .cli, session: other, turn: turn),
                     CompletionIdentity(source: .desktop, session: other, turn: turn)])
    // Dropped for good: a later scan reporting the desktop copy again does not bring it back.
    queue.apply(completions: [AttentionCompletion(source: .desktop, session: session, turn: turn, arrivedAt: 10)])
    #expect(!queue.items.contains { $0.completion?.id == CompletionIdentity(source: .desktop, session: session, turn: turn) })
}
