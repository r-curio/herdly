import Foundation
import Testing
@testable import HerdlyCore

// #385: the companion's in-memory answer capability for live Claude questions, driven through
// scans (observe, prune) and receipt results exactly as the app drives it, with explicit times.

@Test func aScanThatMissesALiveQuestionThenARescanRestoresItsAnswerToken() throws {
    let fixture = try CapabilityFixture()
    defer { fixture.remove() }
    var state = ClaudeQuestionCapabilities()
    try fixture.receipt(&state, generation: 1, now: 101.4)
    #expect(state.canAnswer(fixture.id))

    // One scan lists neither the request file nor its hook record: the token is pruned.
    state.prune(now: 102, roots: [fixture.root], listedIDs: [])
    #expect(!state.canAnswer(fixture.id))

    // The rescan lists it again; its receipt work re-adopts this companion's receipt.
    try fixture.receipt(&state, generation: 2, now: 103.4)
    #expect(state.canAnswer(fixture.id))
}

@Test func aHeldQuestionPrunedAfterItsThirtySecondsIsAnswerableAgainOnTheRescan() throws {
    let fixture = try CapabilityFixture()
    defer { fixture.remove() }
    var state = ClaudeQuestionCapabilities()
    try fixture.receipt(&state, generation: 1, now: 101.4)
    // The pointer rests on the notch: the hold carries the question to publish + 60 s.
    state.hold(fixture.request, until: 160)
    #expect(state.deadline(for: fixture.request) == 160)

    // Past the 30-second window, inside the hold, a scan misses it and the rescan lists it.
    state.prune(now: 140, roots: [fixture.root], listedIDs: [])
    #expect(!state.canAnswer(fixture.id))
    #expect(state.deadline(for: fixture.request) == 160)
    try fixture.receipt(&state, generation: 2, now: 142)
    #expect(state.canAnswer(fixture.id))
    state.prune(now: 143, roots: [fixture.root], listedIDs: [fixture.id])
    #expect(state.canAnswer(fixture.id))
}

@Test func anUnheldQuestionPrunedAfterItsThirtySecondsStaysExpired() throws {
    let fixture = try CapabilityFixture()
    defer { fixture.remove() }
    var state = ClaudeQuestionCapabilities()
    try fixture.receipt(&state, generation: 1, now: 101.4)
    state.prune(now: 129, roots: [fixture.root], listedIDs: [])
    // The rescan after the window: no work is accepted and nothing is answerable.
    if let work = state.observe(fixture.live, scanGeneration: 2) {
        _ = state.reconcile(claudeQuestionIssueReceipt(work, now: 131), currentGeneration: 2,
                            roots: [fixture.root], now: 131)
    }
    #expect(!state.canAnswer(fixture.id))
    state.prune(now: 131, roots: [fixture.root], listedIDs: [fixture.id])
    #expect(state.live[fixture.id] == nil)
}

@Test func aHoldNeverRunsPastTwoMinutesFromPublishAndIsForgottenAfterIt() throws {
    let fixture = try CapabilityFixture()
    defer { fixture.remove() }
    var state = ClaudeQuestionCapabilities()
    try fixture.receipt(&state, generation: 1, now: 101.4)
    state.hold(fixture.request, until: 500)
    #expect(state.deadline(for: fixture.request) == 220)
    state.prune(now: 220, roots: [fixture.root], listedIDs: [])
    #expect(state.deadline(for: fixture.request) == fixture.request.expiresAt)
}

@Test func aSpentTokenIsNotRestoredByAPruneAndRescan() throws {
    let fixture = try CapabilityFixture()
    defer { fixture.remove() }
    var state = ClaudeQuestionCapabilities()
    try fixture.receipt(&state, generation: 1, now: 101.4)
    let spent = state.spend(fixture.id, now: 105)
    #expect(spent)
    #expect(!state.canAnswer(fixture.id))
    state.prune(now: 106, roots: [fixture.root], listedIDs: [])
    let rescanWork = state.observe(fixture.live, scanGeneration: 2)
    #expect(rescanWork == nil)
    #expect(!state.canAnswer(fixture.id))
}

@Test func aReceiptFromAPreviousLaunchNeverMakesTheRescannedQuestionAnswerable() throws {
    let fixture = try CapabilityFixture()
    defer { fixture.remove() }
    var previousLaunch = ClaudeQuestionCapabilities()
    try fixture.receipt(&previousLaunch, generation: 1, now: 101.4)
    var relaunched = ClaudeQuestionCapabilities()
    let queued = relaunched.observe(fixture.live, scanGeneration: 1)
    let work = try #require(queued)
    let disposition = relaunched.reconcile(claudeQuestionIssueReceipt(work, now: 103), currentGeneration: 1,
                                           roots: [fixture.root], now: 103)
    #expect(disposition == .discard)
    #expect(!relaunched.canAnswer(fixture.id))
}

private struct CapabilityFixture {
    let directory: URL
    let request: ClaudeQuestionRequest
    var id: String { request.requestID }
    var live: LiveClaudeQuestion { LiveClaudeQuestion(request: request, events: directory, sourceScope: "/root") }
    var root: ClaudeQuestionRootKey { live.root }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdly-claude-question-capabilities-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        request = ClaudeQuestionRequest(requestID: "request-1", installationID: "install-1", sourceScope: "/root",
                                        eventDirectory: directory.standardizedFileURL.path,
                                        sessionID: "session-1", promptID: "prompt-1", toolUseID: "tool-1",
                                        publishedAt: 100, expiresAt: 130,
                                        prompts: [QuestionPrompt(header: "Release", question: "Which?",
                                                                 options: ["Red", "Blue"])])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// One scan that lists the question, then its receipt work landing on the main actor.
    func receipt(_ state: inout ClaudeQuestionCapabilities, generation: UInt64, now: Double) throws {
        let queued = state.observe(live, scanGeneration: generation)
        let work = try #require(queued)
        state.prune(now: now, roots: [root], listedIDs: [id])
        _ = state.reconcile(claudeQuestionIssueReceipt(work, now: now), currentGeneration: generation,
                            roots: [root], now: now)
    }
}
