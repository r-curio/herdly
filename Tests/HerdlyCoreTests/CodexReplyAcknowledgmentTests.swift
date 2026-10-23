import Foundation
import Testing
@testable import HerdlyCore

// Agreed 2026-10-08: a prompt in a Codex CLI session acknowledges that session's earlier completions,
// and an acknowledged Codex completion must leave both queues.

private let session = UUID(uuidString: "01A119C4-47AE-74E1-824E-B4FC99AB7938")!
private let otherSession = UUID(uuidString: "01A11611-0AE8-7042-9F19-FD36707AB5D6")!
private let firstTurn = UUID(uuidString: "01A119C6-0E39-7933-B3E1-7753FF1ED4CC")!
private let secondTurn = UUID(uuidString: "01A119C7-3649-75A0-AB35-0A6CB94F64A8")!
private let replyTurn = UUID(uuidString: "01A119CA-1AD9-7150-A77A-A5295618A40B")!

private func at(_ seconds: Double) -> String { RolloutTimestamp.format(1_791_430_000 + seconds) }
private func completion(_ turn: UUID, session: UUID = session, source: AttentionSource = .cli,
                        arrivedAt seconds: Double) -> AttentionCompletion {
    AttentionCompletion(source: source, session: session, turn: turn, arrivedAt: 1_791_430_000 + seconds)
}

@Test func codexReplyAcknowledgesTheSessionsEarlierCompletionsOnly() {
    let completions = [completion(firstTurn, arrivedAt: 10),
                       completion(secondTurn, arrivedAt: 20),
                       completion(replyTurn, arrivedAt: 40),
                       completion(firstTurn, session: otherSession, arrivedAt: 10),
                       completion(secondTurn, source: .desktop, arrivedAt: 10)]
    let events: [CLIEvent] = [.turnStarted(session: session, turn: secondTurn, receivedAt: at(15)),
                              .turnStarted(session: session, turn: replyTurn, receivedAt: at(30))]
    // The latest prompt (at 30) acknowledges both earlier turns, not its own turn's completion,
    // another session's completion, or a desktop completion.
    #expect(CodexReplyAcknowledgment.acknowledged(completions, events: events)
            == [completion(firstTurn, arrivedAt: 10).id, completion(secondTurn, arrivedAt: 20).id])
    // Events out of order still use the latest prompt.
    #expect(CodexReplyAcknowledgment.acknowledged(completions, events: events.reversed()).count == 2)
}

@Test func codexReplyKeepsCompletionsArrivingAtOrAfterThePrompt() {
    let completions = [completion(firstTurn, arrivedAt: 30), completion(secondTurn, arrivedAt: 31)]
    let events: [CLIEvent] = [.turnStarted(session: session, turn: replyTurn, receivedAt: at(30))]
    #expect(CodexReplyAcknowledgment.acknowledged(completions, events: events).isEmpty)
    // An unparsable prompt time or no prompt acknowledges nothing.
    #expect(CodexReplyAcknowledgment.acknowledged([completion(firstTurn, arrivedAt: 1)],
                                                  events: [.turnStarted(session: session, turn: replyTurn,
                                                                        receivedAt: "not a time")]).isEmpty)
    #expect(CodexReplyAcknowledgment.acknowledged([completion(firstTurn, arrivedAt: 1)],
                                                  events: [.sessionStarted(session: session, receivedAt: at(5))]).isEmpty)
}

@Test func codexCompletionOutcomeIDMatchesTheMirroredOutcome() {
    for source in [AttentionSource.cli, .desktop] {
        let item = completion(firstTurn, source: source, arrivedAt: 10)
        #expect(CodexAttentionAdapter.outcomeID(for: item.id) == CodexAttentionAdapter.outcome(from: item).id)
    }
}

// Why acknowledgment must dismiss both queues: the Codex sync keeps outcomes it no longer receives.
@Test func codexOutcomeSurvivesSyncUntilDismissedInTheSharedQueue() {
    let item = completion(firstTurn, arrivedAt: 10)
    var queue = AgentAttentionQueue()
    queue.apply(CodexAttentionAdapter.observations(completions: [item]), now: item.arrivedAt)
    let outcomeID = CodexAttentionAdapter.outcomeID(for: item.id)
    // The Codex queue dropped it; the sync reconciles with nothing to keep.
    queue.reconcile(source: .codex, sourceScope: CodexAttentionAdapter.sourceScope, keeping: [])
    #expect(queue.snapshot.outcomes.map(\.id) == [outcomeID])
    queue.dismiss(.outcome(outcomeID))
    #expect(queue.snapshot.outcomes.isEmpty)
    // A late re-observation does not bring it back.
    queue.apply(CodexAttentionAdapter.observations(completions: [item]), now: item.arrivedAt + 1)
    #expect(queue.snapshot.outcomes.isEmpty)
}

// Issue #359: a completion queued as desktop while its session was not yet (or no longer) known as
// CLI clears with that session's later prompt once the scan classifies it CLI again.
@Test func codexReplyAcknowledgesADesktopLabelledCompletionOfACLISession() {
    let completions = [completion(firstTurn, source: .desktop, arrivedAt: 10),
                       completion(replyTurn, source: .desktop, arrivedAt: 20),
                       completion(secondTurn, source: .desktop, arrivedAt: 40)]
    let events: [CLIEvent] = [.turnStarted(session: session, turn: replyTurn, receivedAt: at(30))]
    // Same timing rules as a CLI completion: strictly before the prompt, other turns only.
    #expect(CodexReplyAcknowledgment.acknowledged(completions, events: events, cliSessions: [session])
            == [completion(firstTurn, source: .desktop, arrivedAt: 10).id])
    // Not classified CLI in this scan: nothing.
    #expect(CodexReplyAcknowledgment.acknowledged(completions, events: events, cliSessions: [otherSession]).isEmpty)
}

@Test func codexReplyLeavesDesktopOriginatedCompletionsAlone() {
    let completions = [completion(firstTurn, source: .desktop, arrivedAt: 10),
                       completion(firstTurn, session: otherSession, source: .desktop, arrivedAt: 10)]
    let events: [CLIEvent] = [.turnStarted(session: session, turn: replyTurn, receivedAt: at(30)),
                              .turnStarted(session: otherSession, turn: replyTurn, receivedAt: at(30))]
    // A desktop-originated thread keeps its desktop read-state rule even if classified CLI.
    #expect(CodexReplyAcknowledgment.acknowledged(completions, events: events, cliSessions: [session, otherSession],
                                                  desktopOriginatedSessions: [otherSession])
            == [completion(firstTurn, source: .desktop, arrivedAt: 10).id])
}
