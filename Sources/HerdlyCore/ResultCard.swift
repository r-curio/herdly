import Foundation

// The result card a finished turn pops (#323, Paper D33, 9NU, 9RW): the header line, the last
// message, "Your prompt", the reply field where Herdly can reach the session, then Open and Dismiss.
// These are the card's pure rules; the view and the sends live in HerdlyApp. Nothing here
// acknowledges a result: seeing the card, unfolding it, or sending leaves it queued, and only the
// turn the reply starts (`CodexReplyAcknowledgment`), a verified visit, or Dismiss clears it.

/// Whether the result card shows its reply field, and whether a send folds the card.
public enum ResultCardReply {
    /// The field shows only while the card has sent nothing and a verified route reaches the session:
    /// the daemon holding the thread, or the session's one bound pane on a host that types replies
    /// (ADR 0017). With no route at all (`nil`), or an unavailable one (ended, in a turn, no daemon,
    /// no exact tab, a host that cannot type), the card has no field and no reason line.
    public static func offersField(target: SessionReplyTarget?, phase: SessionReplyPhase) -> Bool {
        guard phase == .ready, let target else { return false }
        return target.isReachable
    }

    /// A Codex card. The Codex app has no agreed reply path, so a desktop result has no field even when
    /// the daemon holds its thread.
    public static func offersField(for completion: AttentionCompletion, target: SessionReplyTarget,
                                   phase: SessionReplyPhase) -> Bool {
        completion.source == .cli && offersField(target: target, phase: phase)
    }

    /// A send folds the card when it takes the reply out of `.ready`. A refused send stays `.ready`
    /// and keeps the card and its text; a later settle of a reply already under way folds nothing.
    public static func foldsCard(before: SessionReplyPhase, after: SessionReplyPhase) -> Bool {
        before == .ready && after != .ready
    }
}

extension RowNote {
    /// The result row's note once its card's reply has left (D21): in place of the place label, from
    /// the card's in-memory progress only. It never claims more than Herdly saw: a Codex reply the
    /// daemon took, or text typed with its submit, waits for Codex; a Claude reply is never confirmed
    /// by more than its typing; text that may sit in Codex's composer, or no turn start inside the
    /// window, is not confirmed; a reply that never left offers Open to reply in the agent. Nil while
    /// the card has sent nothing.
    public static func reply<ID>(_ progress: ReplyProgress<ID>, agent: AgentSource) -> RowNote? {
        switch progress.phase {
        case .ready:
            return nil
        case .sending:
            return .sending
        case .sent, .working:
            if progress.composerMayHoldText || agent == .claude { return .sentUnconfirmed }
            return .awaitingCodex
        case .unconfirmed:
            return .sentUnconfirmed
        case .failed:
            return .replyNotDelivered(agent)
        }
    }
}

/// Whether a result pops its card at all.
public enum ResultPop {
    /// A result restored after a restart (uncertain), or one that arrived before Herdly last started,
    /// goes straight to the queue without a card or a sound.
    public static func isFresh(_ outcome: AgentOutcome, launchedAt: Double) -> Bool {
        !outcome.uncertain && outcome.arrivedAt >= launchedAt
    }

    /// A Codex CLI result while Ghostty controls are on pops only when the latest inventory shows the
    /// session's exact tab and another tab selected (ADR 0016, "Presentation and scanning"). Its own
    /// tab in front, no inventory yet, or no exact tab for the session: no pop, and the result waits in
    /// the queue. A Codex app result, or Ghostty off, is not judged here. Other terminal hosts are not
    /// consulted yet.
    public static func ghosttyAllows(source: AttentionSource, session: UUID, ghosttyEnabled: Bool,
                                     live: Set<UUID>, snapshot: GhosttySnapshot?) -> Bool {
        guard source == .cli, ghosttyEnabled else { return true }
        guard let snapshot, let target = GhosttyMatch.target(session: session, live: live, snapshot: snapshot) else { return false }
        return snapshot.selected != target
    }
}
