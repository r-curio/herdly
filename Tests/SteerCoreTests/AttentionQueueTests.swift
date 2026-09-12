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
    queue.apply(scan: scan, desktopEvents: [], now: 110)
    #expect(queue.items.first?.kind == .actionableRequest)

    queue.apply(scan: scan, desktopEvents: [], now: 129)
    #expect(queue.items.first?.kind == .actionableRequest)
    queue.apply(scan: scan, desktopEvents: [], now: 130.1)
    #expect(queue.items.first?.kind == .handedBackRequest)
    #expect(queue.items.first?.id == .request(request.identity))
    #expect(queue.items.first?.arrivedAt == request.arrivedAt)
}

@Test func readerPreservesPendingReceiptAsActionableQueueItem() throws {
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
    var queue = AttentionQueue()
    queue.apply(scan: scan, desktopEvents: [], now: 129)
    #expect(queue.items.first?.kind == .actionableRequest)
    queue.apply(scan: scan, desktopEvents: [], now: 131)
    #expect(queue.items.first?.kind == .handedBackRequest)
}
