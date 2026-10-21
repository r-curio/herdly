import Foundation
import Testing
@testable import HerdlyCore

private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/claude", session: "s1", surface: .cli)
private let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s1", surface: .cli)
private let approval = AgentAttentionID.approval(AgentCallIdentity(session: claude, turn: "t1", call: "toolu_1"))
/// Same session and turn, another call.
private let sibling = AgentAttentionID.approval(AgentCallIdentity(session: claude, turn: "t1", call: "toolu_2"))
/// Same session id and call id under another source.
private let otherSource = AgentAttentionID.approval(AgentCallIdentity(session: codex, turn: "t1", call: "toolu_1"))
private let question = AgentAttentionID.question(AgentCallIdentity(session: codex, turn: "t2", call: "call_1"))

@Test func rowNotesReadExactlyTheAgreedStrings() {
    let fixed: [RowNote] = [.sending, .approvalReceived, .sentUnconfirmed, .notDelivered, .awaitingCodex]
    #expect(fixed.map(\.text) == ["Sending…", "Claude got your approval", "Sent, not confirmed",
                                  "Not delivered · answer in Claude", "Sent, waiting for Codex"])
    // An earlier question's key (#321): "Sent k of n, on question k+1".
    #expect(RowNote.keySent(question: 0, of: 3).text == "Sent 1 of 3, on question 2")
    #expect(RowNote.keySent(question: 1, of: 3).text == "Sent 2 of 3, on question 3")
    #expect(RowNote.notDelivered.offersOpen)
    #expect((fixed + [.keySent(question: 0, of: 2)]).filter(\.offersOpen) == [.notDelivered])
}

@Test func notesAreIsolatedPerExactRequestIdentity() {
    var notes = RowNotes()
    let pending: Set<AgentAttentionID> = [approval, sibling, otherSource, question]
    do { let result = notes.record(.sending, for: approval, pending: pending); #expect(result) }
    do { let result = notes.record(.awaitingCodex, for: question, pending: pending); #expect(result) }
    #expect(notes.note(for: approval) == .sending)
    #expect(notes.note(for: sibling) == nil)
    #expect(notes.note(for: otherSource) == nil)

    // Resolving the sibling touches nothing else.
    notes.reconcile(pending: [approval, otherSource, question])
    #expect(notes.note(for: approval) == .sending)
    #expect(notes.note(for: question) == .awaitingCodex)
}

@Test func aNoteClearsOnlyWhenItsOwnRequestResolves() {
    var notes = RowNotes()
    notes.record(.sentUnconfirmed, for: approval, pending: [approval, question])
    notes.record(.awaitingCodex, for: question, pending: [approval, question])
    notes.reconcile(pending: [approval, question])
    #expect(notes.note(for: approval) == .sentUnconfirmed)

    notes.resolve(question)
    #expect(notes.note(for: question) == nil)
    #expect(notes.note(for: approval) == .sentUnconfirmed)

    notes.reconcile(pending: [question])
    #expect(notes.note(for: approval) == nil)
}

@Test func aLateOrDuplicateEventNeverResurrectsAClearedNote() {
    var notes = RowNotes()
    notes.record(.sending, for: approval, pending: [approval])
    notes.reconcile(pending: [])
    // A delivery result arriving after the request cleared, even with the request reappearing in a
    // stale scan, does not bring the note back.
    do { let result = notes.record(.approvalReceived, for: approval, pending: [approval]); #expect(!result) }
    #expect(notes.note(for: approval) == nil)

    notes.record(.awaitingCodex, for: question, pending: [question])
    notes.resolve(question)
    notes.resolve(question)
    do { let result = notes.record(.awaitingCodex, for: question, pending: [question]); #expect(!result) }
    #expect(notes.note(for: question) == nil)
}

@Test func aDuplicateSameNoteKeepsTheNoteAndAWithdrawnSendCanBeRetried() {
    var notes = RowNotes()
    notes.record(.sending, for: question, pending: [question])
    notes.record(.sending, for: question, pending: [question])
    #expect(notes.note(for: question) == .sending)
    // Nothing was sent: the note goes, and a later send may note again.
    notes.withdraw(question)
    #expect(notes.note(for: question) == nil)
    do { let result = notes.record(.sending, for: question, pending: [question]); #expect(result) }
}

@Test func malformedOrPartialInputNeverCreatesANoteImplyingDelivery() {
    // Delivery without publication is contradictory: treat it as not delivered.
    #expect(RowNoteUpdate.claudeDecision(.allowOnce, published: false, delivered: true) == .record(.notDelivered))
    #expect(RowNoteUpdate.claudeDecision(.allowOnce, published: true, delivered: false) == .record(.sentUnconfirmed))
    #expect(RowNoteUpdate.claudeDecision(.allowOnce, published: true, delivered: true) == .record(.approvalReceived))
    // A no-decision release is never the user's decision and changes no note.
    #expect(RowNoteUpdate.claudeDecision(.noDecision, published: true, delivered: true) == .unchanged)

    var notes = RowNotes()
    // Not a request at all.
    let outcome = AgentAttentionID.outcome(AgentTurnIdentity(session: claude, turn: "t1"))
    do { let recorded = notes.record(.approvalReceived, for: outcome, pending: [outcome]); #expect(!recorded) }
    // A request the queue does not hold.
    do { let recorded = notes.record(.approvalReceived, for: approval, pending: []); #expect(!recorded) }
    #expect(notes.note(for: approval) == nil)
    // A receipt names only an approval; a question never gets one.
    do { let recorded = notes.record(.approvalReceived, for: question, pending: [question]); #expect(!recorded) }
    #expect(notes.note(for: question) == nil)
}

@Test func aConfirmedDenyIsResolutionEvidenceAndClearsTheNote() {
    #expect(RowNoteUpdate.claudeDecision(.deny, published: true, delivered: true) == .resolve)
    #expect(RowNoteUpdate.claudeDecision(.deny, published: true, delivered: false) == .record(.sentUnconfirmed))
    var notes = RowNotes()
    notes.record(.sending, for: approval, pending: [approval])
    notes.apply(RowNoteUpdate.claudeDecision(.deny, published: true, delivered: true), for: approval, pending: [approval])
    #expect(notes.note(for: approval) == nil)
    // A late duplicate confirmation cannot bring a note back.
    notes.apply(.record(.sentUnconfirmed), for: approval, pending: [approval])
    #expect(notes.note(for: approval) == nil)
}

@Test func aClaudeAnswerAndADaemonAnswerNoteOnlyWhatWasSent() {
    #expect(RowNoteUpdate.claudeAnswer(published: false, delivered: true) == .record(.notDelivered))
    #expect(RowNoteUpdate.claudeAnswer(published: true, delivered: false) == .record(.sentUnconfirmed))
    // Claude's helper confirming the answer is resolution evidence for that call: no note remains.
    #expect(RowNoteUpdate.claudeAnswer(published: true, delivered: true) == .resolve)
    #expect(RowNoteUpdate.codexDaemonAnswer(sent: true) == .record(.awaitingCodex))
    #expect(RowNoteUpdate.codexDaemonAnswer(sent: false) == .withdraw)
}

@Test func onlyTheFinalQuestionOfAKeyedSetNotesAndAKeyThatMayHaveBeenWrittenIsUnconfirmed() {
    let three = AttentionQuestion(source: .cli, session: UUID(), turn: UUID(), callID: "c", arrivedAt: 0, questionCount: 3)
    #expect(!three.isFinalQuestion(0))
    #expect(!three.isFinalQuestion(1))
    #expect(three.isFinalQuestion(2))
    #expect(!three.isFinalQuestion(3))
    #expect(!three.isFinalQuestion(-1))
    let one = AttentionQuestion(source: .cli, session: UUID(), turn: UUID(), callID: "c", arrivedAt: 0)
    #expect(one.isFinalQuestion(0))

    // A non-final key notes nothing while it is in flight, so the card stays open.
    #expect(RowNoteUpdate.codexKeySending(final: false) == .unchanged)
    #expect(RowNoteUpdate.codexKeySending(final: true) == .record(.sending))
    // A non-final key Herdly reports written: "Sent k of n, on question k+1"; one that may have been
    // written is not confirmed; one not sent withdraws any note. A note never claims undelivered keys.
    #expect(RowNoteUpdate.codexKeyAnswer(.delivered(.queued), question: 0, of: 3) == .record(.keySent(question: 0, of: 3)))
    #expect(RowNoteUpdate.codexKeyAnswer(.delivered(.queued), question: 1, of: 3) == .record(.keySent(question: 1, of: 3)))
    #expect(RowNoteUpdate.codexKeyAnswer(.delivered(.possiblySent(.timeout)), question: 0, of: 3) == .record(.sentUnconfirmed))
    #expect(RowNoteUpdate.codexKeyAnswer(.delivered(.notSent(.notRunning)), question: 0, of: 3) == .withdraw)
    #expect(RowNoteUpdate.codexKeyAnswer(.vetoed(.leftHerdr), question: 0, of: 3) == .withdraw)
    // Final key: written → waiting for Codex; may have been written → not confirmed; nothing sent → withdrawn.
    #expect(RowNoteUpdate.codexKeyAnswer(.delivered(.queued), question: 2, of: 3) == .record(.awaitingCodex))
    #expect(RowNoteUpdate.codexKeyAnswer(.delivered(.possiblySent(.timeout)), question: 2, of: 3) == .record(.sentUnconfirmed))
    #expect(RowNoteUpdate.codexKeyAnswer(.delivered(.notSent(.notRunning)), question: 2, of: 3) == .withdraw)
    #expect(RowNoteUpdate.codexKeyAnswer(.vetoed(.leftHerdr), question: 2, of: 3) == .withdraw)
    #expect(RowNoteUpdate.codexKeyAnswer(.delivered(.queued), question: 0, of: 1) == .record(.awaitingCodex))
    #expect(RowNoteUpdate.ghosttyKeyAnswer(sent: true, question: 2, of: 3) == .record(.awaitingCodex))
    #expect(RowNoteUpdate.ghosttyKeyAnswer(sent: true, question: 0, of: 3) == .record(.keySent(question: 0, of: 3)))
    #expect(RowNoteUpdate.ghosttyKeyAnswer(sent: false, question: 0, of: 3) == .withdraw)
    #expect(RowNoteUpdate.ghosttyKeyAnswer(sent: false, question: 2, of: 3) == .withdraw)
}

@Test func anEarlierKeysNoteIsForAQuestionOnlyAndALaterKeyReplacesIt() {
    var notes = RowNotes()
    let pending: Set<AgentAttentionID> = [approval, question]
    do { let result = notes.record(.keySent(question: 0, of: 2), for: approval, pending: pending); #expect(!result) }
    do { let result = notes.record(.keySent(question: 0, of: 2), for: question, pending: pending); #expect(result) }
    #expect(notes.note(for: question)?.text == "Sent 1 of 2, on question 2")
    notes.apply(.record(.awaitingCodex), for: question, pending: pending)
    #expect(notes.note(for: question) == .awaitingCodex)
}

@Test func aClaudeDecisionWhoseCheckGoesStaleSettlesByWhatWasWritten() {
    // The root, receipt or scan changed before the result came back: Herdly cannot verify receipt.
    #expect(RowNoteUpdate.claudeDecisionUnverified(published: true) == .record(.sentUnconfirmed))
    #expect(RowNoteUpdate.claudeDecisionUnverified(published: false) == .withdraw)
    var notes = RowNotes()
    notes.record(.sending, for: approval, pending: [approval])
    notes.apply(RowNoteUpdate.claudeDecisionUnverified(published: true), for: approval, pending: [approval])
    #expect(notes.note(for: approval) == .sentUnconfirmed)
    notes.apply(RowNoteUpdate.claudeDecisionUnverified(published: false), for: approval, pending: [approval])
    #expect(notes.note(for: approval) == nil)
}
