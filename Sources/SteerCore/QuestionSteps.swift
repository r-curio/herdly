import Foundation

/// Display-only question rail. The viewed step is independent of answer progress; summaries
/// describe only answers Steer itself drafted or sent, never source acknowledgment.
public struct QuestionSteps: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case answered
        case current
        case upcoming
    }

    public struct Step: Equatable, Sendable, Identifiable {
        public let id: Int
        public let label: String
        public let state: State
        public let summary: String?
        public let canEdit: Bool
    }

    public struct Answered: Equatable, Sendable {
        public let label: String
        public let answer: String
    }

    public let steps: [Step]
    /// Earlier questions with an answer Steer holds, in order. An earlier question Steer holds no
    /// answer for is marked answered on the rail but gets no line, so nothing is invented.
    public let answered: [Answered]

    /// - Parameters:
    ///   - prompts: the call's questions in order.
    ///   - current: the question the card is on; clamped to the list.
    ///   - answer: the answer Steer holds for a question index, if any.
    public static func make(_ prompts: [QuestionPrompt], current: Int, viewed: Int? = nil,
                            editable: Bool = false, currentStatus: String? = "Answering now", answer: (Int) -> ChosenAnswer?) -> QuestionSteps {
        guard !prompts.isEmpty else { return QuestionSteps(steps: [], answered: []) }
        let current = min(max(current, 0), prompts.count - 1)
        let viewed = min(max(viewed ?? current, 0), prompts.count - 1)
        var steps: [Step] = []
        var answered: [Answered] = []
        for (index, prompt) in prompts.enumerated() {
            let label = label(prompt, index: index)
            let state: State = index == viewed ? .current : (index < current ? .answered : .upcoming)
            let summary: String?
            switch answer(index) {
            case let .option(option):
                summary = prompt.options.indices.contains(option) ? QuestionOptionLabel(prompt.options[option]).text : "Option \(option + 1)"
            case let .text(text): summary = text
            case nil: summary = index == current ? currentStatus : (currentStatus == nil ? nil : "Not answered yet")
            }
            steps.append(Step(id: index, label: label, state: state, summary: summary,
                              canEdit: editable && index < current && index != viewed && answer(index) != nil))
            guard index < current, let chosen = answer(index) else { continue }
            switch chosen {
            case let .option(option):
                let text = prompt.options.indices.contains(option) ? prompt.options[option] : "Option \(option + 1)"
                answered.append(Answered(label: label, answer: text))
            case let .text(text):
                answered.append(Answered(label: label, answer: text))
            }
        }
        return QuestionSteps(steps: steps, answered: answered)
    }

    /// The question's own short header, or its position when the agent gave none.
    public static func label(_ prompt: QuestionPrompt, index: Int) -> String {
        let header = prompt.header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return header.isEmpty ? "Question \(index + 1)" : header
    }

    /// The one sentence a read-only card leads with, instead of a warning above every question.
    public static func answerElsewhere(count: Int, agent: String) -> String {
        count > 1 ? "\(agent) is asking \(count) questions. Answer them in \(agent)."
                  : "\(agent) is asking a question. Answer it in \(agent)."
    }
}

/// Display only: the original option label remains the exact value sent to the agent.
public struct QuestionOptionLabel: Equatable, Sendable {
    public let text: String
    public let recommended: Bool

    public init(_ label: String) {
        let suffix = " (Recommended)"
        recommended = label.hasSuffix(suffix) && label.count > suffix.count
        text = recommended ? String(label.dropLast(suffix.count)) : label
    }
}
