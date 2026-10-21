import Foundation

/// One answer the user gave in the notch: a listed option by position, or typed text (daemon path only).
public enum ChosenAnswer: Equatable, Sendable {
    case option(Int)
    case text(String)
}

/// What the notch may offer for one question inside a call.
public enum QuestionOffer: Equatable, Sendable {
    /// The listed option labels; the notch can relay any of them as its one-based digit.
    case options([String])
    /// The question needs Codex's own panel; the reason is shown on the card.
    case continueInCodex(String)
}

/// Where the notch is with one call. The rollout records nothing until the whole call is answered,
/// so progress through a multi-question call is Herdly's own bookkeeping of what it sent.
public enum QuestionAnswerPhase: Equatable, Sendable {
    /// Buttons are shown for the current question.
    case ready
    /// A key is on its way; buttons are disabled and the send is never re-entered.
    case sending
    /// The last question's key was delivered; waiting for the rollout to record the answer.
    case sent(at: Double)
    /// No output arrived within the confirmation window; Open in Codex only, never a resend.
    case unconfirmed(sentAt: Double)
    /// The pre-send guard or Ghostty refused; nothing was sent for this question.
    case failed(String)
}

/// Herdly's memory of one call: which question the Codex pane should now be on, which options were
/// sent or drafted, what the user has selected but not sent, and the phase. In memory only; a restart
/// returns the question as plain pending with nothing selected, so nothing is ever sent for it.
public struct QuestionAnswerProgress: Equatable, Sendable {
    /// Seconds after the last key within which the rollout is expected to record the answer.
    public static let confirmationWindow: Double = 10

    public let call: QuestionIdentity
    /// The question the Codex pane should now be showing (zero-based).
    public private(set) var questionIndex: Int
    /// Zero-based option index sent or drafted, by question index.
    public private(set) var picks: [Int: Int]
    /// Typed answers drafted for the daemon path, by question index. Never used for a key relay.
    public private(set) var texts: [Int: String]
    /// What the user selected for a question and has not yet sent or drafted with Next (D16), by
    /// question index. Selecting never sends: only Send (or Next on the daemon path) uses it.
    public private(set) var selected: [Int: ChosenAnswer]
    public private(set) var phase: QuestionAnswerPhase

    public init(call: QuestionIdentity) {
        self.call = call
        self.questionIndex = 0
        self.picks = [:]
        self.texts = [:]
        self.selected = [:]
        self.phase = .ready
    }

    /// The answer the card shows as chosen for a question: the unsent selection, else the answer
    /// Herdly drafted or sent for it.
    public func selection(for index: Int) -> ChosenAnswer? {
        selected[index] ?? answer(for: index)
    }

    /// A click on an option, or its digit (D16): selects it and sends nothing. Only the question the
    /// card is answering may be selected; a later one can be read but not answered out of order. With
    /// `revisesDrafts` (the daemon path only, whose earlier answers are unsent drafts) an earlier
    /// drafted question's answer is replaced in place; a sent key is never revised. The caller has
    /// already applied its route's policy to `answer`.
    public func selecting(question index: Int, answer: ChosenAnswer, revisesDrafts: Bool = false) -> QuestionAnswerProgress {
        guard canSelect(question: index, revisesDrafts: revisesDrafts) else { return self }
        guard index == questionIndex else { return replacingDraft(question: index, answer: answer) }
        var next = self
        next.selected[index] = answer
        return next
    }

    /// Whether question `index` takes a selection now: the question being answered, or with
    /// `revisesDrafts` (the daemon path) an earlier question whose answer is an unsent draft.
    public func canSelect(question index: Int, revisesDrafts: Bool = false) -> Bool {
        guard phase == .ready else { return false }
        if index == questionIndex { return answer(for: index) == nil }
        return revisesDrafts && index >= 0 && index < questionIndex && answer(for: index) != nil
    }

    /// The answer held for a question, drafted or sent.
    public func answer(for index: Int) -> ChosenAnswer? {
        if let option = picks[index] { return .option(option) }
        if let text = texts[index] { return .text(text) }
        return nil
    }

    /// The offer for question `index`: digits only when Herdly holds the complete option list Codex
    /// shows for it. Anything Herdly cannot number exactly stays in Codex.
    public static func offer(_ question: AttentionQuestion, at index: Int) -> QuestionOffer {
        guard !question.prompts.isEmpty else { return .continueInCodex("Herdly could not read this question.") }
        guard index >= 0, index < question.prompts.count else {
            return .continueInCodex("This question is beyond what Herdly can show.")
        }
        let prompt = question.prompts[index]
        guard !prompt.isSecret else { return .continueInCodex(QuestionCardLines.secret) }
        guard !prompt.options.isEmpty else { return .continueInCodex("This question takes a typed answer.") }
        guard prompt.optionsComplete, prompt.options.count <= QuestionAnswerPolicy.maximumDigit else {
            return .continueInCodex("Codex lists more options than Herdly can show.")
        }
        return .options(prompt.options)
    }

    public var offersButtons: Bool { phase == .ready }

    /// `.ready` → `.sending` for the current question. The caller has already applied the policy.
    public func startingSend(question index: Int, option: Int) -> QuestionAnswerProgress {
        startingSend(question: index)
    }

    /// `.ready` → `.sending` for the current question, whatever the answer's kind.
    public func startingSend(question index: Int) -> QuestionAnswerProgress {
        var next = self
        guard phase == .ready, index == questionIndex, answer(for: index) == nil else { return self }
        next.phase = .sending
        return next
    }

    /// Forgets every unsent selection, keeping drafts and sent answers. Used when the card's route
    /// changed after the user selected, so a selection is never sent by a route it was not made on.
    public func clearingSelections() -> QuestionAnswerProgress {
        var next = self
        next.selected = [:]
        return next
    }

    /// Daemon path: keeps a non-last question's answer without sending anything and moves on to the
    /// next question. The whole call is sent as one response after the last answer.
    public func recordingDraft(question index: Int, answer: ChosenAnswer) -> QuestionAnswerProgress {
        var next = self
        guard phase == .ready, index == questionIndex, self.answer(for: index) == nil else { return self }
        next.store(answer, at: index)
        next.questionIndex = index + 1
        return next
    }

    /// Only the daemon policy may replace an unsent draft; terminal progress never calls this.
    public func replacingDraft(question index: Int, answer: ChosenAnswer) -> QuestionAnswerProgress {
        guard phase == .ready, index >= 0, index < questionIndex, self.answer(for: index) != nil else { return self }
        var next = self
        next.store(answer, at: index)
        return next
    }

    /// Records a delivered key. A non-last question advances the expected pane position and stays
    /// ready; the last question waits for the rollout output.
    public func recordingSent(question index: Int, option: Int, of question: AttentionQuestion, at now: Double) -> QuestionAnswerProgress {
        recordingSent(question: index, answer: .option(option), of: question, at: now)
    }

    /// Records a delivered answer (a key through Ghostty, or the whole call's response through the
    /// daemon, in which case `index` is the last question).
    public func recordingSent(question index: Int, answer: ChosenAnswer, of question: AttentionQuestion, at now: Double) -> QuestionAnswerProgress {
        var next = self
        guard phase == .sending, index == questionIndex else { return self }
        next.store(answer, at: index)
        if index + 1 < question.questionCount {
            next.questionIndex = index + 1
            next.phase = .ready
        } else {
            next.phase = .sent(at: now)
        }
        return next
    }

    private mutating func store(_ answer: ChosenAnswer, at index: Int) {
        switch answer {
        case let .option(option): picks[index] = option; texts[index] = nil
        case let .text(text): texts[index] = text; picks[index] = nil
        }
        selected[index] = nil
    }

    /// Nothing was sent; the reason is shown and the call is never retried by Herdly.
    public func recordingFailure(_ reason: String) -> QuestionAnswerProgress {
        var next = self
        guard phase == .sending else { return self }
        next.phase = .failed(reason)
        return next
    }

    /// A sent last answer with no output inside the window becomes unconfirmed, for good.
    public func expiring(at now: Double) -> QuestionAnswerProgress {
        guard case let .sent(at) = phase, now - at >= Self.confirmationWindow else { return self }
        var next = self
        next.phase = .unconfirmed(sentAt: at)
        return next
    }
}

/// Whether one Send may become one key press. Mirrors `ApprovalDecisionPolicy`: it judges the
/// queue's current copy of the question, never the row that was rendered.
public enum QuestionAnswerPolicy {
    /// One key press carries one digit; Codex's pane binds 1 through 9.
    public static let maximumDigit = 9

    public enum Rejection: Equatable, Sendable {
        case notInQueue, notCLI, ghosttyDisabled, wrongQuestion, notOfferable, optionOutOfRange, notReady
    }

    /// Nil when the digit may be sent.
    public static func rejection(for current: AttentionQuestion?, ghosttyEnabled: Bool,
                                 progress: QuestionAnswerProgress, question index: Int, option: Int) -> Rejection? {
        guard let current, current.id == progress.call else { return .notInQueue }
        guard current.source == .cli else { return .notCLI }
        guard ghosttyEnabled else { return .ghosttyDisabled }
        guard index == progress.questionIndex else { return .wrongQuestion }
        guard case let .options(labels) = QuestionAnswerProgress.offer(current, at: index) else { return .notOfferable }
        guard option >= 0, option < labels.count, option + 1 <= maximumDigit else { return .optionOutOfRange }
        guard progress.phase == .ready, progress.picks[index] == nil else { return .notReady }
        return nil
    }

    /// The key name Ghostty receives for a zero-based option: its one-based digit.
    public static func key(forOption option: Int) -> String {
        precondition(option >= 0 && option < maximumDigit, "an option beyond the digit range is never sent")
        return String(option + 1)
    }
}

/// The pre-send check against the rollout as it is right now. Unreadable evidence is never "still pending".
public enum QuestionAnswerGuard {
    public static func stillPending(_ question: AttentionQuestion, in evidence: ReminderReader.RolloutEvidence) -> Bool {
        let turn = TurnIdentity(session: question.session, turn: question.turn)
        guard !evidence.completed.contains(turn), !evidence.canceled.contains(turn) else { return false }
        return evidence.pendingQuestions.contains { $0.session == question.session && $0.turn == question.turn && $0.callID == question.callID }
    }
}
