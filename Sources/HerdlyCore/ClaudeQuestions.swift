import Foundation

public enum ClaudeQuestionTiming {
    public static let connectionTimeout: TimeInterval = 5
    /// A Claude question's window from the helper's publish, matching a live approval's (ADR 0020,
    /// amended 2026-10-30). On expiry the helper sends nothing and Claude's own question stays.
    public static let answerTimeout: TimeInterval = ApprovalTiming.handoffTimeout
    public static let pollInterval: TimeInterval = 0.02
    public static let livenessTimeout: TimeInterval = 0.25
    public static let deliveryAckTimeout: TimeInterval = 0.5

    /// The app writes a hold this far ahead of the deadline the notch shows, and the helper's own
    /// cap keeps the same lead, so the helper never stops before the notch's last offer.
    public static let holdLead: TimeInterval = ApprovalTiming.holdLead

    /// The deadline the notch shows for a question whose window ends at `expiresAt`: a hover hold's
    /// deadline when it is later, never past `ApprovalTiming.maximumHold` after publish. A missing
    /// or malformed hold leaves `expiresAt`. Holding answers nothing.
    ///
    /// It measures the cap from publish, not from `expiresAt` as `ApprovalTiming.heldDeadline`
    /// does: a question has no separate receipt deadline, and its window starts at the helper's
    /// publish, so publish + 2 min holds even for a receipt issued late or a shortened window.
    public static func heldDeadline(publishedAt: Double, expiresAt: Double, held: Double?) -> Double {
        heldDeadline(publishedAt: publishedAt, expiresAt: expiresAt, held: held, lead: 0)
    }

    /// The helper's deadline for the same question: as `heldDeadline`, with `holdLead` past the cap.
    public static func helperDeadline(publishedAt: Double, expiresAt: Double, held: Double?) -> Double {
        heldDeadline(publishedAt: publishedAt, expiresAt: expiresAt, held: held, lead: holdLead)
    }

    private static func heldDeadline(publishedAt: Double, expiresAt: Double, held: Double?,
                                     lead: TimeInterval) -> Double {
        guard let held, held.isFinite, publishedAt.isFinite else { return expiresAt }
        return min(max(expiresAt, held), max(expiresAt, publishedAt + ApprovalTiming.maximumHold + lead))
    }
}

/// A live AskUserQuestion helper invocation. This is a transport record, not saved attention state.
public struct ClaudeQuestionRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let installationID: String
    /// The normalized Claude configuration root, which identifies the source scope.
    public let sourceScope: String
    /// The normalized Herdly event directory used only for this rendezvous.
    public let eventDirectory: String
    public let sessionID: String
    public let promptID: String
    public let toolUseID: String
    public let toolName: String
    public let publishedAt: Double
    public let expiresAt: Double
    public let prompts: [QuestionPrompt]

    public init(requestID: String, installationID: String, sourceScope: String, eventDirectory: String,
                sessionID: String, promptID: String,
                toolUseID: String, toolName: String = "AskUserQuestion", publishedAt: Double,
                expiresAt: Double, prompts: [QuestionPrompt]) {
        self.requestID = requestID
        self.installationID = installationID
        self.sourceScope = sourceScope
        self.eventDirectory = eventDirectory
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
    /// The event directory is separate from the source scope and is checked against the file path.
    public let eventDirectory: String
    public let receivedAt: Double
    public let expiresAt: Double

    public init(requestID: String, installationID: String, sourceScope: String, eventDirectory: String,
                receivedAt: Double,
                expiresAt: Double) {
        self.requestID = requestID
        self.installationID = installationID
        self.sourceScope = sourceScope
        self.eventDirectory = eventDirectory
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt
    }
}

public struct ClaudeQuestionLiveness: Codable, Equatable, Sendable {
    public let requestID: String
    public let installationID: String
    public let sourceScope: String
    public let eventDirectory: String
    public let sessionID: String
    public let promptID: String
    public let toolUseID: String
    public let heartbeatAt: Double

    public init(requestID: String, installationID: String, sourceScope: String, eventDirectory: String,
                sessionID: String, promptID: String, toolUseID: String, heartbeatAt: Double) {
        self.requestID = requestID
        self.installationID = installationID
        self.sourceScope = sourceScope
        self.eventDirectory = eventDirectory
        self.sessionID = sessionID
        self.promptID = promptID
        self.toolUseID = toolUseID
        self.heartbeatAt = heartbeatAt
    }
}

public struct ClaudeQuestionDelivery: Codable, Equatable, Sendable {
    public let requestID: String
    public let installationID: String
    public let sourceScope: String
    public let eventDirectory: String
    public let sessionID: String
    public let promptID: String
    public let toolUseID: String
    public let answerDecidedAt: Double
    public let deliveredAt: Double

    public init(requestID: String, installationID: String, sourceScope: String, eventDirectory: String,
                sessionID: String, promptID: String, toolUseID: String, answerDecidedAt: Double,
                deliveredAt: Double) {
        self.requestID = requestID
        self.installationID = installationID
        self.sourceScope = sourceScope
        self.eventDirectory = eventDirectory
        self.sessionID = sessionID
        self.promptID = promptID
        self.toolUseID = toolUseID
        self.answerDecidedAt = answerDecidedAt
        self.deliveredAt = deliveredAt
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
    /// The event directory is separate from the source scope and is checked against the file path.
    public let eventDirectory: String
    public let sessionID: String
    public let promptID: String
    public let toolUseID: String
    public let kind: ClaudeQuestionAnswerKind
    public let answer: String
    public let decidedAt: Double

    public init(requestID: String, installationID: String, sourceScope: String, eventDirectory: String,
                sessionID: String, promptID: String,
                toolUseID: String, kind: ClaudeQuestionAnswerKind, answer: String, decidedAt: Double) {
        self.requestID = requestID
        self.installationID = installationID
        self.sourceScope = sourceScope
        self.eventDirectory = eventDirectory
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
    private static let rendezvousDirectoryName = ".herdly-claude-questions"
    private static let maximumEntries = 4096

    private struct BoundedEntries {
        let values: [URL]
        let hasMore: Bool
    }

    /// Question transport files live below the event directory so hook observations and the
    /// rendezvous lifecycle have independent bounds.
    public static func rendezvousDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent(rendezvousDirectoryName, isDirectory: true)
    }

    public static func requestURL(in directory: URL, id: String) -> URL {
        rendezvousDirectory(in: directory).appendingPathComponent(id + ".question")
    }

    public static func receiptURL(in directory: URL, id: String) -> URL {
        rendezvousDirectory(in: directory).appendingPathComponent(id + ".question-receipt")
    }

    public static func answerURL(in directory: URL, id: String) -> URL {
        rendezvousDirectory(in: directory).appendingPathComponent(id + ".question-answer")
    }

    public static func livenessURL(in directory: URL, id: String) -> URL {
        rendezvousDirectory(in: directory).appendingPathComponent(id + ".question-live")
    }

    public static func deliveryURL(in directory: URL, id: String) -> URL {
        rendezvousDirectory(in: directory).appendingPathComponent(id + ".question-delivery")
    }

    /// The app's hover hold for a live question (ADR 0020), an `ApprovalHoldRecord` written only
    /// while the pointer is on the notch.
    public static func holdURL(in directory: URL, id: String) -> URL {
        rendezvousDirectory(in: directory).appendingPathComponent(id + ".question-hold")
    }

    /// The helper's deadline for the question with any readable, matching hold, bounded by
    /// `ClaudeQuestionTiming.helperDeadline`; `expiresAt` defaults to the request's own.
    public static func heldDeadline(for request: ClaudeQuestionRequest, expiresAt: Double? = nil,
                                    in directory: URL) -> Double {
        let base = expiresAt ?? request.expiresAt
        guard validID(request.requestID) else { return base }
        return ClaudeQuestionTiming.helperDeadline(
            publishedAt: request.publishedAt, expiresAt: base,
            held: ApprovalHoldStore.heldUntil(at: holdURL(in: directory, id: request.requestID),
                                              requestID: request.requestID))
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

    /// The helper replaces this marker while it is waiting for the user's answer. Its exact
    /// identity and freshness let the app fail closed when the helper has exited.
    @discardableResult
    public static func publish(_ liveness: ClaudeQuestionLiveness, in directory: URL) -> Bool {
        guard validID(liveness.requestID) else { return false }
        return replace(try? JSONEncoder().encode(liveness), to: livenessURL(in: directory, id: liveness.requestID))
    }

    /// This is written by the helper only after it has emitted Claude's response.
    @discardableResult
    public static func publish(_ delivery: ClaudeQuestionDelivery, in directory: URL) -> Bool {
        guard validID(delivery.requestID) else { return false }
        return write(try? JSONEncoder().encode(delivery), to: deliveryURL(in: directory, id: delivery.requestID))
    }

    public static func request(for id: String, in directory: URL) -> ClaudeQuestionRequest? {
        guard validID(id) else { return nil }
        return decode(requestURL(in: directory, id: id), as: ClaudeQuestionRequest.self)
    }

    public static func receipt(for id: String, in directory: URL) -> ClaudeQuestionReceipt? {
        guard validID(id) else { return nil }
        return decode(receiptURL(in: directory, id: id), as: ClaudeQuestionReceipt.self)
    }

    public static func answer(for id: String, in directory: URL) -> ClaudeQuestionAnswer? {
        guard validID(id) else { return nil }
        return decode(answerURL(in: directory, id: id), as: ClaudeQuestionAnswer.self)
    }

    public static func liveness(for id: String, in directory: URL) -> ClaudeQuestionLiveness? {
        guard validID(id) else { return nil }
        return decode(livenessURL(in: directory, id: id), as: ClaudeQuestionLiveness.self)
    }

    public static func delivery(for id: String, in directory: URL) -> ClaudeQuestionDelivery? {
        guard validID(id) else { return nil }
        return decode(deliveryURL(in: directory, id: id), as: ClaudeQuestionDelivery.self)
    }

    public static func removeLiveness(for id: String, in directory: URL) {
        guard validID(id) else { return }
        try? FileManager.default.removeItem(at: livenessURL(in: directory, id: id))
    }

    public static func removeAnswer(for id: String, in directory: URL) {
        guard validID(id) else { return }
        try? FileManager.default.removeItem(at: answerURL(in: directory, id: id))
    }

    /// Reads only fresh, bounded request records for the selected installation.
    public static func pending(in directory: URL, installationID: String, observingSince: Double,
                               now: Double = Date().timeIntervalSince1970) -> [ClaudeQuestionRequest] {
        let rendezvous = rendezvousDirectory(in: directory)
        guard let bounded = boundedEntries(in: rendezvous) else {
            return []
        }
        let eventDirectory = directory.standardizedFileURL.path
        var pending: [ClaudeQuestionRequest] = []
        for url in bounded.values where url.pathExtension == "question" {
            guard let request = decode(url, as: ClaudeQuestionRequest.self),
                  validID(request.requestID),
                  request.eventDirectory == eventDirectory,
                  request.toolName == "AskUserQuestion",
                  request.prompts.count == 1,
                  request.prompts.first?.question?.isEmpty == false,
                  request.publishedAt.isFinite, request.expiresAt.isFinite,
                  request.expiresAt >= request.publishedAt else { continue }
            if heldDeadline(for: request, in: directory) < now {
                guard url.lastPathComponent == request.requestID + ".question" else { continue }
                removeTriplet(for: request.requestID, in: directory)
                continue
            }
            guard request.installationID == installationID,
                  request.publishedAt >= observingSince, request.publishedAt <= now else { continue }
            pending.append(request)
        }
        guard !bounded.hasMore else { return [] }
        return pending.sorted {
            $0.publishedAt == $1.publishedAt ? $0.requestID < $1.requestID : $0.publishedAt < $1.publishedAt
        }.prefix(maximumEntries).map { $0 }
    }

    private static func boundedEntries(in directory: URL) -> BoundedEntries? {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                               includingPropertiesForKeys: nil,
                                                               options: []) else { return nil }
        var entries: [URL] = []
        while let entry = enumerator.nextObject() as? URL {
            if entries.count == maximumEntries {
                return BoundedEntries(values: entries, hasMore: true)
            }
            entries.append(entry)
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
            }
        }
        return BoundedEntries(values: entries, hasMore: false)
    }

    private static func removeTriplet(for id: String, in directory: URL) {
        let manager = FileManager.default
        for url in [requestURL(in: directory, id: id), receiptURL(in: directory, id: id),
                    answerURL(in: directory, id: id), livenessURL(in: directory, id: id),
                    deliveryURL(in: directory, id: id), holdURL(in: directory, id: id)] {
            try? manager.removeItem(at: url)
        }
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
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".herdly-" + UUID().uuidString)
        do {
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    private static func replace(_ data: Data?, to destination: URL) -> Bool {
        guard let data,
              (try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)) != nil else { return false }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".herdly-" + UUID().uuidString)
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
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
        func refreshLiveness() -> Bool {
            ClaudeQuestionStore.publish(ClaudeQuestionLiveness(
                requestID: request.requestID, installationID: request.installationID,
                sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                sessionID: request.sessionID, promptID: request.promptID,
                toolUseID: request.toolUseID, heartbeatAt: Date().timeIntervalSince1970), in: directory)
        }

        guard refreshLiveness() else { return nil }
        let connectionDeadline = ProcessInfo.processInfo.systemUptime + connectionTimeout
        var receipt: ClaudeQuestionReceipt?
        repeat {
            guard refreshLiveness() else { return nil }
            if let candidate = ClaudeQuestionStore.receipt(for: request.requestID, in: directory),
               candidate.requestID == request.requestID,
               candidate.installationID == request.installationID,
               candidate.sourceScope == request.sourceScope,
               candidate.eventDirectory == request.eventDirectory,
               candidate.eventDirectory == directory.standardizedFileURL.path,
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

        let started = ProcessInfo.processInfo.systemUptime
        let baseDeadline = min(started + answerTimeout,
                               started + max(0, receipt.expiresAt - Date().timeIntervalSince1970))
        // A hover hold moves the deadline later by what it adds to the receipt's, re-read on every
        // poll and never past two minutes from publish (ADR 0020). Expiry answers nothing.
        var heldUntil = max(receipt.expiresAt, ClaudeQuestionStore.heldDeadline(for: request, expiresAt: receipt.expiresAt,
                                                                                in: directory))
        while ProcessInfo.processInfo.systemUptime
                < min(baseDeadline + (heldUntil - receipt.expiresAt), started + ApprovalTiming.helperWaitBound) {
            guard refreshLiveness() else { return nil }
            heldUntil = max(heldUntil, ClaudeQuestionStore.heldDeadline(for: request, expiresAt: receipt.expiresAt,
                                                                         in: directory))
            if let answer = ClaudeQuestionStore.answer(for: request.requestID, in: directory),
               answer.requestID == request.requestID,
               answer.installationID == request.installationID,
               answer.sourceScope == request.sourceScope,
               answer.eventDirectory == request.eventDirectory,
               answer.eventDirectory == directory.standardizedFileURL.path,
               answer.sessionID == request.sessionID,
               answer.promptID == request.promptID,
               answer.toolUseID == request.toolUseID,
               answer.decidedAt.isFinite,
               answer.decidedAt >= receipt.receivedAt,
               answer.decidedAt <= heldUntil,
               answer.decidedAt <= Date().timeIntervalSince1970,
               ClaudeQuestionAnswerPolicy.accepts(request: request, answer: answer) {
                return answer
            }
            Thread.sleep(forTimeInterval: ClaudeQuestionTiming.pollInterval)
        }
        return nil
    }

    /// Waits for the helper's one-shot acknowledgment after it has emitted the hook response.
    public static func awaitDelivery(for request: ClaudeQuestionRequest, answer: ClaudeQuestionAnswer,
                                     in directory: URL,
                                     timeout: TimeInterval = ClaudeQuestionTiming.deliveryAckTimeout) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let now = Date().timeIntervalSince1970
            if let delivery = ClaudeQuestionStore.delivery(for: request.requestID, in: directory),
               delivery.requestID == request.requestID,
               delivery.installationID == request.installationID,
               delivery.sourceScope == request.sourceScope,
               delivery.eventDirectory == request.eventDirectory,
               delivery.eventDirectory == directory.standardizedFileURL.path,
               delivery.sessionID == request.sessionID,
               delivery.promptID == request.promptID,
               delivery.toolUseID == request.toolUseID,
               delivery.answerDecidedAt == answer.decidedAt,
               delivery.deliveredAt.isFinite,
               delivery.deliveredAt >= answer.decidedAt,
               delivery.deliveredAt <= now,
               delivery.deliveredAt <= ClaudeQuestionStore.heldDeadline(for: request, in: directory) {
                return true
            }
            Thread.sleep(forTimeInterval: ClaudeQuestionTiming.pollInterval)
        }
        return false
    }
}

public enum ClaudeQuestionAnswerPolicy {
    public static let maximumText = 4000

    public static func accepts(request: ClaudeQuestionRequest, answer: ClaudeQuestionAnswer) -> Bool {
        guard answer.requestID == request.requestID,
              answer.installationID == request.installationID,
              answer.sourceScope == request.sourceScope,
              answer.eventDirectory == request.eventDirectory,
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
