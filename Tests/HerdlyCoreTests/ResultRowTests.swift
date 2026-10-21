import Foundation
import Testing
@testable import HerdlyCore

private let codexCLI = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "3f9a2c1e-0000-4000-8000-000000000001", surface: .cli)
private let codexApp = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "3f9a2c1e-0000-4000-8000-000000000002", surface: .desktop)
private let claudeCLI = AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude", session: "abcdef12-3456", surface: .cli)

/// Every observation spelled out; the fixture's defaults describe a reachable session so each test
/// names only what it changes. The Core initializer itself has no defaults.
private func observe(_ source: AgentSource, herdr: HerdrOpenAvailability = .notInHerdr, scan: Bool = true,
                     line: OpenUnavailableReason? = nil, known: Bool = true, hostsOff: Bool = false,
                     claudeOpenable: Bool = true, background: Bool = false,
                     lastSeen: OpenUnavailableReason? = nil) -> ResultRowObservation {
    ResultRowObservation(source: source, herdr: herdr, scanOffersOpen: scan, terminalLine: line,
                         codexSessionKnown: known, codexTerminalHostsOff: hostsOff, claudeOpenable: claudeOpenable,
                         claudeBackground: background, claudeLastSeen: lastSeen)
}

private func read(_ source: AgentSource, herdr: HerdrOpenAvailability = .notInHerdr, scan: Bool = true,
                  line: OpenUnavailableReason? = nil, known: Bool = true, hostsOff: Bool = false,
                  claudeOpenable: Bool = true, background: Bool = false,
                  lastSeen: OpenUnavailableReason? = nil) -> ResultRowReading {
    ResultRowReading.resolve(observe(source, herdr: herdr, scan: scan, line: line, known: known, hostsOff: hostsOff,
                                     claudeOpenable: claudeOpenable, background: background, lastSeen: lastSeen))
}

private func reach(_ source: AgentSource, herdr: HerdrOpenAvailability = .notInHerdr, scan: Bool = true,
                   line: OpenUnavailableReason? = nil, known: Bool = true, claudeOpenable: Bool = true) -> ResultRowTarget {
    read(source, herdr: herdr, scan: scan, line: line, known: known, claudeOpenable: claudeOpenable).target
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
    // A Codex app thread is not covered by the terminal scan: it offers Open and has no line.
    #expect(read(.codex) == ResultRowReading(target: .reachable, line: nil))
    #expect(reach(.codex, herdr: .available) == .reachable)
    // The scan ruled Open out: its line shows under the name.
    #expect(read(.codex, scan: false, line: .appNotRunning(.ghostty))
            == ResultRowReading(target: .unreachable, line: .terminal(.appNotRunning(.ghostty))))
    #expect(reach(.codex, herdr: .available, scan: false, line: .sessionEnded) == .unreachable)
    #expect(read(.codex, herdr: .unavailable(.ghosttyTTYUnsupported))
            == ResultRowReading(target: .unreachable, line: .herdr(.ghosttyTTYUnsupported)))
    // A malformed id: unreachable, and the line says Herdly cannot tell where the session is.
    #expect(read(.codex, known: false) == ResultRowReading(target: .unreachable, line: .terminal(.appNotIdentified)))
    // A click whose recheck failed keeps the row reachable until the next scan, with the click's line.
    #expect(read(.codex, line: .sessionEnded) == ResultRowReading(target: .reachable, line: .terminal(.sessionEnded)))
    // Every terminal host switched off: the scan skips the session, and its app cannot be identified
    // (product.md "Notch", ADR 0015's amendment).
    #expect(read(.codex, hostsOff: true) == ResultRowReading(target: .unreachable, line: .terminal(.appNotIdentified)))
    // The Claude inputs never decide a Codex row.
    #expect(reach(.codex, claudeOpenable: false) == .reachable)
}

@Test func aClaudeRowIsReachableInHerdrOrWhenInventoriesAndTheScanAllowOpen() {
    #expect(read(.claude) == ResultRowReading(target: .reachable, line: nil))
    // herdr's own binding opens the pane; the Ghostty rules are not read.
    #expect(read(.claude, herdr: .available, scan: false, line: .sessionEnded, claudeOpenable: false)
            == ResultRowReading(target: .reachable, line: nil))
    #expect(reach(.claude, herdr: .unavailable(.ghosttyTTYUnsupported)) == .unreachable)
    #expect(read(.claude, scan: false, line: .hostUnreadable(.iTerm2))
            == ResultRowReading(target: .unreachable, line: .terminal(.hostUnreadable(.iTerm2))))
}

@Test func everyUnreachableClaudeRowCarriesTheLineItsCardWouldShow() {
    // Not verified live (including Ghostty off with no last-seen app, the cards' Set up Ghostty case).
    #expect(read(.claude, claudeOpenable: false) == ResultRowReading(target: .unreachable, line: .claudeNotVerified))
    // No longer live: the app its process last walked to names the line (#280).
    #expect(read(.claude, claudeOpenable: false, lastSeen: .appNotRunning(.ghostty))
            == ResultRowReading(target: .unreachable, line: .claudeLastSeen(.appNotRunning(.ghostty))))
    // A background session shows its terminal line when it has one, else the not-verified line; never none.
    #expect(read(.claude, line: .sessionEnded, claudeOpenable: false, background: true)
            == ResultRowReading(target: .unreachable, line: .terminal(.sessionEnded)))
    #expect(read(.claude, claudeOpenable: false, background: true)
            == ResultRowReading(target: .unreachable, line: .claudeNotVerified))
}

@Test func herdrWithGhosttyControlsOffIsPresentedByTheGhosttyRules() {
    let off = HerdrOpenAvailability.unavailable(.session(.ghosttyControlsOff))
    #expect(off.presented == .notInHerdr)
    #expect(read(.claude, herdr: off.presented) == ResultRowReading(target: .reachable, line: nil))
    // Any other herdr cause stays unavailable.
    #expect(HerdrOpenAvailability.unavailable(.ghosttyTTYUnsupported).presented == .unavailable(.ghosttyTTYUnsupported))
    #expect(HerdrOpenAvailability.available.presented == .available)
}

@Test func reachableResultRowsOpenTheirSessionAndUnreachableOnesDoNothing() throws {
    let items = rows()
    for item in items where item.kind.opensSession {
        #expect(QueueRowSelection.action(for: item, target: .reachable) == .openSession(item.session))
        #expect(QueueRowSelection.action(for: item, target: .unreachable) == nil)
    }
    #expect(Set(items.filter(\.kind.opensSession).map(\.kind)) == [.outcome, .earlierOutcome, .waiting, .statusUnavailable])
    // A working row still opens in place (#319), whatever its session's reach.
    let working = try #require(items.first { $0.kind == .running })
    #expect(QueueRowSelection.action(for: working, target: .reachable) == .openInPlace(working.id))
    #expect(QueueRowSelection.action(for: working, target: .unreachable) == .openInPlace(working.id))
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

@Test func theFoldWaitsForTheOpenAndKeepsThePanelOnlyForThisClicksLine() {
    var fold = RowOpenFold()
    let reachable = ResultRowReading(target: .reachable, line: nil)
    // Nothing pending: nothing to settle.
    #expect(fold.settle(opening: false, reading: reachable, clickLineAt: nil) == .none)

    fold.begin(codexCLI, at: 100)
    #expect(fold.settle(opening: true, reading: reachable, clickLineAt: nil) == .none)
    #expect(fold.pending == codexCLI)
    #expect(fold.settle(opening: false, reading: reachable, clickLineAt: nil) == .collapse)
    #expect(fold.pending == nil)
    // Settled once: a later refresh does not fold the panel again.
    #expect(fold.settle(opening: false, reading: reachable, clickLineAt: nil) == .none)

    // A line from this click keeps the panel; a line from an earlier click does not.
    let failed = ResultRowReading(target: .reachable, line: .terminal(.sessionEnded))
    fold.begin(claudeCLI, at: 200)
    #expect(fold.settle(opening: false, reading: failed, clickLineAt: 201) == .stay)
    fold.begin(claudeCLI, at: 300)
    #expect(fold.settle(opening: false, reading: failed, clickLineAt: 201) == .collapse)
    // A row that became unreachable meanwhile shows its line; the panel stays.
    fold.begin(codexCLI, at: 400)
    #expect(fold.settle(opening: false, reading: ResultRowReading(target: .unreachable, line: .herdr(.ghosttyTTYUnsupported)),
                        clickLineAt: nil) == .stay)

    fold.begin(codexApp, at: 500)
    fold.cancel()
    #expect(fold.settle(opening: false, reading: reachable, clickLineAt: nil) == .none)
}

/// A reachable row's click whose recheck cannot reach the exact tab only raises the app (ADR 0015):
/// the real Open-line, acknowledgment and queue rules leave the result queued, and the panel folds.
@Test func anOpenFallbackFoldsThePanelAndLeavesTheResultQueued() {
    let key = "codex:\(codexCLI.session)"
    var lines = OpenUnavailableLines<String>()
    var queue = AgentAttentionQueue()
    let outcome = AgentOutcome(session: codexCLI, turn: "t1", status: .finished, arrivedAt: 50)
    queue.apply(.outcome(outcome))
    // An earlier click failed, so a stale click line is on the row.
    lines.recordOpen(.unavailable(.sessionEnded), for: key, at: 60)
    var fold = RowOpenFold()
    fold.begin(codexCLI, at: 100)

    let result = TerminalOpenResult.fellBack(.ghostty, .noUniqueTarget)
    lines.recordOpen(result, for: key, at: 101)
    for id in TerminalVisitAcknowledgment.afterOpen([TerminalCompletionCandidate(outcome)], result: result, preOpenAt: 100) {
        queue.dismiss(.outcome(id))
    }
    let reading = ResultRowReading.resolve(observe(.codex, scan: lines.offersOpen(key), line: lines.line(for: key)))
    #expect(reading == ResultRowReading(target: .reachable, line: nil))
    #expect(fold.settle(opening: false, reading: reading, clickLineAt: lines.clickedAt(key)) == .collapse)
    // Raising the app acknowledged nothing: the result is still queued.
    #expect(queue.items(at: 102).compactMap(\.outcome).map(\.id) == [outcome.id])

    // The same click finding the session ended instead keeps the panel with its line, result retained.
    fold.begin(codexCLI, at: 200)
    lines.recordOpen(.unavailable(.sessionEnded), for: key, at: 201)
    let failed = ResultRowReading.resolve(observe(.codex, scan: lines.offersOpen(key), line: lines.line(for: key)))
    #expect(failed == ResultRowReading(target: .reachable, line: .terminal(.sessionEnded)))
    #expect(fold.settle(opening: false, reading: failed, clickLineAt: lines.clickedAt(key)) == .stay)
    #expect(queue.items(at: 202).compactMap(\.outcome).map(\.id) == [outcome.id])

    // A verified Open, by contrast, acknowledges the result through ADR 0016's rule.
    #expect(TerminalVisitAcknowledgment.afterOpen([TerminalCompletionCandidate(outcome)], result: .opened, preOpenAt: 300)
            == [outcome.id])
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
