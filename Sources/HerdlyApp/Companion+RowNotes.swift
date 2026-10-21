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

    /// A Codex question's note identity, as the source-neutral queue holds it.
    static func codexQuestionNoteID(_ question: AttentionQuestion) -> AgentAttentionID {
        .question(CodexAttentionAdapter.question(from: question).id)
    }

    /// A typed digit for question `index` is about to be sent (Ghostty, herdr, tmux, Zellij, WezTerm).
    /// Only the call's final question notes and leaves the clicked card.
    func noteCodexKeySending(_ question: AttentionQuestion, index: Int) {
        updateRowNote(.codexKeySending(final: question.isFinalQuestion(index)), for: Self.codexQuestionNoteID(question),
                      userAction: true)
    }

    /// A typed digit settled (herdr, tmux, Zellij, WezTerm). An earlier question's key notes "Sent k
    /// of n, on question k+1" without leaving the card, since the user is still answering on it.
    func noteCodexKeyAnswer(_ question: AttentionQuestion, index: Int, outcome: HerdrQuestionRelay.Outcome) {
        updateRowNote(.codexKeyAnswer(outcome, question: index, of: question.questionCount),
                      for: Self.codexQuestionNoteID(question))
    }
}
