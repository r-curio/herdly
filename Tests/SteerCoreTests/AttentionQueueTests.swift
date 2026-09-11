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
    #expect(queue.items.map(\.id) == [.request(request.id), .completion(completion.id), .running(running.id)])
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
