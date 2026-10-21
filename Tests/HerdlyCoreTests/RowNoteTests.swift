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

@Test func rowNotesReadExactlyTheFiveAgreedStrings() {
    #expect(Set(RowNote.allCases.map(\.text)) == ["Sending…", "Claude got your approval", "Sent, not confirmed",
                                                  "Not delivered · answer in Claude", "Sent, waiting for Codex"])
    #expect(RowNote.allCases.count == 5)
    #expect(RowNote.notDelivered.offersOpen)
    #expect(RowNote.allCases.filter(\.offersOpen) == [.notDelivered])
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
    #expect(RowNote.claudeDecision(.allowOnce, published: false, delivered: true) == .record(.notDelivered))
    #expect(RowNote.claudeDecision(.allowOnce, published: true, delivered: false) == .record(.sentUnconfirmed))
    #expect(RowNote.claudeDecision(.allowOnce, published: true, delivered: true) == .record(.approvalReceived))
    // A no-decision release is never the user's decision and changes no note.
    #expect(RowNote.claudeDecision(.noDecision, published: true, delivered: true) == .unchanged)

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
    #expect(RowNote.claudeDecision(.deny, published: true, delivered: true) == .resolve)
    #expect(RowNote.claudeDecision(.deny, published: true, delivered: false) == .record(.sentUnconfirmed))
    var notes = RowNotes()
    notes.record(.sending, for: approval, pending: [approval])
    notes.apply(RowNote.claudeDecision(.deny, published: true, delivered: true), for: approval, pending: [approval])
    #expect(notes.note(for: approval) == nil)
    // A late duplicate confirmation cannot bring a note back.
    notes.apply(.record(.sentUnconfirmed), for: approval, pending: [approval])
    #expect(notes.note(for: approval) == nil)
}

@Test func aClaudeAnswerAndADaemonAnswerNoteOnlyWhatWasSent() {
    #expect(RowNote.claudeAnswer(published: false, delivered: true) == .record(.notDelivered))
    #expect(RowNote.claudeAnswer(published: true, delivered: false) == .record(.sentUnconfirmed))
    // Claude's helper confirming the answer is resolution evidence for that call: no note remains.
    #expect(RowNote.claudeAnswer(published: true, delivered: true) == .resolve)
    #expect(RowNote.codexDaemonAnswer(sent: true) == .record(.awaitingCodex))
    #expect(RowNote.codexDaemonAnswer(sent: false) == .withdraw)
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

    // A non-final key writes no note and leaves no card.
    #expect(RowNote.codexKeySending(final: false) == .unchanged)
    #expect(RowNote.codexKeySending(final: true) == .record(.sending))
    #expect(RowNote.codexKeyAnswer(.delivered(.queued), final: false) == .unchanged)
    #expect(RowNote.codexKeyAnswer(.delivered(.possiblySent(.timeout)), final: false) == .unchanged)
    // Final key: written → waiting for Codex; may have been written → not confirmed; nothing sent → withdrawn.
    #expect(RowNote.codexKeyAnswer(.delivered(.queued), final: true) == .record(.awaitingCodex))
    #expect(RowNote.codexKeyAnswer(.delivered(.possiblySent(.timeout)), final: true) == .record(.sentUnconfirmed))
    #expect(RowNote.codexKeyAnswer(.delivered(.notSent(.notRunning)), final: true) == .withdraw)
    #expect(RowNote.codexKeyAnswer(.vetoed(.leftHerdr), final: true) == .withdraw)
    #expect(RowNote.ghosttyKeyAnswer(sent: true, final: true) == .record(.awaitingCodex))
    #expect(RowNote.ghosttyKeyAnswer(sent: true, final: false) == .unchanged)
    #expect(RowNote.ghosttyKeyAnswer(sent: false, final: true) == .withdraw)
}
