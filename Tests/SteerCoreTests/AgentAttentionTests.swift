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

@Test func mixedSourcesKeepPriorityCountsAndTruthfulClaudeLabels() {
    let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex-session", surface: .cli)
    let claude = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "claude-session", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: claude, turn: "turn", arrivedAt: 1, status: .waiting)))
    queue.apply(.outcome(AgentOutcome(session: codex, turn: "turn", status: .finished, arrivedAt: 2)))

    #expect(queue.items.map(\.kind) == [.waiting, .outcome])
    #expect(queue.workingCount == 0)
    #expect(queue.toCheckCount == 2)
    #expect(AgentStripSummary.sessionLabel(claude) == "Claude session claude-s")
}

@Test func waitingClaudeSessionNeedsAttentionButConcreteActionsWinOnce() {
    let session = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "waiting", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: session, turn: "turn", arrivedAt: 1, status: .waiting)))
    #expect(queue.items.map(\.kind) == [.waiting])
    #expect(queue.toCheckCount == 1)

    queue.apply(.question(AgentQuestion(session: session, turn: "turn", call: "question", arrivedAt: 2)))
    #expect(queue.items.map(\.kind) == [.question])
    #expect(queue.toCheckCount == 1)

    queue.apply(.approval(AgentApproval(session: session, turn: "turn", call: "approval", arrivedAt: 3)))
    #expect(queue.items.map(\.kind) == [.actionableApproval, .question])
    #expect(queue.toCheckCount == 2)
}

@Test func namedAgentLabelsKeepSourceVisible() {
    let claude = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "claude", surface: .cli)
    let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex", surface: .desktop)
    #expect(AgentStripSummary.sessionLabel(claude, names: [claude: "Review API"]) == "Claude · Review API")
    #expect(AgentStripSummary.sessionLabel(codex, names: [codex: "Fix tests"]) == "Codex · Fix tests")
}

@Test func codexAdapterKeepsDetailsAndQuestionPromptsForTheSharedView() {
    let session = UUID()
    let turn = UUID()
    let request = AttentionRequest(id: UUID(), source: .cli, session: session, turn: turn, arrivedAt: 1,
                                   details: ApprovalDetails(taskName: "Review", command: "swift test",
                                                            reason: "Check the change."))
    let question = AttentionQuestion(source: .cli, session: session, turn: turn, callID: "call", arrivedAt: 2,
                                     prompts: [QuestionPrompt(header: "Choice", question: "Continue?", options: ["Yes", "No"])])
    let approval = CodexAttentionAdapter.approval(from: request)
    let agentQuestion = CodexAttentionAdapter.question(from: question)
    #expect(approval.details?.taskName == "Review")
    #expect(approval.details?.command == "swift test")
    #expect(agentQuestion.prompts == question.prompts)
}

@Test func ambiguousClaudeSessionIsStatusUnavailableAndNeedsAttention() {
    let session = "11111111-1111-4111-8111-111111111111"
    var queue = AgentAttentionQueue()
    queue.apply(.unavailable(sourceScope: "/tmp/root", observedAt: 2,
                             reason: "duplicate", ambiguousSessionIDs: [session]))

    #expect(queue.items.first?.kind == .statusUnavailable)
    #expect(queue.items.first?.unavailableReason?.contains("unavailable") == true)
    #expect(queue.toCheckCount == 1)
    #expect(queue.workingCount == 0)
}

@Test func freshMixedSourceCardsChooseQueuePriorityForOneSpotlight() {
    let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex", surface: .cli)
    let claude = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "claude", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: codex, turn: "turn", call: "approval", arrivedAt: 1)))
    queue.apply(.question(AgentQuestion(session: claude, turn: "turn", call: "question", arrivedAt: 2)))
    queue.apply(.outcome(AgentOutcome(session: claude, turn: "outcome", status: .finished, arrivedAt: 3)))
    let items = queue.items(at: 1)
    let candidates = Set(items.map(\.id))

    #expect(AgentPresentationSelection.highestPriority(in: items, candidates: candidates) == items.first?.id)
    #expect(AgentPresentationEligibility.foregroundGate(source: .claude, codexForeground: true) == false)
    #expect(AgentPresentationEligibility.foregroundGate(source: .codex, codexForeground: true) == true)
}

@Test func foregroundCodexDoesNotSuppressFreshClaudeOrPromoteRestoredClaude() {
    let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex", surface: .desktop)
    let claude = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "claude", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: claude, turn: "old", status: .finished, arrivedAt: 1)))
    queue.apply(.outcome(AgentOutcome(session: codex, turn: "new", status: .finished, arrivedAt: 2)))
    let items = queue.items(at: 2)
    let freshIDs = Set(items.map(\.id))
    let eligibleWithBothFresh = Set(items.filter {
        AgentPresentationEligibility.foregroundGate(source: $0.session.source, codexForeground: true) != true
    }.map(\.id))

    #expect(AgentPresentationSelection.highestPriority(in: items, candidates: eligibleWithBothFresh)
            == items.first { $0.session.source == .claude }?.id)

    let onlyCodexFresh = freshIDs.filter { id in
        items.first { $0.id == id }?.session.source == .codex
    }
    let eligibleOnlyCodex = Set(items.filter {
        onlyCodexFresh.contains($0.id)
            && AgentPresentationEligibility.foregroundGate(source: $0.session.source, codexForeground: true) != true
    }.map(\.id))
    #expect(AgentPresentationSelection.highestPriority(in: items, candidates: eligibleOnlyCodex) == nil)
}

@Test func handedBackApprovalRetainsSourceRequestDetails() {
    let session = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "session", surface: .cli)
    let details = ApprovalDetails(taskName: "Review", project: "/tmp/project", action: "Run",
                                  command: "swift test", reason: "Verify", longText: "Run the full suite.")
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: session, turn: "turn", call: "call", arrivedAt: 1,
                                        state: .actionable, details: details)))
    queue.apply(.approval(AgentApproval(session: session, turn: "turn", call: "call", arrivedAt: 1,
                                        state: .handedBack)))

    let item = queue.items(at: 40).first
    #expect(item?.kind == .handedBackApproval)
    #expect(item?.approval?.details == details)
}

@Test func mixedPriorityLeavesSameCategoryOutcomeForTheNextSpotlight() {
    let claude = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "claude", surface: .cli)
    let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex", surface: .desktop)
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: claude, turn: "first", status: .finished, arrivedAt: 1)))
    queue.apply(.outcome(AgentOutcome(session: claude, turn: "second", status: .failed, arrivedAt: 2)))
    queue.apply(.question(AgentQuestion(session: codex, turn: "turn", call: "question", arrivedAt: 3)))
    let items = queue.items(at: 3)
    let firstCandidates = Set(items.map(\.id))
    let first = AgentPresentationSelection.highestPriority(in: items, candidates: firstCandidates)
    let remainingOutcomes = Set(items.filter { $0.kind == .outcome }.map(\.id))

    #expect(first == items.first { $0.kind == .question }?.id)
    #expect(AgentPresentationSelection.highestPriority(in: items, candidates: remainingOutcomes)
            == items.first { $0.outcome?.turn == "first" }?.id)
}

@Test func aTerminalCodexSessionsDesktopOutcomeCopyIsDropped() {
    let session = UUID(), other = UUID(), turn = UUID(), soloTurn = UUID()
    func outcome(_ source: AttentionSource, _ session: UUID, _ turn: UUID) -> AgentObservation {
        .outcome(CodexAttentionAdapter.outcome(from: AttentionCompletion(source: source, session: session, turn: turn, arrivedAt: 10)))
    }
    var queue = AgentAttentionQueue()
    queue.apply([outcome(.cli, session, turn), outcome(.desktop, session, turn), outcome(.desktop, session, soloTurn),
                 outcome(.cli, other, turn), outcome(.desktop, other, turn)], now: 20)
    let dropped = queue.dropDesktopDuplicates(codexTerminalSessions: [session.uuidString])
    #expect(dropped == [AgentTurnIdentity(session: CodexAttentionAdapter.session(session, surface: .desktop), turn: turn.uuidString)])
    let left = Set(queue.items(at: 20).compactMap(\.outcome).map { "\($0.session.surface)-\($0.session.session == session.uuidString)-\($0.turn == turn.uuidString)" })
    #expect(left == ["cli-true-true", "desktop-true-false", "cli-false-true", "desktop-false-true"])
}
