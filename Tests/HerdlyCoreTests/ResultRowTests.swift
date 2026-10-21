import Foundation
import Testing
@testable import HerdlyCore

private let codexCLI = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "3f9a2c1e-0000-4000-8000-000000000001", surface: .cli)
private let codexApp = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "3f9a2c1e-0000-4000-8000-000000000002", surface: .desktop)
private let claudeCLI = AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude", session: "abcdef12-3456", surface: .cli)

private func reach(_ source: AgentSource, herdr: HerdrOpenAvailability = .notInHerdr, scan: Bool = true,
                   known: Bool = true, claudeOpenable: Bool = true) -> ResultRowTarget {
    ResultRowTarget.resolve(source: source, herdr: herdr, scanOffersOpen: scan, codexSessionKnown: known,
                            claudeOpenable: claudeOpenable)
}

/// One row of each kind: a finished, a failed, a stopped and an Earlier result, a Claude session
/// waiting, a working row, and a Claude session whose status is unavailable.
private func rows() -> [AgentAttentionItem] {
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: codexCLI, turn: "done", status: .finished, arrivedAt: 400)))
    queue.apply(.outcome(AgentOutcome(session: codexApp, turn: "broke", status: .failed, arrivedAt: 400)))
    queue.apply(.outcome(AgentOutcome(session: claudeCLI, turn: "halted", status: .stopped, arrivedAt: 400)))
    queue.apply(.outcome(AgentOutcome(session: codexCLI, turn: "old", status: .finished, arrivedAt: 10)))
    queue.apply(.running(AgentRunning(session: AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude",
                                                                   session: "waiter", surface: .cli),
                                      turn: "w", arrivedAt: 400, status: .waiting)))
    queue.apply(.running(AgentRunning(session: AgentSessionIdentity(source: .codex, sourceScope: "codex",
                                                                   session: "busy", surface: .cli),
                                      turn: "r", arrivedAt: 400)))
    queue.apply(.unavailable(sourceScope: "/tmp/root", observedAt: 2, reason: "duplicate",
                             ambiguousSessionIDs: ["11111111-1111-4111-8111-111111111111"]))
    return queue.items(at: 401)
}

@Test func onlyResultsWaitingAndStatusUnknownRowsOpenTheirSession() {
    let kinds: [AgentAttentionKind] = [.actionableApproval, .question, .handedBackApproval, .waiting, .outcome,
                                       .earlierOutcome, .statusUnavailable, .running]
    let opening = kinds.filter(\.opensSession)
    #expect(opening == [.waiting, .outcome, .earlierOutcome, .statusUnavailable])
}

@Test func aCodexRowIsReachableUnlessHerdrTheScanOrAnUnknownSessionRulesOpenOut() {
    #expect(reach(.codex) == .reachable)
    // A Codex app thread is not covered by the terminal scan, so it keeps Open.
    #expect(reach(.codex, scan: true) == .reachable)
    #expect(reach(.codex, herdr: .available) == .reachable)
    #expect(reach(.codex, scan: false) == .unreachable)
    #expect(reach(.codex, herdr: .available, scan: false) == .unreachable)
    #expect(reach(.codex, herdr: .unavailable(.ghosttyTTYUnsupported)) == .unreachable)
    #expect(reach(.codex, known: false) == .unreachable)
    // The Claude inputs never decide a Codex row.
    #expect(reach(.codex, claudeOpenable: false) == .reachable)
}

@Test func aClaudeRowIsReachableInHerdrOrWhenInventoriesAndTheScanAllowOpen() {
    #expect(reach(.claude) == .reachable)
    // herdr's own binding opens the pane; the Ghostty rules are not read.
    #expect(reach(.claude, herdr: .available, scan: false, claudeOpenable: false) == .reachable)
    #expect(reach(.claude, herdr: .unavailable(.ghosttyTTYUnsupported)) == .unreachable)
    // Not live exactly once, Ghostty awaiting permission, or switched off ("Set up Ghostty"): no Open.
    #expect(reach(.claude, claudeOpenable: false) == .unreachable)
    #expect(reach(.claude, scan: false) == .unreachable)
}

@Test func reachableResultRowsOpenTheirSessionAndUnreachableOnesDoNothing() throws {
    let items = rows()
    for item in items where item.kind.opensSession {
        #expect(QueueRowSelection.returnAction(for: item, target: .reachable) == .openSession(item.session))
        #expect(QueueRowSelection.returnAction(for: item, target: .unreachable) == nil)
    }
    #expect(Set(items.filter(\.kind.opensSession).map(\.kind)) == [.outcome, .earlierOutcome, .waiting, .statusUnavailable])
    // A working row still opens in place (#319), whatever its session's reach.
    let working = try #require(items.first { $0.kind == .running })
    #expect(QueueRowSelection.returnAction(for: working, target: .reachable) == .openInPlace(working.id))
    #expect(QueueRowSelection.returnAction(for: working, target: .unreachable) == .openInPlace(working.id))
}

@Test func unreachableTakesTheWordSlotOnResultRowsOnly() throws {
    let items = rows()
    let word = { (turn: String, target: ResultRowTarget) in
        items.first { $0.outcome?.turn == turn }.flatMap { QueueRowPresentation.exception($0, target: target) }
    }
    // Reachable rows keep D17's words.
    #expect(word("done", .reachable) == nil)
    #expect(word("broke", .reachable) == .failed)
    #expect(word("halted", .reachable) == nil)
    // An unreachable row reads "Unreachable", ahead of "Failed" (8J1); VoiceOver still says it failed.
    #expect(word("done", .unreachable) == .unreachable)
    #expect(word("broke", .unreachable) == .unreachable)
    let failed = try #require(items.first { $0.outcome?.turn == "broke" })
    #expect(QueueRowPresentation.spokenState(failed) == "Codex failed")
    let waiting = try #require(items.first { $0.kind == .waiting })
    #expect(QueueRowPresentation.exception(waiting, target: .unreachable) == .unreachable)
    let unknown = try #require(items.first { $0.kind == .statusUnavailable })
    #expect(QueueRowPresentation.exception(unknown, target: .unreachable) == .unreachable)
    // A working row has no word and never reads Unreachable.
    let working = try #require(items.first { $0.kind == .running })
    #expect(QueueRowPresentation.exception(working, target: .unreachable) == nil)
    #expect(RowException.unreachable.word == "Unreachable")
    #expect(!RowException.unreachable.isFailure)
}

@Test func theFoldWaitsForTheOpenAndKeepsThePanelWhenTheRowShowsAReasonLine() {
    var fold = RowOpenFold()
    // Nothing pending: nothing to settle.
    #expect(fold.settle(opening: false, showsLine: false) == .none)

    fold.begin(codexCLI)
    #expect(fold.settle(opening: true, showsLine: false) == .none)
    #expect(fold.pending == codexCLI)
    #expect(fold.settle(opening: false, showsLine: false) == .collapse)
    #expect(fold.pending == nil)
    // Settled once: a later refresh does not fold the panel again.
    #expect(fold.settle(opening: false, showsLine: false) == .none)

    // A click-time recheck that found the session unavailable leaves its line on the row; the panel stays.
    fold.begin(claudeCLI)
    #expect(fold.settle(opening: false, showsLine: true) == .stay)
    #expect(fold.pending == nil)

    fold.begin(codexApp)
    fold.cancel()
    #expect(fold.settle(opening: false, showsLine: false) == .none)
}

@Test func dismissClearsOnlyThatResultAndKeepsTheSessionsOtherTurns() {
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: codexCLI, turn: "t1", status: .finished, arrivedAt: 10)))
    queue.apply(.outcome(AgentOutcome(session: codexCLI, turn: "t2", status: .failed, arrivedAt: 20)))
    queue.apply(.outcome(AgentOutcome(session: claudeCLI, turn: "t3", status: .finished, arrivedAt: 30)))
    queue.dismiss(.outcome(AgentTurnIdentity(session: codexCLI, turn: "t1")))
    let left = queue.items(at: 40).compactMap(\.outcome).map { "\($0.session.session.prefix(8)):\($0.turn)" }
    #expect(left.sorted() == ["3f9a2c1e:t2", "abcdef12:t3"])
    #expect(queue.acknowledgedOutcomes == [AgentTurnIdentity(session: codexCLI, turn: "t1")])
}
