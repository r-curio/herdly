import Foundation

/// A key pressed while a spotlight question card has the keyboard (#428, Paper L "Spotlight question
/// by keyboard"). The panel only receives keys once the hotkey or a click made it key, so a key typed
/// in another app never becomes one of these.
public enum SpotlightCardKey: Equatable, Sendable {
    case digit(Int)
    case returnKey
    /// O: the card's Open.
    case open
    /// X: the card's Dismiss.
    case dismiss
    /// ←: the previous question of the call.
    case previousQuestion
    /// →: the next question of the call.
    case nextQuestion
}

/// What one key does on the card. Only `primary` can lead to a send, and only through the card's own
/// Next or Send while it is enabled: no other key, no timer, and nothing after hand-back.
public enum SpotlightCardAction: Equatable, Sendable {
    /// Selects (or on a pick-several question toggles) option `n`, one-based. Never sends.
    case select(Int)
    /// The card's Next or Send, exactly as clicking it, only while it is enabled.
    case primary
    /// The card's Open, exactly as clicking it.
    case open
    /// The card's Dismiss, exactly as clicking it. Sends nothing.
    case dismiss
    /// Moves the viewed question by this many steps, as ‹ › do. Sends nothing.
    case step(Int)
    /// A digit on a keyboard card that cannot take one (read-only or handed back, Paper L frame 7:
    /// "digits do nothing"): the key is swallowed silently. Nothing is selected and nothing is sent.
    case consume
    /// The key does nothing here and goes on to the queue or macOS.
    case none

    /// Whether the panel takes the key rather than passing it on.
    public var consumesKey: Bool { self != .none }
}

/// Where a question card with the keyboard stands.
public enum SpotlightCardPhase: Equatable, Sendable {
    /// Herdly can answer it here.
    case answering
    /// Herdly cannot answer it here (the Codex app without the daemon, a question it cannot verify,
    /// one handed to the agent by Open): reference only, Return opens the agent.
    case readOnly
    /// Its countdown ended while the card had the keyboard: the agent asks again itself, no answer
    /// was sent, and Return opens the agent (Paper L "7 · Time runs out").
    case handedBack(askedAt: Double)
    /// The user's Send left Herdly; the panel folds a second later (Paper L "4 · Sent").
    case sent(SpotlightSentAnswer)
}

/// The one question card on screen as the key table sees it (#321, #428).
public enum SpotlightCardFocus: Equatable, Sendable {
    /// Shown, but the keyboard is not in it: a clicked card, or a spotlight before the hotkey or a
    /// click. Digits and Return reach it as before #428 (#321), and only while Herdly can answer it.
    case withoutKeyboard(answerable: Bool)
    /// A spotlight question card that has the keyboard.
    case keyboard(SpotlightCardPhase)
}

/// The one key table for a question card. A digit only ever selects, and only Return reaches the
/// card's Next or Send, only while Herdly can answer it: never after hand-back or once sent.
public enum SpotlightCardKeys {
    public static func action(for key: SpotlightCardKey, card: SpotlightCardFocus) -> SpotlightCardAction {
        switch card {
        case let .withoutKeyboard(answerable):
            guard answerable else { return .none }
            switch key {
            case let .digit(number): return (1...9).contains(number) ? .select(number) : .none
            case .returnKey: return .primary
            case .open, .dismiss, .previousQuestion, .nextQuestion: return .none
            }
        case .keyboard(.sent):
            return .none
        case .keyboard(.handedBack):
            switch key {
            case .returnKey, .open: return .open
            case let .digit(number): return (1...9).contains(number) ? .consume : .none
            case .dismiss, .previousQuestion, .nextQuestion: return .none
            }
        case .keyboard(.readOnly):
            switch key {
            case .returnKey, .open: return .open
            case .dismiss: return .dismiss
            case .previousQuestion: return .step(-1)
            case .nextQuestion: return .step(1)
            case let .digit(number): return (1...9).contains(number) ? .consume : .none
            }
        case .keyboard(.answering):
            switch key {
            case let .digit(number): return (1...9).contains(number) ? .select(number) : .none
            case .returnKey: return .primary
            case .open: return .open
            case .dismiss: return .dismiss
            case .previousQuestion: return .step(-1)
            case .nextQuestion: return .step(1)
            }
        }
    }
}

/// What a card says once its Send left Herdly: "Sent to Claude: 2 · Every workflow that mentions it".
/// Sending does not establish that the agent acted on it; the row follows the agent's own events.
public struct SpotlightSentAnswer: Equatable, Sendable {
    /// One question's answer as it was sent.
    public enum Pick: Equatable, Sendable {
        /// Zero-based option indexes; several on a pick-several question.
        case options([Int])
        case typed(String)

        /// What the user's selection sends: a non-blank typed answer takes the place of the options
        /// (as `ClaudeQuestionSelection` and the daemon field both rule), otherwise the options in order.
        public init(typed: String, options: [Int]) {
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            self = text.isEmpty ? .options(options.sorted()) : .typed(text)
        }
    }

    public let line: String
    /// The last question's text and options, drawn dim under the line with the sent ones filled.
    public let question: String?
    public let options: [String]
    public let chosen: Set<Int>

    /// `lastPick` is the last question's answer; a call of several questions reads "<n> answers".
    public static func make(agent: String, prompts: [QuestionPrompt], lastPick: Pick) -> Self {
        let shown = prompts.last
        let chosen: Set<Int> = if case let .options(indexes) = lastPick { Set(indexes) } else { [] }
        let line: String
        if prompts.count > 1 {
            line = "Sent to \(agent): \(prompts.count) answers"
        } else {
            switch lastPick {
            case let .options(indexes):
                let sorted = indexes.sorted()
                let labels = sorted.map { index in
                    shown.flatMap { $0.options.indices.contains(index) ? QuestionOptionLabel($0.options[index]).text : nil }
                        ?? "option \(index + 1)"
                }
                line = "Sent to \(agent): \(sorted.map { String($0 + 1) }.joined(separator: ", ")) · \(labels.joined(separator: ", "))"
            case let .typed(text):
                line = "Sent to \(agent): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
        return Self(line: line, question: shown?.question, options: shown?.options ?? [], chosen: chosen)
    }
}

/// The question card that has the keyboard (#428): whether Herdly can still answer it, whether its
/// countdown ended while the user was on it, and the confirmation of a Send. Time is wall-clock
/// seconds, the same clock as a Claude question's deadline. Memory only.
public struct SpotlightKeyboardCard: Equatable, Sendable {
    /// A Claude question's countdown: when it was asked and its current (possibly held) deadline.
    public struct Window: Equatable, Sendable {
        public let askedAt: Double
        public let deadline: Double
        public init(askedAt: Double, deadline: Double) {
            self.askedAt = askedAt
            self.deadline = deadline
        }
    }

    /// How long the sent line shows before the panel folds.
    public static let sentHold: Double = 1

    public private(set) var card: AgentAttentionID?
    private var window: Window?
    private var handedBackAskedAt: Double?
    private var armed: SpotlightSentAnswer?
    private var sent: SpotlightSentAnswer?
    private var foldAt: Double?

    public init() {}

    /// One refresh. `card` is the spotlight question that has the keyboard, or nil; `answerable` is
    /// whether Herdly can answer it now; `window` its countdown while it can. A different card starts
    /// over. Nil when no card has the keyboard.
    public mutating func observe(card: AgentAttentionID?, answerable: Bool, window: Window?, now: Double) -> SpotlightCardPhase? {
        if card != self.card { self = Self(); self.card = card }
        guard card != nil else { return nil }
        if let sent { return .sent(sent) }
        if let handedBackAskedAt { return .handedBack(askedAt: handedBackAskedAt) }
        if answerable {
            if let window { self.window = window }
            return .answering
        }
        // Answerability ended. Only the countdown running out is a hand-back; anything else (Open,
        // the helper gone) leaves a card to read.
        if let window = self.window, now >= window.deadline {
            handedBackAskedAt = window.askedAt
            return .handedBack(askedAt: window.askedAt)
        }
        return .readOnly
    }

    /// The card is about to send `answer`. Nothing shows until the send is confirmed.
    public mutating func arm(_ answer: SpotlightSentAnswer, for card: AgentAttentionID) {
        guard card == self.card, sent == nil else { return }
        armed = answer
    }

    /// The route recorded that the armed send left Herdly. True when the card now shows it.
    @discardableResult
    public mutating func confirmSent(for card: AgentAttentionID, now: Double) -> Bool {
        guard card == self.card, let armed, sent == nil else { return false }
        sent = armed
        self.armed = nil
        foldAt = now + Self.sentHold
        return true
    }

    /// The sent line has shown its second: the panel folds and the keyboard goes back.
    public func foldDue(now: Double) -> Bool {
        foldAt.map { now >= $0 } ?? false
    }

    /// The card whose sent line is still within its second. The presentation keeps it on screen even
    /// if its question has already left the queue, so the line always shows for the whole second.
    public func keepsSentCard(now: Double) -> AgentAttentionID? {
        guard sent != nil, let foldAt, now < foldAt else { return nil }
        return card
    }

    /// The card handed back with no answer: its keyboard hold has ended. It follows its normal
    /// spotlight open time from here, as if focus had just left (#428).
    public var endsKeyboardHold: Bool { handedBackAskedAt != nil }
}

/// A new approval or question that arrives while a spotlight card has the keyboard waits behind it
/// (Paper L "8 · Another one arrives"); it takes the spotlight once Send or Escape ends the hold. Its
/// own deadline keeps running: waiting changes nothing about the request.
public enum SpotlightKeyboardWait {
    /// The waiting request the line names: the one that would take the spotlight next, by the
    /// spotlight's own priority rule. Results never wait here.
    public static func waiting(behind focused: AgentAttentionID, items: [AgentAttentionItem],
                               fresh: Set<AgentAttentionID>) -> AgentAttentionItem? {
        let candidates = fresh.filter { $0 != focused && $0.isRequest }
        let id = AgentPresentationSelection.highestPriority(in: items, candidates: candidates)
        return items.first { $0.id == id }
    }

    public static func line(_ item: AgentAttentionItem, name: String) -> String {
        "\(name) \(item.kind == .question ? "needs an answer" : "needs approval") · next"
    }
}

/// The one dim line under a spotlight question card (Paper L frames 1, 2, 4, 5 and 7), built from
/// parts that carry both what is shown and what VoiceOver says.
public struct SpotlightCardFoot: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public let shown: String
        public let spoken: String
    }

    public let parts: [Part]
    public var text: String { parts.map(\.shown).joined(separator: " · ") }
    public var spoken: String { parts.map(\.spoken).joined(separator: ", ") }

    /// - Parameters:
    ///   - returnApp: the app Escape gives the keyboard back to, when known (`NotchKeyboardReturn.target`).
    ///   - hotkey: the notch hotkey's title while it is on and registered; nil otherwise.
    public static func make(card: SpotlightCardFocus, questionCount: Int, viewedIsLast: Bool,
                            returnApp: String?, hotkey: String?) -> Self? {
        let back = returnApp.map { Part(shown: "esc back to \($0)", spoken: "Escape goes back to \($0)") }
            ?? Part(shown: "esc close", spoken: "Escape closes")
        let steps = questionCount > 1 ? [Part(shown: "← → step", spoken: "left and right arrows step between questions")] : []
        let open = Part(shown: "⏎ open", spoken: "Return opens the agent")
        switch card {
        case let .withoutKeyboard(answerable):
            // "Answer here" would be false on a card Herdly cannot answer, and the key must work.
            guard answerable, let hotkey else { return nil }
            return Self(parts: [Part(shown: "\(hotkey) to answer here", spoken: "Press \(hotkey) to answer here")])
        case .keyboard(.sent):
            let seconds = Int(SpotlightKeyboardCard.sentHold.rounded())
            return Self(parts: [returnApp.map { Part(shown: "Back to \($0) in \(seconds)s",
                                                      spoken: "Back to \($0) in \(seconds) second\(seconds == 1 ? "" : "s")") }
                ?? Part(shown: "Closing in \(seconds)s", spoken: "Closing in \(seconds) second\(seconds == 1 ? "" : "s")")])
        case .keyboard(.handedBack):
            return Self(parts: [open, back])
        case .keyboard(.readOnly):
            return Self(parts: [open] + steps + [back])
        case .keyboard(.answering):
            let pick = Part(shown: "1–9 pick", spoken: "1 to 9 picks")
            let primary = questionCount > 1 && !viewedIsLast
                ? Part(shown: "⏎ next", spoken: "Return goes to the next question")
                : Part(shown: "⏎ send", spoken: "Return sends")
            return Self(parts: [pick, primary] + steps + [back])
        }
    }
}

public enum SpotlightCardLines {
    /// "Handed back with no answer · asked 30s ago".
    public static func handedBack(askedAt: Double, now: Double) -> String {
        let seconds = max(0, now - askedAt)
        let ago = seconds < 60 ? "\(Int(seconds))s ago" : SpotlightRequest.elapsed(since: askedAt, now: now)
        return "Handed back with no answer · asked \(ago)"
    }
}
