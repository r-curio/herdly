import Foundation
import Testing
@testable import SteerCore

private func claudeQuestionRequest() -> ClaudeQuestionRequest {
    ClaudeQuestionRequest(requestID: "request-1", installationID: "install-1", sourceScope: "/events",
                          sessionID: "session-1",
                          promptID: "prompt-1", toolUseID: "tool-1", publishedAt: 10, expiresAt: 20,
                          prompts: [QuestionPrompt(header: "Release", question: "Which?",
                                                   options: ["Red", "Blue"])])
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
        _ = ClaudeQuestionStore.publish(ClaudeQuestionReceipt(requestID: request.requestID,
                                                              installationID: request.installationID,
                                                              sourceScope: request.sourceScope,
                                                              receivedAt: now + 0.01, expiresAt: now + 1), in: directory)
        _ = ClaudeQuestionStore.publish(ClaudeQuestionAnswer(requestID: request.requestID,
                                                             installationID: request.installationID,
                                                             sourceScope: request.sourceScope,
                                                             sessionID: request.sessionID, promptID: request.promptID,
                                                             toolUseID: request.toolUseID, kind: .option,
                                                             answer: "Blue", decidedAt: now + 0.02), in: directory)
    }
    let answer = ClaudeQuestionHelper.awaitAnswer(for: request, in: directory,
                                                  connectionTimeout: 0.2, answerTimeout: 0.2)
    #expect(answer?.answer == "Blue")
}
