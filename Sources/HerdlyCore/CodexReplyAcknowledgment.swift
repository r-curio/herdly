import Foundation

/// Agreed with the user on 2026-10-08, matching the Claude rule in docs/product.md: a prompt submitted
/// in a Codex CLI session (its `UserPromptSubmit` turn start) acknowledges that session's completions
/// from other turns that arrived strictly before the prompt. A completion arriving at or after the
/// prompt, and completions of other sessions, stay queued. A prompt sent by a script or by Herdly's own
/// reply field starts a turn the same way and also acknowledges; Herdly cannot tell them apart.
public enum CodexReplyAcknowledgment {
    /// The terminal completions acknowledged by each session's latest turn start in `events`. A turn
    /// start whose time does not parse acknowledges nothing.
    public static func acknowledged(_ completions: [AttentionCompletion], events: [CLIEvent]) -> Set<CompletionIdentity> {
        var latest: [UUID: (turn: UUID, at: Double)] = [:]
        for case let .turnStarted(session, turn, receivedAt) in events {
            guard let at = RolloutTimestamp.parse(receivedAt), at.isFinite else { continue }
            if let current = latest[session], current.at >= at { continue }
            latest[session] = (turn, at)
        }
        return Set(completions.filter { completion in
            guard completion.source == .cli, let reply = latest[completion.session] else { return false }
            return completion.turn != reply.turn && completion.arrivedAt.isFinite && completion.arrivedAt < reply.at
        }.map(\.id))
    }
}
