import Foundation
import Testing
@testable import HerdlyCore

// Claude Desktop Code sessions (#471): the registry's host, the session index, and Open's plan.

private let desktopHook = "8b98df5a-86b6-4f95-9672-efb2e494b3fd"
private let terminalHook = "22222222-2222-4222-8222-222222222222"
private let desktopLocal = "local_192c3a70-1434-4035-9547-ecd4d906bf8f"

private func registryEntry(pid: Int32, sessionID: String, entrypoint: Any?) throws -> ClaudeSessionRegistry.Entry {
    var row: [String: Any] = ["pid": Int(pid), "sessionId": sessionID, "cwd": "/tmp/probe", "name": "probe",
                              "startedAt": 1_795_504_100_000, "kind": "interactive", "status": "busy"]
    if let entrypoint { row["entrypoint"] = entrypoint }
    return .init(pid: pid, data: try JSONSerialization.data(withJSONObject: row))
}

private func sessionFile(local: Any?, hook: Any?, focusedAt: Any? = 1_795_504_100_366) throws -> Data {
    var object: [String: Any] = ["cwd": "/tmp/probe", "isArchived": false, "enabledMcpTools": ["a:b": true]]
    if let local { object["sessionId"] = local }
    if let hook { object["cliSessionId"] = hook }
    if let focusedAt { object["lastFocusedAt"] = focusedAt }
    return try JSONSerialization.data(withJSONObject: object)
}

@Test func claudeRegistryNamesClaudeDesktopAsTheHostOnlyForItsEntrypoint() throws {
    let scan = ClaudeSessionRegistry.decode([try registryEntry(pid: 10, sessionID: desktopHook, entrypoint: "claude-desktop"),
                                             try registryEntry(pid: 11, sessionID: terminalHook, entrypoint: "cli")],
                                            sourceScope: "/tmp/root", observedAt: 10, isRunning: { _ in true })
    #expect(scan.available)
    let hosts = Dictionary(uniqueKeysWithValues: scan.sessions.map { ($0.sessionID, $0.host) })
    #expect(hosts == [desktopHook: .claudeDesktop, terminalHook: .terminal])
}

@Test func claudeRegistryTreatsAMissingOrUnknownEntrypointAsATerminal() throws {
    for entrypoint: Any? in [nil, "sdk-cli", 7, "Claude-Desktop"] {
        let scan = ClaudeSessionRegistry.decode([try registryEntry(pid: 10, sessionID: desktopHook, entrypoint: entrypoint)],
                                                sourceScope: "/tmp/root", observedAt: 10, isRunning: { _ in true })
        #expect(scan.available)
        #expect(scan.sessions.map(\.host) == [.terminal])
    }
}

@Test func claudeDesktopIndexJoinsTheHookSessionToItsDesktopID() throws {
    let index = ClaudeDesktopSessionIndex.decode([try sessionFile(local: desktopLocal, hook: desktopHook.uppercased())])
    #expect(index.localID(for: desktopHook) == desktopLocal)
    #expect(index.localID(for: desktopHook.uppercased()) == desktopLocal)
    #expect(index.localID(for: terminalHook) == nil)
}

@Test func claudeDesktopIndexSkipsFilesThatNameNoExactSession() throws {
    let files = [Data("not json".utf8),
                 try sessionFile(local: nil, hook: desktopHook),
                 try sessionFile(local: desktopLocal, hook: nil),
                 try sessionFile(local: desktopLocal, hook: "not-a-uuid"),
                 try sessionFile(local: "remote_abc", hook: desktopHook),
                 try sessionFile(local: "local_", hook: desktopHook),
                 try sessionFile(local: "local_a/b", hook: desktopHook),
                 try sessionFile(local: "local_" + String(repeating: "a", count: 65), hook: desktopHook),
                 try sessionFile(local: 12, hook: desktopHook)]
    #expect(ClaudeDesktopSessionIndex.decode(files).localIDs.isEmpty)
}

@Test func claudeDesktopIndexLeavesOutAHookSessionTwoDesktopIDsClaim() throws {
    let other = "local_aaaaaaaa-1434-4035-9547-ecd4d906bf8f"
    let index = ClaudeDesktopSessionIndex.decode([try sessionFile(local: desktopLocal, hook: desktopHook),
                                                  try sessionFile(local: other, hook: desktopHook),
                                                  try sessionFile(local: desktopLocal, hook: terminalHook),
                                                  try sessionFile(local: desktopLocal, hook: terminalHook)])
    #expect(index.localID(for: desktopHook) == nil)
    // The same pair written twice is still one exact id.
    #expect(index.localID(for: terminalHook) == desktopLocal)
}

@Test func claudeDesktopIndexReadsTheTwoLevelLayoutWithoutFollowingSymlinks() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-desktop-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let organization = support.appendingPathComponent("claude-code-sessions/account/org", isDirectory: true)
    try FileManager.default.createDirectory(at: organization, withIntermediateDirectories: true)
    try sessionFile(local: desktopLocal, hook: desktopHook).write(to: organization.appendingPathComponent(desktopLocal + ".json"))
    try Data("{}".utf8).write(to: organization.appendingPathComponent("scheduled-tasks.json"))
    // A symlinked account folder is never read.
    let outside = support.appendingPathComponent("outside/org", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try sessionFile(local: "local_bbbb", hook: terminalHook).write(to: outside.appendingPathComponent("local_bbbb.json"))
    try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("claude-code-sessions/linked"),
                                               withDestinationURL: support.appendingPathComponent("outside"))

    let index = try #require(ClaudeDesktopSessionIndex.read(applicationSupport: support))
    #expect(index.localIDs == [desktopHook: desktopLocal])
    #expect(ClaudeDesktopSessionIndex.lastFocusedAt(localID: desktopLocal, applicationSupport: support) == 1_795_504_100.366)
    #expect(ClaudeDesktopSessionIndex.lastFocusedAt(localID: "local_bbbb", applicationSupport: support) == nil)
    #expect(ClaudeDesktopSessionIndex.lastFocusedAt(localID: "../x", applicationSupport: support) == nil)
    #expect(ClaudeDesktopSessionIndex.read(applicationSupport: support.appendingPathComponent("missing")) == nil)
}

@Test func claudeDesktopLastFocusedAtReadsOnlyAPositiveNumber() throws {
    #expect(ClaudeDesktopSessionIndex.lastFocusedAt(try sessionFile(local: desktopLocal, hook: desktopHook, focusedAt: 2000)) == 2)
    for value: Any? in [nil, true, "1795504100366", 0, -5] {
        #expect(ClaudeDesktopSessionIndex.lastFocusedAt(try sessionFile(local: desktopLocal, hook: desktopHook, focusedAt: value)) == nil)
    }
}

@Test func claudeDesktopContinueLinkNamesTheExactSession() {
    #expect(ClaudeDesktopOpen.continueURL(localID: desktopLocal)?.absoluteString
            == "claude://code/continue?session=\(desktopLocal)")
    #expect(ClaudeDesktopOpen.continueURL(localID: "local_a&session=last") == nil)
    #expect(ClaudeDesktopOpen.continueURL(localID: "last") == nil)
}

@Test func claudeDesktopOpenPlanRequiresOneLiveDesktopHolder() {
    func plan(complete: Bool = true, holders: Int = 1, desktop: Bool = true, anywhere: Bool = true,
              local: String? = desktopLocal, running: Bool = true) -> ClaudeDesktopOpen.Plan {
        ClaudeDesktopOpen.plan(complete: complete, holders: holders, desktopHolder: desktop, listedAnywhere: anywhere,
                               localID: local, claudeRunning: running)
    }
    #expect(plan() == .exact(ClaudeDesktopOpen.continueURL(localID: desktopLocal)!))
    #expect(plan(complete: false) == .unavailable(.appNotIdentified))
    #expect(plan(holders: 0, anywhere: false) == .unavailable(.sessionEnded))
    #expect(plan(holders: 0, anywhere: true) == .unavailable(.appNotIdentified))
    #expect(plan(holders: 2) == .unavailable(.appNotIdentified))
    #expect(plan(desktop: false) == .unavailable(.appNotIdentified))
    #expect(plan(running: false) == .unavailable(.claudeDesktopNotRunning))
    // Without an exact id Open only raises Claude Desktop.
    #expect(plan(local: nil) == .raise)
    #expect(plan(local: "local_bad/id") == .raise)
}

@Test func claudeDesktopOpenVerifiesOnlyFocusRecordedAfterTheClick() {
    #expect(ClaudeDesktopOpen.verified(lastFocusedAt: 100.2, clickedAt: 100))
    #expect(ClaudeDesktopOpen.verified(lastFocusedAt: 99.97, clickedAt: 100))
    #expect(!ClaudeDesktopOpen.verified(lastFocusedAt: 99, clickedAt: 100))
    #expect(!ClaudeDesktopOpen.verified(lastFocusedAt: nil, clickedAt: 100))
}

@Test func claudeDesktopOpenResultsHandBackAndShowTheAgreedLines() {
    #expect(ClaudeDesktopOpen.Result.opened.handsBackRequest)
    #expect(ClaudeDesktopOpen.Result.opened.cardLine == nil)
    #expect(ClaudeDesktopOpen.Result.raised.handsBackRequest)
    #expect(ClaudeDesktopOpen.Result.raised.cardLine?.cardLine
            == "Herdly couldn't find this session in Claude Desktop, so it brought Claude Desktop forward.")
    let unavailable = ClaudeDesktopOpen.Result.unavailable(.claudeDesktopNotRunning)
    #expect(!unavailable.handsBackRequest)
    #expect(unavailable.cardLine?.cardLine == "Claude Desktop isn't running.")
    #expect(ClaudeDesktopPresentation.place == "Claude Desktop")
}

@Test func claudeDesktopOpenWaitsLongerThanClaudeDesktopTakesToRecordFocus() {
    // Live, 2026-11-24: Claude Desktop wrote `lastFocusedAt` 1.34 s after the link with nothing else
    // running, and a 2 s wait reported a reached session as not found. Keep a wide margin.
    #expect(ClaudeDesktopOpen.verificationTimeout >= 4)
}

// Live, 2026-11-24: an Open clicked while Claude Desktop already showed the session wrote no new
// `lastFocusedAt`, so a reached session showed the fallback note.
@Test func claudeDesktopOpenCountsASessionAlreadyShownAsReached() throws {
    let otherLocal = "local_2a2a2a2a-1434-4035-9547-ecd4d906bf8f"
    let index = ClaudeDesktopSessionIndex.decode([try sessionFile(local: desktopLocal, hook: desktopHook, focusedAt: 3000),
                                                  try sessionFile(local: otherLocal, hook: terminalHook, focusedAt: 2000)])
    #expect(index.frontLocalID == desktopLocal)
    #expect(ClaudeDesktopOpen.alreadyShowing(localID: desktopLocal, claudeFrontmost: true, index: index))
    // Another app in front, another session in front, a tie, or no readable index: not already shown.
    #expect(!ClaudeDesktopOpen.alreadyShowing(localID: desktopLocal, claudeFrontmost: false, index: index))
    #expect(!ClaudeDesktopOpen.alreadyShowing(localID: otherLocal, claudeFrontmost: true, index: index))
    let tie = ClaudeDesktopSessionIndex.decode([try sessionFile(local: desktopLocal, hook: desktopHook, focusedAt: 3000),
                                                try sessionFile(local: otherLocal, hook: terminalHook, focusedAt: 3000)])
    #expect(!ClaudeDesktopOpen.alreadyShowing(localID: desktopLocal, claudeFrontmost: true, index: tie))
    #expect(!ClaudeDesktopOpen.alreadyShowing(localID: desktopLocal, claudeFrontmost: true, index: nil))
}

// #474: results acknowledge by ADR 0016's rules, with "visible" from `lastFocusedAt` and frontmost.

private let otherLocal = "local_2a2a2a2a-1434-4035-9547-ecd4d906bf8f"

@Test func claudeDesktopFrontSessionIsTheStrictlyLatestFocus() throws {
    let later = ClaudeDesktopSessionIndex.decode([try sessionFile(local: desktopLocal, hook: desktopHook, focusedAt: 2000),
                                                  try sessionFile(local: otherLocal, hook: terminalHook, focusedAt: 3000)])
    #expect(later.frontLocalID == otherLocal)
    let tie = ClaudeDesktopSessionIndex.decode([try sessionFile(local: desktopLocal, hook: desktopHook, focusedAt: 3000),
                                                try sessionFile(local: otherLocal, hook: terminalHook, focusedAt: 3000)])
    #expect(tie.frontLocalID == nil)
    // A file with no focus, or no valid ids, never becomes the front session.
    let unfocused = ClaudeDesktopSessionIndex.decode([try sessionFile(local: desktopLocal, hook: desktopHook, focusedAt: nil),
                                                      try sessionFile(local: "bad", hook: terminalHook, focusedAt: 9000)])
    #expect(unfocused.frontLocalID == nil)
}

@Test func claudeDesktopReadsVisibleOnlyWhileFrontmostWithAKnownFrontSession() {
    let index = ClaudeDesktopSessionIndex(localIDs: [desktopHook: desktopLocal], frontLocalID: desktopLocal)
    #expect(ClaudeDesktopVisibility.reading(frontmost: true, index: index) == .visible(desktopLocal))
    #expect(ClaudeDesktopVisibility.reading(frontmost: false, index: index) == .nothing)
    #expect(ClaudeDesktopVisibility.reading(frontmost: true, index: nil) == .unknown)
    #expect(ClaudeDesktopVisibility.reading(frontmost: true, index: ClaudeDesktopSessionIndex(localIDs: [:])) == .unknown)
}

@Test func claudeDesktopVisitAndDwellAcknowledgeOnlyTheFrontSession() {
    let mine = [TerminalCompletionCandidate(id: "early", arrivedAt: 99), TerminalCompletionCandidate(id: "during", arrivedAt: 101.5)]
    var tracker = TerminalVisitTracker<String>()
    tracker.record(.init(takenAt: 100, reading: .nothing))
    tracker.record(.init(takenAt: 102, reading: ClaudeDesktopVisibility.reading(
        frontmost: true, index: .init(localIDs: [:], frontLocalID: desktopLocal))))
    // The switch to the session acknowledges what arrived before the earlier scan, not during it.
    #expect(tracker.acknowledged(mine, target: desktopLocal) == ["early"])
    #expect(tracker.acknowledged(mine, target: otherLocal).isEmpty)
    #expect(tracker.acknowledged(mine, target: nil).isEmpty)

    // Dwell: a result arriving while the session is in front clears after five more seconds in front.
    let arriving = [TerminalCompletionCandidate(id: "dwell", arrivedAt: 103)]
    tracker.record(.init(takenAt: 104, reading: .visible(desktopLocal)))
    tracker.record(.init(takenAt: 106, reading: .visible(desktopLocal)))
    #expect(tracker.acknowledged(arriving, target: desktopLocal).isEmpty)
    tracker.record(.init(takenAt: 108, reading: .visible(desktopLocal)))
    #expect(tracker.acknowledged(arriving, target: desktopLocal) == ["dwell"])

    // An unreadable read restarts the run and proves no visit.
    var broken = TerminalVisitTracker<String>()
    broken.record(.init(takenAt: 102, reading: .visible(desktopLocal)))
    broken.record(.init(takenAt: 104, reading: .unknown))
    broken.record(.init(takenAt: 106, reading: .visible(desktopLocal)))
    broken.record(.init(takenAt: 108, reading: .visible(desktopLocal)))
    #expect(broken.acknowledged(arriving, target: desktopLocal).isEmpty)

    // Another session in front, then a switch back, is a visit.
    var switched = TerminalVisitTracker<String>()
    switched.record(.init(takenAt: 104, reading: .visible(otherLocal)))
    #expect(switched.acknowledged(arriving, target: desktopLocal).isEmpty)
    switched.record(.init(takenAt: 106, reading: .visible(desktopLocal)))
    #expect(switched.acknowledged(arriving, target: desktopLocal) == ["dwell"])

    // An Open resets the tracker: a scan started before it counts for nothing.
    var opened = TerminalVisitTracker<String>()
    opened.record(.init(takenAt: 100, reading: .nothing))
    opened.reset(at: 101)
    opened.record(.init(takenAt: 100.5, reading: .visible(desktopLocal)))
    #expect(opened.acknowledged(mine, target: desktopLocal).isEmpty)
}

@Test func claudeDesktopOnlyAVerifiedOpenAcknowledgesAndOnlyEarlierResults() {
    let results = [TerminalCompletionCandidate(id: "before", arrivedAt: 99.9),
                   TerminalCompletionCandidate(id: "at", arrivedAt: 100),
                   TerminalCompletionCandidate(id: "after", arrivedAt: 101)]
    #expect(ClaudeDesktopVisibility.afterOpen(results, result: .opened, clickedAt: 100) == ["before"])
    #expect(ClaudeDesktopVisibility.afterOpen(results, result: .raised, clickedAt: 100).isEmpty)
    #expect(ClaudeDesktopVisibility.afterOpen(results, result: .unavailable(.claudeDesktopNotRunning), clickedAt: 100).isEmpty)
    #expect(ClaudeDesktopVisibility.afterOpen(results, result: .opened, clickedAt: .nan).isEmpty)
}

// #474 follow-up: the visit check reads every two seconds while Claude Desktop is frontmost, so it
// re-parses only files Claude Desktop changed.
@Test func claudeDesktopCachedReadFollowsChangedFilesAndForgetsRemovedOnes() throws {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-desktop-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let organization = support.appendingPathComponent("claude-code-sessions/account/org", isDirectory: true)
    try FileManager.default.createDirectory(at: organization, withIntermediateDirectories: true)
    let otherLocal = "local_2a2a2a2a-1434-4035-9547-ecd4d906bf8f"
    let mine = organization.appendingPathComponent(desktopLocal + ".json")
    let other = organization.appendingPathComponent(otherLocal + ".json")
    try sessionFile(local: desktopLocal, hook: desktopHook, focusedAt: 3000).write(to: mine)
    try sessionFile(local: otherLocal, hook: terminalHook, focusedAt: 2000).write(to: other)

    var cache = ClaudeDesktopSessionFileCache()
    #expect(ClaudeDesktopSessionIndex.read(applicationSupport: support, cache: &cache)?.frontLocalID == desktopLocal)
    #expect(cache.count == 2)
    // Unchanged files give the same answer from the cache.
    #expect(ClaudeDesktopSessionIndex.read(applicationSupport: support, cache: &cache)?.frontLocalID == desktopLocal)

    // Claude Desktop focuses the other session: its file changes and is parsed again.
    try sessionFile(local: otherLocal, hook: terminalHook, focusedAt: 4000).write(to: other)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: other.path)
    #expect(ClaudeDesktopSessionIndex.read(applicationSupport: support, cache: &cache)?.frontLocalID == otherLocal)

    // A removed file leaves the cache and the index.
    try FileManager.default.removeItem(at: other)
    let index = ClaudeDesktopSessionIndex.read(applicationSupport: support, cache: &cache)
    #expect(index?.frontLocalID == desktopLocal)
    #expect(index?.localID(for: terminalHook) == nil)
    #expect(cache.count == 1)
}
