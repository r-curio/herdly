import Foundation

// Replying to a finished session from its completion card. The reply starts a new turn on that
// exact thread through the local app-server daemon (`turn/start`, per the schema the installed CLI
// generates), the same verified transport that answers questions by call id. The Ghostty relay
// carries one digit and nothing else (ADR 0006), so a session the daemon does not hold offers no
// reply field at all; the card says why and the user opens Codex. Everything here is pure
// bookkeeping and policy; the socket lives in the app.

/// What Steer knows right now about reaching a finished session. Gathered at the moment the user
/// sends, never remembered from when the card rendered.
public struct SessionReplyAvailability: Equatable, Sendable {
    public let daemonConnected: Bool
    /// Threads the daemon reports loaded; only these can take a new turn.
    public let daemonThreads: Set<UUID>
    /// Sessions whose end Codex recorded.
    public let endedSessions: Set<UUID>
    /// Sessions with a turn running right now.
    public let workingSessions: Set<UUID>

    public init(daemonConnected: Bool = false, daemonThreads: Set<UUID> = [],
                endedSessions: Set<UUID> = [], workingSessions: Set<UUID> = []) {
        self.daemonConnected = daemonConnected
        self.daemonThreads = daemonThreads
        self.endedSessions = endedSessions
        self.workingSessions = workingSessions
    }
}

/// Where a reply would go. There is one transport; anything else is no transport.
public enum SessionReplyTarget: Equatable, Sendable {
    /// The daemon holds this thread: the reply starts a new turn on it, by thread id.
    case daemon(thread: UUID)
    /// Nothing verified can carry the text. The field is disabled and the card shows the reason.
    case unavailable(SessionReplyPolicy.Rejection)

    /// Whether the card may offer the field at all.
    public var isReachable: Bool {
        if case .daemon = self { return true }
        return false
    }
}

public enum SessionReplyRouting {
    /// The target for one completion. An ended or newly working session is unreachable whatever the
    /// daemon holds: the first has nowhere to put a turn and the second is already in one.
    public static func target(for completion: AttentionCompletion,
                              availability: SessionReplyAvailability) -> SessionReplyTarget {
        if availability.endedSessions.contains(completion.session) { return .unavailable(.sessionEnded) }
        if availability.workingSessions.contains(completion.session) { return .unavailable(.sessionWorking) }
        guard availability.daemonConnected else { return .unavailable(.noDaemon) }
        guard availability.daemonThreads.contains(completion.session) else { return .unavailable(.threadNotLoaded) }
        return .daemon(thread: completion.session)
    }
}

/// Where the card is with one reply. One card sends one reply: every phase but `.ready` refuses
/// another send, and none of them is ever left by a timer sending anything.
public enum SessionReplyPhase: Equatable, Sendable {
    case ready
    /// The `turn/start` request is in flight; the field and button are disabled.
    case sending(String)
    /// The daemon accepted the request; waiting for Codex to record the turn.
    case sent(text: String, at: Double)
    /// Codex started a turn on this session after the reply: the card's own confirmation.
    case working(text: String)
    /// No turn started inside the confirmation window; the card says so and Steer never resends.
    case unconfirmed(text: String, sentAt: Double)
    /// The write or the daemon refused; nothing was sent and nothing is retried.
    case failed(String)
}

/// Steer's memory of one completion card's reply. In memory only: a restart returns the card with
/// an empty field, and the completion itself is untouched either way.
public struct SessionReplyProgress: Equatable, Sendable {
    /// Seconds after the daemon accepted the reply within which Codex is expected to start a turn.
    public static let confirmationWindow: Double = 10

    public let completion: CompletionIdentity
    public private(set) var phase: SessionReplyPhase

    public init(completion: CompletionIdentity) {
        self.completion = completion
        self.phase = .ready
    }

    /// True once this card has said everything it will say; the field stays disabled.
    public var isFinished: Bool {
        switch phase {
        case .ready, .sending, .sent: return false
        case .working, .unconfirmed, .failed: return true
        }
    }

    /// The text Steer sent, once it has left.
    public var sentText: String? {
        switch phase {
        case .ready: return nil
        case let .sending(text), let .sent(text, _), let .working(text), let .unconfirmed(text, _): return text
        case .failed: return nil
        }
    }

    /// `.ready` → `.sending`. The caller has already applied the policy.
    public func startingSend(text: String) -> SessionReplyProgress {
        guard phase == .ready, let trimmed = SessionReplyPolicy.sendableText(text) else { return self }
        var next = self
        next.phase = .sending(trimmed)
        return next
    }

    /// The daemon accepted the request. Only a send that was under way can be recorded.
    public func recordingSent(at now: Double) -> SessionReplyProgress {
        guard case let .sending(text) = phase else { return self }
        var next = self
        next.phase = .sent(text: text, at: now)
        return next
    }

    /// Nothing was sent, or the daemon refused; the reason is shown and Steer never retries.
    public func recordingFailure(_ reason: String) -> SessionReplyProgress {
        guard case .sending = phase else { return self }
        var next = self
        next.phase = .failed(reason)
        return next
    }

    /// Applies what Steer can see of the session now. A turn started after the send is the
    /// confirmation, however late; silence inside the window keeps waiting, and silence past it is
    /// reported as unconfirmed rather than described as an answer Codex has.
    public func observing(sessionWorking: Bool, at now: Double) -> SessionReplyProgress {
        var next = self
        switch phase {
        case let .sent(text, at):
            if sessionWorking { next.phase = .working(text: text) }
            else if now - at >= Self.confirmationWindow { next.phase = .unconfirmed(text: text, sentAt: at) }
        case let .unconfirmed(text, _):
            if sessionWorking { next.phase = .working(text: text) }
        case .ready, .sending, .working, .failed:
            break
        }
        return next
    }
}

/// Whether one typed reply may leave Steer. Judges the queue's current copy of the completion and
/// the availability as it is right now, never the row that was rendered.
public enum SessionReplyPolicy {
    /// The longest reply Steer sends; anything longer belongs in Codex's own composer.
    public static let maximumText = 4000

    public enum Rejection: Equatable, Sendable {
        case notInQueue, noDaemon, threadNotLoaded, sessionEnded, sessionWorking
        case emptyText, textTooLong, notReady
    }

    /// The text Steer would send: trimmed, non-empty, and within the limit.
    public static func sendableText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumText else { return nil }
        return trimmed
    }

    /// Nil when the reply may be sent. `completion` is the queue's copy, nil when it has left, and
    /// `target` is where that copy resolves right now.
    public static func rejection(for completion: AttentionCompletion?, target: SessionReplyTarget,
                                 progress: SessionReplyProgress, text: String) -> Rejection? {
        guard let completion, completion.id == progress.completion else { return .notInQueue }
        if case let .unavailable(reason) = target { return reason }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyText }
        guard trimmed.count <= maximumText else { return .textTooLong }
        guard progress.phase == .ready else { return .notReady }
        return nil
    }

    /// The card's sentence when the daemon refused the request or the write never left. Steer says
    /// what the daemon said, and that it will not try again.
    public static func daemonRefused(_ error: String?) -> String {
        "Codex's daemon did not take the reply\(error.map { " (\($0))" } ?? ""). Steer will not retry; reply in Codex."
    }

    public static func message(for rejection: Rejection) -> String {
        switch rejection {
        case .notInQueue: return "This completion is no longer on the queue."
        case .noDaemon: return "No Codex daemon is running, so Steer cannot reach this session; reply in Codex."
        case .threadNotLoaded: return "Codex's daemon is not holding this session; reply in Codex."
        case .sessionEnded: return "This session has ended; there is nothing to reply to."
        case .sessionWorking: return "This session is working again; send your next prompt in Codex."
        case .emptyText: return "Type a reply first."
        case .textTooLong: return "That reply is longer than Steer sends; send it in Codex."
        case .notReady: return "Steer already sent a reply from this card; it never sends a second one."
        }
    }
}

/// The `turn/start` request that carries one reply. Steer overrides no model, sandbox policy,
/// approval policy, or working directory: the thread keeps every setting it already has.
public enum SessionReplyRequest {
    public static let method = "turn/start"

    /// The params for a new turn on `thread` with the user's text, or nil for text Steer never sends.
    public static func params(thread: UUID, text: String) -> [String: Any]? {
        guard let trimmed = SessionReplyPolicy.sendableText(text) else { return nil }
        return ["threadId": thread.uuidString.lowercased(),
                "input": [["type": "text", "text": trimmed]]]
    }
}

/// One Send, decided in one place: what to do and the params to write, if any. Sending changes
/// nothing about the completion itself, which is acknowledged only by dismissal or a verified visit.
public enum SessionReplySending {
    public enum Outcome: Equatable, Sendable {
        case refused(SessionReplyPolicy.Rejection)
        /// Write `params` as a `turn/start` request, then record sent or failed.
        case sending(SessionReplyProgress)
    }

    public struct Plan {
        public let outcome: Outcome
        public let params: [String: Any]?
    }

    public static func prepare(completion: AttentionCompletion?, availability: SessionReplyAvailability,
                               progress: SessionReplyProgress, text: String) -> Plan {
        // The target is resolved once and judged once; nothing downstream walks the evidence again.
        let target = completion.map { SessionReplyRouting.target(for: $0, availability: availability) }
            ?? .unavailable(.notInQueue)
        if let rejection = SessionReplyPolicy.rejection(for: completion, target: target, progress: progress, text: text) {
            return Plan(outcome: .refused(rejection), params: nil)
        }
        guard case let .daemon(thread) = target, let params = SessionReplyRequest.params(thread: thread, text: text) else {
            return Plan(outcome: .refused(.threadNotLoaded), params: nil)
        }
        return Plan(outcome: .sending(progress.startingSend(text: text)), params: params)
    }
}
