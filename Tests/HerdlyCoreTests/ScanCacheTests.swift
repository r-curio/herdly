import Foundation
import Testing
@testable import HerdlyCore

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-scan-cache-" + UUID().uuidString)
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

@Test func anUnchangedClaudeDirectoryIsNotRecheckedUntilTheLastCheckIsOld() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "a", "captured_at": 1,
                           "prompt_id": "p1", "prompt": "First"], named: "a.json", in: root)
    func scan(now: Double, cache: ClaudeRecordCache) -> (scan: ClaudeObservationScan, cache: ClaudeRecordCache) {
        ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                     now: now, cache: cache)
    }
    let first = scan(now: 100, cache: ClaudeRecordCache())
    #expect(runningPrompts(first.scan) == ["a": "First"])

    // Rewritten in place: the file's stamp changes, the directory's does not.
    let directory = try #require(FileStamp(root, followingLinks: true))
    let path = root.appendingPathComponent("a.json")
    let text = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: "First", with: "Again")
    let handle = try FileHandle(forWritingTo: path)
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
    #expect(FileStamp(root, followingLinks: true) == directory)

    let age = ClaudeObservationReader.maximumUncheckedAge
    let unchecked = scan(now: 100 + age - 1, cache: first.cache)
    #expect(unchecked.scan == first.scan)
    // The bound: once the last full check is that old, every file is checked again.
    let checked = scan(now: 100 + age, cache: unchecked.cache)
    #expect(runningPrompts(checked.scan) == ["a": "Again"])
    // A clock that went back is not trusted either.
    let rewound = scan(now: 50, cache: first.cache)
    #expect(runningPrompts(rewound.scan) == ["a": "Again"])

    // A new record changes the directory's stamp, so it is read on the very next scan.
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "b", "captured_at": 2,
                           "prompt_id": "p1", "prompt": "Second"], named: "b.json", in: root)
    let added = scan(now: 100 + age + 1, cache: checked.cache)
    #expect(runningPrompts(added.scan) == ["a": "Again", "b": "Second"])
}

@Test func aCachedClaudeScanStillAgesItsToolCalls() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "a", "captured_at": 100,
                           "prompt_id": "p1", "prompt": "Build"], named: "a.json", in: root)
    try writeClaudeRecord(["hook_event_name": "PreToolUse", "session_id": "a", "captured_at": 105,
                           "prompt_id": "p1", "tool_name": "Bash", "tool_use_id": "t1",
                           "tool_input": ["command": "swift test"]], named: "b.json", in: root)
    func toolName(_ scan: ClaudeObservationScan) -> String? {
        scan.observations.compactMap { observation -> String? in
            guard case let .running(value) = observation else { return nil }
            return value.toolName
        }.first
    }
    let fresh = ClaudeObservationReader.maximumToolFreshness
    var cache = ClaudeRecordCache()
    // Before the call, while it is fresh, at the boundary, just past it, and long after: the cached
    // scan of the unchanged directory always equals a scan from nothing at the same time.
    for now in [104, 106, 105 + fresh, 105 + fresh + 0.5, 105 + fresh + 1, 105 + fresh + 20] {
        let cached = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                                  now: now, cache: cache)
        #expect(cached.scan == ClaudeObservationReader.scan(events: root, sourceScope: root.path,
                                                            installationID: "install", now: now))
        #expect((toolName(cached.scan) == "Bash") == (now >= 105 && now <= 105 + fresh))
        cache = cached.cache
    }
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

/// A fixed sequence, so a failure repeats.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var value = state
        value ^= value >> 33
        value = value &* 0xff51afd7ed558ccd
        value ^= value >> 33
        return value
    }
}

/// Sessions are built apart and kept between scans. Whatever arrives, leaves or is replaced, in any
/// order and at any time, a scan carrying its cache must equal one from nothing and one that replays
/// every record in a single pass.
@Test(arguments: [1, 2, 3, 4] as [UInt64])
func aScanBuiltSessionBySessionEqualsOneReplayOfEveryRecord(seed: UInt64) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var random = SeededGenerator(state: seed)
    let sessions = ["s1", "s2", "s3", "s4"]
    var prompts: [String: Int] = [:], tools: [String: [String]] = [:], agents: [String: [String]] = [:]
    var files: [String] = []
    var clock = 1_000.0, written = 0, cache = ClaudeRecordCache()

    func record(_ session: String) -> [String: Any] {
        // Mostly forward in time; now and then a record captured before ones already written.
        let at = Int.random(in: 0..<8, using: &random) == 0 ? clock - Double.random(in: 1...40, using: &random) : clock
        var record: [String: Any] = ["session_id": session, "captured_at": at]
        let prompt = "p\(prompts[session] ?? 0)"
        record["prompt_id"] = prompt
        let open = tools[session] ?? [], running = agents[session] ?? []
        switch Int.random(in: 0..<20, using: &random) {
        case 0:
            record["hook_event_name"] = "SessionStart"
        case 1:
            record["hook_event_name"] = "SessionEnd"
        case 2, 3, 4:
            prompts[session, default: 0] += 1
            record["hook_event_name"] = "UserPromptSubmit"
            record["prompt_id"] = "p\(prompts[session] ?? 0)"
            record["prompt"] = "Prompt \(written)"
        case 5, 6, 7, 8, 9:
            let id = "t\(written)", name = ["Bash", "Read", "Edit"].randomElement(using: &random) ?? "Bash"
            tools[session, default: []].append(id)
            record["hook_event_name"] = "PreToolUse"
            record["tool_use_id"] = id
            record["tool_name"] = name
            record["tool_input"] = name == "Bash" ? ["command": "run \(Int.random(in: 0..<3, using: &random))"] : ["file_path": "/tmp/f\(written)"]
            if let agent = running.randomElement(using: &random), Bool.random(using: &random) { record["agent_id"] = agent }
        case 10, 11, 12:
            record["hook_event_name"] = Bool.random(using: &random) ? "PostToolUse" : "PostToolUseFailure"
            record["tool_use_id"] = open.randomElement(using: &random) ?? "t-none"
        case 13:
            record["hook_event_name"] = "PostToolBatch"
            record["tool_input"] = ["tool_use_ids": Array(open.suffix(2))]
        case 14, 15:
            record["hook_event_name"] = "PermissionRequest"
            record["tool_name"] = "Bash"
            record["tool_input"] = ["command": "run \(Int.random(in: 0..<3, using: &random))"]
            record["approval_request_id"] = "a\(written)"
        case 16:
            record["hook_event_name"] = Bool.random(using: &random) ? "Stop" : "StopFailure"
            record["last_assistant_message"] = "Done \(written)"
        case 17, 18:
            let agent = "g\(written)"
            agents[session, default: []].append(agent)
            record["hook_event_name"] = "SubagentStart"
            record["agent_id"] = agent
            record["agent_type"] = "Explore"
        default:
            record["hook_event_name"] = "SubagentStop"
            record["agent_id"] = running.randomElement(using: &random) ?? "g-none"
        }
        return record
    }

    for step in 0..<200 {
        // Sometimes seconds apart, sometimes past the freshness and full-check bounds.
        clock += [0.5, 2, 2, 5, 12, 45].randomElement(using: &random) ?? 2
        let session = sessions.randomElement(using: &random) ?? "s1"
        switch Int.random(in: 0..<20, using: &random) {
        case 0 where !files.isEmpty:
            let index = Int.random(in: 0..<files.count, using: &random)
            try FileManager.default.removeItem(at: root.appendingPathComponent(files.remove(at: index)))
        case 1 where !files.isEmpty:
            // Another record under a name already read: an atomic write gives it a new inode.
            try writeClaudeRecord(record(session), named: files.randomElement(using: &random) ?? files[0], in: root)
        case 2:
            break   // Only time passes.
        default:
            let name = String(format: "r%04d.json", written)
            try writeClaudeRecord(record(session), named: name, in: root)
            files.append(name)
        }
        written += 1
        let now = clock + Double.random(in: 0...3, using: &random)
        let carried = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                                   now: now, cache: cache)
        let reference = ClaudeObservationReader.referenceScan(events: root, sourceScope: root.path,
                                                              installationID: "install", now: now)
        #expect(carried.scan == reference, "step \(step), seed \(seed)")
        #expect(carried.scan == ClaudeObservationReader.scan(events: root, sourceScope: root.path,
                                                             installationID: "install", now: now),
                "step \(step), seed \(seed)")
        cache = carried.cache
    }
}

@Test func aRecordAlreadyReadIsNotLookedAtAgainWhileItsNameKeepsItsInode() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "a", "captured_at": 1,
                           "prompt_id": "p1", "prompt": "First"], named: "a.json", in: root)
    func scan(now: Double, cache: ClaudeRecordCache) -> (scan: ClaudeObservationScan, cache: ClaudeRecordCache) {
        ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install", now: now, cache: cache)
    }
    let first = scan(now: 100, cache: ClaudeRecordCache())

    // Rewritten in place, then another session's record arrives: the directory changed, but a.json
    // keeps its inode, so until the next full check it is not looked at and "First" stands.
    let path = root.appendingPathComponent("a.json")
    let text = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: "First", with: "Again")
    let handle = try FileHandle(forWritingTo: path)
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "b", "captured_at": 2,
                           "prompt_id": "p1", "prompt": "Second"], named: "b.json", in: root)
    let age = ClaudeObservationReader.maximumUncheckedAge
    let trusted = scan(now: 100 + age - 1, cache: first.cache)
    #expect(runningPrompts(trusted.scan) == ["a": "First", "b": "Second"])
    // A third record does not push the full check back: it is due by the first scan's time.
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "c", "captured_at": 3,
                           "prompt_id": "p1", "prompt": "Third"], named: "c.json", in: root)
    let checked = scan(now: 100 + age, cache: trusted.cache)
    #expect(runningPrompts(checked.scan) == ["a": "Again", "b": "Second", "c": "Third"])

    // A replaced file has a new inode: read at once, with no wait for the full check.
    try writeClaudeRecord(["hook_event_name": "UserPromptSubmit", "session_id": "b", "captured_at": 2,
                           "prompt_id": "p1", "prompt": "Replaced"], named: "b.json", in: root)
    #expect(runningPrompts(scan(now: 100 + age + 1, cache: checked.cache).scan)
            == ["a": "Again", "b": "Replaced", "c": "Third"])
}
