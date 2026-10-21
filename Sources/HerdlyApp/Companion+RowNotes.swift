import Foundation
import HerdlyCore

/// Row notes (D10): the short delivery line a queue row carries after the user approves, denies,
/// or answers it from the notch. Keyed by the exact request identity; see `RowNotes`.
extension Companion {
    /// Approvals and questions the queue holds now: the only identities a note may be written for.
    var rowNotePendingIDs: Set<AgentAttentionID> {
        Set(agentQueue.items(at: Date().timeIntervalSince1970).lazy.map(\.id).filter { id in
            switch id {
            case .approval, .question: return true
            case .outcome, .running, .unavailable: return false
            }
        })
    }

    func rowNote(for id: AgentAttentionID) -> RowNote? { rowNotes.note(for: id) }

    /// Records the note. `userAction` marks the note written by the user's own Approve, Deny or Send:
    /// on the clicked card it returns to the queue where the note shows. A delivery result settling
    /// later never moves the user off a card they reopened.
    func recordRowNote(_ note: RowNote, for id: AgentAttentionID, userAction: Bool = true) {
        var next = rowNotes
        guard next.record(note, for: id, pending: rowNotePendingIDs) else { return }
        if next != rowNotes { rowNotes = next }
        if userAction { leaveClickedCard(after: id) }
    }

    /// Records `note`, or with nil treats the settled delivery as resolution evidence for `id`.
    func settleRowNote(_ note: RowNote?, for id: AgentAttentionID, userAction: Bool = false) {
        if let note {
            recordRowNote(note, for: id, userAction: userAction)
        } else {
            var next = rowNotes
            next.resolve(id)
            if next != rowNotes { rowNotes = next }
        }
    }

    /// Clears the notes of requests that have left the queue; called on every refresh.
    func pruneRowNotes() {
        guard !rowNotes.isEmpty else { return }
        var next = rowNotes
        next.reconcile(pending: rowNotePendingIDs)
        if next != rowNotes { rowNotes = next }
    }

    private static func noteID(_ question: AttentionQuestion) -> AgentAttentionID {
        .question(CodexAttentionAdapter.question(from: question).id)
    }

    /// A Codex question's digit or daemon answer is about to leave Herdly.
    func noteCodexAnswerSending(_ question: AttentionQuestion) {
        recordRowNote(.sending, for: Self.noteID(question))
    }

    /// The send settled. Nothing sent withdraws the note; a later send may note again. `userAction`
    /// is true only where this is the first note of the user's Send (the daemon's one write).
    func noteCodexAnswer(_ question: AttentionQuestion, sent: Bool, userAction: Bool = false) {
        let id = Self.noteID(question)
        if let note = RowNote.codexAnswer(sent: sent) {
            recordRowNote(note, for: id, userAction: userAction)
        } else {
            var next = rowNotes
            next.withdraw(id)
            if next != rowNotes { rowNotes = next }
        }
    }
}
