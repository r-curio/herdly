import Foundation
import HerdlyCore
import Testing

// #411: Open on a live Claude question hands it back to Claude with no answer.

private func handBackDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("herdly-claude-question-handback-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func handBackRequest(_ id: String, in directory: URL, publishedAt: Double,
                             window: Double = 5) -> ClaudeQuestionRequest {
    ClaudeQuestionRequest(requestID: id, installationID: "install-1", sourceScope: "/root",
                          eventDirectory: directory.standardizedFileURL.path, sessionID: "session-1",
                          promptID: "prompt-1", toolUseID: "tool-1", publishedAt: publishedAt,
                          expiresAt: publishedAt + window,
                          prompts: [QuestionPrompt(header: "Release", question: "Which?", options: ["Red", "Blue"])])
}

private func receipt(for request: ClaudeQuestionRequest) -> ClaudeQuestionReceipt {
    ClaudeQuestionReceipt(requestID: request.requestID, installationID: request.installationID,
                          sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                          receivedAt: request.publishedAt, expiresAt: request.expiresAt)
}

@Test func claudeQuestionHandBackMatchesOnlyTheExactCall() throws {
    let directory = try handBackDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = handBackRequest("exact", in: directory, publishedAt: 100)
    let exact = ClaudeQuestionHandBack(for: request, handedBackAt: 101)
    #expect(exact.handsBack(request, in: directory, now: 102))

    func with(_ change: (inout [String: Any]) -> Void) throws -> ClaudeQuestionHandBack {
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(exact)) as? [String: Any])
        change(&object)
        return try JSONDecoder().decode(ClaudeQuestionHandBack.self, from: JSONSerialization.data(withJSONObject: object))
    }
    for key in ["requestID", "installationID", "sourceScope", "eventDirectory", "sessionID", "promptID", "toolUseID"] {
        #expect(!(try with { $0[key] = "other" }).handsBack(request, in: directory, now: 102), "\(key)")
    }
    // Before publish, in the future, or read from another directory: ignored.
    #expect(!ClaudeQuestionHandBack(for: request, handedBackAt: 99).handsBack(request, in: directory, now: 102))
    #expect(!ClaudeQuestionHandBack(for: request, handedBackAt: 103).handsBack(request, in: directory, now: 102))
    #expect(!exact.handsBack(request, in: directory.appendingPathComponent("elsewhere"), now: 102))
}

@Test func claudeQuestionHelperStopsPromptlyOnAMatchingHandBack() throws {
    let directory = try handBackDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let request = handBackRequest("handed-back", in: directory, publishedAt: now - 0.05)
    #expect(ClaudeQuestionStore.publish(request, in: directory))
    #expect(ClaudeQuestionStore.publish(receipt(for: request), in: directory))
    #expect(ClaudeQuestionStore.publish(ClaudeQuestionHandBack(for: request, handedBackAt: now - 0.01), in: directory))
    let started = ProcessInfo.processInfo.systemUptime
    #expect(ClaudeQuestionHelper.awaitAnswer(for: request, in: directory,
                                             connectionTimeout: 0.5, answerTimeout: 3) == nil)
    // Well before the 3-second window: the hand-back ended the wait, not the deadline.
    #expect(ProcessInfo.processInfo.systemUptime - started < 1)
}

@Test func claudeQuestionHelperIgnoresAMismatchedOrMalformedHandBack() throws {
    let directory = try handBackDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let request = handBackRequest("mismatched", in: directory, publishedAt: now - 0.05)
    #expect(ClaudeQuestionStore.publish(request, in: directory))
    #expect(ClaudeQuestionStore.publish(receipt(for: request), in: directory))
    let other = ClaudeQuestionHandBack(requestID: request.requestID, installationID: request.installationID,
                                       sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                                       sessionID: request.sessionID, promptID: request.promptID,
                                       toolUseID: "another-tool", handedBackAt: now - 0.01)
    #expect(ClaudeQuestionStore.publish(other, in: directory))
    let answerTimeout = 0.3
    let started = ProcessInfo.processInfo.systemUptime
    #expect(ClaudeQuestionHelper.awaitAnswer(for: request, in: directory,
                                             connectionTimeout: 0.5, answerTimeout: answerTimeout) == nil)
    // It waited out its window: the mismatched record did not stop it.
    #expect(ProcessInfo.processInfo.systemUptime - started >= answerTimeout - 0.05)

    let malformed = handBackRequest("malformed", in: directory, publishedAt: now - 0.05)
    #expect(ClaudeQuestionStore.publish(malformed, in: directory))
    #expect(ClaudeQuestionStore.publish(receipt(for: malformed), in: directory))
    try Data("{\"requestID\":\"malformed\"".utf8)
        .write(to: ClaudeQuestionStore.handBackURL(in: directory, id: malformed.requestID))
    // A matching answer still arrives after the malformed record and is returned.
    let answer = ClaudeQuestionAnswer(requestID: malformed.requestID, installationID: malformed.installationID,
                                      sourceScope: malformed.sourceScope, eventDirectory: malformed.eventDirectory,
                                      sessionID: malformed.sessionID, promptID: malformed.promptID,
                                      toolUseID: malformed.toolUseID, kind: .option, answer: "Red",
                                      decidedAt: Date().timeIntervalSince1970)
    #expect(ClaudeQuestionStore.publish(answer, in: directory))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: malformed, in: directory,
                                             connectionTimeout: 0.5, answerTimeout: 0.5)?.answers.first?.answer == "Red")
}

@Test func claudeQuestionAnswerAlreadyWrittenWinsOverAHandBack() throws {
    let directory = try handBackDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let request = handBackRequest("answered", in: directory, publishedAt: now - 0.05)
    #expect(ClaudeQuestionStore.publish(request, in: directory))
    #expect(ClaudeQuestionStore.publish(receipt(for: request), in: directory))
    let answer = ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                                      sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                                      sessionID: request.sessionID, promptID: request.promptID,
                                      toolUseID: request.toolUseID, kind: .option, answer: "Blue",
                                      decidedAt: now - 0.02)
    #expect(ClaudeQuestionStore.publish(answer, in: directory))
    #expect(ClaudeQuestionStore.publish(ClaudeQuestionHandBack(for: request, handedBackAt: now - 0.01), in: directory))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: request, in: directory,
                                             connectionTimeout: 0.5, answerTimeout: 0.5) == answer)
    // The record is written once and never replaced.
    #expect(!ClaudeQuestionStore.publish(ClaudeQuestionHandBack(for: request, handedBackAt: now), in: directory))
}

@Test func claudeQuestionPendingPrunesAnExpiredHandBackWithItsRequest() throws {
    let directory = try handBackDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let expired = handBackRequest("expired", in: directory, publishedAt: now - 100, window: 1)
    #expect(ClaudeQuestionStore.publish(expired, in: directory))
    #expect(ClaudeQuestionStore.publish(ClaudeQuestionHandBack(for: expired, handedBackAt: now - 99.5), in: directory))
    _ = ClaudeQuestionStore.pending(in: directory, installationID: "install-1", observingSince: now - 200, now: now)
    #expect(!FileManager.default.fileExists(atPath: ClaudeQuestionStore.handBackURL(in: directory, id: "expired").path))
}
