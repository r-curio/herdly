import Foundation
import Testing
@testable import HerdlyCore

private let derived = ClaudeSessionTitles.RegisteredName(name: "landbase-22", source: "derived")

private func temporaryEventsDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-titles-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func claudeSessionTitleSourceSkipsPromptsThatSayNothingAboutTheWork() {
    #expect(ClaudeSessionTitles.titleSource(nil) == nil)
    #expect(ClaudeSessionTitles.titleSource("  \n ") == nil)
    #expect(ClaudeSessionTitles.titleSource("<task-notification>\n<task-id>b2</task-id>") == nil)
    #expect(ClaudeSessionTitles.titleSource("<command-name>/clear</command-name>") == nil)
    #expect(ClaudeSessionTitles.titleSource("/clear") == nil)
    #expect(ClaudeSessionTitles.titleSource("/compact   ") == nil)
    #expect(ClaudeSessionTitles.titleSource("/ship-batch lan-1918 to lan-1920") == "/ship-batch lan-1918 to lan-1920")
    #expect(ClaudeSessionTitles.titleSource("  fix the login redirect\n") == "fix the login redirect")
    let long = String(repeating: "a", count: ClaudeSessionTitles.maximumSourceLength + 50)
    #expect(ClaudeSessionTitles.titleSource(long)?.count == ClaudeSessionTitles.maximumSourceLength)
}

@Test func claudeSessionTitleRegistryNameMustBelongToTheExactSession() {
    let entry = Data(#"{"pid":1,"sessionId":"session-a","name":"landbase-22","nameSource":"derived"}"#.utf8)
    #expect(ClaudeSessionTitles.registeredName(entry, sessionID: "session-a") == derived)
    #expect(ClaudeSessionTitles.registeredName(entry, sessionID: "session-b") == nil)
    #expect(ClaudeSessionTitles.registeredName(Data("{".utf8), sessionID: "session-a") == nil)
    let unnamed = Data(#"{"sessionId":"session-a","name":""}"#.utf8)
    #expect(ClaudeSessionTitles.registeredName(unnamed, sessionID: "session-a") == nil)
    let auto = Data(#"{"sessionId":"session-a","name":"rooms-redesign","nameSource":"auto"}"#.utf8)
    #expect(ClaudeSessionTitles.registeredName(auto, sessionID: "session-a")?.isDerived == false)
}

@Test func claudeSessionTitleActsOnlyOnADerivedPlaceholder() {
    let prompt = "migrate the sheet into the scheduler"
    for name in [nil, ClaudeSessionTitles.RegisteredName(name: "mine", source: "user"),
                 ClaudeSessionTitles.RegisteredName(name: "ai", source: "auto"),
                 ClaudeSessionTitles.RegisteredName(name: "probe", source: "hook"),
                 ClaudeSessionTitles.RegisteredName(name: "unknown", source: nil)] {
        #expect(ClaudeSessionTitles.action(prompt: prompt, registered: name, record: nil, now: 10) == .none)
        let ready = ClaudeSessionTitles.Record(status: .ready, title: "migrate-sheet", attempts: 1, updatedAt: 5)
        #expect(ClaudeSessionTitles.action(prompt: prompt, registered: name, record: ready, now: 10) == .none)
    }
    #expect(ClaudeSessionTitles.action(prompt: prompt, registered: derived, record: nil, now: 10) == .generate(source: prompt))
    #expect(ClaudeSessionTitles.action(prompt: "/clear", registered: derived, record: nil, now: 10) == .none)
}

@Test func claudeSessionTitleAppliesAReadyTitleOnceOnAnyLaterPrompt() {
    let ready = ClaudeSessionTitles.Record(status: .ready, title: "migrate-sheet", attempts: 1, updatedAt: 5)
    #expect(ClaudeSessionTitles.action(prompt: "<task-notification>", registered: derived, record: ready, now: 10)
        == .apply(title: "migrate-sheet"))
    let applied = ClaudeSessionTitles.Record(status: .applied, title: "migrate-sheet", attempts: 1, updatedAt: 10)
    #expect(ClaudeSessionTitles.action(prompt: "keep going", registered: derived, record: applied, now: 20) == .none)
    let unusable = ClaudeSessionTitles.Record(status: .ready, title: "!!!", attempts: 1, updatedAt: 5)
    #expect(ClaudeSessionTitles.action(prompt: "keep going", registered: derived, record: unusable, now: 10)
        == .generate(source: "keep going"))
}

@Test func claudeSessionTitleRetriesFailedOrAbandonedGenerationWithinTheAttemptBound() {
    let lifetime = ClaudeSessionTitles.pendingLifetime
    let pending = ClaudeSessionTitles.Record(status: .pending, attempts: 1, updatedAt: 100)
    #expect(ClaudeSessionTitles.action(prompt: "next", registered: derived, record: pending, now: 100 + lifetime - 1) == .none)
    #expect(ClaudeSessionTitles.action(prompt: "next", registered: derived, record: pending, now: 100 + lifetime)
        == .generate(source: "next"))
    let failed = ClaudeSessionTitles.Record(status: .failed, attempts: 1, updatedAt: 100)
    #expect(ClaudeSessionTitles.action(prompt: "next", registered: derived, record: failed, now: 101) == .generate(source: "next"))
    #expect(ClaudeSessionTitles.action(prompt: "/clear", registered: derived, record: failed, now: 101) == .none)
    let exhausted = ClaudeSessionTitles.Record(status: .failed, attempts: ClaudeSessionTitles.maximumAttempts, updatedAt: 100)
    #expect(ClaudeSessionTitles.action(prompt: "next", registered: derived, record: exhausted, now: 101) == .none)
}

@Test func claudeSessionTitleSanitizesTheModelReplyIntoKebabCase() {
    #expect(ClaudeSessionTitles.sanitizedTitle("migrate-sheet-to-scheduler\n") == "migrate-sheet-to-scheduler")
    #expect(ClaudeSessionTitles.sanitizedTitle("\n  \"Fix Login Redirect!\"  \nextra") == "fix-login-redirect")
    #expect(ClaudeSessionTitles.sanitizedTitle("`ship_batch: LAN-1918`") == "ship-batch-lan-1918")
    #expect(ClaudeSessionTitles.sanitizedTitle("") == nil)
    #expect(ClaudeSessionTitles.sanitizedTitle("1918 2020") == nil)
    #expect(ClaudeSessionTitles.sanitizedTitle("Café déjà vu") == "caf-d-j-vu")
    let long = ClaudeSessionTitles.sanitizedTitle(Array(repeating: "word", count: 30).joined(separator: " "))
    #expect(long.map { $0.count <= ClaudeSessionTitles.maximumTitleLength && !$0.hasSuffix("-") } == true)
}

@Test func claudeSessionTitleHookOutputSetsTheTitleForUserPromptSubmit() throws {
    let data = try #require(ClaudeSessionTitles.hookOutput(title: "migrate-sheet"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let output = try #require(object["hookSpecificOutput"] as? [String: String])
    #expect(output == ["hookEventName": "UserPromptSubmit", "sessionTitle": "migrate-sheet"])
}

@Test func claudeSessionTitleGenerationIsIsolatedFromTheParentSession() {
    let environment = ["PATH": "/bin", "HOME": "/home", "CLAUDE_CODE_CHILD_SESSION": "1",
                       "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/s", "CLAUDE_CODE_MESSAGING_TOKEN": "secret",
                       "CLAUDE_CODE_SESSION_ID": "s", "CLAUDE_PID": "1", "CLAUDE_PROJECT_DIR": "/p"]
    #expect(ClaudeSessionTitles.generationEnvironment(environment)
        == ["PATH": "/bin", "HOME": "/home", "CLAUDE_CODE_CHILD_SESSION": "1"])
    let arguments = ClaudeSessionTitles.generationArguments
    #expect(arguments.contains("--no-session-persistence"))
    #expect(arguments.contains(#"{"disableAllHooks":true}"#))
    #expect(zip(arguments, arguments.dropFirst()).contains { $0 == "--tools" && $1.isEmpty })
    #expect(zip(arguments, arguments.dropFirst()).contains { $0 == "--setting-sources" && $1.isEmpty })
    #expect(ClaudeSessionTitles.generationInput(source: "fix the redirect").contains("<request>\nfix the redirect\n</request>"))
}

@Test func claudeSessionTitleOptInAndRecordsLiveBelowTheEventsDirectory() throws {
    let events = try temporaryEventsDirectory()
    defer { try? FileManager.default.removeItem(at: events) }
    #expect(!ClaudeSessionTitles.isEnabled(eventsDirectory: events))
    #expect(ClaudeSessionTitles.setEnabled(true, eventsDirectory: events))
    #expect(ClaudeSessionTitles.isEnabled(eventsDirectory: events))
    #expect(ClaudeSessionTitles.setEnabled(false, eventsDirectory: events))
    #expect(!ClaudeSessionTitles.isEnabled(eventsDirectory: events))
    #expect(ClaudeSessionTitles.setEnabled(false, eventsDirectory: events))

    let record = ClaudeSessionTitles.Record(status: .ready, title: "migrate-sheet", attempts: 1, updatedAt: 5)
    #expect(ClaudeSessionTitles.save(record, sessionID: "a7565d0f-1442", in: events))
    #expect(ClaudeSessionTitles.load(sessionID: "a7565d0f-1442", in: events) == record)
    #expect(ClaudeSessionTitles.load(sessionID: "other", in: events) == nil)
    #expect(!ClaudeSessionTitles.save(record, sessionID: "../escape", in: events))
    #expect(ClaudeSessionTitles.load(sessionID: "../escape", in: events) == nil)
    // Hook-event retention only lists the top level, so these files never look like events.
    let topLevel = try FileManager.default.contentsOfDirectory(atPath: events.path)
    #expect(topLevel == [ClaudeSessionTitles.directoryName])
}

@Test func claudeSessionTitlePruneRemovesOldRecordsButKeepsTheOptIn() throws {
    let events = try temporaryEventsDirectory()
    defer { try? FileManager.default.removeItem(at: events) }
    #expect(ClaudeSessionTitles.setEnabled(true, eventsDirectory: events))
    let record = ClaudeSessionTitles.Record(status: .applied, title: "old", attempts: 1, updatedAt: 0)
    #expect(ClaudeSessionTitles.save(record, sessionID: "old", in: events))
    #expect(ClaudeSessionTitles.save(record, sessionID: "fresh", in: events))
    ClaudeSessionTitles.prune(in: events, now: Date().addingTimeInterval(ClaudeSessionTitles.recordAge - 60))
    #expect(ClaudeSessionTitles.load(sessionID: "old", in: events) != nil)
    ClaudeSessionTitles.prune(in: events, now: Date().addingTimeInterval(ClaudeSessionTitles.recordAge + 60))
    #expect(ClaudeSessionTitles.load(sessionID: "old", in: events) == nil)
    #expect(ClaudeSessionTitles.load(sessionID: "fresh", in: events) == nil)
    #expect(ClaudeSessionTitles.isEnabled(eventsDirectory: events))
}

@Test func claudeSessionTitleReplacesAHerdlyTitleThatClearCarriedOver() throws {
    let events = try temporaryEventsDirectory()
    defer { try? FileManager.default.removeItem(at: events) }
    let applied = ClaudeSessionTitles.Record(status: .applied, title: "ghostty-toggle-reverts", attempts: 1, updatedAt: 5)
    #expect(ClaudeSessionTitles.save(applied, sessionID: "before-clear", in: events))
    let carried = ClaudeSessionTitles.RegisteredName(name: "ghostty-toggle-reverts", source: "hook")

    #expect(ClaudeSessionTitles.isCarriedOver(carried, sessionID: "after-clear", in: events))
    // The session that earned the title, a user's name, and an unrelated hook name are not carry-overs.
    #expect(!ClaudeSessionTitles.isCarriedOver(carried, sessionID: "before-clear", in: events))
    #expect(!ClaudeSessionTitles.isCarriedOver(ClaudeSessionTitles.RegisteredName(name: "ghostty-toggle-reverts", source: "user"),
                                               sessionID: "after-clear", in: events))
    #expect(!ClaudeSessionTitles.isCarriedOver(ClaudeSessionTitles.RegisteredName(name: "probe", source: "hook"), sessionID: "after-clear", in: events))
    #expect(!ClaudeSessionTitles.isCarriedOver(nil, sessionID: "after-clear", in: events))

    let prompt = "fix the notch title after clear"
    #expect(ClaudeSessionTitles.action(prompt: prompt, registered: carried, record: nil, now: 10, carriedOver: true)
        == .generate(source: prompt))
    let ready = ClaudeSessionTitles.Record(status: .ready, title: "notch-title-after-clear", attempts: 1, updatedAt: 12)
    #expect(ClaudeSessionTitles.action(prompt: "keep going", registered: carried, record: ready, now: 20, carriedOver: true)
        == .apply(title: "notch-title-after-clear"))
    #expect(ClaudeSessionTitles.action(prompt: prompt, registered: nil, record: nil, now: 10, carriedOver: true) == .none)
}

@Test func claudeSessionTitleIgnoresUnreadableRecordsWhenCheckingCarryOver() throws {
    let events = try temporaryEventsDirectory()
    defer { try? FileManager.default.removeItem(at: events) }
    let folder = ClaudeSessionTitles.directory(in: events)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: folder.appendingPathComponent("torn.json"))
    let pending = ClaudeSessionTitles.Record(status: .ready, title: "ghostty-toggle-reverts", attempts: 1, updatedAt: 5)
    #expect(ClaudeSessionTitles.save(pending, sessionID: "other", in: events))
    #expect(!ClaudeSessionTitles.isCarriedOver(ClaudeSessionTitles.RegisteredName(name: "ghostty-toggle-reverts", source: "hook"),
                                               sessionID: "after-clear", in: events))
}
