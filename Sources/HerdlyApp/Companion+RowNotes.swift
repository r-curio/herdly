import Foundation
import HerdlyCore

/// Row notes (D10): the short delivery line a queue row carries after the user approves, denies,
/// or answers it from the notch. Keyed by the exact request identity; see `RowNotes`.
extension Companion {
    /// Approvals and questions the queue holds now: the only identities a note may be written for.
    var rowNotePendingIDs: Set<AgentAttentionID> {
        Set(agentQueue.items(at: Date().timeIntervalSince1970).lazy.map(\.id).filter(\.isRequest))
    }

    func rowNote(for id: AgentAttentionID) -> RowNote? { rowNotes.note(for: id) }

    /// Applies one note update. `userAction` marks the update written by the user's own Approve, Deny
    /// or Send: when it records a note on the clicked card, the card returns to the queue where the
    /// note shows. A delivery result settling later never moves the user off a card they reopened.
    /// The caller refreshes.
    func updateRowNote(_ update: RowNoteUpdate, for id: AgentAttentionID, userAction: Bool = false) {
        var next = rowNotes
        let recorded = next.apply(update, for: id, pending: rowNotePendingIDs)
        if next != rowNotes { rowNotes = next }
        if recorded && userAction { leaveClickedCard(after: id) }
    }

    /// Clears the notes of requests that have left the queue; called on every refresh.
    func pruneRowNotes() {
        guard !rowNotes.isEmpty else { return }
        var next = rowNotes
        next.reconcile(pending: rowNotePendingIDs)
        if next != rowNotes { rowNotes = next }
    }

    static func rowNoteID(_ question: AttentionQuestion) -> AgentAttentionID {
        .question(CodexAttentionAdapter.question(from: question).id)
    }
}
