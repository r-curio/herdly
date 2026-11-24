import Foundation
import Testing
@testable import HerdlyCore

// Send Feedback (Paper "Send feedback (2026-11-24)"): an anonymous note emailed through the relay.

private func png(_ bytes: Int) -> FeedbackAttachment {
    FeedbackAttachment(filename: "shot.png", data: Data(repeating: 1, count: bytes))!
}

private func details(includeVersions: Bool = true) -> FeedbackAppDetails {
    FeedbackAppDetails(herdlyVersion: "0.9.4", herdlyBuild: "e1da6fb", macOSVersion: "26.1",
                       codexConnected: true, codexCLIVersion: includeVersions ? "0.150.0" : nil,
                       codexDesktopVersion: includeVersions ? "26.1015" : nil,
                       claudeConnected: nil, claudeVersion: nil, ghosttyEnabled: true)
}

private func body(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func sendStaysDisabledUntilThereIsADescription() {
    var draft = FeedbackDraft()
    #expect(!draft.canSend)
    draft.description = "  \n "
    #expect(!draft.canSend)
    draft.description = "The card stayed up."
    #expect(draft.canSend)
    draft.description = String(repeating: "a", count: FeedbackDraft.maxDescriptionLength + 1)
    #expect(!draft.canSend)
}

@Test func onlyImageFilesAreAccepted() {
    #expect(FeedbackAttachment(filename: "Shot.PNG", data: Data([1]))?.contentType == "image/png")
    #expect(FeedbackAttachment(filename: "photo.jpeg", data: Data([1]))?.contentType == "image/jpeg")
    #expect(FeedbackAttachment(filename: "notes.txt", data: Data([1])) == nil)
    #expect(FeedbackAttachment(filename: "script", data: Data([1])) == nil)
    #expect(FeedbackAttachment(filename: "empty.png", data: Data()) == nil)
}

@Test func attachmentsStopAtFiveAndTwentyMegabytes() {
    var draft = FeedbackDraft()
    for _ in 0..<5 { #expect(draft.add(png(10)) == .added) }
    #expect(draft.add(png(10)) == .tooMany)
    #expect(draft.attachments.count == 5)

    var large = FeedbackDraft()
    #expect(large.add(png(FeedbackDraft.maxAttachmentBytes - 10)) == .added)
    #expect(large.add(png(11)) == .tooLarge)
    #expect(large.add(png(10)) == .added)
    #expect(large.attachmentBytes == FeedbackDraft.maxAttachmentBytes)
}

@Test func removingAnAttachmentKeepsTheOthers() {
    var draft = FeedbackDraft()
    let first = png(1), second = png(2)
    _ = draft.add(first)
    _ = draft.add(second)
    draft.removeAttachment(id: first.id)
    #expect(draft.attachments == [second])
}

@Test func appDetailsNameVersionsAndConnectionsOnly() {
    #expect(details().lines == [
        "Herdly 0.9.4 (e1da6fb) · macOS 26.1",
        "Codex: connected · CLI 0.150.0 · Desktop 26.1015",
        "Claude Code: checking",
        "Ghostty: on"
    ])
    #expect(details(includeVersions: false).lines[1] == "Codex: connected")
}

@Test func requestCarriesTheTrimmedNoteAndBase64Screenshots() throws {
    var draft = FeedbackDraft()
    draft.kind = .idea
    draft.area = .approvals
    draft.description = "  Show the deadline as a ring.  \n"
    _ = draft.add(FeedbackAttachment(filename: "ring.png", data: Data([0xDE, 0xAD]))!)
    let endpoint = URL(string: "https://relay.test/feedback")!
    let request = try #require(FeedbackRelay.request(draft: draft, details: details(), endpoint: endpoint))
    #expect(request.url == endpoint)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let json = try body(request)
    #expect(json["kind"] as? String == "idea")
    #expect(json["area"] as? String == "approvals")
    #expect(json["description"] as? String == "Show the deadline as a ring.")
    #expect((json["details"] as? [String])?.first == "Herdly 0.9.4 (e1da6fb) · macOS 26.1")
    let attachment = try #require((json["attachments"] as? [[String: String]])?.first)
    #expect(attachment == ["filename": "ring.png", "contentType": "image/png", "content": "3q0="])
}

@Test func switchingDetailsOffLeavesThemOutOfTheRequest() throws {
    var draft = FeedbackDraft()
    draft.description = "Bug"
    draft.includeDetails = false
    let request = try #require(FeedbackRelay.request(draft: draft, details: details()))
    let json = try body(request)
    #expect(json["details"] == nil)
}

@Test func anUnsendableDraftBuildsNoRequest() {
    #expect(FeedbackRelay.request(draft: FeedbackDraft(), details: details()) == nil)
}

@Test func relayAnswersBecomeFooterLines() {
    #expect(FeedbackRelay.outcome(statusCode: 202) == .sent)
    #expect(FeedbackRelay.outcome(statusCode: 429) == .failed("Couldn't send: too many notes from this network. Try again in an hour."))
    #expect(FeedbackRelay.outcome(statusCode: 413) == .failed("Couldn't send: the screenshots are too large."))
    #expect(FeedbackRelay.outcome(statusCode: 400) == .failed("Couldn't send: the feedback service turned the note down (400)."))
    #expect(FeedbackRelay.outcome(statusCode: 502) == .failed("Couldn't send: the feedback service is having trouble. Try again later."))
}
