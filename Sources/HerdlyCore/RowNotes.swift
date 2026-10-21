import Foundation

/// The short line a queue row carries after the user approves, denies, or answers it from the
/// notch (D10). It says only what Herdly knows about delivery; it never says Codex or Claude acted.
public enum RowNote: Equatable, Sendable {
    /// Herdly is sending the decision or answer.
    case sending
    /// Claude's helper confirmed it received this decision. Only a user decision qualifies.
    case delivered(ApprovalDecision)
    /// Herdly wrote it, but no confirmation came back.
    case sentUnconfirmed
    /// Claude could not receive it; the user answers in Claude, so the row offers Open.
    case notDelivered
    /// A Codex question answer left Herdly; Codex has not recorded it yet.
    case awaitingCodex

    public var text: String {
        switch self {
        case .sending: return "Sending…"
        case let .delivered(decision): return decision == .deny ? "Claude got your denial" : "Claude got your approval"
        case .sentUnconfirmed: return "Sent, not confirmed"
        case .notDelivered: return "Not delivered · answer in Claude"
        case .awaitingCodex: return "Sent, waiting for Codex"
        }
    }

    /// Whether the row offers Open beside the note.
    public var offersOpen: Bool { self == .notDelivered }

    /// The note for a Claude approval decision once its delivery attempt settles. Delivery counts
    /// only when the decision was published and the helper confirmed it; a no-decision release is
    /// never the user's decision and gets no note.
    public static func claudeDecision(_ decision: ApprovalDecision, published: Bool, delivered: Bool) -> RowNote? {
        guard decision.isUserDecision else { return nil }
        guard published else { return .notDelivered }
        return delivered ? .delivered(decision) : .sentUnconfirmed
    }

    /// The note for a Claude question answer once its delivery attempt settles. Nil when the helper
    /// confirmed it: that confirmation is resolution evidence for the call, so the note clears.
    public static func claudeAnswer(published: Bool, delivered: Bool) -> RowNote? {
        guard published else { return .notDelivered }
        return delivered ? nil : .sentUnconfirmed
    }

    /// The note for a Codex question answer (a typed digit or a daemon response). Nil when nothing
    /// was sent, so the "Sending…" note is withdrawn rather than claiming anything.
    public static func codexAnswer(sent: Bool) -> RowNote? {
        sent ? .awaitingCodex : nil
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
    /// already cleared. A delivery confirmation is accepted only for an approval and a user decision.
    @discardableResult
    public mutating func record(_ note: RowNote, for id: AgentAttentionID, pending: Set<AgentAttentionID>) -> Bool {
        guard pending.contains(id), !cleared.contains(id) else { return false }
        switch (id, note) {
        case let (.approval, .delivered(decision)) where decision.isUserDecision: break
        case (_, .delivered): return false
        case (.approval, _), (.question, _): break
        case (.outcome, _), (.running, _), (.unavailable, _): return false
        }
        notes[id] = note
        return true
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
