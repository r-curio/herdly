import Foundation
import Testing
@testable import HerdlyCore

// #385: a live Claude question whose receipt this running companion already issued must not stay
// read-only after its in-memory token is pruned and the question is rescanned.

@Test func claudeQuestionReceiptIsReissuedAfterAPruneAndRescanFindsThisCompanionsOwnReceipt() throws {
    let directory = try receiptTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = receiptTestRequest(in: directory, publishedAt: 100)
    var ledger = ClaudeQuestionReceiptLedger()

    // First scan: the companion issues the receipt and records it.
    let first = try #require(ClaudeQuestionStore.issueReceipt(for: request, in: directory,
                                                               issued: ledger.adoptable(for: request), now: 101.4))
    ledger.record(first)
    // A prune drops the token, and the rescan queues receipt work again. The receipt file is
    // still there, so a plain publish fails; this was the stuck state.
    #expect(!ClaudeQuestionStore.publish(first, in: directory))
    let again = ClaudeQuestionStore.issueReceipt(for: request, in: directory,
                                                 issued: ledger.adoptable(for: request), now: 103.4)
    #expect(again == first)
}

@Test func claudeQuestionReceiptOnDiskFromAPreviousLaunchOrAnotherProcessIsNeverAdopted() throws {
    let directory = try receiptTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = receiptTestRequest(in: directory, publishedAt: 100)
    // An identical receipt left by an earlier launch: this launch's ledger is empty.
    let previous = ClaudeQuestionReceipt(requestID: request.requestID, installationID: request.installationID,
                                         sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                                         receivedAt: 101, expiresAt: request.expiresAt)
    #expect(ClaudeQuestionStore.publish(previous, in: directory))
    let ledger = ClaudeQuestionReceiptLedger()
    #expect(ClaudeQuestionStore.issueReceipt(for: request, in: directory,
                                             issued: ledger.adoptable(for: request), now: 102) == nil)

    // This companion issued a receipt, but another one is what is on disk.
    var own = ClaudeQuestionReceiptLedger()
    own.record(ClaudeQuestionReceipt(requestID: request.requestID, installationID: request.installationID,
                                     sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                                     receivedAt: 101.5, expiresAt: request.expiresAt))
    #expect(ClaudeQuestionStore.issueReceipt(for: request, in: directory,
                                             issued: own.adoptable(for: request), now: 102) == nil)
}

@Test func claudeQuestionReceiptReadoptionStillDiscardsMismatchedExpiredAndSpentRequests() throws {
    let directory = try receiptTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = receiptTestRequest(in: directory, publishedAt: 100)
    var ledger = ClaudeQuestionReceiptLedger()
    let receipt = try #require(ClaudeQuestionStore.issueReceipt(for: request, in: directory,
                                                                 issued: nil, now: 101))
    ledger.record(receipt)

    // A request with the same id but another identity or window is not the one receipted.
    let variants = [
        ClaudeQuestionRequest(requestID: request.requestID, installationID: "install-2",
                              sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                              sessionID: request.sessionID, promptID: request.promptID, toolUseID: request.toolUseID,
                              publishedAt: request.publishedAt, expiresAt: request.expiresAt, prompts: request.prompts),
        ClaudeQuestionRequest(requestID: request.requestID, installationID: request.installationID,
                              sourceScope: "/other-root", eventDirectory: request.eventDirectory,
                              sessionID: request.sessionID, promptID: request.promptID, toolUseID: request.toolUseID,
                              publishedAt: request.publishedAt, expiresAt: request.expiresAt, prompts: request.prompts),
        ClaudeQuestionRequest(requestID: request.requestID, installationID: request.installationID,
                              sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                              sessionID: request.sessionID, promptID: request.promptID, toolUseID: request.toolUseID,
                              publishedAt: request.publishedAt, expiresAt: request.expiresAt + 5,
                              prompts: request.prompts),
        ClaudeQuestionRequest(requestID: request.requestID, installationID: request.installationID,
                              sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                              sessionID: request.sessionID, promptID: request.promptID, toolUseID: request.toolUseID,
                              publishedAt: 101.5, expiresAt: request.expiresAt, prompts: request.prompts)
    ]
    for variant in variants {
        #expect(ClaudeQuestionStore.issueReceipt(for: variant, in: directory,
                                                 issued: ledger.adoptable(for: variant), now: 102) == nil)
    }
    // Expired: nothing is issued, even this companion's own receipt.
    #expect(ClaudeQuestionStore.issueReceipt(for: request, in: directory,
                                             issued: ledger.adoptable(for: request), now: request.expiresAt) == nil)
    // Spent: the token is spent once; re-adoption never grants it again.
    ledger.spend(request.requestID)
    #expect(ledger.adoptable(for: request) == nil)
    #expect(ClaudeQuestionStore.issueReceipt(for: request, in: directory,
                                             issued: ledger.adoptable(for: request), now: 102) == nil)
}

@Test func claudeQuestionReceiptLedgerKeepsReceiptsAndSpentMarksUntilNoHelperCanStillWait() {
    let request = ClaudeQuestionRequest(requestID: "request-1", installationID: "install-1", sourceScope: "/root",
                                        eventDirectory: "/events", sessionID: "session-1", promptID: "prompt-1",
                                        toolUseID: "tool-1", publishedAt: 100, expiresAt: 130,
                                        prompts: [QuestionPrompt(header: "Release", question: "Which?",
                                                                 options: ["Red", "Blue"])])
    let receipt = ClaudeQuestionReceipt(requestID: "request-1", installationID: "install-1", sourceScope: "/root",
                                        eventDirectory: "/events", receivedAt: 101, expiresAt: 130)
    var ledger = ClaudeQuestionReceiptLedger()
    ledger.record(receipt)
    // A hover hold can keep the helper waiting to publish + 2 min + 1 s; the receipt stays adoptable.
    ledger.prune(now: 221.9)
    #expect(ledger.adoptable(for: request) == receipt)
    ledger.prune(now: 222)
    #expect(ledger.adoptable(for: request) == nil)

    var spent = ClaudeQuestionReceiptLedger()
    spent.record(receipt)
    spent.spend("request-1")
    spent.prune(now: 150)
    #expect(spent.isSpent("request-1"))
    #expect(spent.adoptable(for: request) == nil)
    spent.prune(now: 222)
    #expect(!spent.isSpent("request-1"))
}

private func receiptTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("herdly-claude-question-ledger-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func receiptTestRequest(in directory: URL, requestID: String = "request-1",
                                publishedAt: Double) -> ClaudeQuestionRequest {
    ClaudeQuestionRequest(requestID: requestID, installationID: "install-1", sourceScope: "/root",
                          eventDirectory: directory.standardizedFileURL.path,
                          sessionID: "session-1", promptID: "prompt-1", toolUseID: "tool-1",
                          publishedAt: publishedAt, expiresAt: publishedAt + ClaudeQuestionTiming.answerTimeout,
                          prompts: [QuestionPrompt(header: "Release", question: "Which?", options: ["Red", "Blue"])])
}
