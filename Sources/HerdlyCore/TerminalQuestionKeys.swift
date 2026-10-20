import Foundation

// ADR 0017's Codex question digits through a terminal host's pane-addressed send (WezTerm first, #240),
// host-neutral: the host supplies its bound pane and its send. ADR 0010's rules apply with that send in
// place of herdr's `agent.send_keys`: one digit per click, spent before the send, never Enter, text,
// Other, Skip or Escape, and a fresh check immediately before it. Offered only on a host whose
// `typesQuestionDigits` is on, which waits for a live run showing the digit alone commits there.
// Pure; HerdlyApp owns the reads and the send.

public enum TerminalQuestionKeys {
    /// One click accepted: the digit to send, the progress in `.sending`, and the ledger with the key
    /// spent on `pane` before anything is written.
    public struct Start: Equatable, Sendable {
        public let key: String
        public let pane: TypedInputPane
        public let progress: QuestionAnswerProgress
        public let ledger: QuestionRelayLedger
    }

    /// Judges one click against the queue's current copy of the question, the relay policy (one to eight
    /// exactly numbered options, `isSecret` offers nothing) and the ledger. `pane` is the bound pane from
    /// the latest scan, or the pane this call's earlier keys went to; the send still rechecks it.
    public static func start(current: AttentionQuestion?, progress: QuestionAnswerProgress, ledger: QuestionRelayLedger,
                             pane: TypedInputPane?, question index: Int,
                             option: Int) -> Result<Start, HerdrQuestionRelay.Rejection> {
        // A pane-bound session needs no Ghostty controls: the policy's Ghostty check passes.
        if let rejection = QuestionAnswerPolicy.rejection(for: current, ghosttyEnabled: true, progress: progress,
                                                          question: index, option: option) {
            return .failure(.policy(rejection))
        }
        guard let current, let key = HerdrQuestionRelay.key(forOption: option) else { return .failure(.policy(.optionOutOfRange)) }
        guard let pane else { return .failure(.noPane) }
        var next = ledger
        guard next.spend(current.id, question: index, route: .terminal(pane)) else { return .failure(.alreadySent) }
        return .success(Start(key: key, pane: pane, progress: progress.startingSend(question: index, option: option),
                              ledger: next))
    }

    /// The whole fresh check immediately before the digit: the rollout as just re-read shows the call
    /// pending in its turn, and the binding re-run on fresh reads (the agent still in the foreground
    /// included) names the same pane the click spent. nil when the digit may go.
    public static func preSendCheck(question: AttentionQuestion, evidence: ReminderReader.RolloutEvidence,
                                    route: TerminalReplyRoute?, spent: TypedInputPane) -> HerdrQuestionRelayUnavailable? {
        if let veto = HerdrQuestionRelay.rolloutVeto(for: question, in: evidence) { return veto }
        guard case .pane(let pane)? = route else { return .leftHerdr }
        return pane == spent ? nil : .paneChanged
    }

    /// The host send's delivery in the relay's terms: anything that may have typed counts as sent.
    public static func delivery(_ delivery: TypedInputDelivery) -> HerdrKeyDelivery {
        switch delivery {
        case .written: .queued
        case .possiblyWritten: .possiblySent(.timeout)
        case .notWritten: .notSent(.notRunning)
        }
    }
}
