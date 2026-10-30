import Foundation
import Testing
@testable import HerdlyCore
@testable import HerdlyApp

// ADR 0020, amended 2026-10-30 (#374): a live Claude question pauses like a live approval.

@Test func aClaudeQuestionWaitsThirtySecondsAndAHoldNeverRunsPastTwoMinutesFromPublish() {
    #expect(ClaudeQuestionTiming.answerTimeout == 30)
    #expect(ClaudeQuestionTiming.heldDeadline(publishedAt: 0, expiresAt: 30, held: nil) == 30)
    #expect(ClaudeQuestionTiming.heldDeadline(publishedAt: 0, expiresAt: 30, held: 20) == 30)
    #expect(ClaudeQuestionTiming.heldDeadline(publishedAt: 0, expiresAt: 30, held: 45) == 45)
    #expect(ClaudeQuestionTiming.heldDeadline(publishedAt: 0, expiresAt: 30, held: 500) == 120)
    #expect(ClaudeQuestionTiming.heldDeadline(publishedAt: 0, expiresAt: 30, held: .nan) == 30)
    #expect(ClaudeQuestionTiming.heldDeadline(publishedAt: 0, expiresAt: 30, held: .infinity) == 30)
    // A shorter window (a receipt issued late) still caps at two minutes from publish.
    #expect(ClaudeQuestionTiming.heldDeadline(publishedAt: 0, expiresAt: 10, held: 500) == 120)
}

@Test func hoveringKeepsAClaudeQuestionsTimeLeftUpToTheCap() {
    var hold = ApprovalHoverHold<String>()
    let live = [ApprovalHoverHold<String>.Live(key: "question", expiresAt: 30)]
    hold.update(hovering: true, live: live, now: 10)
    hold.update(hovering: true, live: live, now: 50)
    #expect(hold.deadline(for: "question", expiresAt: 30) == 70)
    hold.update(hovering: true, live: live, now: 200)
    #expect(hold.deadline(for: "question", expiresAt: 30) == 120)
    #expect(ClaudeQuestionTiming.heldDeadline(publishedAt: 0, expiresAt: 30,
                                              held: hold.deadline(for: "question", expiresAt: 30)) == 120)
}

private func liveQuestion(_ id: String, in directory: URL, window: Double) -> ClaudeQuestionRequest {
    let now = Date().timeIntervalSince1970
    let request = ClaudeQuestionRequest(requestID: id, installationID: "install-1", sourceScope: "/root",
                                        eventDirectory: directory.standardizedFileURL.path,
                                        sessionID: "session-1", promptID: "prompt-1", toolUseID: "tool-1",
                                        publishedAt: now, expiresAt: now + window,
                                        prompts: [QuestionPrompt(header: nil, question: "Which?", options: ["Red", "Blue"])])
    _ = ClaudeQuestionStore.publish(request, in: directory)
    _ = ClaudeQuestionStore.publish(ClaudeQuestionReceipt(requestID: id, installationID: request.installationID,
                                                          sourceScope: request.sourceScope,
                                                          eventDirectory: request.eventDirectory,
                                                          receivedAt: now, expiresAt: request.expiresAt), in: directory)
    return request
}

private func answer(_ request: ClaudeQuestionRequest, at decidedAt: Double) -> ClaudeQuestionAnswer {
    ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                         sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                         sessionID: request.sessionID, promptID: request.promptID, toolUseID: request.toolUseID,
                         kind: .option, answer: "Blue", decidedAt: decidedAt)
}

@Test func theQuestionHelperWaitsForAHoldAndAcceptsAnAnswerWithinIt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-question-hold-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let request = liveQuestion("held", in: directory, window: 0.3)
    #expect(ApprovalHoldStore.publish(ApprovalHoldRecord(requestID: "held", heldUntil: request.publishedAt + 1.2),
                                      to: ClaudeQuestionStore.holdURL(in: directory, id: "held")))
    #expect(ClaudeQuestionStore.heldDeadline(for: request, in: directory) == request.publishedAt + 1.2)
    let writer = Thread {
        Thread.sleep(forTimeInterval: 0.6)
        _ = ClaudeQuestionStore.publish(answer(request, at: Date().timeIntervalSince1970), in: directory)
    }
    writer.start()
    #expect(ClaudeQuestionHelper.awaitAnswer(for: request, in: directory,
                                             connectionTimeout: 0.2, answerTimeout: 0.3)?.answer == "Blue")
}

@Test func aMalformedOrMismatchedQuestionHoldLeavesTheBaseDeadlineAndExpiryAnswersNothing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-question-hold-bad-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let malformed = liveQuestion("malformed", in: directory, window: 0.2)
    try Data("{\"request_id\":\"malformed\",\"held_until\":\"later\"}".utf8)
        .write(to: ClaudeQuestionStore.holdURL(in: directory, id: "malformed"))
    #expect(ClaudeQuestionStore.heldDeadline(for: malformed, in: directory) == malformed.expiresAt)

    let mismatched = liveQuestion("mismatched", in: directory, window: 0.2)
    #expect(ApprovalHoldStore.publish(ApprovalHoldRecord(requestID: "other", heldUntil: mismatched.publishedAt + 5),
                                      to: ClaudeQuestionStore.holdURL(in: directory, id: "mismatched")))
    #expect(ClaudeQuestionStore.heldDeadline(for: mismatched, in: directory) == mismatched.expiresAt)

    // No answer arrives: the helper returns nothing once the base window passes, and a hold far
    // past the cap is bounded to two minutes from publish rather than honoured.
    let started = Date()
    #expect(ClaudeQuestionHelper.awaitAnswer(for: mismatched, in: directory,
                                             connectionTimeout: 0.1, answerTimeout: 0.2) == nil)
    #expect(Date().timeIntervalSince(started) < 1)
    let capped = liveQuestion("capped", in: directory, window: 0.2)
    #expect(ApprovalHoldStore.publish(ApprovalHoldRecord(requestID: "capped", heldUntil: capped.publishedAt + 10_000),
                                      to: ClaudeQuestionStore.holdURL(in: directory, id: "capped")))
    #expect(ClaudeQuestionStore.heldDeadline(for: capped, in: directory) == capped.publishedAt + ApprovalTiming.maximumHold)
}

@Test func anAnswerDecidedAfterTheHeldDeadlineIsRefused() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-question-hold-late-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let request = liveQuestion("late", in: directory, window: 0.2)
    #expect(ApprovalHoldStore.publish(ApprovalHoldRecord(requestID: "late", heldUntil: request.publishedAt + 0.5),
                                      to: ClaudeQuestionStore.holdURL(in: directory, id: "late")))
    #expect(ClaudeQuestionStore.publish(answer(request, at: request.publishedAt + 0.9), in: directory))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: request, in: directory,
                                             connectionTimeout: 0.1, answerTimeout: 0.2) == nil)
}

@Test func pendingKeepsAHeldQuestionPastItsBaseWindowAndCleansItsHoldOnExpiry() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-question-hold-pending-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let request = liveQuestion("pending", in: directory, window: 1)
    let holdURL = ClaudeQuestionStore.holdURL(in: directory, id: "pending")
    #expect(ApprovalHoldStore.publish(ApprovalHoldRecord(requestID: "pending", heldUntil: request.publishedAt + 5),
                                      to: holdURL))
    #expect(ClaudeQuestionStore.pending(in: directory, installationID: "install-1", observingSince: 0,
                                        now: request.publishedAt + 3).map(\.requestID) == ["pending"])
    #expect(ClaudeQuestionStore.pending(in: directory, installationID: "install-1", observingSince: 0,
                                        now: request.publishedAt + 6).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: holdURL.path))
}

@Test func theAppKeepsAHeldQuestionAnswerableOnlyUntilItsHeldDeadline() {
    let request = ClaudeQuestionRequest(requestID: "app", installationID: "install-1", sourceScope: "/root",
                                        eventDirectory: "/events", sessionID: "session-1", promptID: "prompt-1",
                                        toolUseID: "tool-1", publishedAt: 0, expiresAt: 30,
                                        prompts: [QuestionPrompt(header: nil, question: "Which?", options: ["Red"])])
    let liveness = ClaudeQuestionLiveness(requestID: "app", installationID: "install-1", sourceScope: "/root",
                                          eventDirectory: "/events", sessionID: "session-1", promptID: "prompt-1",
                                          toolUseID: "tool-1", heartbeatAt: 40)
    #expect(!claudeQuestionLivenessIsCurrent(liveness, request: request, now: 40.1))
    #expect(claudeQuestionLivenessIsCurrent(liveness, request: request, now: 40.1, deadline: 45))
    #expect(!claudeQuestionLivenessIsCurrent(liveness, request: request, now: 40.1, deadline: 40))
    // The countdown stands still while held: 20 s left at 10, still 20 s left at 50 with the hold.
    #expect(ApprovalCountdown(arrivedAt: 0, expiresAt: 30, now: 10)?.label == "20s left")
    #expect(ApprovalCountdown(arrivedAt: 0, expiresAt: 70, now: 50)?.label == "20s left")
    #expect(ApprovalCountdown(arrivedAt: 0, expiresAt: 70, now: 50)?.fraction
                == ApprovalCountdown(arrivedAt: 0, expiresAt: 30, now: 10)?.fraction)
}
