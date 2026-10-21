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

@Test func rowNotesReadExactlyAsAgreed() {
    #expect(RowNote.sending.text == "Sending…")
    #expect(RowNote.delivered(.allowOnce).text == "Claude got your approval")
    #expect(RowNote.sentUnconfirmed.text == "Sent, not confirmed")
    #expect(RowNote.notDelivered.text == "Not delivered · answer in Claude")
    #expect(RowNote.awaitingCodex.text == "Sent, waiting for Codex")
    #expect(RowNote.notDelivered.offersOpen)
    #expect(!RowNote.sending.offersOpen)
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
    do { let result = notes.record(.delivered(.allowOnce), for: approval, pending: [approval]); #expect(!result) }
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
    #expect(RowNote.claudeDecision(.allowOnce, published: false, delivered: true) == .notDelivered)
    #expect(RowNote.claudeDecision(.allowOnce, published: true, delivered: false) == .sentUnconfirmed)
    #expect(RowNote.claudeDecision(.allowOnce, published: true, delivered: true) == .delivered(.allowOnce))
    #expect(RowNote.claudeDecision(.deny, published: true, delivered: true) == .delivered(.deny))
    // A no-decision release is never the user's decision.
    #expect(RowNote.claudeDecision(.noDecision, published: true, delivered: true) == nil)

    var notes = RowNotes()
    // Not a request at all.
    let outcome = AgentAttentionID.outcome(AgentTurnIdentity(session: claude, turn: "t1"))
    do { let result = notes.record(.delivered(.allowOnce), for: outcome, pending: [outcome]); #expect(!result) }
    // A request the queue does not hold.
    do { let result = notes.record(.delivered(.allowOnce), for: approval, pending: []); #expect(!result) }
    #expect(notes.note(for: approval) == nil)
    // A confirmation names only an approval decision; a question never gets one.
    do { let result = notes.record(.delivered(.allowOnce), for: question, pending: [question]); #expect(!result) }
    do { let result = notes.record(.delivered(.noDecision), for: approval, pending: [approval]); #expect(!result) }
    #expect(notes.note(for: question) == nil)
}

@Test func aCodexKeyOrDaemonSendNotesOnlyWhatWasSent() {
    #expect(RowNote.codexAnswer(sent: true) == .awaitingCodex)
    #expect(RowNote.codexAnswer(sent: false) == nil)
    #expect(RowNote.claudeAnswer(published: false, delivered: true) == .notDelivered)
    #expect(RowNote.claudeAnswer(published: true, delivered: false) == .sentUnconfirmed)
    // Claude's helper confirming the answer is resolution evidence for that call: no note remains.
    #expect(RowNote.claudeAnswer(published: true, delivered: true) == nil)
}
