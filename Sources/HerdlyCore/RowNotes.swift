import Foundation

/// The short line a queue row carries after the user approves, denies, or answers it from the
/// notch (D10). It says only what Herdly knows about delivery; it never says Codex or Claude acted.
/// The copy is exactly the five agreed strings.
public enum RowNote: Equatable, Sendable, CaseIterable {
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

    public var text: String {
        switch self {
        case .sending: return "Sending…"
        case .approvalReceived: return "Claude got your approval"
        case .sentUnconfirmed: return "Sent, not confirmed"
        case .notDelivered: return "Not delivered · answer in Claude"
        case .awaitingCodex: return "Sent, waiting for Codex"
        }
    }

    /// Whether the row offers Open beside the note.
    public var offersOpen: Bool { self == .notDelivered }

    /// A Claude approval decision's delivery settled. Delivery counts only when the decision was
    /// published and the helper confirmed it. A confirmed denial is resolution evidence for the call
    /// (there is no agreed note for it), so its note clears; a no-decision release changes nothing.
    public static func claudeDecision(_ decision: ApprovalDecision, published: Bool, delivered: Bool) -> RowNoteUpdate {
        guard decision.isUserDecision else { return .unchanged }
        guard published else { return .record(.notDelivered) }
        guard delivered else { return .record(.sentUnconfirmed) }
        return decision == .allowOnce ? .record(.approvalReceived) : .resolve
    }

    /// A Claude question answer's delivery settled. The helper's confirmation is resolution evidence
    /// for the call, so the note clears.
    public static func claudeAnswer(published: Bool, delivered: Bool) -> RowNoteUpdate {
        guard published else { return .record(.notDelivered) }
        return delivered ? .resolve : .record(.sentUnconfirmed)
    }

    /// The daemon's one write of a whole Codex answer. Nothing written withdraws the note.
    public static func codexDaemonAnswer(sent: Bool) -> RowNoteUpdate {
        sent ? .record(.awaitingCodex) : .withdraw
    }

    /// A Codex question's digit is about to be typed. Only the final question of the call notes and
    /// leaves the clicked card; earlier questions stay unanswered (their wording is #321).
    public static func codexKeySending(final: Bool) -> RowNoteUpdate {
        final ? .record(.sending) : .unchanged
    }

    /// A typed digit settled (herdr, tmux, Zellij, WezTerm). Written → waiting for Codex; may have
    /// been written → not confirmed; nothing written, or vetoed → the note is withdrawn.
    public static func codexKeyAnswer(_ outcome: HerdrQuestionRelay.Outcome, final: Bool) -> RowNoteUpdate {
        guard final else { return .unchanged }
        switch outcome {
        case .delivered(.queued): return .record(.awaitingCodex)
        case .delivered(.possiblySent): return .record(.sentUnconfirmed)
        case .delivered(.notSent), .vetoed: return .withdraw
        }
    }

    /// A Ghostty digit settled: Ghostty reports only whether it sent the key.
    public static func ghosttyKeyAnswer(sent: Bool, final: Bool) -> RowNoteUpdate {
        guard final else { return .unchanged }
        return sent ? .record(.awaitingCodex) : .withdraw
    }
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
