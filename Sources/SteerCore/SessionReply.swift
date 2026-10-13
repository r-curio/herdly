import Foundation

// Replying to a finished session from its completion card. The reply starts a new turn on that
// exact thread through the local app-server daemon (`turn/start`, per the schema the installed CLI
// generates), the same verified transport that answers questions by call id. When the daemon does
// not hold the thread, ADR 0017's second route types the reply into the session's one bound pane on a
// host that types replies (`TerminalTypedInput.swift`). The Ghostty relay carries one digit and
// nothing else (ADR 0006). With neither route the field is disabled and the card says why.
// Everything here is pure bookkeeping and policy; the socket and the host calls live in the app.

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
    /// The typed-input route of each session from the latest scan, only while a host that types
    /// replies is switched on. A session without an entry has no typed route at all.
    public let terminalRoutes: [UUID: TerminalReplyRoute]

    public init(daemonConnected: Bool = false, daemonThreads: Set<UUID> = [],
                endedSessions: Set<UUID> = [], workingSessions: Set<UUID> = [],
                terminalRoutes: [UUID: TerminalReplyRoute] = [:]) {
        self.daemonConnected = daemonConnected
        self.daemonThreads = daemonThreads
        self.endedSessions = endedSessions
        self.workingSessions = workingSessions
        self.terminalRoutes = terminalRoutes
    }
}

/// Where a reply would go: the daemon, the bound pane, or nowhere.
public enum SessionReplyTarget: Equatable, Sendable {
    /// The daemon holds this thread: the reply starts a new turn on it, by thread id.
    case daemon(thread: UUID)
    /// The daemon does not hold it; the reply is typed into this bound pane (ADR 0017).
    case terminal(TypedInputPane)
    /// Nothing verified can carry the text. The field is disabled and the card shows the reason.
    case unavailable(SessionReplyPolicy.Rejection)

    /// Whether the card may offer the field at all.
    public var isReachable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// The route one reply left by. One card sends at most one reply, by one route.
public enum SessionReplyRoute: Equatable, Hashable, Sendable {
    case daemon
    case terminal(TypedInputPane)
}

public enum SessionReplyRouting {
    /// The target for one completion. An ended or newly working session is unreachable whatever the
    /// daemon holds: the first has nowhere to put a turn and the second is already in one. The daemon
    /// wins whenever it holds the thread (ADR 0017); otherwise a typed route, when there is one, decides.
    public static func target(for completion: AttentionCompletion,
                              availability: SessionReplyAvailability) -> SessionReplyTarget {
        if availability.endedSessions.contains(completion.session) { return .unavailable(.sessionEnded) }
        if availability.workingSessions.contains(completion.session) { return .unavailable(.sessionWorking) }
        if availability.daemonConnected, availability.daemonThreads.contains(completion.session) {
            return .daemon(thread: completion.session)
        }
        switch availability.terminalRoutes[completion.session] {
        case .pane(let pane)?: return .terminal(pane)
        case .unreachable?: return .unavailable(.terminalUnreachable)
        case .hostCannotType(let host)?: return .unavailable(.hostCannotType(host))
        case nil: break
        }
        guard availability.daemonConnected else { return .unavailable(.noDaemon) }
        return .unavailable(.threadNotLoaded)
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
    /// Codex started a turn on this session after the reply. That turn start also acknowledges the
    /// completion (`CodexReplyAcknowledgment`), so the card usually leaves the queue in the same scan
    /// and its progress is pruned; a further send is then refused as `notInQueue`.
    case working(text: String)
    /// No turn started inside the confirmation window; the card says so and Steer never resends.
    case unconfirmed(text: String, sentAt: Double)
    /// The write or the daemon refused; nothing was sent and nothing is retried.
    case failed(String)
}

/// Steer's memory of one completion card's reply, keyed by the card's completion: a Codex
/// `CompletionIdentity` (`SessionReplyProgress`) or a Claude outcome's `AgentTurnIdentity`. In memory
/// only: a restart returns the card with an empty field, and the completion itself is untouched
/// either way.
public struct ReplyProgress<ID: Hashable & Sendable>: Equatable, Sendable {
    /// Seconds after the reply left within which the session is expected to start a turn.
    public static var confirmationWindow: Double { 10 }

    public let completion: ID
    public private(set) var phase: SessionReplyPhase
    /// The route the reply left by, once a send started.
    public private(set) var route: SessionReplyRoute?
    /// Codex's text counts as sent but its separate submit did not go: the text may be waiting in the
    /// composer. Steer never presses Enter later.
    public private(set) var composerMayHoldText = false
    /// When the user's send began, if the caller said. A turn start at or after it confirms the reply
    /// (`observing`); without it the moment the reply counted as sent stands in.
    public private(set) var sendStartedAt: Double?

    public init(completion: ID) {
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

    /// `.ready` → `.sending` by `route`, begun at `now` when given. The caller has already applied the policy.
    public func startingSend(text: String, route: SessionReplyRoute = .daemon, at now: Double? = nil) -> ReplyProgress {
        guard phase == .ready, let trimmed = SessionReplyPolicy.sendableText(text) else { return self }
        var next = self
        next.phase = .sending(trimmed)
        next.route = route
        next.sendStartedAt = now
        return next
    }

    /// Settles a typed reply (ADR 0017): anything that counts as sent is sent, and is never resent;
    /// a run that sent nothing fails with its reason, for good.
    public func settling(_ run: TypedReplyRun, at now: Double) -> ReplyProgress {
        switch run {
        case .sent:
            return recordingSent(at: now)
        case .sentTextOnly:
            var next = recordingSent(at: now)
            if next != self { next.composerMayHoldText = true }
            return next
        case .notSent(.vetoed(let veto)):
            return recordingFailure(veto.message)
        case .notSent(.notWritten):
            return recordingFailure("Steer couldn't type into the session's tab; nothing was sent. Reply in the session.")
        }
    }

    /// The daemon accepted the request. Only a send that was under way can be recorded.
    public func recordingSent(at now: Double) -> ReplyProgress {
        guard case let .sending(text) = phase else { return self }
        var next = self
        next.phase = .sent(text: text, at: now)
        return next
    }

    /// Nothing was sent, or the daemon refused; the reason is shown and Steer never retries.
    public func recordingFailure(_ reason: String) -> ReplyProgress {
        guard case .sending = phase else { return self }
        var next = self
        next.phase = .failed(reason)
        return next
    }

    /// Applies what Steer can see of the session now: whether it is in a turn, and the latest turn
    /// start Steer has a record of (`ReplyTurnStarts`). A turn started after the send is the
    /// confirmation, however late, whether a scan caught it running or only its start record remains
    /// because it finished between scans (#271). Silence inside the window keeps waiting, and silence
    /// past it is reported as unconfirmed rather than described as an answer Codex has.
    public func observing(sessionWorking: Bool, latestTurnStart: Double? = nil, at now: Double) -> ReplyProgress {
        var next = self
        switch phase {
        case let .sent(text, at):
            if sessionWorking || startedAfterSend(latestTurnStart, sentAt: at) { next.phase = .working(text: text) }
            else if now - at >= Self.confirmationWindow { next.phase = .unconfirmed(text: text, sentAt: at) }
        case let .unconfirmed(text, at):
            if sessionWorking || startedAfterSend(latestTurnStart, sentAt: at) { next.phase = .working(text: text) }
        case .ready, .sending, .working, .failed:
            break
        }
        return next
    }

    /// Hook records date a turn start to the whole second, truncated, and a turn can start before the
    /// daemon's or the host's answer that marks the reply sent. So the start is compared with the
    /// second in which the send began: a turn in that second or later counts, an earlier one never.
    private func startedAfterSend(_ turnStart: Double?, sentAt: Double) -> Bool {
        guard let turnStart, turnStart.isFinite else { return false }
        return turnStart >= (sendStartedAt ?? sentAt).rounded(.down)
    }
}

/// A Codex completion card's reply.
public typealias SessionReplyProgress = ReplyProgress<CompletionIdentity>

/// The evidence `ReplyProgress.observing` takes besides a running turn: each session's latest
/// turn start on record (#271). A reply's turn can start and end between two scans, so it is never
/// seen running; its `UserPromptSubmit` record stays. Both readers of the hook records count: the
/// CLI events exist only for sessions the scan classified as CLI, while the hook reader decodes every
/// record, so a session the scan did not classify as CLI this time is still confirmed.
public enum ReplyTurnStarts {
    /// The latest parseable turn start per session. A turn's end or a tool call starts nothing.
    public static func latest(cliEvents: [CLIEvent], hookEvents: [DesktopEvent]) -> [UUID: Double] {
        var latest: [UUID: Double] = [:]
        func record(_ session: UUID, _ receivedAt: String) {
            guard let at = RolloutTimestamp.parse(receivedAt), at.isFinite else { return }
            latest[session] = max(latest[session] ?? at, at)
        }
        for case let .turnStarted(session, _, receivedAt) in cliEvents { record(session, receivedAt) }
        for event in hookEvents {
            switch event {
            case let .turnStarted(session, _, receivedAt), let .promptSubmitted(session, _, _, receivedAt):
                record(session, receivedAt)
            default:
                break
            }
        }
        return latest
    }
}

/// Whether one typed reply may leave Steer. Judges the queue's current copy of the completion and
/// the availability as it is right now, never the row that was rendered.
public enum SessionReplyPolicy {
    /// The longest reply Steer sends; anything longer belongs in Codex's own composer.
    public static let maximumText = 4000

    public enum Rejection: Error, Equatable, Sendable {
        case notInQueue, noDaemon, threadNotLoaded, sessionEnded, sessionWorking
        case emptyText, textTooLong, notReady
        /// A typed route exists but the session has no exact binding (ADR 0017).
        case terminalUnreachable
        /// The session is bound in a host that never types (iTerm2).
        case hostCannotType(TerminalHost)
        /// Typed replies only: a second line or a control character.
        case notOneLine
        /// Typed replies only: text starting with `/` or `!`.
        case commandText
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
        return rejection(target: target, phase: progress.phase, text: text)
    }

    /// The target and text half of the policy, for any agent's card.
    public static func rejection(target: SessionReplyTarget, phase: SessionReplyPhase, text: String) -> Rejection? {
        if case let .unavailable(reason) = target { return reason }
        if case .terminal = target, case let .failure(reason) = TypedReplyText.sendable(text) {
            switch reason {
            case .emptyText: return .emptyText
            case .textTooLong: return .textTooLong
            case .notOneLine: return .notOneLine
            case .commandText: return .commandText
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyText }
        guard trimmed.count <= maximumText else { return .textTooLong }
        guard phase == .ready else { return .notReady }
        return nil
    }

    /// The card's sentence when the daemon refused the request or the write never left. Steer says
    /// what the daemon said, and that it will not try again.
    public static func daemonRefused(_ error: String?) -> String {
        "Codex's daemon did not take the reply\(error.map { " (\($0))" } ?? ""). Steer will not retry; reply in Codex."
    }

    /// The sentence for `rejection` on `agent`'s card.
    public static func message(for rejection: Rejection, agent: AgentSource) -> String {
        guard agent == .claude else { return message(for: rejection) }
        switch rejection {
        case .sessionWorking: return "This session is working again; send your next prompt in Claude."
        case .textTooLong: return "That reply is longer than Steer sends; send it in Claude."
        default: return message(for: rejection)
        }
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
        case .terminalUnreachable: return "Steer can't reach this session's tab. Reply in the session."
        case .hostCannotType(let host): return "Steer can't type into \(host.displayName). Reply in the session."
        case .notOneLine: return "Steer types one line only; send longer replies in the session."
        case .commandText: return "Type commands starting with / or ! in the session itself."
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
/// nothing about the completion itself; the turn start Codex records for it acknowledges
/// (`CodexReplyAcknowledgment`).
public enum SessionReplySending {
    public enum Outcome: Equatable, Sendable {
        case refused(SessionReplyPolicy.Rejection)
        /// Write `params` as a `turn/start` request, then record sent or failed.
        case sending(SessionReplyProgress)
    }

    /// A reply typed into the bound pane: the pane the click chose and the writes, in order.
    public struct TerminalSend: Equatable, Sendable {
        public let pane: TypedInputPane
        public let writes: [TypedWrite]
    }

    public struct Plan {
        public let outcome: Outcome
        /// The daemon route's `turn/start` params.
        public let params: [String: Any]?
        /// The typed route's writes.
        public let terminal: TerminalSend?

        init(outcome: Outcome, params: [String: Any]? = nil, terminal: TerminalSend? = nil) {
            self.outcome = outcome
            self.params = params
            self.terminal = terminal
        }
    }

    /// `now` is when the user's send began: a turn start before that second never confirms the reply.
    public static func prepare(completion: AttentionCompletion?, availability: SessionReplyAvailability,
                               progress: SessionReplyProgress, text: String, at now: Double? = nil) -> Plan {
        // The target is resolved once and judged once; nothing downstream walks the evidence again.
        let target = completion.map { SessionReplyRouting.target(for: $0, availability: availability) }
            ?? .unavailable(.notInQueue)
        if let rejection = SessionReplyPolicy.rejection(for: completion, target: target, progress: progress, text: text) {
            return Plan(outcome: .refused(rejection))
        }
        switch target {
        case let .daemon(thread):
            guard let params = SessionReplyRequest.params(thread: thread, text: text) else {
                return Plan(outcome: .refused(.emptyText))
            }
            return Plan(outcome: .sending(progress.startingSend(text: text, at: now)), params: params)
        case let .terminal(pane):
            guard case let .success(trimmed) = TypedReplyText.sendable(text) else { return Plan(outcome: .refused(.emptyText)) }
            return Plan(outcome: .sending(progress.startingSend(text: trimmed, route: .terminal(pane), at: now)),
                        terminal: TerminalSend(pane: pane, writes: TypedReplyWrites.plan(agent: .codex, text: trimmed)))
        case let .unavailable(reason):
            return Plan(outcome: .refused(reason))
        }
    }
}

/// A Claude Code completion card's reply. Claude has no daemon: the only route is typed input into the
/// session's bound pane (ADR 0017), the session's first reply path.
public enum ClaudeReplyRouting {
    /// The target for a Claude outcome, nil when no typed route exists at all (no host that types replies
    /// is switched on): the card then offers no field, as before.
    public static func target(ended: Bool, inTurn: Bool, route: TerminalReplyRoute?) -> SessionReplyTarget? {
        guard let route else { return nil }
        if ended { return .unavailable(.sessionEnded) }
        if inTurn { return .unavailable(.sessionWorking) }
        switch route {
        case .pane(let pane): return .terminal(pane)
        case .unreachable: return .unavailable(.terminalUnreachable)
        case .hostCannotType(let host): return .unavailable(.hostCannotType(host))
        }
    }

    /// One Send judged against the target as it is now: the pane and Claude's one write (text and its
    /// submit together), or why nothing leaves.
    public static func prepare<ID>(target: SessionReplyTarget, progress: ReplyProgress<ID>,
                                   text: String) -> Result<SessionReplySending.TerminalSend, SessionReplyPolicy.Rejection> {
        if let rejection = SessionReplyPolicy.rejection(target: target, phase: progress.phase, text: text) {
            return .failure(rejection)
        }
        // The policy above refused every unavailable target and every text the typed route refuses;
        // Claude never has a daemon target.
        guard case let .terminal(pane) = target else { return .failure(.notReady) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(SessionReplySending.TerminalSend(pane: pane, writes: TypedReplyWrites.plan(agent: .claude, text: trimmed)))
    }
}
