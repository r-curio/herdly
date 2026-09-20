import Foundation
import Testing
@testable import SteerCore
@testable import SteerApp

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
                                             scanGeneration: 1, written: true)
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 2,
                                             liveRequest: request, rootIsCurrent: true, now: 11) == .staleAccept)
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 1,
                                             liveRequest: request, rootIsCurrent: true, now: 11) == .accept)
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 2,
                                             liveRequest: nil, rootIsCurrent: true, now: 11) == .discard)
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 2,
                                             liveRequest: claudeQuestionRequest(requestID: "other"),
                                             rootIsCurrent: true, now: 11) == .discard)
    #expect(claudeQuestionReceiptDisposition(result, currentGeneration: 2,
                                             liveRequest: request, rootIsCurrent: false, now: 11) == .discard)
    #expect(claudeQuestionReceiptDisposition(
        ClaudeQuestionReceiptResult(request: request, requestID: request.requestID, root: root,
                                    scanGeneration: 1, written: false),
        currentGeneration: 2, liveRequest: request, rootIsCurrent: true, now: 11) == .discard)
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
                                     answer: multi.answer, decidedAt: 11)
    #expect(!ClaudeQuestionAnswerPolicy.accepts(request: request, answer: wrong))
}

@Test func claudeQuestionStoreRefusesReplacementAndHelperRequiresExactReceiptAndAnswer() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-question-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let request = ClaudeQuestionRequest(requestID: "request-1", installationID: "install-1", sourceScope: "/root",
                                        eventDirectory: directory.standardizedFileURL.path,
                                        sessionID: "session-1",
                                        promptID: "prompt-1", toolUseID: "tool-1", publishedAt: now,
                                        expiresAt: now + 1, prompts: [QuestionPrompt(header: "Release", question: "Which?",
                                                                                     options: ["Red", "Blue"])])
    #expect(ClaudeQuestionStore.publish(request, in: directory))
    #expect(!ClaudeQuestionStore.publish(request, in: directory))

    DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
        let receipt = claudeQuestionReceipt(for: request, receivedAt: now + 0.01)
        let answer = claudeQuestionAnswer(for: request, decidedAt: now + 0.02)
        _ = ClaudeQuestionStore.publish(receipt, in: directory)
        _ = ClaudeQuestionStore.publish(answer, in: directory)
    }
    let answer = ClaudeQuestionHelper.awaitAnswer(for: request, in: directory,
                                                  connectionTimeout: 0.2, answerTimeout: 0.2)
    #expect(answer?.answer == "Blue")
    #expect(!ClaudeQuestionStore.publish(claudeQuestionAnswer(for: request, answer: "Red", decidedAt: now + 0.03),
                                        in: directory))
}

@Test func claudeQuestionHelperRejectsMismatchedAndLateRecords() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-question-mismatch-" + UUID().uuidString)
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-question-root-" + UUID().uuidString)
    let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-question-other-" + UUID().uuidString)
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
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-question-bounded-" + UUID().uuidString)
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
