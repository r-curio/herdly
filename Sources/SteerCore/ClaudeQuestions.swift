import Foundation

public enum ClaudeQuestionTiming {
    public static let connectionTimeout: TimeInterval = 5
    public static let answerTimeout: TimeInterval = 10
    public static let pollInterval: TimeInterval = 0.02
}

/// A live AskUserQuestion helper invocation. This is a transport record, not saved attention state.
public struct ClaudeQuestionRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let installationID: String
    public let sourceScope: String
    public let sessionID: String
    public let promptID: String
    public let toolUseID: String
    public let toolName: String
    public let publishedAt: Double
    public let expiresAt: Double
    public let prompts: [QuestionPrompt]

    public init(requestID: String, installationID: String, sourceScope: String, sessionID: String, promptID: String,
                toolUseID: String, toolName: String = "AskUserQuestion", publishedAt: Double,
                expiresAt: Double, prompts: [QuestionPrompt]) {
        self.requestID = requestID
        self.installationID = installationID
        self.sourceScope = sourceScope
        self.sessionID = sessionID
        self.promptID = promptID
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.publishedAt = publishedAt
        self.expiresAt = expiresAt
        self.prompts = prompts
    }
}

public struct ClaudeQuestionReceipt: Codable, Equatable, Sendable {
    public let requestID: String
    public let installationID: String
    public let sourceScope: String
    public let receivedAt: Double
    public let expiresAt: Double

    public init(requestID: String, installationID: String, sourceScope: String, receivedAt: Double,
                expiresAt: Double) {
        self.requestID = requestID
        self.installationID = installationID
        self.sourceScope = sourceScope
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
    }
}

public enum ClaudeQuestionAnswerKind: String, Codable, Sendable {
    case option
    case multiSelect = "multi_select"
    case text
}

public struct ClaudeQuestionAnswer: Codable, Equatable, Sendable {
    public let requestID: String
    public let installationID: String
    public let sourceScope: String
    public let sessionID: String
    public let promptID: String
    public let toolUseID: String
    public let kind: ClaudeQuestionAnswerKind
    public let answer: String
    public let decidedAt: Double

    public init(requestID: String, installationID: String, sourceScope: String, sessionID: String, promptID: String,
                toolUseID: String, kind: ClaudeQuestionAnswerKind, answer: String, decidedAt: Double) {
        self.requestID = requestID
        self.installationID = installationID
        self.sourceScope = sourceScope
        self.sessionID = sessionID
        self.promptID = promptID
        self.toolUseID = toolUseID
        self.kind = kind
        self.answer = answer
        self.decidedAt = decidedAt
    }
}

/// Files are only a rendezvous for an invocation that is still waiting in a hook process. The app
/// keeps the capability to answer in memory, so a restart cannot replay a saved request.
public enum ClaudeQuestionStore {
    public static func requestURL(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent(id + ".question")
    }

    public static func receiptURL(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent(id + ".question-receipt")
    }

    public static func answerURL(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent(id + ".question-answer")
    }

    @discardableResult
    public static func publish(_ request: ClaudeQuestionRequest, in directory: URL) -> Bool {
        guard validID(request.requestID) else { return false }
        return write(try? JSONEncoder().encode(request), to: requestURL(in: directory, id: request.requestID))
    }

    @discardableResult
    public static func publish(_ receipt: ClaudeQuestionReceipt, in directory: URL) -> Bool {
        guard validID(receipt.requestID) else { return false }
        return write(try? JSONEncoder().encode(receipt), to: receiptURL(in: directory, id: receipt.requestID))
    }

    @discardableResult
    public static func publish(_ answer: ClaudeQuestionAnswer, in directory: URL) -> Bool {
        guard validID(answer.requestID) else { return false }
        return write(try? JSONEncoder().encode(answer), to: answerURL(in: directory, id: answer.requestID))
    }

    public static func request(for id: String, in directory: URL) -> ClaudeQuestionRequest? {
        decode(requestURL(in: directory, id: id), as: ClaudeQuestionRequest.self)
    }

    public static func receipt(for id: String, in directory: URL) -> ClaudeQuestionReceipt? {
        decode(receiptURL(in: directory, id: id), as: ClaudeQuestionReceipt.self)
    }

    public static func answer(for id: String, in directory: URL) -> ClaudeQuestionAnswer? {
        decode(answerURL(in: directory, id: id), as: ClaudeQuestionAnswer.self)
    }

    /// Reads only fresh, bounded request records for the selected installation.
    public static func pending(in directory: URL, installationID: String, observingSince: Double,
                               now: Double = Date().timeIntervalSince1970) -> [ClaudeQuestionRequest] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              urls.count <= 4096 else { return [] }
        return urls.compactMap { url -> ClaudeQuestionRequest? in
            guard url.pathExtension == "question",
                  let request = decode(url, as: ClaudeQuestionRequest.self),
                  validID(request.requestID),
                  request.installationID == installationID,
                  request.sourceScope == directory.standardizedFileURL.path,
                  request.toolName == "AskUserQuestion",
                  request.prompts.count == 1,
                  request.prompts.first?.question?.isEmpty == false,
                  request.publishedAt.isFinite, request.publishedAt >= observingSince,
                  request.publishedAt <= now, request.expiresAt >= request.publishedAt,
                  request.expiresAt >= now else { return nil }
            return request
        }.sorted { $0.publishedAt == $1.publishedAt ? $0.requestID < $1.requestID : $0.publishedAt < $1.publishedAt }
    }

    private static func decode<T: Decodable>(_ url: URL, as type: T.Type) -> T? {
        guard let bytes = SafeFile.read(url, limit: 128 * 1024) else { return nil }
        return try? JSONDecoder().decode(type, from: bytes)
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func write(_ data: Data?, to destination: URL) -> Bool {
        guard let data,
              (try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)) != nil else { return false }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".steer-" + UUID().uuidString)
        do {
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }
}

/// The helper waits for an app receipt and then accepts one exact answer. Any uncertainty falls
/// through to Claude's own question UI by returning nil.
public enum ClaudeQuestionHelper {
    public static func awaitAnswer(for request: ClaudeQuestionRequest, in directory: URL,
                                   connectionTimeout: TimeInterval = ClaudeQuestionTiming.connectionTimeout,
                                   answerTimeout: TimeInterval = ClaudeQuestionTiming.answerTimeout) -> ClaudeQuestionAnswer? {
        let connectionDeadline = ProcessInfo.processInfo.systemUptime + connectionTimeout
        var receipt: ClaudeQuestionReceipt?
        repeat {
            if let candidate = ClaudeQuestionStore.receipt(for: request.requestID, in: directory),
               candidate.requestID == request.requestID,
               candidate.installationID == request.installationID,
               candidate.sourceScope == request.sourceScope,
               candidate.receivedAt.isFinite,
               candidate.receivedAt >= request.publishedAt,
               candidate.receivedAt <= Date().timeIntervalSince1970,
               candidate.receivedAt <= request.expiresAt,
               candidate.expiresAt >= candidate.receivedAt,
               candidate.expiresAt <= request.expiresAt {
                receipt = candidate
                break
            }
            Thread.sleep(forTimeInterval: ClaudeQuestionTiming.pollInterval)
        } while ProcessInfo.processInfo.systemUptime < connectionDeadline
        guard let receipt else { return nil }

        let deadline = min(ProcessInfo.processInfo.systemUptime + answerTimeout,
                           ProcessInfo.processInfo.systemUptime + max(0, receipt.expiresAt - Date().timeIntervalSince1970))
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let answer = ClaudeQuestionStore.answer(for: request.requestID, in: directory),
               answer.requestID == request.requestID,
               answer.installationID == request.installationID,
               answer.sourceScope == request.sourceScope,
               answer.sessionID == request.sessionID,
               answer.promptID == request.promptID,
               answer.toolUseID == request.toolUseID,
               answer.decidedAt.isFinite,
               answer.decidedAt >= receipt.receivedAt,
               answer.decidedAt <= receipt.expiresAt,
               answer.decidedAt <= Date().timeIntervalSince1970,
               ClaudeQuestionAnswerPolicy.accepts(request: request, answer: answer) {
                return answer
            }
            Thread.sleep(forTimeInterval: ClaudeQuestionTiming.pollInterval)
        }
        return nil
    }
}

public enum ClaudeQuestionAnswerPolicy {
    public static let maximumText = 4000

    public static func accepts(request: ClaudeQuestionRequest, answer: ClaudeQuestionAnswer) -> Bool {
        guard answer.requestID == request.requestID,
              answer.installationID == request.installationID,
              answer.sourceScope == request.sourceScope,
              answer.sessionID == request.sessionID,
              answer.promptID == request.promptID,
              answer.toolUseID == request.toolUseID,
              request.toolName == "AskUserQuestion",
              request.prompts.count == 1,
              let prompt = request.prompts.first,
              prompt.question?.isEmpty == false else { return false }
        let value = answer.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximumText else { return false }
        switch answer.kind {
        case .option:
            return !prompt.multiSelect && prompt.optionsComplete && prompt.options.contains(value)
        case .multiSelect:
            guard prompt.multiSelect, prompt.optionsComplete else { return false }
            let values = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return !values.isEmpty && Set(values).count == values.count && values.allSatisfy(prompt.options.contains)
        case .text:
            return true
        }
    }

    /// Builds Claude's documented PreToolUse response from the unchanged original input.
    public static func hookOutput(toolInput: [String: Any], request: ClaudeQuestionRequest,
                                  answer: ClaudeQuestionAnswer) -> Data? {
        guard accepts(request: request, answer: answer),
              let questions = toolInput["questions"] as? [[String: Any]], questions.count == 1,
              let parsed = QuestionPrompt.parseCall(toolInput: toolInput), parsed.count == 1,
              parsed.prompts == request.prompts,
              let question = questions[0]["question"] as? String, !question.isEmpty else { return nil }
        var updatedInput = toolInput
        updatedInput["answers"] = [question: answer.answer.trimmingCharacters(in: .whitespacesAndNewlines)]
        let output: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": updatedInput
        ]]
        guard JSONSerialization.isValidJSONObject(output) else { return nil }
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }
}
