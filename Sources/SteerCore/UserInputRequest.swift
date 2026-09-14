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

    public let header: String?
    public let question: String?
    /// Option labels only; descriptions and the free-text field stay in Codex.
    public let options: [String]
    /// True when any cap shortened this prompt; the view says the full text is in Codex.
    public let truncated: Bool

    public init(header: String?, question: String?, options: [String], truncated: Bool = false) {
        self.header = header
        self.question = question
        self.options = options
        self.truncated = truncated
    }

    /// Parses the tool's `arguments` JSON (`{"questions":[{header, question, options:[{label}]}]}`).
    /// Nil when the text is not that shape; the caller still records the question without text.
    public static func parse(arguments: String) -> [QuestionPrompt]? {
        guard arguments.utf8.count <= maximumArguments,
              let root = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let questions = root["questions"] as? [[String: Any]] else { return nil }
        var prompts: [QuestionPrompt] = []
        for entry in questions.prefix(maximumQuestions) {
            var truncated = questions.count > maximumQuestions
            let header = capped(entry["header"] as? String, to: maximumHeader, truncated: &truncated)
            let question = capped(entry["question"] as? String, to: maximumQuestion, truncated: &truncated)
            var options: [String] = []
            if let raw = entry["options"] as? [[String: Any]] {
                if raw.count > maximumOptions { truncated = true }
                for option in raw.prefix(maximumOptions) {
                    guard let label = capped(option["label"] as? String, to: maximumLabel, truncated: &truncated),
                          !label.isEmpty else { continue }
                    options.append(label)
                }
            }
            prompts.append(QuestionPrompt(header: header, question: question, options: options, truncated: truncated))
        }
        return prompts
    }

    private static func capped(_ text: String?, to limit: Int, truncated: inout Bool) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed.isEmpty ? nil : trimmed }
        truncated = true
        return String(trimmed.prefix(limit)) + "…"
    }
}

/// A question Codex is waiting on, read from the session rollout. Pending while the rollout shows
/// the call without an output for its call id; the companion never answers it.
public struct AttentionQuestion: Identifiable, Equatable, Sendable {
    public let source: AttentionSource
    public let session: UUID
    public let turn: UUID
    public let callID: String
    public let arrivedAt: Double
    /// Empty when the arguments could not be read; the call itself is still evidence Codex is blocked.
    public let prompts: [QuestionPrompt]
    public var id: QuestionIdentity { QuestionIdentity(source: source, session: session, callID: callID) }

    public init(source: AttentionSource = .desktop, session: UUID, turn: UUID, callID: String, arrivedAt: Double,
                prompts: [QuestionPrompt] = []) {
        self.source = source
        self.session = session
        self.turn = turn
        self.callID = callID
        self.arrivedAt = arrivedAt
        self.prompts = prompts
    }

    public func with(source: AttentionSource) -> AttentionQuestion {
        AttentionQuestion(source: source, session: session, turn: turn, callID: callID, arrivedAt: arrivedAt, prompts: prompts)
    }
}
