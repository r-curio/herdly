import Foundation
import Testing
@testable import HerdlyCore
@testable import HerdlyApp

@Test func claudeQuestionViewStateKeySeparatesEveryQuestionIdentityPart() {
    let session = AgentSessionIdentity(source: .claude, sourceScope: "/root-a", session: "session-a", surface: .cli)
    let question = AgentQuestion(session: session, turn: "prompt-a", call: "tool-a", arrivedAt: 1,
                                 helperRequestID: "request-a")
    let key = ClaudeQuestionViewStateKey(question: question, index: 0)
    let variants = [
        ClaudeQuestionViewStateKey(question: AgentQuestion(
            session: AgentSessionIdentity(source: .claude, sourceScope: "/root-b", session: "session-a", surface: .cli),
            turn: "prompt-a", call: "tool-a", arrivedAt: 1, helperRequestID: "request-a"), index: 0),
        ClaudeQuestionViewStateKey(question: AgentQuestion(
            session: AgentSessionIdentity(source: .claude, sourceScope: "/root-a", session: "session-b", surface: .cli),
            turn: "prompt-a", call: "tool-a", arrivedAt: 1, helperRequestID: "request-a"), index: 0),
        ClaudeQuestionViewStateKey(question: AgentQuestion(session: session, turn: "prompt-b", call: "tool-a",
                                                           arrivedAt: 1, helperRequestID: "request-a"), index: 0),
        ClaudeQuestionViewStateKey(question: AgentQuestion(session: session, turn: "prompt-a", call: "tool-b",
                                                           arrivedAt: 1, helperRequestID: "request-a"), index: 0),
        ClaudeQuestionViewStateKey(question: AgentQuestion(session: session, turn: "prompt-a", call: "tool-a",
                                                           arrivedAt: 1, helperRequestID: "request-b"), index: 0),
        ClaudeQuestionViewStateKey(question: question, index: 1)
    ]
    #expect(Set(variants).count == variants.count)
    #expect(Set(variants.map(\.storageKey)).count == variants.count)
    #expect(!variants.contains(key))
}

@Test func staleClaudeQuestionReceiptWorkerCanReplayOnlyTheExactLiveRequest() {
    let request = claudeQuestionRequest(requestID: "generation-race", sourceScope: "/root-a",
                                        eventDirectory: "/events-a", publishedAt: 10, expiresAt: 20)
    let root = ClaudeQuestionRootKey(sourceScope: "/root-a", eventsPath: "/events-a", installationID: "install-1")
    let result = ClaudeQuestionReceiptResult(request: request, requestID: request.requestID, root: root,
                                             scanGeneration: 1,
                                             receipt: claudeQuestionReceipt(for: request, receivedAt: 10.5))
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 2,
                                             liveRequest: request, rootIsCurrent: true, spent: false, held: nil,
                                             now: 11) == .staleAccept)
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 1,
                                             liveRequest: request, rootIsCurrent: true, spent: false, held: nil,
                                             now: 11) == .accept)
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 2,
                                             liveRequest: nil, rootIsCurrent: true, spent: false, held: nil,
                                             now: 11) == .discard)
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 2,
                                             liveRequest: claudeQuestionRequest(requestID: "other"),
                                             rootIsCurrent: true, spent: false, held: nil, now: 11) == .discard)
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 2,
                                             liveRequest: request, rootIsCurrent: false, spent: false, held: nil,
                                             now: 11) == .discard)
    #expect(claudeQuestionReceiptDisposition(
        ClaudeQuestionReceiptResult(request: request, requestID: request.requestID, root: root,
                                    scanGeneration: 1, receipt: nil),
        currentGeneration: 2, liveRequest: request, rootIsCurrent: true, spent: false, held: nil, now: 11) == .discard)
    // A worker that lands after the token was spent never grants it again (#385).
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 1,
                                             liveRequest: request, rootIsCurrent: true, spent: true, held: nil,
                                             now: 11) == .discard)
}

/// #385: one receipt result is discarded (its live question was pruned before it landed), then the
/// rescan's receipt work finds the receipt already on disk. Before the fix that work could never
/// write, so the question stayed read-only for its whole window.
@Test func claudeQuestionReceiptWorkReadoptsThisCompanionsReceiptAfterADiscardedResult() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("herdly-claude-question-readopt-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let events = directory.standardizedFileURL.path
    let request = claudeQuestionRequest(eventDirectory: events, publishedAt: 100, expiresAt: 130)
    let root = ClaudeQuestionRootKey(sourceScope: "/root", eventsPath: events, installationID: "install-1")
    var ledger = ClaudeQuestionReceiptLedger()

    let first = claudeQuestionIssueReceipt(ClaudeQuestionReceiptWork(
        request: request, eventsPath: events, root: root, scanGeneration: 1,
        issued: ledger.adoptable(for: request), held: nil), now: 101.4)
    // The live question was pruned before the result landed: discarded, but still recorded.
    #expect(claudeQuestionReceiptDisposition(first, currentGeneration: 2, liveRequest: nil, rootIsCurrent: true,
                                             spent: false, held: nil, now: 101.5) == .discard)
    ledger.record(try #require(first.receipt))

    let rescan = claudeQuestionIssueReceipt(ClaudeQuestionReceiptWork(
        request: request, eventsPath: events, root: root, scanGeneration: 3,
        issued: ledger.adoptable(for: request), held: nil), now: 103.4)
    #expect(rescan.receipt == first.receipt)
    #expect(claudeQuestionReceiptDisposition(rescan, currentGeneration: 3, liveRequest: request, rootIsCurrent: true,
                                             spent: false, held: nil, now: 103.5) == .accept)

    // A new launch has an empty ledger: the same receipt on disk grants nothing.
    let restarted = claudeQuestionIssueReceipt(ClaudeQuestionReceiptWork(
        request: request, eventsPath: events, root: root, scanGeneration: 1,
        issued: ClaudeQuestionReceiptLedger().adoptable(for: request), held: nil), now: 104)
    #expect(restarted.receipt == nil)
    #expect(claudeQuestionReceiptDisposition(restarted, currentGeneration: 1, liveRequest: request,
                                             rootIsCurrent: true, spent: false, held: nil, now: 104) == .discard)
}

private func claudeQuestionRequest(requestID: String = "request-1", installationID: String = "install-1",
                                  sourceScope: String = "/root", eventDirectory: String = "/events",
                                  publishedAt: Double = 10,
                                  expiresAt: Double = 20) -> ClaudeQuestionRequest {
    ClaudeQuestionRequest(requestID: requestID, installationID: installationID, sourceScope: sourceScope,
                          eventDirectory: eventDirectory,
                          sessionID: "session-1",
                          promptID: "prompt-1", toolUseID: "tool-1", publishedAt: publishedAt, expiresAt: expiresAt,
                          prompts: [QuestionPrompt(header: "Release", question: "Which?",
                                                   options: ["Red", "Blue"])])
}

private func claudeQuestionReceipt(for request: ClaudeQuestionRequest, installationID: String? = nil,
                                  sourceScope: String? = nil, eventDirectory: String? = nil,
                                  receivedAt: Double? = nil,
                                  expiresAt: Double? = nil) -> ClaudeQuestionReceipt {
    ClaudeQuestionReceipt(requestID: request.requestID, installationID: installationID ?? request.installationID,
                          sourceScope: sourceScope ?? request.sourceScope,
                          eventDirectory: eventDirectory ?? request.eventDirectory,
                          receivedAt: receivedAt ?? request.publishedAt,
                          expiresAt: expiresAt ?? request.expiresAt)
}

private func claudeQuestionAnswer(for request: ClaudeQuestionRequest, installationID: String? = nil,
                                  sourceScope: String? = nil, eventDirectory: String? = nil,
                                  answer: String = "Blue",
                                  decidedAt: Double? = nil) -> ClaudeQuestionAnswer {
    ClaudeQuestionAnswer(requestID: request.requestID, installationID: installationID ?? request.installationID,
                         sourceScope: sourceScope ?? request.sourceScope,
                         eventDirectory: eventDirectory ?? request.eventDirectory,
                         sessionID: request.sessionID, promptID: request.promptID, toolUseID: request.toolUseID,
                         kind: .option, answer: answer, decidedAt: decidedAt ?? request.publishedAt)
}

private func claudeQuestionLiveness(for request: ClaudeQuestionRequest,
                                    heartbeatAt: Double) -> ClaudeQuestionLiveness {
    ClaudeQuestionLiveness(requestID: request.requestID, installationID: request.installationID,
                           sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                           sessionID: request.sessionID, promptID: request.promptID,
                           toolUseID: request.toolUseID, heartbeatAt: heartbeatAt)
}

@Test func claudeQuestionPolicyPreservesInputAndAddsOnlyTheChosenAnswer() throws {
    let request = claudeQuestionRequest()
    let answer = ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                                      sourceScope: request.sourceScope,
                                      eventDirectory: request.eventDirectory,
                                      sessionID: request.sessionID, promptID: request.promptID,
                                      toolUseID: request.toolUseID, kind: .option, answer: "Blue", decidedAt: 11)
    let input: [String: Any] = ["questions": [["header": "Release", "question": "Which?", "options": [["label": "Red"], ["label": "Blue"]]]],
                                "extra": "preserve"]
    let data = try #require(ClaudeQuestionAnswerPolicy.hookOutput(toolInput: input, request: request, answer: answer))
    let output = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let hook = try #require(output["hookSpecificOutput"] as? [String: Any])
    #expect(hook["permissionDecision"] as? String == "allow")
    let updated = try #require(hook["updatedInput"] as? [String: Any])
    #expect(updated["extra"] as? String == "preserve")
    #expect((updated["answers"] as? [String: String])?["Which?"] == "Blue")
    #expect(ClaudeQuestionAnswerPolicy.accepts(request: request, answer: answer))
}

@Test func claudeQuestionPolicyAcceptsMultiSelectAndTypedAnswersButRejectsWrongIdentity() {
    let request = ClaudeQuestionRequest(requestID: "request-1", installationID: "install-1", sourceScope: "/root",
                                        eventDirectory: "/events",
                                        sessionID: "session-1",
                                        promptID: "prompt-1", toolUseID: "tool-1", publishedAt: 10, expiresAt: 20,
                                        prompts: [QuestionPrompt(header: nil, question: "Where?",
                                                                 options: ["Development", "Production"], multiSelect: true)])
    let multi = ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                                     sourceScope: request.sourceScope,
                                     eventDirectory: request.eventDirectory,
                                     sessionID: request.sessionID, promptID: request.promptID,
                                     toolUseID: request.toolUseID, kind: .multiSelect,
                                     answer: "Development, Production", decidedAt: 11)
    #expect(ClaudeQuestionAnswerPolicy.accepts(request: request, answer: multi))
    let typed = ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                                     sourceScope: request.sourceScope,
                                     eventDirectory: request.eventDirectory,
                                     sessionID: request.sessionID, promptID: request.promptID,
                                     toolUseID: request.toolUseID, kind: .text, answer: "after QA", decidedAt: 11)
    #expect(ClaudeQuestionAnswerPolicy.accepts(request: request, answer: typed))
    let wrong = ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                                     sourceScope: request.sourceScope,
                                     eventDirectory: request.eventDirectory,
                                     sessionID: "other-session", promptID: request.promptID,
                                     toolUseID: request.toolUseID, kind: .multiSelect,
                                     answer: "Development, Production", decidedAt: 11)
    #expect(!ClaudeQuestionAnswerPolicy.accepts(request: request, answer: wrong))
}

@Test func claudeQuestionStoreRefusesReplacementAndHelperRequiresExactReceiptAndAnswer() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let request = ClaudeQuestionRequest(requestID: "request-1", installationID: "install-1", sourceScope: "/root",
                                        eventDirectory: directory.standardizedFileURL.path,
                                        sessionID: "session-1",
                                        promptID: "prompt-1", toolUseID: "tool-1", publishedAt: now - 0.05,
                                        expiresAt: now + 1, prompts: [QuestionPrompt(header: "Release", question: "Which?",
                                                                                     options: ["Red", "Blue"])])
    #expect(ClaudeQuestionStore.publish(request, in: directory))
    #expect(!ClaudeQuestionStore.publish(request, in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: request, receivedAt: now - 0.02), in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionAnswer(for: request, decidedAt: now - 0.01), in: directory))
    let answer = ClaudeQuestionHelper.awaitAnswer(for: request, in: directory,
                                                  connectionTimeout: 0.2, answerTimeout: 0.2)
    #expect(answer?.answers.first?.answer == "Blue")
    #expect(!ClaudeQuestionStore.publish(claudeQuestionAnswer(for: request, answer: "Red", decidedAt: now + 0.03),
                                        in: directory))
}

@Test func claudeQuestionStoreRejectsInvalidReadIDsBeforePathConstruction() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-read-id-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = claudeQuestionRequest(requestID: "sentinel", eventDirectory: directory.standardizedFileURL.path)
    let receipt = claudeQuestionReceipt(for: request)
    let answer = claudeQuestionAnswer(for: request)
    try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("sentinel.question"))
    try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("sentinel.question-receipt"))
    try JSONEncoder().encode(answer).write(to: directory.appendingPathComponent("sentinel.question-answer"))

    for invalidID in ["../sentinel", "", "a/b", "a\\b"] {
        #expect(ClaudeQuestionStore.request(for: invalidID, in: directory) == nil)
        #expect(ClaudeQuestionStore.receipt(for: invalidID, in: directory) == nil)
        #expect(ClaudeQuestionStore.answer(for: invalidID, in: directory) == nil)
    }
}

@Test func claudeQuestionHelperLossAfterReceiptFailsClosedBeforeAnswerWrite() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-liveness-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = claudeQuestionRequest(requestID: "liveness", eventDirectory: directory.standardizedFileURL.path,
                                        publishedAt: 10, expiresAt: 20)
    let receipt = claudeQuestionReceipt(for: request, receivedAt: 10.5)
    let answer = claudeQuestionAnswer(for: request, decidedAt: 11)
    let liveness = claudeQuestionLiveness(for: request, heartbeatAt: 10.9)
    #expect(ClaudeQuestionStore.publish(request, in: directory))
    #expect(ClaudeQuestionStore.publish(receipt, in: directory))
    #expect(ClaudeQuestionStore.publish(liveness, in: directory))
    #expect(claudeQuestionLivenessIsCurrent(liveness, request: request, now: 11, deadline: request.expiresAt,
                                            maximumAge: 0.25))

    // The helper exits abruptly after the receipt but before the user clicks. Its last marker is
    // still present but stale, so the app's final pre-write check refuses to create an answer and
    // no delivery ack can exist.
    #expect(ClaudeQuestionStore.liveness(for: request.requestID, in: directory) == liveness)
    #expect(!claudeQuestionLivenessIsCurrent(liveness, request: request, now: 11.3, deadline: request.expiresAt,
                                            maximumAge: 0.25))
    #expect(ClaudeQuestionStore.publish(answer, in: directory))
    #expect(!claudeQuestionAwaitDeliveryAndCleanUp(request, answer: answer, in: directory,
                                                    timeout: 0.03))
    #expect(ClaudeQuestionStore.delivery(for: request.requestID, in: directory) == nil)
    #expect(!FileManager.default.fileExists(atPath: ClaudeQuestionStore.answerURL(in: directory,
                                                                                    id: request.requestID).path))
}

@Test func claudeQuestionDeliveryAckBindsExactAnswerIdentity() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-delivery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = claudeQuestionRequest(requestID: "delivery", eventDirectory: directory.standardizedFileURL.path,
                                        publishedAt: 10, expiresAt: 20)
    let answer = claudeQuestionAnswer(for: request, decidedAt: 11)
    let wrong = ClaudeQuestionDelivery(requestID: request.requestID, installationID: request.installationID,
                                       sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                                       sessionID: request.sessionID, promptID: request.promptID,
                                       toolUseID: request.toolUseID, answerDecidedAt: 12, deliveredAt: 12)
    #expect(ClaudeQuestionStore.publish(wrong, in: directory))
    #expect(!ClaudeQuestionHelper.awaitDelivery(for: request, answer: answer, in: directory,
                                                timeout: 0.03))
    let correctRequest = claudeQuestionRequest(requestID: "delivery-correct",
                                               eventDirectory: directory.standardizedFileURL.path,
                                               publishedAt: 10, expiresAt: 20)
    let correctAnswer = claudeQuestionAnswer(for: correctRequest, decidedAt: 11)
    #expect(ClaudeQuestionStore.publish(ClaudeQuestionDelivery(
        requestID: correctRequest.requestID, installationID: correctRequest.installationID,
        sourceScope: correctRequest.sourceScope, eventDirectory: correctRequest.eventDirectory,
        sessionID: correctRequest.sessionID, promptID: correctRequest.promptID,
        toolUseID: correctRequest.toolUseID, answerDecidedAt: correctAnswer.decidedAt,
        deliveredAt: 11.1), in: directory))
    #expect(ClaudeQuestionHelper.awaitDelivery(for: correctRequest, answer: correctAnswer,
                                               in: directory, timeout: 0.03))
}

@Test func claudeQuestionHelperRejectsMismatchedAndLateRecords() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-mismatch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970

    let mismatched = claudeQuestionRequest(requestID: "mismatch", sourceScope: "/root",
                                           eventDirectory: directory.standardizedFileURL.path,
                                           publishedAt: now, expiresAt: now + 1)
    #expect(ClaudeQuestionStore.publish(mismatched, in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: mismatched,
                                                              installationID: "other-installation",
                                                              eventDirectory: "/other-events"), in: directory))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: mismatched, in: directory,
                                             connectionTimeout: 0.03, answerTimeout: 0.03) == nil)

    let wrongAnswer = claudeQuestionRequest(requestID: "wrong-answer", sourceScope: "/root",
                                            eventDirectory: directory.standardizedFileURL.path,
                                            publishedAt: now, expiresAt: now + 0.05)
    #expect(ClaudeQuestionStore.publish(wrongAnswer, in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: wrongAnswer), in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionAnswer(for: wrongAnswer,
                                                             installationID: "other-installation",
                                                             eventDirectory: "/other-events"), in: directory))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: wrongAnswer, in: directory,
                                             connectionTimeout: 0.03, answerTimeout: 0.05) == nil)

    let late = claudeQuestionRequest(requestID: "late", sourceScope: "/root",
                                     eventDirectory: directory.standardizedFileURL.path,
                                     publishedAt: now, expiresAt: now + 0.05)
    #expect(ClaudeQuestionStore.publish(late, in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: late), in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionAnswer(for: late, decidedAt: now + 1), in: directory))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: late, in: directory,
                                             connectionTimeout: 0.03, answerTimeout: 0.08) == nil)
}

@Test func claudeQuestionHelperCannotReadAnotherRootAndPendingSkipsRestoredRequests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-root-" + UUID().uuidString)
    let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-other-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: otherRoot)
    }
    let now = Date().timeIntervalSince1970
    let request = claudeQuestionRequest(requestID: "cross-root", sourceScope: "/root",
                                        eventDirectory: root.standardizedFileURL.path,
                                        publishedAt: now, expiresAt: now + 1)
    #expect(ClaudeQuestionStore.publish(request, in: root))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: request), in: otherRoot))
    #expect(ClaudeQuestionStore.publish(claudeQuestionAnswer(for: request), in: otherRoot))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: request, in: root,
                                             connectionTimeout: 0.03, answerTimeout: 0.03) == nil)

    let restored = claudeQuestionRequest(requestID: "restored", sourceScope: "/root",
                                         eventDirectory: root.standardizedFileURL.path,
                                         publishedAt: now - 100, expiresAt: now + 100)
    #expect(ClaudeQuestionStore.publish(restored, in: root))
    let pending = ClaudeQuestionStore.pending(in: root, installationID: restored.installationID,
                                              observingSince: now - 1, now: now)
    #expect(!pending.contains { $0.requestID == restored.requestID })
}

@Test func claudeQuestionPendingIgnoresSharedDirectoryNoiseAndPrunesOnlyExpiredTriplets() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-bounded-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let eventDirectory = directory.standardizedFileURL.path
    let current = claudeQuestionRequest(requestID: "current", sourceScope: "/root",
                                        eventDirectory: eventDirectory, publishedAt: now - 0.1, expiresAt: now + 100)
    let live = claudeQuestionRequest(requestID: "live", sourceScope: "/root",
                                     eventDirectory: eventDirectory, publishedAt: now - 10, expiresAt: now + 100)
    let expired = claudeQuestionRequest(requestID: "expired", sourceScope: "/root",
                                        eventDirectory: eventDirectory, publishedAt: now - 100, expiresAt: now - 1)
    #expect(ClaudeQuestionStore.publish(current, in: directory))
    #expect(ClaudeQuestionStore.publish(live, in: directory))
    #expect(ClaudeQuestionStore.publish(expired, in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: expired), in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionAnswer(for: expired), in: directory))

    for index in 0..<4100 {
        try Data("unrelated".utf8).write(to: directory.appendingPathComponent("unrelated-\(index).json"))
    }

    let pending = ClaudeQuestionStore.pending(in: directory, installationID: current.installationID,
                                              observingSince: now - 200, now: now)
    #expect(Set(pending.map(\.requestID)) == Set([current.requestID, live.requestID]))
    #expect(FileManager.default.fileExists(atPath: ClaudeQuestionStore.requestURL(in: directory,
                                                                                    id: current.requestID).path))
    #expect(FileManager.default.fileExists(atPath: ClaudeQuestionStore.requestURL(in: directory,
                                                                                    id: live.requestID).path))
    #expect(!FileManager.default.fileExists(atPath: ClaudeQuestionStore.requestURL(in: directory,
                                                                                     id: expired.requestID).path))
    #expect(!FileManager.default.fileExists(atPath: ClaudeQuestionStore.receiptURL(in: directory,
                                                                                     id: expired.requestID).path))
    #expect(!FileManager.default.fileExists(atPath: ClaudeQuestionStore.answerURL(in: directory,
                                                                                    id: expired.requestID).path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unrelated-4099.json").path))
}

@Test func claudeQuestionPendingFailsClosedForPrivateNoiseWithoutDeletingLiveTriplet() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-private-noise-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let current = claudeQuestionRequest(requestID: "current", sourceScope: "/root",
                                        eventDirectory: directory.standardizedFileURL.path,
                                        publishedAt: now - 0.1, expiresAt: now + 100)
    #expect(ClaudeQuestionStore.publish(current, in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: current), in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionAnswer(for: current), in: directory))
    let rendezvous = ClaudeQuestionStore.rendezvousDirectory(in: directory)
    for index in 0..<4100 {
        try Data("unrelated".utf8).write(to: rendezvous.appendingPathComponent("unrelated-\(index).tmp"))
    }

    #expect(ClaudeQuestionStore.pending(in: directory, installationID: current.installationID,
                                        observingSince: now - 1, now: now).isEmpty)
    #expect(FileManager.default.fileExists(atPath: ClaudeQuestionStore.requestURL(in: directory,
                                                                                    id: current.requestID).path))
    #expect(FileManager.default.fileExists(atPath: ClaudeQuestionStore.receiptURL(in: directory,
                                                                                    id: current.requestID).path))
    #expect(FileManager.default.fileExists(atPath: ClaudeQuestionStore.answerURL(in: directory,
                                                                                   id: current.requestID).path))
}

@Test func claudeQuestionPendingNeverDeletesLiveTripletForForgedFilename() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-forged-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let live = claudeQuestionRequest(requestID: "live", sourceScope: "/root",
                                     eventDirectory: directory.standardizedFileURL.path,
                                     publishedAt: now - 0.1, expiresAt: now + 100)
    #expect(ClaudeQuestionStore.publish(live, in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: live), in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionAnswer(for: live), in: directory))
    let forged = claudeQuestionRequest(requestID: live.requestID, sourceScope: live.sourceScope,
                                       eventDirectory: live.eventDirectory,
                                       publishedAt: now - 100, expiresAt: now - 1)
    let forgedURL = ClaudeQuestionStore.rendezvousDirectory(in: directory).appendingPathComponent("other.question")
    try JSONEncoder().encode(forged).write(to: forgedURL)

    let pending = ClaudeQuestionStore.pending(in: directory, installationID: live.installationID,
                                              observingSince: now - 1, now: now)
    #expect(pending.map(\.requestID) == [live.requestID])
    #expect(FileManager.default.fileExists(atPath: ClaudeQuestionStore.requestURL(in: directory,
                                                                                    id: live.requestID).path))
    #expect(FileManager.default.fileExists(atPath: ClaudeQuestionStore.receiptURL(in: directory,
                                                                                    id: live.requestID).path))
    #expect(FileManager.default.fileExists(atPath: ClaudeQuestionStore.answerURL(in: directory,
                                                                                   id: live.requestID).path))
    #expect(FileManager.default.fileExists(atPath: forgedURL.path))
}

@Test func claudeQuestionPendingDrainsExpiredBatchesBeforeRecoveringLiveRequest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-question-expired-batches-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let eventDirectory = directory.standardizedFileURL.path
    let current = claudeQuestionRequest(requestID: "current", sourceScope: "/root",
                                        eventDirectory: eventDirectory, publishedAt: now - 0.1, expiresAt: now + 100)
    #expect(ClaudeQuestionStore.publish(current, in: directory))

    // Each expired request contributes a request, receipt, and answer file. This exceeds the
    // bounded scan in one pass while keeping the records canonical and safe to prune.
    for index in 0..<1400 {
        let expired = claudeQuestionRequest(requestID: "expired-\(index)", sourceScope: "/root",
                                            eventDirectory: eventDirectory, publishedAt: now - 100,
                                            expiresAt: now - 1)
        #expect(ClaudeQuestionStore.publish(expired, in: directory))
        #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: expired), in: directory))
        #expect(ClaudeQuestionStore.publish(claudeQuestionAnswer(for: expired), in: directory))
    }

    var pending: [ClaudeQuestionRequest] = []
    for _ in 0..<8 {
        pending = ClaudeQuestionStore.pending(in: directory, installationID: current.installationID,
                                              observingSince: now - 200, now: now)
        if !pending.isEmpty { break }
    }
    #expect(pending.map(\.requestID) == [current.requestID])
    #expect(FileManager.default.fileExists(atPath: ClaudeQuestionStore.requestURL(in: directory,
                                                                                    id: current.requestID).path))
    #expect(!FileManager.default.fileExists(atPath: ClaudeQuestionStore.requestURL(in: directory,
                                                                                     id: "expired-0").path))
}
