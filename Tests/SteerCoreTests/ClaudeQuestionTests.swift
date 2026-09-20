import Foundation
import Testing
@testable import SteerCore

private func claudeQuestionRequest(requestID: String = "request-1", installationID: String = "install-1",
                                  sourceScope: String = "/events", publishedAt: Double = 10,
                                  expiresAt: Double = 20) -> ClaudeQuestionRequest {
    ClaudeQuestionRequest(requestID: requestID, installationID: installationID, sourceScope: sourceScope,
                          sessionID: "session-1",
                          promptID: "prompt-1", toolUseID: "tool-1", publishedAt: publishedAt, expiresAt: expiresAt,
                          prompts: [QuestionPrompt(header: "Release", question: "Which?",
                                                   options: ["Red", "Blue"])])
}

private func claudeQuestionReceipt(for request: ClaudeQuestionRequest, installationID: String? = nil,
                                  sourceScope: String? = nil, receivedAt: Double? = nil,
                                  expiresAt: Double? = nil) -> ClaudeQuestionReceipt {
    ClaudeQuestionReceipt(requestID: request.requestID, installationID: installationID ?? request.installationID,
                          sourceScope: sourceScope ?? request.sourceScope,
                          receivedAt: receivedAt ?? request.publishedAt,
                          expiresAt: expiresAt ?? request.expiresAt)
}

private func claudeQuestionAnswer(for request: ClaudeQuestionRequest, installationID: String? = nil,
                                  sourceScope: String? = nil, answer: String = "Blue",
                                  decidedAt: Double? = nil) -> ClaudeQuestionAnswer {
    ClaudeQuestionAnswer(requestID: request.requestID, installationID: installationID ?? request.installationID,
                         sourceScope: sourceScope ?? request.sourceScope,
                         sessionID: request.sessionID, promptID: request.promptID, toolUseID: request.toolUseID,
                         kind: .option, answer: answer, decidedAt: decidedAt ?? request.publishedAt)
}

@Test func claudeQuestionPolicyPreservesInputAndAddsOnlyTheChosenAnswer() throws {
    let request = claudeQuestionRequest()
    let answer = ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                                      sourceScope: request.sourceScope,
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
    let request = ClaudeQuestionRequest(requestID: "request-1", installationID: "install-1", sourceScope: "/events",
                                        sessionID: "session-1",
                                        promptID: "prompt-1", toolUseID: "tool-1", publishedAt: 10, expiresAt: 20,
                                        prompts: [QuestionPrompt(header: nil, question: "Where?",
                                                                 options: ["Development", "Production"], multiSelect: true)])
    let multi = ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                                     sourceScope: request.sourceScope,
                                     sessionID: request.sessionID, promptID: request.promptID,
                                     toolUseID: request.toolUseID, kind: .multiSelect,
                                     answer: "Development, Production", decidedAt: 11)
    #expect(ClaudeQuestionAnswerPolicy.accepts(request: request, answer: multi))
    let typed = ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                                     sourceScope: request.sourceScope,
                                     sessionID: request.sessionID, promptID: request.promptID,
                                     toolUseID: request.toolUseID, kind: .text, answer: "after QA", decidedAt: 11)
    #expect(ClaudeQuestionAnswerPolicy.accepts(request: request, answer: typed))
    let wrong = ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                                     sourceScope: request.sourceScope,
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
    let request = ClaudeQuestionRequest(requestID: "request-1", installationID: "install-1", sourceScope: directory.path,
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

    let mismatched = claudeQuestionRequest(requestID: "mismatch", sourceScope: directory.path,
                                           publishedAt: now, expiresAt: now + 1)
    #expect(ClaudeQuestionStore.publish(mismatched, in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: mismatched,
                                                              installationID: "other-installation"), in: directory))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: mismatched, in: directory,
                                             connectionTimeout: 0.03, answerTimeout: 0.03) == nil)

    let wrongAnswer = claudeQuestionRequest(requestID: "wrong-answer", sourceScope: directory.path,
                                            publishedAt: now, expiresAt: now + 0.05)
    #expect(ClaudeQuestionStore.publish(wrongAnswer, in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: wrongAnswer), in: directory))
    #expect(ClaudeQuestionStore.publish(claudeQuestionAnswer(for: wrongAnswer,
                                                             installationID: "other-installation"), in: directory))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: wrongAnswer, in: directory,
                                             connectionTimeout: 0.03, answerTimeout: 0.05) == nil)

    let late = claudeQuestionRequest(requestID: "late", sourceScope: directory.path,
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
    let request = claudeQuestionRequest(requestID: "cross-root", sourceScope: root.standardizedFileURL.path,
                                        publishedAt: now, expiresAt: now + 1)
    #expect(ClaudeQuestionStore.publish(request, in: root))
    #expect(ClaudeQuestionStore.publish(claudeQuestionReceipt(for: request), in: otherRoot))
    #expect(ClaudeQuestionStore.publish(claudeQuestionAnswer(for: request), in: otherRoot))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: request, in: root,
                                             connectionTimeout: 0.03, answerTimeout: 0.03) == nil)

    let restored = claudeQuestionRequest(requestID: "restored", sourceScope: root.standardizedFileURL.path,
                                         publishedAt: now - 100, expiresAt: now + 100)
    #expect(ClaudeQuestionStore.publish(restored, in: root))
    let pending = ClaudeQuestionStore.pending(in: root, installationID: restored.installationID,
                                              observingSince: now - 1, now: now)
    #expect(!pending.contains { $0.requestID == restored.requestID })
}
