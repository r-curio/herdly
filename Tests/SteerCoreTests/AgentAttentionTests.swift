import Foundation
import Testing
@testable import SteerCore

@Test func agentIdentityKeepsSameUpstreamIDsSeparateBySourceAndScope() {
    let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "same", surface: .desktop)
    let claudeA = AgentSessionIdentity(source: .claude, sourceScope: "root-a", session: "same", surface: .cli)
    let claudeB = AgentSessionIdentity(source: .claude, sourceScope: "root-b", session: "same", surface: .cli)
    let turn = "turn-1"
    var queue = AgentAttentionQueue()

    queue.apply(.outcome(AgentOutcome(session: codex, turn: turn, status: .finished, arrivedAt: 1)))
    queue.apply(.outcome(AgentOutcome(session: claudeA, turn: turn, status: .failed, arrivedAt: 2)))
    queue.apply(.outcome(AgentOutcome(session: claudeB, turn: turn, status: .stopped, arrivedAt: 3)))

    #expect(queue.items.count == 3)
    #expect(Set(queue.items.map(\.id)).count == 3)
}

@Test func codexCompletionsNormalizeIntoTheSharedOutcomeModel() {
    let completion = AttentionCompletion(source: .cli, session: UUID(), turn: UUID(), arrivedAt: 10)
    let observations = CodexAttentionAdapter.observations(completions: [completion])
    var queue = AgentAttentionQueue()
    queue.apply(observations)
    let outcome = queue.items.first?.outcome

    #expect(outcome?.session.source == .codex)
    #expect(outcome?.session.sourceScope == "codex")
    #expect(outcome?.session.surface == .cli)
    #expect(outcome?.status == .finished)
    #expect(outcome?.turn == completion.turn.uuidString)
}

@Test func sharedQueueKeepsDeadlinePriorityAndEarlierDecayDeterministic() {
    let approvalSession = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "approval", surface: .cli)
    let questionSession = AgentSessionIdentity(source: .claude, sourceScope: "root-a", session: "question", surface: .cli)
    let outcomeSession = AgentSessionIdentity(source: .claude, sourceScope: "root-b", session: "outcome", surface: .cli)
    let runningSession = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "running", surface: .desktop)
    var queue = AgentAttentionQueue()

    queue.apply(.approval(AgentApproval(session: approvalSession, turn: "t1", call: "a1", arrivedAt: 10, handoffAfter: 30)))
    queue.apply(.question(AgentQuestion(session: questionSession, turn: "t2", call: "q1", arrivedAt: 11)))
    queue.apply(.outcome(AgentOutcome(session: outcomeSession, turn: "t3", status: .unavailable, arrivedAt: 12)))
    queue.apply(.running(AgentRunning(session: runningSession, turn: "t4", arrivedAt: 13)))

    #expect(queue.items(at: 39).map(\.kind) == [.actionableApproval, .question, .outcome, .running])
    #expect(queue.items(at: 40).map(\.kind) == [.question, .handedBackApproval, .outcome, .running])
    #expect(queue.items(at: 312).first { $0.outcome != nil }?.kind == .earlierOutcome)
    #expect(queue.toCheckCount == 3)
}

@Test func versionOneCodexSnapshotsMigrateToFinishedVersionTwoOutcomes() throws {
    let session = UUID(), turn = UUID()
    let legacy = """
    {"version":1,"completions":[{"source":"cli","session":"\(session.uuidString.lowercased())","turn":"\(turn.uuidString.lowercased())","arrivedAt":12,"uncertain":false}],"acknowledged":[]}
    """

    let snapshot = try JSONDecoder().decode(AttentionSnapshot.self, from: Data(legacy.utf8))

    #expect(snapshot.version == 2)
    #expect(snapshot.outcomes.count == 1)
    #expect(snapshot.outcomes.first?.status == .finished)
    #expect(snapshot.outcomes.first?.session.sourceScope == "codex")
    #expect(snapshot.completions.first?.session == session)
}

@Test func restoredOutcomeIsUncertainWithoutChangingItsStatusOrAcknowledgment() {
    let session = AgentSessionIdentity(source: .claude, sourceScope: "root-a", session: "same", surface: .cli)
    let outcome = AgentOutcome(session: session, turn: "turn", status: .failed, arrivedAt: 10)
    let restored = AgentAttentionQueue(snapshot: AgentAttentionSnapshot(outcomes: [outcome]))

    #expect(restored.items.first?.outcome?.status == .failed)
    #expect(restored.items.first?.outcome?.uncertain == true)
    #expect(restored.toCheckCount == 1)
}

@Test func versionTwoSnapshotRoundTripsSourceScopedOutcomes() throws {
    let sources: [(AgentSource, String, AgentOutcomeStatus)] = [
        (.codex, "codex", .finished), (.claude, "root-a", .failed), (.claude, "root-b", .stopped)
    ]
    let outcomes = sources.map { source, scope, status in
        AgentOutcome(session: AgentSessionIdentity(source: source, sourceScope: scope, session: "same", surface: .cli),
                     turn: "same-turn", status: status, arrivedAt: 1)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = root.appendingPathComponent("attention.json")
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(AttentionSnapshotStore.save(AttentionSnapshot(outcomes: outcomes), to: file))
    let loaded = AttentionSnapshotStore.load(from: file)
    #expect(Set(loaded.outcomes.map(\.id)) == Set(outcomes.map(\.id)))
    #expect(Set(loaded.outcomes.map(\.status)) == [.finished, .failed, .stopped])
}
