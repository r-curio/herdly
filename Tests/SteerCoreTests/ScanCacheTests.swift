import Foundation
import Testing
@testable import SteerCore

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-scan-cache-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Rewrites `url` in place (same inode) with `text` of the same length and restores its modification time,
/// so only a reader that reuses its cache can still see the old contents.
private func overwriteKeepingStamp(_ url: URL, with text: String) throws {
    var info = stat()
    #expect(stat(url.path, &info) == 0)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
    // Restored to the nanosecond: `Date` would round it, and the stamp would differ.
    var times = [info.st_atimespec, info.st_mtimespec]
    #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
    #expect(FileStamp(url, followingLinks: true) != nil)
}

@Test func anUnchangedRolloutIsReusedAndAChangedOneIsReread() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID()
    let start: [String: String] = ["session_id": session.uuidString, "hook_event_name": "SessionStart",
                                   "received_at": "2026-01-01T00:00:00Z"]
    try JSONSerialization.data(withJSONObject: start).write(to: root.appendingPathComponent("start.json"))
    let rollout = root.appendingPathComponent("rollout-" + session.uuidString.lowercased() + ".jsonl")
    let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"cli\"}}\n"
    let done = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turn)\"}}\n"
    try Data(meta.utf8).write(to: rollout)

    let first = ReminderReader.scan(events: root, rollouts: root)
    #expect(first.cliSessions == [session])
    #expect(first.completed.isEmpty)
    #expect(first.rolloutCache.count == 1)

    // Same stamp: the cached read stands even though the bytes on disk are now unreadable.
    try overwriteKeepingStamp(rollout, with: String(repeating: "x", count: meta.utf8.count - 1) + "\n")
    let reused = ReminderReader.scan(events: root, rollouts: root, rolloutCache: first.rolloutCache)
    #expect(reused.cliSessions == [session])
    #expect(reused.rolloutCache.count == 1)
    // Without the cache the same bytes fail closed.
    #expect(ReminderReader.scan(events: root, rollouts: root).cliSessions.isEmpty)

    // An append changes the stamp, so the next scan rereads and sees the ended turn.
    try Data((meta + done).utf8).write(to: rollout)
    let changed = ReminderReader.scan(events: root, rollouts: root, rolloutCache: reused.rolloutCache)
    #expect(changed.cliSessions == [session])
    #expect(changed.completed == [TurnIdentity(session: session, turn: turn)])

    // A rollout no longer read is not carried forward.
    try FileManager.default.removeItem(at: rollout)
    let gone = ReminderReader.scan(events: root, rollouts: root, rolloutCache: changed.rolloutCache)
    #expect(gone.cliSessions.isEmpty)
    #expect(gone.rolloutCache.count == 0)
}

@Test func aRolloutWithAnApprovalProbeIsAlwaysReadFresh() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID()
    let request = ApprovalRequest(requestID: UUID(), sessionID: session, turnID: turn,
                                  details: ApprovalDetails(command: "touch MARKER"),
                                  receivedAt: Date().timeIntervalSince1970, outcome: .noDecision)
    #expect(ApprovalStore.publish(request, in: root))
    let rollout = root.appendingPathComponent("rollout-" + session.uuidString.lowercased() + ".jsonl")
    let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\"}}\n"
    // Same length as `done`, so the rewrite below keeps the file's size.
    let filler = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"other_event00\",\"turn_id\":\"\(turn)\"}}\n"
    let done = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turn)\"}}\n"
    try Data((meta + filler).utf8).write(to: rollout)
    let first = ReminderReader.scan(events: root, rollouts: root)
    #expect(first.attentionRequests.map(\.id) == [request.id])
    #expect(first.completed.isEmpty)

    // The stamp is unchanged, but a session holding a request is read fresh every scan, because
    // only its current bytes can say the request resolved.
    try overwriteKeepingStamp(rollout, with: meta + done)
    let next = ReminderReader.scan(events: root, rollouts: root, rolloutCache: first.rolloutCache)
    #expect(next.completed == [TurnIdentity(session: session, turn: turn)])
}

private func writeClaudeRecord(_ record: [String: Any], named name: String, in root: URL,
                               installationID: String = "install") throws {
    var record = record
    record["source"] = ClaudeSetupRequirements.helperSource
    record["installation_id"] = installationID
    try JSONSerialization.data(withJSONObject: record).write(to: root.appendingPathComponent(name), options: .atomic)
}

private func runningPrompts(_ scan: ClaudeObservationScan) -> [String: String] {
    Dictionary(uniqueKeysWithValues: scan.observations.compactMap { observation -> (String, String)? in
        guard case let .running(value) = observation else { return nil }
        return (value.identity.session.session, value.prompt ?? "")
    })
}

@Test func claudeRecordsAreReusedUntilTheirFileChanges() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "a", "captured_at": 1,
                           "prompt_id": "p1", "prompt": "First"], named: "a.json", in: root)
    let first = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                             now: 10, cache: ClaudeRecordCache())
    #expect(runningPrompts(first.scan) == ["a": "First"])
    #expect(first.cache.count == 1)

    // Same stamp: the cached record stands, as the one-time atomic writes guarantee in use.
    let path = root.appendingPathComponent("a.json")
    let size = try #require(try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int)
    try overwriteKeepingStamp(path, with: String(repeating: " ", count: size))
    let reused = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                              now: 10, cache: first.cache)
    #expect(reused.scan == first.scan)

    // A new record is read; a replaced one (new inode) is reread.
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "b", "captured_at": 2,
                           "prompt_id": "p1", "prompt": "Second"], named: "b.json", in: root)
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "a", "captured_at": 1,
                           "prompt_id": "p1", "prompt": "Changed"], named: "a.json", in: root)
    let changed = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                               now: 10, cache: reused.cache)
    #expect(runningPrompts(changed.scan) == ["a": "Changed", "b": "Second"])
    #expect(changed.scan == ClaudeObservationReader.scan(events: root, sourceScope: root.path,
                                                         installationID: "install", now: 10))

    // A deleted record leaves the cache.
    try FileManager.default.removeItem(at: root.appendingPathComponent("b.json"))
    let pruned = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                              now: 10, cache: changed.cache)
    #expect(runningPrompts(pruned.scan) == ["a": "Changed"])
    #expect(pruned.cache.count == 1)
}

@Test func claudeRecordCacheResetsForAnotherInstallationAndNeverFollowsLinks() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "a", "captured_at": 1,
                           "prompt_id": "p1", "prompt": "Mine"], named: "a.json", in: root)
    let mine = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                            now: 10, cache: ClaudeRecordCache())
    #expect(runningPrompts(mine.scan) == ["a": "Mine"])
    // Another installation's scan does not reuse records accepted for this one.
    let other = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "other",
                                             now: 10, cache: mine.cache)
    #expect(other.scan.observations.isEmpty)

    // A link to a valid record is not a record, cached or not.
    let outside = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: outside) }
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "b", "captured_at": 2,
                           "prompt_id": "p1", "prompt": "Linked"], named: "b.json", in: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("b.json"),
                                               withDestinationURL: outside.appendingPathComponent("b.json"))
    let linked = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                              now: 10, cache: mine.cache)
    #expect(runningPrompts(linked.scan) == ["a": "Mine"])
}

@Test func codexHookRecordsAreSharedBetweenReadersAndReusedUntilTheyChange() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = UUID(), turn = UUID()
    func write(_ event: String, at time: String, named name: String) throws {
        let record: [String: String] = ["session_id": session.uuidString, "turn_id": turn.uuidString,
                                        "hook_event_name": event, "received_at": time]
        try JSONSerialization.data(withJSONObject: record).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    try write("SessionStart", at: "2026-01-01T00:00:00Z", named: "start.json")
    try write("UserPromptSubmit", at: "2026-01-01T00:00:01Z", named: "prompt.json")

    let first = ReminderReader.scan(events: root, rollouts: root)
    #expect(first.hookCache.count == 2)
    let desktop = DesktopEventReader.read(from: root, cache: first.hookCache)
    #expect(desktop.events == DesktopEventReader.read(from: root))
    #expect(desktop.events.count == 2)

    // Same stamp: the cached bytes stand for both readers, even though the file on disk changed.
    let start = root.appendingPathComponent("start.json")
    let size = try #require(try FileManager.default.attributesOfItem(atPath: start.path)[.size] as? Int)
    try overwriteKeepingStamp(start, with: String(repeating: " ", count: size))
    let cache = first.hookCache.merging(desktop.cache)
    #expect(DesktopEventReader.read(from: root, cache: cache).events.count == 2)
    #expect(DesktopEventReader.read(from: root).count == 1)

    // A new or replaced record is read; a deleted one leaves the cache.
    try write("Stop", at: "2026-01-01T00:00:02Z", named: "stop.json")
    try write("SessionStart", at: "2026-01-01T00:00:00Z", named: "start.json")
    try FileManager.default.removeItem(at: root.appendingPathComponent("prompt.json"))
    let next = ReminderReader.scan(events: root, rollouts: root, hookCache: cache)
    let replay = DesktopEventReader.read(from: root, cache: next.hookCache)
    #expect(replay.events == DesktopEventReader.read(from: root))
    #expect(replay.events.count == 2)
    #expect(next.hookCache.merging(replay.cache).count == 2)
}
