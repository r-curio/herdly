import Foundation

/// A question Codex posed to the user through its `request_user_input` tool: the desktop panel with
/// a question, numbered options, a Skip button and a free-text field. One call carries one or more
/// questions; identity is the call, since a turn can pose several calls in sequence.
public struct QuestionIdentity: Hashable, Codable, Sendable {
    public let source: AttentionSource
    public let session: UUID
    public let callID: String

    public init(source: AttentionSource, session: UUID, callID: String) {
        self.source = source
        self.session = session
        self.callID = callID
    }
}

/// One question inside a call, capped for display. Empty options means free text only.
public struct QuestionPrompt: Equatable, Sendable {
    public static let maximumQuestions = 8
    public static let maximumHeader = 80
    public static let maximumQuestion = 240
    public static let maximumOptions = 8
    public static let maximumLabel = 80
    public static let maximumArguments = 64 * 1024

    /// Codex's own id for the question; the daemon answer is keyed by it. Nil when unreadable.
    public let id: String?
    public let header: String?
    public let question: String?
    /// Option labels in Codex's own order; descriptions and the free-text field stay in Codex.
    /// Position matters: the notch relays an option as its one-based digit, so a label is never
    /// skipped. When one cannot be read the list stops there and `optionsComplete` is false.
    public let options: [String]
    /// True when any cap shortened this prompt; the view says the full text is in Codex.
    public let truncated: Bool
    /// Codex's `isOther`: the panel adds an "Other" free-text row after the listed options. The
    /// notch never offers or sends it.
    public let isOther: Bool
    /// False when Codex listed more options than Steer keeps or one label was unreadable, so the
    /// digits the notch could send would not cover Codex's list. Such a question stays in Codex.
    public let optionsComplete: Bool

    public init(id: String? = nil, header: String?, question: String?, options: [String], truncated: Bool = false,
                isOther: Bool = false, optionsComplete: Bool = true) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.truncated = truncated
        self.isOther = isOther
        self.optionsComplete = optionsComplete
    }

    /// Parses the tool's `arguments` JSON (`{"questions":[{header, question, isOther, options:[{label}]}]}`).
    /// Nil when the text is not that shape; the caller still records the question without text.
    public static func parse(arguments: String) -> [QuestionPrompt]? {
        parseCall(arguments: arguments)?.prompts
    }

    /// The parsed prompts plus Codex's raw question count, which can exceed the number kept.
    public static func parseCall(arguments: String) -> (prompts: [QuestionPrompt], count: Int)? {
        guard arguments.utf8.count <= maximumArguments,
              let root = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let questions = root["questions"] as? [[String: Any]] else { return nil }
        var prompts: [QuestionPrompt] = []
        for entry in questions.prefix(maximumQuestions) {
            var truncated = questions.count > maximumQuestions
            let id = (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let header = capped(entry["header"] as? String, to: maximumHeader, truncated: &truncated)
            let question = capped(entry["question"] as? String, to: maximumQuestion, truncated: &truncated)
            let isOther = entry["isOther"] as? Bool ?? false
            var options: [String] = []
            var complete = true
            if let raw = entry["options"] as? [[String: Any]] {
                if raw.count > maximumOptions { truncated = true; complete = false }
                for option in raw.prefix(maximumOptions) {
                    guard let label = capped(option["label"] as? String, to: maximumLabel, truncated: &truncated),
                          !label.isEmpty else { truncated = true; complete = false; break }
                    options.append(label)
                }
            } else if entry["options"] != nil, !(entry["options"] is NSNull) {
                // Options present but not a list: Codex may show choices Steer cannot number.
                truncated = true
                complete = false
            }
            prompts.append(QuestionPrompt(id: id, header: header, question: question, options: options, truncated: truncated,
                                          isOther: isOther, optionsComplete: complete))
        }
        return (prompts, questions.count)
    }

    private static func capped(_ text: String?, to limit: Int, truncated: inout Bool) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed.isEmpty ? nil : trimmed }
        truncated = true
        return String(trimmed.prefix(limit)) + "…"
    }

    /// Trimmed text shortened to `limit` with an ellipsis; nil when empty. The one display cap.
    public static func display(_ text: String?, limit: Int) -> String? {
        var truncated = false
        return capped(text, to: limit, truncated: &truncated)
    }
}

/// A question Codex is waiting on, read from the session rollout. Pending while the rollout shows
/// the call without an output for its call id. The companion relays only an option the user chose
/// in the notch (see `QuestionAnswerProgress`); it never chooses an answer itself.
public struct AttentionQuestion: Identifiable, Equatable, Sendable {
    public let source: AttentionSource
    public let session: UUID
    public let turn: UUID
    public let callID: String
    public let arrivedAt: Double
    /// Empty when the arguments could not be read; the call itself is still evidence Codex is blocked.
    public let prompts: [QuestionPrompt]
    /// How many questions Codex posed in this call; more than `prompts.count` when the cap applied.
    public let questionCount: Int
    public var id: QuestionIdentity { QuestionIdentity(source: source, session: session, callID: callID) }

    public init(source: AttentionSource = .desktop, session: UUID, turn: UUID, callID: String, arrivedAt: Double,
                prompts: [QuestionPrompt] = [], questionCount: Int? = nil) {
        self.source = source
        self.session = session
        self.turn = turn
        self.callID = callID
        self.arrivedAt = arrivedAt
        self.prompts = prompts
        self.questionCount = max(questionCount ?? prompts.count, prompts.count)
    }

    public func with(source: AttentionSource) -> AttentionQuestion {
        AttentionQuestion(source: source, session: session, turn: turn, callID: callID, arrivedAt: arrivedAt,
                          prompts: prompts, questionCount: questionCount)
    }
}
