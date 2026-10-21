import Foundation

/// The short line a queue row carries after the user approves, denies, or answers it from the
/// notch (D10). It says only what Herdly knows about delivery; it never says Codex or Claude acted.
/// The copy is exactly the agreed strings.
public enum RowNote: Equatable, Sendable {
    /// Herdly is sending the decision or answer.
    case sending
    /// Claude's helper confirmed it received this one-time approval.
    case approvalReceived
    /// Herdly wrote it, or it may have been written, but no confirmation came back.
    case sentUnconfirmed
    /// Claude could not receive it; the user answers in Claude, so the row offers Open.
    case notDelivered
    /// A Codex question answer left Herdly; Codex has not recorded it yet.
    case awaitingCodex
    /// The key for an earlier question of a call (zero-based `question` of `of`) was written to the
    /// session; the session should now show the next one (#321). Recorded only for a key Herdly
    /// reports sent, and only for a question.
    case keySent(question: Int, of: Int)

    public var text: String {
        switch self {
        case .sending: return "Sending…"
        case .approvalReceived: return "Claude got your approval"
        case .sentUnconfirmed: return "Sent, not confirmed"
        case .notDelivered: return "Not delivered · answer in Claude"
        case .awaitingCodex: return "Sent, waiting for Codex"
        case let .keySent(question, count): return "Sent \(question + 1) of \(count), on question \(question + 2)"
        }
    }

    /// Whether the row offers Open beside the note.
    public var offersOpen: Bool { self == .notDelivered }
}

/// One change to a request's row note.
public enum RowNoteUpdate: Equatable, Sendable {
    case record(RowNote)
    /// Matching resolution evidence: the note clears and never returns.
    case resolve
    /// Nothing was sent: the note goes, and a later send may note again.
    case withdraw
    case unchanged
}

extension RowNoteUpdate {
    /// A Claude approval decision's delivery settled. Delivery counts only when the decision was
    /// published and the helper confirmed it. A confirmed denial is resolution evidence for the call
    /// (there is no agreed note for it), so its note clears; a no-decision release changes nothing.
    public static func claudeDecision(_ decision: ApprovalDecision, published: Bool, delivered: Bool) -> Self {
        guard decision.isUserDecision else { return .unchanged }
        guard published else { return .record(.notDelivered) }
        guard delivered else { return .record(.sentUnconfirmed) }
        return decision == .allowOnce ? .record(.approvalReceived) : .resolve
    }

    /// A Claude question answer's delivery settled. The helper's confirmation is resolution evidence
    /// for the call, so the note clears.
    public static func claudeAnswer(published: Bool, delivered: Bool) -> Self {
        guard published else { return .record(.notDelivered) }
        return delivered ? .resolve : .record(.sentUnconfirmed)
    }

    /// The daemon's one write of a whole Codex answer. Nothing written withdraws the note.
    public static func codexDaemonAnswer(sent: Bool) -> Self {
        sent ? .record(.awaitingCodex) : .withdraw
    }

    /// A Codex question's digit is about to be typed. Only the final question of the call notes and
    /// leaves the clicked card; an earlier question's key keeps the card open and notes once it settles.
    public static func codexKeySending(final: Bool) -> Self {
        final ? .record(.sending) : .unchanged
    }

    /// A typed digit for zero-based question `index` of a `count`-question call settled (herdr, tmux,
    /// Zellij, WezTerm). Written → waiting for Codex, or for an earlier question "Sent k of n, on
    /// question k+1"; may have been written → not confirmed; nothing written, or vetoed → withdrawn.
    public static func codexKeyAnswer(_ outcome: HerdrQuestionRelay.Outcome, question index: Int, of count: Int) -> Self {
        switch outcome {
        case .delivered(.queued): return written(question: index, of: count)
        case .delivered(.possiblySent): return .record(.sentUnconfirmed)
        case .delivered(.notSent), .vetoed: return .withdraw
        }
    }

    /// A Ghostty digit settled: Ghostty reports only whether it sent the key.
    public static func ghosttyKeyAnswer(sent: Bool, question index: Int, of count: Int) -> Self {
        sent ? written(question: index, of: count) : .withdraw
    }

    private static func written(question index: Int, of count: Int) -> Self {
        index == max(1, count) - 1 ? .record(.awaitingCodex) : .record(.keySent(question: index, of: count))
    }

    /// A Claude approval decision whose root, receipt or scan changed before its result came back:
    /// receipt cannot be verified. Written → not confirmed; nothing written → the note is withdrawn.
    public static func claudeDecisionUnverified(published: Bool) -> Self {
        published ? .record(.sentUnconfirmed) : .withdraw
    }
}

/// Row notes by the exact request identity (source, scope, session, turn and call). A note is
/// recorded only for an approval or question the queue still holds, clears only when that exact
/// request leaves the queue or resolves, and once cleared never returns for the same identity, so
/// a late or duplicate delivery result cannot resurrect it. Process memory only.
public struct RowNotes: Equatable, Sendable {
    private var notes: [AgentAttentionID: RowNote] = [:]
    /// Identities whose note cleared on resolution; they never take a note again.
    private var cleared: Set<AgentAttentionID> = []

    public init() {}

    public var isEmpty: Bool { notes.isEmpty }

    public func note(for id: AgentAttentionID) -> RowNote? { notes[id] }

    /// Records `note` for `id` when `id` is an approval or question in `pending` that has not
    /// already cleared. A receipt note is accepted only for an approval.
    @discardableResult
    public mutating func record(_ note: RowNote, for id: AgentAttentionID, pending: Set<AgentAttentionID>) -> Bool {
        guard id.isRequest, pending.contains(id), !cleared.contains(id) else { return false }
        if note == .approvalReceived, case .question = id { return false }
        if case .keySent = note, case .approval = id { return false }
        notes[id] = note
        return true
    }

    /// Applies one update; true only when it recorded a note.
    @discardableResult
    public mutating func apply(_ update: RowNoteUpdate, for id: AgentAttentionID, pending: Set<AgentAttentionID>) -> Bool {
        switch update {
        case let .record(note): return record(note, for: id, pending: pending)
        case .resolve: resolve(id)
        case .withdraw: withdraw(id)
        case .unchanged: break
        }
        return false
    }

    /// Clears the notes of requests the queue no longer holds; every other note stays.
    public mutating func reconcile(pending: Set<AgentAttentionID>) {
        for id in notes.keys where !pending.contains(id) { resolve(id) }
    }

    /// Matching resolution evidence for exactly this request.
    public mutating func resolve(_ id: AgentAttentionID) {
        notes.removeValue(forKey: id)
        cleared.insert(id)
    }

    /// Nothing was sent (a send refused or failed before leaving Herdly): the note goes without
    /// counting as resolution, so a later send may note again.
    public mutating func withdraw(_ id: AgentAttentionID) {
        notes.removeValue(forKey: id)
    }
}
