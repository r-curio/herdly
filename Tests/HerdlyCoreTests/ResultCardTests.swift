import Foundation
import Testing
@testable import HerdlyCore

// #323 (Paper D33, 9NU, 9RW): the result card a finished turn pops. The reply field shows only where
// Herdly can reach the session; a send folds the card and its row carries the reply's note; the
// message shows five lines with "Show all" for the rest; restored results never pop. Seeing the card,
// unfolding it, or sending acknowledges nothing.

private let session = UUID(uuidString: "01A09D9B-7642-7B51-BCCE-9B66CFE5361F")!
private let turn = UUID(uuidString: "01A09DB7-0C51-7F33-9EBC-4E44F91DF22C")!
private let pane = TypedInputPane(host: .terminalApp, paneID: "9882", tty: "/dev/ttys005")
private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/Users/me/.claude", session: "c-1", surface: .cli)

private func completion(_ source: AttentionSource = .cli) -> AttentionCompletion {
    AttentionCompletion(source: source, session: session, turn: turn, arrivedAt: 100)
}

// MARK: The reply field

@Test func aReachableCLICardOffersTheReplyField() {
    let ready = SessionReplyPhase.ready
    #expect(ResultCardReply.offersField(for: completion(), target: .daemon(thread: session), phase: ready))
    #expect(ResultCardReply.offersField(for: completion(), target: .terminal(pane), phase: ready))
}

@Test func anUnreachableCardHasNoFieldAndNoReason() {
    // Ended, mid-turn, no daemon, not loaded, no exact tab, a host that cannot type: no field at all.
    let reasons: [SessionReplyPolicy.Rejection] = [.sessionEnded, .sessionWorking, .noDaemon, .threadNotLoaded,
                                                    .terminalUnreachable, .hostCannotType(.iTerm2)]
    for reason in reasons {
        #expect(ResultCardReply.offersField(for: completion(), target: .unavailable(reason), phase: .ready) == false)
    }
}

@Test func aCodexAppCardHasNoReplyFieldEvenWhenTheDaemonHoldsTheThread() {
    #expect(ResultCardReply.offersField(for: completion(.desktop), target: .daemon(thread: session), phase: .ready) == false)
}

@Test func aCodexAppCardHasNoReplyFieldEvenWithATypedRoute() {
    #expect(ResultCardReply.offersField(for: completion(.desktop), target: .terminal(pane), phase: .ready) == false)
}

@Test func aClaudeCardOffersTheFieldOnlyWithATypingHost() {
    // No host that types replies is on: no route, no field.
    let none = ClaudeReplyRouting.target(ended: false, inTurn: false, route: nil)
    #expect(ResultCardReply.offersField(target: none, phase: .ready) == false)
    let typing = ClaudeReplyRouting.target(ended: false, inTurn: false, route: .pane(pane))
    #expect(ResultCardReply.offersField(target: typing, phase: .ready))
    let iTerm2 = ClaudeReplyRouting.target(ended: false, inTurn: false, route: .hostCannotType(.iTerm2))
    #expect(ResultCardReply.offersField(target: iTerm2, phase: .ready) == false)
    let working = ClaudeReplyRouting.target(ended: false, inTurn: true, route: .pane(pane))
    #expect(ResultCardReply.offersField(target: working, phase: .ready) == false)
}

@Test func aCardWhoseReplyLeftHasNoField() {
    for phase in [SessionReplyPhase.sending("x"), .sent(text: "x", at: 1), .working(text: "x"),
                  .unconfirmed(text: "x", sentAt: 1), .failed("no")] {
        #expect(ResultCardReply.offersField(for: completion(), target: .daemon(thread: session), phase: phase) == false)
    }
}

// MARK: Folding on send

@Test func aSendThatLeavesReadyFoldsTheCard() {
    #expect(ResultCardReply.foldsCard(before: .ready, after: .sending("now add tests")))
    #expect(ResultCardReply.foldsCard(before: .ready, after: .sent(text: "now add tests", at: 1)))
    #expect(ResultCardReply.foldsCard(before: .ready, after: .failed("nothing was sent")))
    #expect(ResultCardReply.foldsCard(before: .ready, after: .ready) == false)
    // A card already past its one reply is not folded again by a later settle.
    #expect(ResultCardReply.foldsCard(before: .sending("x"), after: .sent(text: "x", at: 1)) == false)
}

@Test func aReplyRefusedMidTurnStaysReadyWithNoNoteAndNoFold() {
    // The session started another turn after the card rendered: the send is refused and the card keeps the text.
    let working = SessionReplyAvailability(daemonConnected: true, daemonThreads: [session], workingSessions: [session])
    let progress = SessionReplyProgress(completion: completion().id)
    let plan = SessionReplySending.prepare(completion: completion(), availability: working, progress: progress,
                                           text: "now add tests", at: 200)
    #expect(plan.outcome == .refused(.sessionWorking))
    #expect(progress.phase == .ready)
    #expect(RowNote.reply(progress, agent: .codex) == nil)
    #expect(ResultCardReply.foldsCard(before: .ready, after: progress.phase) == false)
}

// MARK: The row note after a send

@Test func eachCodexReplyPhaseHasItsRowNote() {
    let ready = SessionReplyProgress(completion: completion().id)
    #expect(RowNote.reply(ready, agent: .codex) == nil)
    let sending = ready.startingSend(text: "now add tests", at: 200)
    #expect(RowNote.reply(sending, agent: .codex)?.text == "Sending…")
    let sent = sending.recordingSent(at: 201)
    #expect(RowNote.reply(sent, agent: .codex)?.text == "Sent, waiting for Codex")
    let working = sent.observing(sessionWorking: true, at: 202)
    #expect(working.phase == .working(text: "now add tests"))
    #expect(RowNote.reply(working, agent: .codex)?.text == "Sent, waiting for Codex")
    let unconfirmed = sent.observing(sessionWorking: false, at: 201 + SessionReplyProgress.confirmationWindow)
    #expect(RowNote.reply(unconfirmed, agent: .codex)?.text == "Sent, not confirmed")
    let failed = sending.recordingFailure("Codex's daemon did not take the reply.")
    let note = RowNote.reply(failed, agent: .codex)
    #expect(note?.text == "Not delivered · reply in Codex")
    #expect(note?.offersOpen == true)
    #expect(RowNote.reply(sent, agent: .codex)?.offersOpen == false)
}

@Test func codexTextThatMayWaitInTheComposerIsNotConfirmed() {
    let sending = SessionReplyProgress(completion: completion().id).startingSend(text: "now add tests", route: .terminal(pane))
    let textOnly = sending.settling(.sentTextOnly, at: 201)
    #expect(textOnly.composerMayHoldText)
    #expect(RowNote.reply(textOnly, agent: .codex)?.text == "Sent, not confirmed")
}

@Test func eachClaudeReplyPhaseHasItsRowNote() {
    let id = AgentTurnIdentity(session: claude, turn: "t-1")
    let sending = ReplyProgress(completion: id).startingSend(text: "now add tests", route: .terminal(pane))
    #expect(RowNote.reply(sending, agent: .claude)?.text == "Sending…")
    let sent = sending.settling(.sent, at: 201)
    #expect(RowNote.reply(sent, agent: .claude)?.text == "Sent, not confirmed")
    #expect(RowNote.reply(sent.observing(sessionWorking: true, at: 202), agent: .claude)?.text == "Sent, not confirmed")
    let failed = sending.settling(.notSent(.notWritten), at: 201)
    #expect(RowNote.reply(failed, agent: .claude)?.text == "Not delivered · reply in Claude")
    #expect(RowNote.reply(failed, agent: .claude)?.offersOpen == true)
}

// MARK: Sending acknowledges nothing

private func timestamp(_ seconds: Double) -> String { RolloutTimestamp.format(seconds) }

@Test func onlyTheTurnTheReplyStartsAcknowledgesTheResult() {
    // The app's path: each scan acknowledges what `CodexReplyAcknowledgment` returns and dismisses it.
    func scan(_ queue: inout AttentionQueue, events: [CLIEvent]) {
        for id in CodexReplyAcknowledgment.acknowledged(queue.items.compactMap(\.completion), events: events, cliSessions: []) {
            queue.dismiss(.completion(id))
        }
    }
    var queue = AttentionQueue()
    queue.apply(completions: [completion()])
    let sent = SessionReplyProgress(completion: completion().id).startingSend(text: "now add tests", at: 200)
        .recordingSent(at: 200)
    #expect(ResultCardReply.foldsCard(before: .ready, after: sent.phase))
    // Sent and folded, but no turn start yet: the result stays queued.
    scan(&queue, events: [])
    #expect(queue.items.contains { $0.id == .completion(completion().id) })
    // A turn start before the result arrived is not the reply's and acknowledges nothing.
    scan(&queue, events: [.turnStarted(session: session, turn: turn, receivedAt: timestamp(90))])
    #expect(queue.items.contains { $0.id == .completion(completion().id) })
    // The turn the reply started, at or after the send, acknowledges it.
    let replyTurn = UUID(uuidString: "01A09DC4-1F22-7AA4-8C31-5B71A0C24D10")!
    scan(&queue, events: [.turnStarted(session: session, turn: replyTurn, receivedAt: timestamp(200))])
    #expect(queue.items.contains { $0.id == .completion(completion().id) } == false)
    #expect(queue.acknowledgedCompletions.contains(completion().id))
}

@Test func sendingFromTheResultCardLeavesTheResultQueued() {
    var queue = AgentAttentionQueue()
    let outcome = AgentOutcome(session: claude, turn: "t-1", status: .finished, arrivedAt: 100)
    queue.apply(.outcome(outcome))
    let sent = ReplyProgress(completion: outcome.id).startingSend(text: "now add tests", route: .terminal(pane))
        .settling(.sent, at: 101)
    // The note and the fold are presentation only: the result stays until its turn start, a visit or Dismiss.
    #expect(RowNote.reply(sent, agent: .claude) != nil)
    #expect(ResultCardReply.foldsCard(before: .ready, after: sent.phase))
    #expect(queue.snapshot.outcomes.contains { $0.id == outcome.id })
}

@Test func aReplyNoteIsNeverWrittenIntoTheRequestNotes() {
    // Request notes take approvals and questions only; a result's note comes from its card's reply alone.
    var notes = RowNotes()
    let id = AgentAttentionID.outcome(AgentTurnIdentity(session: claude, turn: "t-1"))
    #expect(notes.record(.replyNotDelivered(.claude), for: id, pending: [id]) == false)
    #expect(notes.note(for: id) == nil)
}

// MARK: The message and "Show all"

@Test func aMessageWithinFiveLinesHasNothingMoreToShow() {
    let preview = CompletionPreview("Snapshots now write to a temp file and rename into place.\nAll 214 tests pass.")
    #expect(preview?.truncated == false)
    #expect(preview?.extent == .whole)
}

@Test func aTruncatedMessageKeepsItsFullTextForShowAll() {
    let message = (1...8).map { "Line \($0) of the answer." }.joined(separator: "\n")
    let preview = CompletionPreview(message)
    #expect(preview?.truncated == true)
    #expect(preview?.text.hasSuffix("…") == true)
    #expect(preview?.extent == .cut(full: message))
}

@Test func theFullMessageIsCappedAndSaysSo() {
    #expect(CompletionPreview.maximumFullCharacters == 20_000)
    let long = String(repeating: "a", count: 25_000)
    let preview = CompletionPreview(long)
    #expect(preview?.truncated == true)
    #expect(preview?.extent == .cutAndCapped(full: String(repeating: "a", count: 20_000)))
    // Exactly at the cap is the whole message.
    let atCap = String(repeating: "b", count: 20_000)
    #expect(CompletionPreview(atCap)?.extent == .cut(full: atCap))
}

// MARK: No pop

@Test func onlyAFreshResultPops() {
    let launchedAt = 1_000.0
    let fresh = AgentOutcome(session: claude, turn: "t-1", status: .finished, arrivedAt: 1_000)
    #expect(ResultPop.isFresh(fresh, launchedAt: launchedAt))
    // Arrived before Herdly last started: queued silently.
    let before = AgentOutcome(session: claude, turn: "t-2", status: .finished, arrivedAt: 999.9)
    #expect(ResultPop.isFresh(before, launchedAt: launchedAt) == false)
    // Restored after a restart: Herdly cannot tell whether it was seen, so it never pops.
    let restored = AgentOutcome(session: claude, turn: "t-3", status: .finished, arrivedAt: 1_200, uncertain: true)
    #expect(ResultPop.isFresh(restored, launchedAt: launchedAt) == false)
}

// MARK: No pop while the session's Ghostty tab is in front (ADR 0016)

private let claudeID = "0f3c2a1b-4d5e-4f60-8a7b-9c0d1e2f3a4b"
private let claudeTab = AgentSessionIdentity(source: .claude, sourceScope: "/Users/me/.claude", session: claudeID, surface: .cli)

/// One window: t-1 holds the Codex session's title, t-2 a shell, t-3 the Claude session's title.
private func ghostty(selected: String?) throws -> GhosttySnapshot {
    let terminals = ["t-1": GhosttyMatch.title(session), "t-2": "shell", "t-3": GhosttyMatch.claudeTitle(claudeID)!]
    let data: [String: Any] = [
        "status": "ok", "front_window_id": "w",
        "windows": [["id": "w", "tabs": terminals.keys.sorted().map { tab in
            ["id": tab, "terminals": [["id": "p" + tab, "name": terminals[tab]!]]] as [String: Any]
        }]],
        "selected": selected.map { ["window_id": "w", "tab_id": $0, "terminal_id": "p" + $0] as Any } ?? NSNull()
    ]
    return try JSONDecoder().decode(GhosttySnapshot.self, from: JSONSerialization.data(withJSONObject: data))
}

private func codexAllows(_ snapshot: GhosttySnapshot?, session id: UUID = session) -> Bool {
    ResultPop.ghosttyAllows(source: .cli, session: id, ghosttyEnabled: true, live: [id], snapshot: snapshot)
}

private func claudeAllows(_ snapshot: GhosttySnapshot?, enabled: Bool = true) -> Bool {
    ResultPop.claudeGhosttyAllows(claudeTab, ghosttyEnabled: enabled, liveSessionsByScope: [claudeTab.sourceScope: [claudeID]],
                                  inventoryAvailable: [claudeTab.sourceScope: true],
                                  configuredScopes: [claudeTab.sourceScope], snapshot: snapshot)
}

@Test func aCLIResultWhoseGhosttyTabIsInFrontDoesNotPop() throws {
    #expect(codexAllows(try ghostty(selected: "t-1")) == false)
    // Another tab in front: it pops.
    #expect(codexAllows(try ghostty(selected: "t-2")))
}

@Test func aCLIResultWithNoGhosttyTabOrGhosttyNotInFrontPops() throws {
    // A session in another terminal (iTerm2, tmux, herdr) has no Ghostty tab: nothing of it is visible here.
    let other = UUID(uuidString: "01A09DC4-1F22-7AA4-8C31-5B71A0C24D10")!
    #expect(codexAllows(try ghostty(selected: "t-2"), session: other))
    // Ghostty reports no selected tab while another app is in front: nothing in Ghostty is visible.
    #expect(codexAllows(try ghostty(selected: nil)))
}

@Test func aCLIResultWaitsOnlyWhileGhosttyIsBeingRead() {
    let id = session
    // A read in flight: not now. The fresh result stays a candidate and can pop once it lands.
    #expect(ResultPop.ghosttyAllows(source: .cli, session: id, ghosttyEnabled: true, live: [id], snapshot: nil,
                                    reading: true) == false)
    // Ghostty unreadable or not running: nothing visible is known, so it pops.
    #expect(ResultPop.ghosttyAllows(source: .cli, session: id, ghosttyEnabled: true, live: [id], snapshot: nil,
                                    reading: false))
}

@Test func ghosttyIsNotConsultedWhenOffOrForTheCodexApp() throws {
    let inFront = try ghostty(selected: "t-1")
    #expect(ResultPop.ghosttyAllows(source: .cli, session: session, ghosttyEnabled: false, live: [session], snapshot: inFront))
    #expect(ResultPop.ghosttyAllows(source: .desktop, session: session, ghosttyEnabled: true, live: [session], snapshot: nil))
}

@Test func aClaudeResultWhoseGhosttyTabIsInFrontDoesNotPop() throws {
    #expect(claudeAllows(try ghostty(selected: "t-3")) == false)
    #expect(claudeAllows(try ghostty(selected: "t-1")))
    #expect(claudeAllows(try ghostty(selected: nil)))
}

@Test func aClaudeResultPopsWithoutAGhosttyReadingOrBinding() throws {
    // Claude results never waited for Ghostty: with no reading, or with Ghostty off, they pop as before.
    #expect(claudeAllows(nil))
    #expect(claudeAllows(try ghostty(selected: "t-3"), enabled: false))
    // Incomplete inventories give no exact tab, so nothing is known visible: it pops.
    let unbound = ResultPop.claudeGhosttyAllows(claudeTab, ghosttyEnabled: true, liveSessionsByScope: [:], inventoryAvailable: [:],
                                                configuredScopes: [claudeTab.sourceScope], snapshot: try ghostty(selected: "t-3"))
    #expect(unbound)
}

// MARK: The full response setting

@Test func theSettingSetsHowEveryResponseStartsAndShowAllFlipsOnlyThatCard() {
    let cut = CompletionPreview.Extent.cut(full: "1\n2\n3\n4\n5\n6")
    #expect(ResultCardMessage.showsWhole(cut, showsFullResponse: true, flipped: false))
    #expect(!ResultCardMessage.showsWhole(cut, showsFullResponse: true, flipped: true))
    #expect(!ResultCardMessage.showsWhole(cut, showsFullResponse: false, flipped: false))
    #expect(ResultCardMessage.showsWhole(cut, showsFullResponse: false, flipped: true))
}

@Test func aMessageTheCutLeftWholeHasNothingToFold() {
    #expect(ResultCardMessage.showsWhole(.whole, showsFullResponse: false, flipped: false))
}
