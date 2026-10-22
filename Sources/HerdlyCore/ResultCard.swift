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

/// Whether the card's "Your prompt" is open. Settings › Notifications › "Show my full prompt" sets
/// how every card's prompt starts; a click on one card's toggle flips that card only, and the saved
/// choice never changes because of it. Unfolding acknowledges nothing.
public enum ResultCardPrompt {
    public static func isOpen(showsFullPrompt: Bool, flipped: Bool) -> Bool {
        showsFullPrompt != flipped
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

    /// ADR 0016, "Presentation and scanning", for a Codex CLI result while Ghostty controls are on:
    /// no pop only when the latest Ghostty inventory shows the session's exact tab selected. Another
    /// tab selected, Ghostty not in front (it then reports no selected tab), or no exact Ghostty tab
    /// for the session (it runs in another terminal) pops; nothing visible is known. With no inventory
    /// (`nil`) it is not yet only while a read is in flight (`reading`): the fresh result stays a
    /// candidate until it lands. Ghostty unreadable or not running shows nothing visible, so it pops.
    /// A Codex app result, or Ghostty off, is not judged here. Other terminal hosts are not consulted yet.
    public static func ghosttyAllows(source: AttentionSource, session: UUID, ghosttyEnabled: Bool,
                                     live: Set<UUID>, snapshot: GhosttySnapshot?, reading: Bool = false) -> Bool {
        guard source == .cli, ghosttyEnabled else { return true }
        guard let snapshot else { return !reading }
        return allows(selected: snapshot.selected, target: GhosttyMatch.target(session: session, live: live, snapshot: snapshot))
    }

    /// The same rule for a Claude CLI result, through the Claude tab binding the visit rule uses
    /// (`GhosttyVisitTargets.claude`). Claude results never waited for Ghostty, so with no inventory
    /// yet, or Ghostty off, they pop.
    public static func claudeGhosttyAllows(_ identity: AgentSessionIdentity, ghosttyEnabled: Bool,
                                           liveSessionsByScope: [String: [String]], inventoryAvailable: [String: Bool],
                                           configuredScopes: Set<String>, snapshot: GhosttySnapshot?) -> Bool {
        guard ghosttyEnabled, let snapshot else { return true }
        return allows(selected: snapshot.selected,
                      target: GhosttyVisitTargets.claude(identity, liveSessionsByScope: liveSessionsByScope,
                                                         inventoryAvailable: inventoryAvailable,
                                                         configuredScopes: configuredScopes, snapshot: snapshot))
    }

    /// Only the session's own exact tab, selected, holds the card back.
    private static func allows(selected: GhosttyTarget?, target: GhosttyTarget?) -> Bool {
        guard let target else { return true }
        return selected != target
    }
}
