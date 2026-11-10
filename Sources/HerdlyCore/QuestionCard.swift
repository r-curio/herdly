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

/// A Claude question's answer as the user composes it, before Send (#321, D16): the options they
/// ticked (single-select keeps one, multi-select toggles) or the text they typed, never both. Typing
/// text clears the options and selecting an option clears the text, so one Send carries exactly one
/// unambiguous answer. Nothing is sent until Send, and Send needs an option or non-blank text.
public struct ClaudeQuestionSelection: Equatable, Sendable {
    public let multiSelect: Bool
    public private(set) var options: Set<Int> = []
    /// The typed answer as it stands in the field; empty when an option was selected since.
    public private(set) var text: String = ""

    public init(multiSelect: Bool) {
        self.multiSelect = multiSelect
    }

    /// The selection after a click on option `option` of `count`; an option out of range is ignored.
    public func toggling(_ option: Int, of count: Int) -> ClaudeQuestionSelection {
        guard option >= 0, option < count else { return self }
        var next = self
        next.text = ""
        if multiSelect {
            if !next.options.insert(option).inserted { next.options.remove(option) }
        } else {
            next.options = [option]
        }
        return next
    }

    /// The selection after the field's text changed. Any non-blank text clears the options.
    public func typing(_ text: String) -> ClaudeQuestionSelection {
        var next = self
        next.text = text
        if !trimmed(text).isEmpty { next.options = [] }
        return next
    }

    public var canSend: Bool { !options.isEmpty || !trimmed(text).isEmpty }

    /// What Send carries: the trimmed typed text as `.text`; otherwise the one label as `.option`, or
    /// the ticked labels in list order joined by ", " as `.multiSelect`. Nil while nothing is selected
    /// or an option is no longer in `labels`. The helper's own policy still judges the answer.
    public func answer(labels: [String]) -> (kind: ClaudeQuestionAnswerKind, answer: String)? {
        let typed = trimmed(text)
        if !typed.isEmpty { return (.text, typed) }
        guard !options.isEmpty, options.allSatisfy(labels.indices.contains) else { return nil }
        return (multiSelect ? .multiSelect : .option, options.sorted().map { labels[$0] }.joined(separator: ", "))
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A Claude call's answers as the user composes them on the step-through card (#382, #388): one
/// `ClaudeQuestionSelection` per question. Every question can be selected or typed at any time, in
/// any order, however the card reached it (arrows, step names or Next); picking or typing only
/// selects. Next only moves the card on to the next question. Send on the last question hands the
/// whole set to the helper at once, in question order, and only a complete set. A one-question call
/// is the same card with Send at once. View state only; never persisted, and the helper's own policy
/// still judges the set. Unlike a Codex card this has no answering position: Codex key routes type
/// digits in order, a Claude call is one hook output (ADR 0021, amended by #388).
public struct ClaudeQuestionCallSelection: Equatable, Sendable {
    private let optionCounts: [Int]
    private var selections: [ClaudeQuestionSelection]
    /// The question the card shows unless the user stepped elsewhere (zero-based): the first, then
    /// wherever Next last moved on to. It gates nothing; any question is answerable (#388). It is not
    /// "the first unanswered question", because that would move the view while the user selects.
    public private(set) var current: Int = 0

    public init(prompts: [QuestionPrompt]) {
        optionCounts = prompts.map(\.options.count)
        selections = prompts.map { ClaudeQuestionSelection(multiSelect: $0.multiSelect) }
    }

    public var count: Int { selections.count }

    /// Question `index`'s selection; an empty one beyond the call.
    public func selection(at index: Int) -> ClaudeQuestionSelection {
        selections.indices.contains(index) ? selections[index] : ClaudeQuestionSelection(multiSelect: false)
    }

    /// Any question of the call, in any order (#388); never one beyond it.
    public func canSelect(question index: Int) -> Bool {
        selections.indices.contains(index)
    }

    /// A click on option `option` of question `index` (`ClaudeQuestionSelection.toggling`).
    public func toggling(_ option: Int, at index: Int) -> ClaudeQuestionCallSelection {
        guard canSelect(question: index) else { return self }
        var next = self
        next.selections[index] = selections[index].toggling(option, of: optionCounts[index])
        return next
    }

    /// Question `index`'s typed answer changed (`ClaudeQuestionSelection.typing`).
    public func typing(_ text: String, at index: Int) -> ClaudeQuestionCallSelection {
        guard canSelect(question: index) else { return self }
        var next = self
        next.selections[index] = selections[index].typing(text)
        return next
    }

    /// Next from question `index`: moves the card on to the following question, keeping every
    /// selection. Sends nothing and unlocks nothing; refused on the last question.
    public func advancing(from index: Int) -> ClaudeQuestionCallSelection {
        guard index >= 0, index + 1 < count else { return self }
        var next = self
        next.current = index + 1
        return next
    }

    /// The card's answering button for the viewed question (#388): Next before the last question,
    /// enabled while the viewed question has an answer (an unanswered one is left by the arrows or the
    /// rail); Send on the last question, enabled only when every question has an answer. Never a step
    /// on: no question is ever only for review. Codex cards keep `QuestionCardPrimary.make`.
    public func primary(viewed: Int) -> QuestionCardPrimary {
        viewed >= count - 1 ? .send(enabled: answersAreComplete)
                            : .next(enabled: selection(at: viewed).canSend)
    }

    private var answersAreComplete: Bool {
        count > 0 && selections.allSatisfy(\.canSend)
    }

    /// The whole set Send carries, in question order, or nil unless every question has an answer and
    /// `prompts` are the questions this selection was made for.
    public func answers(prompts: [QuestionPrompt]) -> [ClaudeQuestionAnswerEntry]? {
        guard answersAreComplete, prompts.map(\.options.count) == optionCounts,
              prompts.map(\.multiSelect) == selections.map(\.multiSelect) else { return nil }
        var entries: [ClaudeQuestionAnswerEntry] = []
        for (prompt, selection) in zip(prompts, selections) {
            guard let answer = selection.answer(labels: prompt.options) else { return nil }
            entries.append(ClaudeQuestionAnswerEntry(kind: answer.kind, answer: answer.answer))
        }
        return entries
    }

    /// What the step rail shows for question `index`: its option, its ticked labels, or its text, as
    /// it stands now, whatever the question's position (#388); nil while it holds no answer. Display
    /// only.
    public func railAnswer(at index: Int, labels: [String]) -> ChosenAnswer? {
        let selection = selection(at: index)
        guard let answer = selection.answer(labels: labels) else { return nil }
        switch answer.kind {
        case .option: return selection.options.first.map(ChosenAnswer.option)
        case .multiSelect: return .text(selection.options.sorted().map { QuestionOptionLabel(labels[$0]).text }
            .joined(separator: ", "))
        case .text: return .text(answer.answer)
        }
    }
}

extension QuestionAnswerRoute {
    /// The routes that type one option digit per Send (Ghostty, herdr, a terminal host's pane; ADR
    /// 0006, ADR 0017). They carry no typed answer and never revise a sent answer.
    public var isKeyRoute: Bool {
        switch self {
        case .ghosttyRelay, .herdrRelay, .terminalRelay: true
        case .daemon, .daemonAnswered, .relayUnavailable, .desktopReadOnly: false
        }
    }

    /// The daemon's request when the card answers through it and the request holds questions.
    public var daemonRequest: AppServerQuestionRequest? {
        if case let .daemon(request) = self, !request.questions.isEmpty { return request }
        return nil
    }
}

/// Which of a Codex question card's options can be selected (#321). Display rules only: every Send
/// still runs its route's own policy and fresh pending-request check.
public enum QuestionCardOptions {
    /// The option labels the card shows for question `index`: the daemon's own list on the daemon
    /// path, otherwise the rollout prompt's; empty beyond either.
    public static func options(route: QuestionAnswerRoute, question: AttentionQuestion, at index: Int) -> [String] {
        if let request = route.daemonRequest {
            return request.questions.indices.contains(index) ? request.questions[index].displayPrompt.options : []
        }
        return question.prompts.indices.contains(index) ? question.prompts[index].options : []
    }

    /// Whether the viewed question's options can be selected now: the question being answered, or on
    /// the daemon path an earlier unsent draft (`QuestionAnswerProgress.canSelect`). Never a secret, a
    /// question a key route cannot number, a read-only route, or a route without option controls.
    public static func selectable(route: QuestionAnswerRoute, question: AttentionQuestion, progress: QuestionAnswerProgress,
                                  viewed: Int, controls: Bool) -> Bool {
        guard controls else { return false }
        if let request = route.daemonRequest {
            guard request.questions.indices.contains(viewed), !request.questions[viewed].isSecret else { return false }
            return progress.canSelect(question: viewed, revisesDrafts: true)
        }
        guard route.isKeyRoute, case .options = QuestionAnswerProgress.offer(question, at: viewed) else { return false }
        return progress.canSelect(question: viewed)
    }
}

/// Text typed in a daemon card's "Or type an answer" field, by question index, before it becomes a
/// draft (#321). What the card shows is what Send sends: an earlier step's text becomes its draft only
/// on Return, and is discarded when the card leaves that step; the step being answered keeps its text
/// for Next or Send. Text belongs to the route (and daemon request) it was typed on and is never
/// offered to another. View state only; never persisted.
public struct QuestionTypedDrafts: Equatable, Sendable {
    public private(set) var route: QuestionAnswerRoute?
    private var edits: [Int: String] = [:]

    public init() {}

    public var hasEdits: Bool { !edits.isEmpty }

    /// The field's text for question `index`: this route's edit, else the drafted text, else empty.
    public func text(for index: Int, route: QuestionAnswerRoute, progress: QuestionAnswerProgress) -> String {
        if self.route == route, let edit = edits[index] { return edit }
        if case let .text(text) = progress.answer(for: index) { return text }
        return ""
    }

    /// The user typed in question `index`'s field. Text typed under another route is dropped first.
    public func editing(_ index: Int, text: String, route: QuestionAnswerRoute) -> QuestionTypedDrafts {
        var next = self.route == route ? self : QuestionTypedDrafts()
        next.route = route
        next.edits[index] = text
        return next
    }

    /// The card left question `index`. An earlier question's unsubmitted text is discarded, so the
    /// step shows its draft again; the question being answered (`current`) keeps its text.
    public func leaving(_ index: Int, current: Int) -> QuestionTypedDrafts {
        guard index < current else { return self }
        var next = self
        next.edits[index] = nil
        return next
    }

    /// The progress changed: an edit equal to what is now drafted for its question is no longer one.
    public func committing(_ progress: QuestionAnswerProgress) -> QuestionTypedDrafts {
        var next = self
        for (index, edit) in edits {
            if case let .text(text) = progress.answer(for: index),
               text.trimmingCharacters(in: .whitespacesAndNewlines) == edit.trimmingCharacters(in: .whitespacesAndNewlines) {
                next.edits[index] = nil
            }
        }
        return next
    }
}
