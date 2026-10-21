import Foundation

/// The question card's fixed sentences (#321, D24). Display only; none of them is ever sent.
public enum QuestionCardLines {
    /// A question Codex marked secret: the notch is not a private surface, so it offers nothing.
    public static let secret = "Herdly never shows or relays secret answers."
    /// A Codex app question the daemon does not hold: its options are for reading only.
    public static let desktopReadOnly = "Herdly can't answer the Codex app. Answer it there."
    /// A key route carries only the listed options' digits; Other, Skip and typed answers stay in Codex.
    public static let otherAnswersInCodex = "Other answers go in Codex."

    /// The clicked card's stepper caption for the viewed question (D19, this request's questions only).
    public static func stepper(viewed: Int, count: Int) -> String {
        "question \(viewed + 1) of \(count)"
    }

    /// What a key route's card says about the digit it typed. `noun` is the key destination's noun
    /// ("tab" or "pane", `HerdrPresentation.keyDestination`). `next` is the question Codex should now
    /// show (zero-based) after an earlier question's key; nil for the last question's key.
    public static func typed(digit: Int, noun: String, next: Int?) -> String {
        let typed = "Typed \(digit) into this session's \(noun)."
        guard let next else { return typed + " Waiting for Codex to record the answer." }
        return typed + " Codex should now show question \(next + 1)."
    }

    /// The last question's key with no recorded answer after the confirmation window.
    public static func typedUnconfirmed(digit: Int, noun: String) -> String {
        "Typed \(digit) into this session's \(noun), but Codex has not recorded an answer. Check the \(noun); Herdly will not resend."
    }

    /// An earlier question whose key was already typed: review only.
    public static func typedReview(digit: Int, noun: String) -> String {
        "Typed \(digit) into this session's \(noun). It can't be changed here."
    }
}

/// The left button of a question card's bottom row (#321, 6AD): Next on the daemon path before the
/// last question, Send otherwise, or a step on to the next question while reviewing an earlier one.
public enum QuestionCardPrimary: Equatable, Sendable {
    /// Daemon path: keep the selection as a draft and move to the next question. Sends nothing.
    case next(enabled: Bool)
    /// Send the selection: the whole call on the daemon path, one key on a key route.
    case send(enabled: Bool)
    /// Reviewing an earlier question: move the view to `to`; changes nothing.
    case step(to: Int)

    public var enabled: Bool {
        switch self {
        case let .next(enabled), let .send(enabled): enabled
        case .step: true
        }
    }

    /// - Parameters:
    ///   - daemon: the daemon path, which drafts every answer and writes the call once; otherwise a
    ///     key route, where every Send types one digit for the current question (ADR 0006, 0017).
    ///   - viewed: the question on screen; `current` the one being answered; `count` the call's size.
    ///   - selected: whether the viewed question holds an answer to send.
    ///   - ready: whether the progress takes an answer now (`QuestionAnswerPhase.ready`).
    public static func make(daemon: Bool, viewed: Int, current: Int, count: Int, selected: Bool,
                            ready: Bool) -> QuestionCardPrimary {
        let last = viewed >= count - 1
        if viewed < current, !last { return .step(to: viewed + 1) }
        let answerable = viewed == current && selected && ready
        return daemon && !last ? .next(enabled: answerable) : .send(enabled: answerable)
    }
}

/// A Claude question's options as the user ticks them, before Send (#321, D16). Single-select keeps
/// one option; multi-select toggles. Nothing is sent until Send, and Send needs at least one option.
public struct ClaudeQuestionSelection: Equatable, Sendable {
    public let multiSelect: Bool
    public private(set) var options: Set<Int> = []

    public init(multiSelect: Bool) {
        self.multiSelect = multiSelect
    }

    /// The selection after a click on option `option` of `count`; an option out of range is ignored.
    public func toggling(_ option: Int, of count: Int) -> ClaudeQuestionSelection {
        guard option >= 0, option < count else { return self }
        var next = self
        if multiSelect {
            if !next.options.insert(option).inserted { next.options.remove(option) }
        } else {
            next.options = [option]
        }
        return next
    }

    public var canSend: Bool { !options.isEmpty }

    /// The answer text Send carries: the one label, or the ticked labels in list order joined by
    /// ", ". Nil while nothing is selected or an option is no longer in `labels`.
    public func answer(labels: [String]) -> String? {
        guard canSend, options.allSatisfy(labels.indices.contains) else { return nil }
        return options.sorted().map { labels[$0] }.joined(separator: ", ")
    }
}
