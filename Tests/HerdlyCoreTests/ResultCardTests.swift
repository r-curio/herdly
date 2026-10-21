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
    #expect(preview?.full == nil)
    #expect(preview?.fullShortened == false)
}

@Test func aTruncatedMessageKeepsItsFullTextForShowAll() {
    let message = (1...8).map { "Line \($0) of the answer." }.joined(separator: "\n")
    let preview = CompletionPreview(message)
    #expect(preview?.truncated == true)
    #expect(preview?.text.hasSuffix("…") == true)
    #expect(preview?.full == message)
    #expect(preview?.fullShortened == false)
}

@Test func theFullMessageIsCappedAndSaysSo() {
    #expect(CompletionPreview.maximumFullCharacters == 20_000)
    let long = String(repeating: "a", count: 25_000)
    let preview = CompletionPreview(long)
    #expect(preview?.truncated == true)
    #expect(preview?.full?.count == 20_000)
    #expect(preview?.fullShortened == true)
    // Exactly at the cap is the whole message.
    let atCap = CompletionPreview(String(repeating: "b", count: 20_000))
    #expect(atCap?.full?.count == 20_000)
    #expect(atCap?.fullShortened == false)
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
