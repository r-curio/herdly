import Foundation

// The Codex question relay through herdr keys (ADR 0010): which route a call uses, the one key a
// click may send, the fresh check immediately before it, and how a socket result settles Herdly's
// bookkeeping. Everything here is a pure function of its inputs; HerdlyApp owns the socket, the
// rollout read and the scan (Companion+Questions.swift).

/// Why a herdr key for a Codex question was not sent. Nothing left Herdly for this click and the
/// card offers Open in Codex (ADR 0010 "Failure"). Which words the user sees follows
/// `docs/product.md` ("Agreed herdr presentation"); `message` is the generic wording until then.
public enum HerdrQuestionRelayUnavailable: Error, Equatable, Hashable, Sendable {
    /// The session runs in herdr but its pane binding does not hold (ADR 0012/0009).
    case binding(HerdrSessionUnavailable)
    /// A fresh scan no longer shows the session in herdr. A call routed to herdr keys never falls
    /// back to Ghostty keys partway.
    case leftHerdr
    /// The fresh binding names another pane than the one this call's earlier keys went to.
    case paneChanged
    /// The rollout records an output for the call: Codex already has an answer.
    case answeredInRollout
    /// The rollout records the call's turn as completed or canceled.
    case turnEnded
    /// The rollout could not be read, or shows no pending call; unreadable is never "still pending".
    case rolloutUnreadable
    /// herdr reports the pane's agent in a status other than `blocked`; nil when the fresh
    /// snapshot does not list the pane. `blocked` is a veto only, never proof of a pending question.
    case agentNotBlocked(HerdrAgentStatus?)
    /// Answers for this call were drafted for Codex's daemon, which no longer holds it; keys would
    /// land on a question the TUI is not showing.
    case daemonAnswerInProgress
    /// herdr could not be reached, or refused the request, before the key could have been written.
    case herdrRefused(HerdrUnavailableReason)
    /// The session runs in a terminal host that never types a question digit (Terminal.app, iTerm2;
    /// ADR 0017). Not a failure of any send: the card says "Answer this in Codex."
    case noQuestionKeys(TerminalHost)
    /// Another enabled terminal host could hold the session but is unread, unreadable or denied, so
    /// a Ghostty tab carrying the title may be a decoy (ADR 0013 "Inventory"): no key is sent.
    case otherHostUnreadable(TerminalHost)

    /// Generic card wording, matching the Ghostty relay's sentences.
    public var message: String {
        switch self {
        case .noQuestionKeys(let host):
            // product.md, "Typed input unavailable": iTerm2 has no typed input at all.
            return host == .iTerm2 ? ITerm2Presentation.typedInputLine : "Answer this in Codex."
        case .otherHostUnreadable:
            return "Herdly can't reach this session's tab; nothing was sent. Reply in the session."
        case .answeredInRollout, .turnEnded:
            return "Codex already has an answer or the turn ended; nothing was sent."
        case .rolloutUnreadable:
            return "Herdly could not confirm the question is still waiting; nothing was sent. Answer in Codex."
        case .daemonAnswerInProgress:
            return "Answers for this question were kept for Codex's daemon, which no longer holds it; answer in Codex."
        case .binding, .leftHerdr, .paneChanged, .agentNotBlocked, .herdrRefused:
            return "Could not send the key; nothing was sent. Answer in Codex."
        }
    }
}

/// How one `agent.send_keys` request ended, from Herdly's side of the socket.
public enum HerdrKeyDelivery: Equatable, Sendable {
    /// herdr accepted the request. The bytes were queued; Codex reading them is not established.
    case queued
    /// The request may have been written (timeout, disconnect, malformed or mismatched reply after
    /// the write began). It counts as sent and is never resent.
    case possiblySent(HerdrUnavailableReason)
    /// Nothing was written, or herdr answered the request with an explicit error.
    case notSent(HerdrUnavailableReason)

    public var countsAsSent: Bool {
        if case .notSent = self { return false }
        return true
    }

    /// Classifies a `send_keys` result. `writeAttempted` is true once any byte of the request line
    /// could have reached the socket.
    public static func classify(_ result: Result<HerdrReply, HerdrUnavailableReason>,
                                writeAttempted: Bool) -> HerdrKeyDelivery {
        switch result {
        case .success(.accepted):
            return .queued
        case .success:
            // A pong or snapshot cannot answer send_keys: a mismatched reply after the write.
            return .possiblySent(.malformedReply)
        case .failure(let reason):
            guard writeAttempted else { return .notSent(reason) }
            if case .requestRefused = reason { return .notSent(reason) }
            return .possiblySent(reason)
        }
    }
}

/// Which keyed route a call has used. Memory only.
public enum QuestionKeyRoute: Equatable, Hashable, Sendable {
    case herdr(paneID: String)
    case ghostty
    /// A terminal host's bound pane (ADR 0017, `TerminalQuestionKeys`).
    case terminal(TypedInputPane)
}

/// Herdly's memory of the keys it may have sent per call and question index, and of the last
/// pre-send failure per call. A key is spent before the socket write and released only when it
/// certainly was not written, so one call and index never carries two keys (ADR 0010). Memory
/// only: a restart returns every question as plain pending and nothing is resent.
public struct QuestionRelayLedger: Equatable, Sendable {
    private struct Keyed: Equatable, Sendable {
        var route: QuestionKeyRoute
        var indices: Set<Int>
    }

    private var keyed: [QuestionIdentity: Keyed] = [:]
    private var failures: [QuestionIdentity: HerdrQuestionRelayUnavailable] = [:]

    public init() {}

    /// The route this call's keys use, once any key was spent for it.
    public func keyRoute(for call: QuestionIdentity) -> QuestionKeyRoute? { keyed[call]?.route }

    public func hasSpent(_ call: QuestionIdentity, question index: Int) -> Bool {
        keyed[call]?.indices.contains(index) == true
    }

    /// Spends the key for `index` on `route`. False, changing nothing, when that index was already
    /// spent or the call's keys went by another route.
    public mutating func spend(_ call: QuestionIdentity, question index: Int, route: QuestionKeyRoute) -> Bool {
        if let current = keyed[call] {
            guard current.route == route, !current.indices.contains(index) else { return false }
            keyed[call]?.indices.insert(index)
        } else {
            keyed[call] = Keyed(route: route, indices: [index])
        }
        failures[call] = nil
        return true
    }

    /// The key for `index` certainly was not written. The call's route lock lifts once no key for
    /// it remains spent.
    public mutating func release(_ call: QuestionIdentity, question index: Int) {
        guard var current = keyed[call] else { return }
        current.indices.remove(index)
        keyed[call] = current.indices.isEmpty ? nil : current
    }

    public mutating func recordFailure(_ reason: HerdrQuestionRelayUnavailable, for call: QuestionIdentity) {
        failures[call] = reason
    }

    /// The last pre-send failure for a call, for the card and diagnostics.
    public func failure(for call: QuestionIdentity) -> HerdrQuestionRelayUnavailable? { failures[call] }

    /// Forgets calls no longer waiting.
    public mutating func prune(keeping waiting: Set<QuestionIdentity>) {
        keyed = keyed.filter { waiting.contains($0.key) }
        failures = failures.filter { waiting.contains($0.key) }
    }
}

public enum QuestionRelayRouting {
    /// Which path a question card uses, in ADR 0010's precedence:
    /// 1. a call Herdly answered through the daemon stays there;
    /// 2. a call that already carried a key keeps that key route, even if the daemon now holds it;
    /// 3. the daemon, when it holds the exact thread and call;
    /// 4. a desktop question is a pick;
    /// 5. answers drafted for a daemon that no longer holds the call never move to keys;
    /// 6. a CLI session herdr has anything to say about uses herdr keys (or nothing, when its pane
    ///    is unavailable);
    /// 7. a session another host holds is answered in Codex where that host types no digits (Terminal.app,
    ///    iTerm2, and WezTerm until its live digit proof; ADR 0017), and otherwise uses that host's pane
    ///    keys; another host's digits never go to Ghostty;
    /// 8. while another enabled host is unread or unreadable, a Ghostty tab with the title may be a
    ///    decoy, so nothing is offered; only the rest use Ghostty keys.
    ///
    /// `progress` is the raw stored progress (nil when Herdly has none). `terminalHost` is the host
    /// other than Ghostty that the latest scan saw the session's tab in, nil when none. `unreadHost` is
    /// an enabled host whose latest read is missing or unreadable, nil when every one was read.
    /// `typesDigits` says which hosts carry a question digit (`TerminalHost.typesQuestionDigits`): a
    /// session another such host holds uses that host's pane keys (`.terminalRelay`, #240), unless an
    /// enabled host is unread.
    public static func route(for question: AttentionQuestion, book: AppServerQuestionBook, daemonConnected: Bool,
                             ledger: QuestionRelayLedger, progress: QuestionAnswerProgress?,
                             herdr: HerdrSessionBinding, terminalHost: TerminalHost? = nil,
                             unreadHost: TerminalHost? = nil,
                             typesDigits: (TerminalHost) -> Bool = { $0.typesQuestionDigits }) -> QuestionAnswerRoute {
        if book.hasAnswered(question) { return .daemonAnswered }
        switch ledger.keyRoute(for: question.id) {
        case .herdr?: return .herdrRelay
        case .ghostty?: return .ghosttyRelay
        case .terminal?: return .terminalRelay
        case nil: break
        }
        if daemonConnected, let request = book.request(for: question) { return .daemon(request) }
        guard question.source == .cli else { return .desktopPick }
        if let progress, !progress.picks.isEmpty || !progress.texts.isEmpty {
            return .relayUnavailable(.daemonAnswerInProgress)
        }
        // ADR 0013: a key (Ghostty's or herdr's) needs the title unique across every enabled host.
        if let terminalHost, terminalHost != .ghostty {
            guard typesDigits(terminalHost) else { return .relayUnavailable(.noQuestionKeys(terminalHost)) }
            if let unreadHost { return .relayUnavailable(.otherHostUnreadable(unreadHost)) }
            return .terminalRelay
        }
        if let unreadHost { return .relayUnavailable(.otherHostUnreadable(unreadHost)) }
        switch herdr {
        case .notInHerdr:
            return .ghosttyRelay
        case .bound: return .herdrRelay
        case .unavailable(let reason): return .relayUnavailable(.binding(reason))
        }
    }
}

public enum HerdrQuestionRelay {
    /// herdr keys carry digits 1 through 8 (ADR 0010), the options Herdly can number exactly.
    public static let maximumDigit = 8

    /// The one key for a zero-based option, its one-based digit; nil beyond the herdr digit range.
    public static func key(forOption option: Int) -> String? {
        guard option >= 0, option < maximumDigit else { return nil }
        return String(option + 1)
    }

    public enum Rejection: Error, Equatable, Sendable {
        case policy(QuestionAnswerPolicy.Rejection)
        case noPane
        case alreadySent
    }

    /// One click accepted: the key to send, the progress in `.sending`, and the ledger with the key
    /// spent on `pane` before anything is written.
    public struct Start: Equatable, Sendable {
        public let key: String
        public let pane: String
        public let progress: QuestionAnswerProgress
        public let ledger: QuestionRelayLedger
    }

    /// Judges one click against the queue's current copy of the question, the Ghostty relay's
    /// policy (one to eight exactly numbered options, isSecret offers nothing), and the ledger.
    /// `pane` is the bound pane from the latest scan; the send still rechecks it.
    public static func start(current: AttentionQuestion?, progress: QuestionAnswerProgress, ledger: QuestionRelayLedger,
                             ghosttyEnabled: Bool, pane: String?, question index: Int,
                             option: Int) -> Result<Start, Rejection> {
        if let rejection = QuestionAnswerPolicy.rejection(for: current, ghosttyEnabled: ghosttyEnabled, progress: progress,
                                                          question: index, option: option) {
            return .failure(.policy(rejection))
        }
        guard let current, let key = key(forOption: option) else { return .failure(.policy(.optionOutOfRange)) }
        guard let pane else { return .failure(.noPane) }
        var next = ledger
        guard next.spend(current.id, question: index, route: .herdr(paneID: pane)) else { return .failure(.alreadySent) }
        return .success(Start(key: key, pane: pane, progress: progress.startingSend(question: index, option: option),
                              ledger: next))
    }

    /// The rollout half of the fresh check: nil only when the call is pending in readable evidence.
    public static func rolloutVeto(for question: AttentionQuestion,
                                   in evidence: ReminderReader.RolloutEvidence) -> HerdrQuestionRelayUnavailable? {
        let turn = TurnIdentity(session: question.session, turn: question.turn)
        if evidence.completed.contains(turn) || evidence.canceled.contains(turn) { return .turnEnded }
        if evidence.answeredQuestions.contains(where: { $0.session == question.session && $0.callID == question.callID }) {
            return .answeredInRollout
        }
        guard QuestionAnswerGuard.stillPending(question, in: evidence) else { return .rolloutUnreadable }
        return nil
    }

    /// The pane's agent status in a scan; nil when the scan failed or does not list the pane.
    public static func agentStatus(ofPane paneID: String, in outcome: HerdrScanOutcome?) -> HerdrAgentStatus? {
        outcome?.scan?.snapshot.pane(paneID)?.agentStatus
    }

    /// The whole fresh check immediately before the key (ADR 0010): the rollout as just re-read,
    /// the binding against a fresh scan and fresh `pane.process_info` (ADR 0012), the same pane as the click
    /// spent, and herdr reporting that pane's agent as `blocked`. Returns the pane to address.
    public static func preSendCheck(question: AttentionQuestion, evidence: ReminderReader.RolloutEvidence,
                                    binding: HerdrSessionBinding, outcome: HerdrScanOutcome?,
                                    spentPane: String) -> Result<HerdrPaneTarget, HerdrQuestionRelayUnavailable> {
        if let veto = rolloutVeto(for: question, in: evidence) { return .failure(veto) }
        let target: HerdrPaneTarget
        switch binding {
        case .notInHerdr: return .failure(.leftHerdr)
        case .unavailable(let reason): return .failure(.binding(reason))
        case .bound(let value): target = value
        }
        guard target.paneID == spentPane else { return .failure(.paneChanged) }
        let status = agentStatus(ofPane: target.paneID, in: outcome)
        guard status == .blocked else { return .failure(.agentNotBlocked(status)) }
        return .success(target)
    }

    /// How one click ended: vetoed before the key, or the key's delivery.
    public enum Outcome: Equatable, Sendable {
        case vetoed(HerdrQuestionRelayUnavailable)
        case delivered(HerdrKeyDelivery)
    }

    /// Settles the progress and ledger after one click. A key that may have been written counts as
    /// sent: the progress advances (a non-last question) or waits for the rollout (the last), and
    /// the key stays spent. Anything else is a failure with nothing sent; its key is released and
    /// the typed reason kept. Never schedules another key.
    public static func settle(_ outcome: Outcome, progress: QuestionAnswerProgress, ledger: QuestionRelayLedger,
                              question: AttentionQuestion, index: Int, option: Int,
                              now: Double) -> (progress: QuestionAnswerProgress, ledger: QuestionRelayLedger) {
        var next = ledger
        let reason: HerdrQuestionRelayUnavailable
        switch outcome {
        case .delivered(let delivery) where delivery.countsAsSent:
            return (progress.recordingSent(question: index, option: option, of: question, at: now), next)
        case .delivered(.notSent(let failure)):
            reason = .herdrRefused(failure)
        case .delivered:
            reason = .herdrRefused(.malformedReply)
        case .vetoed(let veto):
            reason = veto
        }
        next.release(question.id, question: index)
        next.recordFailure(reason, for: question.id)
        return (progress.recordingFailure(reason.message), next)
    }
}
