import Foundation

// Answering a Codex question exactly, per call id, through the local app-server daemon
// (`~/.codex/app-server-control/app-server-control.sock`). The daemon sends every subscribed
// client `item/tool/requestUserInput` as a JSON-RPC server request; one client responds with the
// answers keyed by question id and the others receive `serverRequest/resolved`. Shapes follow the
// schema the installed CLI generates (`codex app-server generate-json-schema`). Everything here is
// pure bookkeeping and policy; the socket lives in the app.

/// A JSON-RPC request id as the daemon sent it; echoed back verbatim in the response.
public enum AppServerRequestID: Hashable, Sendable {
    case number(Int)
    case text(String)

    init?(json: Any?) {
        if let number = json as? Int { self = .number(number) }
        else if let text = json as? String, !text.isEmpty { self = .text(text) }
        else { return nil }
    }

    var json: Any {
        switch self {
        case let .number(number): return number
        case let .text(text): return text
        }
    }
}

/// One question as the daemon describes it: complete, uncapped, with Codex's own id.
public struct AppServerQuestion: Equatable, Sendable {
    public let id: String
    public let header: String?
    public let question: String?
    /// Nil or empty: a typed answer. Otherwise the exact labels Codex shows, in order.
    public let options: [String]?
    /// Codex adds an "Other" free-text row after the options: typed text is also an answer.
    public let isOther: Bool
    /// Codex hides the typed answer; the notch is not a private surface, so it never answers these.
    public let isSecret: Bool

    public var takesText: Bool { (options ?? []).isEmpty || isOther }
    public var takesOptions: Bool { !(options ?? []).isEmpty }

    /// The same question shaped for display, with the rollout prompt's caps; answers are still
    /// built from this question's own uncapped labels.
    public var displayPrompt: QuestionPrompt {
        QuestionPrompt(id: id, header: QuestionPrompt.display(header, limit: QuestionPrompt.maximumHeader),
                       question: QuestionPrompt.display(question, limit: QuestionPrompt.maximumQuestion),
                       options: (options ?? []).map { QuestionPrompt.display($0, limit: QuestionPrompt.maximumLabel) ?? $0 },
                       isOther: isOther)
    }

    static func parse(_ entry: [String: Any]) -> AppServerQuestion? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        var options: [String]?
        if let raw = entry["options"] as? [[String: Any]] {
            var labels: [String] = []
            for option in raw {
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                labels.append(label)
            }
            options = labels
        } else if entry["options"] != nil, !(entry["options"] is NSNull) {
            return nil
        }
        return AppServerQuestion(id: id, header: entry["header"] as? String, question: entry["question"] as? String,
                                 options: options, isOther: entry["isOther"] as? Bool ?? false,
                                 isSecret: entry["isSecret"] as? Bool ?? false)
    }
}

/// A pending `item/tool/requestUserInput` this connection received. The thread is the session and
/// the item id is the tool call id, the same pair the rollout records.
public struct AppServerQuestionRequest: Equatable, Sendable {
    public let requestID: AppServerRequestID
    public let thread: UUID
    public let turn: UUID?
    public let itemID: String
    public let questions: [AppServerQuestion]
    public let receivedAt: Double

    /// Parses the server request; nil for any shape Steer could not answer exactly.
    public static func parse(message: [String: Any], now: Double) -> AppServerQuestionRequest? {
        guard message["method"] as? String == "item/tool/requestUserInput",
              let requestID = AppServerRequestID(json: message["id"]),
              let params = message["params"] as? [String: Any],
              let thread = (params["threadId"] as? String).flatMap(UUID.init(uuidString:)),
              let itemID = params["itemId"] as? String, !itemID.isEmpty, itemID.utf8.count <= 256,
              let raw = params["questions"] as? [[String: Any]] else { return nil }
        var questions: [AppServerQuestion] = []
        for entry in raw {
            guard let question = AppServerQuestion.parse(entry) else { return nil }
            questions.append(question)
        }
        guard !questions.isEmpty, Set(questions.map(\.id)).count == questions.count else { return nil }
        return AppServerQuestionRequest(requestID: requestID, thread: thread,
                                        turn: (params["turnId"] as? String).flatMap(UUID.init(uuidString:)),
                                        itemID: itemID, questions: questions, receivedAt: now)
    }

    /// The JSON-RPC response for this request with the given `ToolRequestUserInputResponse` result.
    public func responseMessage(result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": requestID.json, "result": result]
    }
}

/// The requests this connection holds, and the ones Steer answered. Memory only, per connection:
/// a request id means nothing on another connection, so a disconnect drops every pending request.
public struct AppServerQuestionBook: Equatable, Sendable {
    public struct Key: Hashable, Sendable {
        public let thread: UUID
        public let itemID: String
    }

    public enum Event: Equatable, Sendable {
        case request(AppServerQuestionRequest)
        case resolved(thread: UUID, requestID: AppServerRequestID)
        case turnCompleted(thread: UUID, turn: UUID)
        case threadClosed(thread: UUID)
        case other(String)
        case ignored
    }

    private var pending: [Key: AppServerQuestionRequest] = [:]
    private var answered: Set<Key> = []

    public init() {}

    public var pendingCount: Int { pending.count }
    /// Every request this connection still holds, oldest first.
    public var pendingRequests: [AppServerQuestionRequest] { pending.values.sorted { $0.receivedAt < $1.receivedAt } }

    /// Applies one message from the daemon. Requests are kept; resolution evidence drops them.
    public mutating func apply(message: [String: Any], now: Double) -> Event {
        guard let method = message["method"] as? String else { return .ignored }
        let params = message["params"] as? [String: Any] ?? [:]
        let thread = (params["threadId"] as? String).flatMap(UUID.init(uuidString:))
        switch method {
        case "item/tool/requestUserInput":
            guard let request = AppServerQuestionRequest.parse(message: message, now: now) else { return .ignored }
            pending[Key(thread: request.thread, itemID: request.itemID)] = request
            return .request(request)
        case "serverRequest/resolved":
            guard let thread, let requestID = AppServerRequestID(json: params["requestId"]) else { return .ignored }
            pending = pending.filter { !($0.value.thread == thread && $0.value.requestID == requestID) }
            return .resolved(thread: thread, requestID: requestID)
        case "turn/completed":
            guard let thread, let turn = ((params["turn"] as? [String: Any])?["id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return .ignored
            }
            pending = pending.filter { !($0.value.thread == thread && $0.value.turn == turn) }
            return .turnCompleted(thread: thread, turn: turn)
        case "thread/closed":
            guard let thread else { return .ignored }
            pending = pending.filter { $0.value.thread != thread }
            // A closed thread can pose nothing more, so its answered calls need no memory.
            answered = answered.filter { $0.thread != thread }
            return .threadClosed(thread: thread)
        default:
            return .other(method)
        }
    }

    /// The request Steer could answer for a rollout question: same thread and call id, still
    /// pending on this connection, and not already answered by Steer.
    public func request(for question: AttentionQuestion) -> AppServerQuestionRequest? {
        let key = Key(thread: question.session, itemID: question.callID)
        guard !answered.contains(key) else { return nil }
        return pending[key]
    }

    public func hasAnswered(_ question: AttentionQuestion) -> Bool {
        answered.contains(Key(thread: question.session, itemID: question.callID))
    }

    /// Steer is about to write the response: the request is spent whatever happens next.
    public mutating func markAnswered(_ request: AppServerQuestionRequest) {
        let key = Key(thread: request.thread, itemID: request.itemID)
        answered.insert(key)
        pending[key] = nil
    }

    /// The connection is gone; its request ids with it. Answers Steer gave are remembered.
    public mutating func disconnect() {
        pending = [:]
    }
}

/// Which path a question card uses. Only one is ever used for a call.
public enum QuestionAnswerRoute: Equatable, Sendable {
    /// The daemon holds the pending request: options and typed answers go back exactly, by call id.
    case daemon(AppServerQuestionRequest)
    /// Steer answered this call through the daemon; the card waits for the rollout to record it.
    case daemonAnswered
    /// CLI session without the daemon: the one relayed key through Ghostty (ADR 0006).
    case ghosttyRelay
    /// CLI session bound to a herdr pane without the daemon: one key per click through herdr's
    /// `agent.send_keys` (ADR 0010). See `QuestionRelayRouting`.
    case herdrRelay
    /// CLI session with no usable relay for this call: nothing is offered but Open in Codex.
    case relayUnavailable(HerdrQuestionRelayUnavailable)
    /// Desktop session without the daemon: a highlighted pick that opens the thread.
    case desktopPick
}

public enum QuestionAnswerRouting {
    public static func route(for question: AttentionQuestion, book: AppServerQuestionBook, daemonConnected: Bool) -> QuestionAnswerRoute {
        if book.hasAnswered(question) { return .daemonAnswered }
        if daemonConnected, let request = book.request(for: question) { return .daemon(request) }
        return question.source == .cli ? .ghosttyRelay : .desktopPick
    }
}

/// Whether one answer may be recorded or sent through the daemon. Judges the queue's current copy
/// of the question and the book as it is right now, never the row that was rendered.
public enum AppServerAnswerPolicy {
    public static let maximumText = 4000

    public enum Rejection: Equatable, Sendable {
        case notInQueue, noDaemonRequest, alreadyAnswered, wrongQuestion, notOfferable, optionOutOfRange
        case textNotOffered, emptyText, textTooLong, secret, notReady, notPendingInRollout, answersIncomplete
    }

    public static func rejection(for current: AttentionQuestion?, book: AppServerQuestionBook,
                                 progress: QuestionAnswerProgress, question index: Int, answer: ChosenAnswer) -> Rejection? {
        guard let current, current.id == progress.call else { return .notInQueue }
        guard !book.hasAnswered(current) else { return .alreadyAnswered }
        guard let request = book.request(for: current) else { return .noDaemonRequest }
        guard index == progress.questionIndex else { return .wrongQuestion }
        guard index >= 0, index < request.questions.count else { return .wrongQuestion }
        let question = request.questions[index]
        guard !question.isSecret else { return .secret }
        switch answer {
        case let .option(option):
            guard question.takesOptions, let options = question.options else { return .notOfferable }
            guard option >= 0, option < options.count else { return .optionOutOfRange }
        case let .text(text):
            guard question.takesText else { return .textNotOffered }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .emptyText }
            guard trimmed.count <= maximumText else { return .textTooLong }
        }
        guard progress.phase == .ready, progress.answer(for: index) == nil else { return .notReady }
        return nil
    }

    /// The `ToolRequestUserInputResponse` result for the whole call, or nil while any question
    /// lacks an answer or an answer no longer matches the request's own list.
    public static func result(for request: AppServerQuestionRequest, progress: QuestionAnswerProgress) -> [String: Any]? {
        var answers: [String: [String: [String]]] = [:]
        for (index, question) in request.questions.enumerated() {
            switch progress.answer(for: index) {
            case let .option(option):
                guard let options = question.options, option >= 0, option < options.count else { return nil }
                answers[question.id] = ["answers": [options[option]]]
            case let .text(text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                answers[question.id] = ["answers": [trimmed]]
            case nil:
                return nil
            }
        }
        return ["answers": answers]
    }

    public static func message(for rejection: Rejection) -> String {
        switch rejection {
        case .notInQueue: return "This question is no longer waiting."
        case .noDaemonRequest: return "Codex's daemon no longer holds this question; answer it in Codex."
        case .alreadyAnswered: return "Steer already answered this question through Codex's daemon."
        case .wrongQuestion: return "Codex is on a different question now."
        case .notOfferable: return "This question takes a typed answer."
        case .optionOutOfRange: return "That option is not one Codex listed."
        case .textNotOffered: return "This question takes one of the listed options."
        case .emptyText: return "Type an answer first."
        case .textTooLong: return "That answer is longer than Steer sends; answer in Codex."
        case .secret: return "Codex asked for a secret; answer it in Codex."
        case .notReady: return "An answer for this question was already given."
        case .notPendingInRollout: return "Codex already has an answer or the turn ended; nothing was sent."
        case .answersIncomplete: return "A question in this call has no answer yet; answer them in order."
        }
    }
}

/// One click or one typed answer on the daemon path, decided in one place. Returns what to do and
/// the message to write, if any. The book is updated as if the message will be written: a request
/// is spent the moment Steer decides to answer it, so nothing is ever sent twice.
public enum AppServerAnswering {
    public enum Outcome: Equatable, Sendable {
        case refused(AppServerAnswerPolicy.Rejection)
        /// A non-last question's answer was kept; nothing to send yet.
        case drafted(QuestionAnswerProgress)
        /// The last answer completed the call: write `message`, then record sent or failed.
        case sending(QuestionAnswerProgress)
    }

    public struct Plan {
        public let outcome: Outcome
        public let message: [String: Any]?
        public let book: AppServerQuestionBook
    }

    /// `stillPending` is the rollout re-read at this instant; false (including unreadable) sends nothing.
    public static func prepare(current: AttentionQuestion?, book: AppServerQuestionBook, progress: QuestionAnswerProgress,
                               question index: Int, answer: ChosenAnswer, stillPending: () -> Bool, now: Double) -> Plan {
        if let rejection = AppServerAnswerPolicy.rejection(for: current, book: book, progress: progress, question: index, answer: answer) {
            return Plan(outcome: .refused(rejection), message: nil, book: book)
        }
        guard let current, let request = book.request(for: current) else {
            return Plan(outcome: .refused(.noDaemonRequest), message: nil, book: book)
        }
        if index + 1 < request.questions.count {
            return Plan(outcome: .drafted(progress.recordingDraft(question: index, answer: answer)), message: nil, book: book)
        }
        guard stillPending() else { return Plan(outcome: .refused(.notPendingInRollout), message: nil, book: book) }
        let sending = progress.startingSend(question: index)
        // The response is built from the drafted answers plus this last one.
        let complete = progress.recordingDraft(question: index, answer: answer)
        guard let result = AppServerAnswerPolicy.result(for: request, progress: complete) else {
            return Plan(outcome: .refused(.answersIncomplete), message: nil, book: book)
        }
        var next = book
        next.markAnswered(request)
        return Plan(outcome: .sending(sending), message: request.responseMessage(result: result), book: next)
    }
}

/// The socket is accepted only when it is a Unix socket owned by this user and private to them: the
/// daemon's own protection is the directory's mode, and Steer never connects to anything looser.
public enum AppServerSocketCheck {
    public enum Problem: Equatable, Sendable {
        case missing, notASocket, notOwnedByUser, sharedPermissions
    }

    public static func problem(exists: Bool, isSocket: Bool, owner: uid_t, mode: mode_t, me: uid_t) -> Problem? {
        guard exists else { return .missing }
        guard isSocket else { return .notASocket }
        guard owner == me else { return .notOwnedByUser }
        guard mode & 0o077 == 0 else { return .sharedPermissions }
        return nil
    }

    /// Inspects the file at `path` without connecting. A symlink is refused as `notASocket` unless
    /// `followsPrivateLink` is set; only the Codex daemon's control socket sets it (ADR 0007), and
    /// herdr's socket keeps ADR 0009's rule of a socket file at the path itself.
    ///
    /// Codex 0.161 replaced its control socket with a symlink to a socket in a per-user directory
    /// (`/private/tmp/codex-daemon-<uid>/<hash>`). With `followsPrivateLink`, one level of symlink is
    /// followed only when the link itself is owned by this user and its absolute target is a socket
    /// that passes every check above, inside a directory owned by this user that no one else can
    /// enter or change (mode `0700` or stricter). Nothing else, not a relative target, a second link,
    /// or a looser directory, is accepted: the target directory sits in world-writable `/tmp`, so its
    /// own mode is what keeps another user from substituting the socket.
    public static func problem(at path: String, followsPrivateLink: Bool = false) -> Problem? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        guard followsPrivateLink, (info.st_mode & S_IFMT) == S_IFLNK else {
            return problem(exists: true, isSocket: (info.st_mode & S_IFMT) == S_IFSOCK, owner: info.st_uid,
                           mode: info.st_mode & 0o777, me: getuid())
        }
        guard info.st_uid == getuid() else { return .notOwnedByUser }
        guard let target = linkTarget(path), target.hasPrefix("/") else { return .notASocket }
        var targetInfo = stat()
        guard lstat(target, &targetInfo) == 0 else { return .missing }
        if let problem = problem(exists: true, isSocket: (targetInfo.st_mode & S_IFMT) == S_IFSOCK,
                                 owner: targetInfo.st_uid, mode: targetInfo.st_mode & 0o777, me: getuid()) {
            return problem
        }
        var directory = stat()
        let parent = (target as NSString).deletingLastPathComponent
        guard lstat(parent, &directory) == 0, (directory.st_mode & S_IFMT) == S_IFDIR else { return .notASocket }
        guard directory.st_uid == getuid() else { return .notOwnedByUser }
        guard directory.st_mode & 0o077 == 0 else { return .sharedPermissions }
        return nil
    }

    private static func linkTarget(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0, count < buffer.count - 1 else { return nil }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
