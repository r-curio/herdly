import Foundation
import Testing
@testable import HerdlyCore

/// A Claude events directory sized like real use: `sessions` sessions sharing `records` records, each a
/// prompt followed by tool calls, most of them completed. The first `active` sessions end on a call still
/// open at `openAt`. Every third file-tool input holds text outside ASCII, as edited source often does.
private func writeSyntheticClaudeEvents(in root: URL, sessions: Int, records: Int, active: Int,
                                        openAt: Double) throws {
    var written = 0
    func write(_ record: [String: Any]) throws {
        var record = record
        record["source"] = ClaudeSetupRequirements.helperSource
        record["installation_id"] = "install"
        try JSONSerialization.data(withJSONObject: record)
            .write(to: root.appendingPathComponent(String(format: "r%05d.json", written)), options: .atomic)
        written += 1
    }
    let perSession = records / sessions
    for index in 0..<sessions {
        let session = "session-\(index)", start = openAt - 10_000 + Double(index)
        try write(["hook_event_name": "UserPromptSubmit", "session_id": session, "captured_at": start,
                   "prompt_id": "p1", "prompt": "Make the scan cheaper for session \(index) — and keep it exact"])
        let calls = (perSession - 1) / 2
        for call in 0..<calls {
            let at = start + Double(call) * 2 + 1, id = "t\(index)-\(call)"
            let text = String(repeating: call % 3 == 0 ? "let café = \"naïve\" // → ok\n" : "let value = compute(input)\n", count: 40)
            let input: [String: Any] = call % 2 == 0
                ? ["command": "cd /Users/someone/project && swift test --filter Suite\(call) 2>&1 | tail -20",
                   "description": "Run the focused suite"]
                : ["file_path": "/Users/someone/project/Sources/File\(call).swift", "old_string": text, "new_string": text + "// done\n"]
            let last = call == calls - 1 && index < active
            try write(["hook_event_name": "PreToolUse", "session_id": session, "captured_at": last ? openAt : at,
                       "prompt_id": "p1", "tool_name": call % 2 == 0 ? "Bash" : "Edit", "tool_use_id": id,
                       "tool_input": input])
            if !last {
                try write(["hook_event_name": "PostToolUse", "session_id": session, "captured_at": at + 1,
                           "prompt_id": "p1", "tool_name": call % 2 == 0 ? "Bash" : "Edit", "tool_use_id": id])
            }
        }
    }
}

/// Not a check: prints what a warm scan costs, so a change to the reader's caching is a number. Run with
/// `HERDLY_MEASURE_CLAUDE_SCAN=1 swift test -c release --filter claudeScanCostPerWarmPass`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["HERDLY_MEASURE_CLAUDE_SCAN"] != nil))
func claudeScanCostPerWarmPass() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-cost-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let openAt = 1_000_000.0, passes = 50
    try writeSyntheticClaudeEvents(in: root, sessions: 30, records: 3_000, active: 5, openAt: openAt)
    var cache = ClaudeRecordCache()
    func pass(now: Double) -> Duration {
        let clock = ContinuousClock(), start = clock.now
        let result = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                                  now: now, cache: cache)
        cache = result.cache
        return clock.now - start
    }
    func report(_ name: String, _ times: [Duration]) {
        let milliseconds = times.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1_000 }.sorted()
        print(String(format: "claude scan cost, %@: median %.3f ms, mean %.3f ms per pass (%d passes)", name,
                     milliseconds[milliseconds.count / 2], milliseconds.reduce(0, +) / Double(milliseconds.count), milliseconds.count))
    }
    report("cold", [pass(now: openAt + 1)])
    // Nothing changes on disk; five sessions' open calls are still fresh.
    report("unchanged, 5 fresh calls", (0..<passes).map { pass(now: openAt + 1 + Double($0) * 0.5) })
    // Nothing changes and every open call has gone stale.
    report("unchanged, idle", (0..<passes).map { pass(now: openAt + 100 + Double($0) * 2) })
    // One session completes a call and starts another before each pass, two seconds apart.
    // The directory listing is timed apart: this reader only asks for it, and in the app a watcher keeps
    // it up to date without the full read a test directory gets.
    var now = openAt + 300, changing: [Duration] = [], listing: [Duration] = []
    for step in 0..<passes {
        now += 2
        for (event, id, at) in [("PostToolUse", "n\(step - 1)", now - 1.5), ("PreToolUse", "n\(step)", now - 1)] {
            let record: [String: Any] = ["source": ClaudeSetupRequirements.helperSource, "installation_id": "install",
                                         "hook_event_name": event, "session_id": "session-0", "captured_at": at,
                                         "prompt_id": "p1", "tool_name": "Bash", "tool_use_id": id,
                                         "tool_input": ["command": "swift build # étape \(step)"]]
            try JSONSerialization.data(withJSONObject: record)
                .write(to: root.appendingPathComponent("n\(step)-\(event).json"), options: .atomic)
        }
        let clock = ContinuousClock(), start = clock.now
        _ = HookEventListing.detailedListing(in: root)
        listing.append(clock.now - start)
        changing.append(pass(now: now))
    }
    report("one session changing, listing", listing)
    report("one session changing, reader", changing)
}

private func temporaryEvents() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-cost-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ record: [String: Any], named name: String, in root: URL, installationID: String = "install") throws {
    var record = record
    record["source"] = ClaudeSetupRequirements.helperSource
    record["installation_id"] = installationID
    try JSONSerialization.data(withJSONObject: record).write(to: root.appendingPathComponent(name), options: .atomic)
}

private func prompt(_ session: String, _ text: String, at: Double = 1) -> [String: Any] {
    ["hook_event_name": "UserPromptSubmit", "session_id": session, "captured_at": at, "prompt_id": "p1", "prompt": text]
}

private func call(_ session: String, _ id: String, at: Double, command: String = "swift test") -> [String: Any] {
    ["hook_event_name": "PreToolUse", "session_id": session, "captured_at": at, "prompt_id": "p1",
     "tool_name": "Bash", "tool_use_id": id, "tool_input": ["command": command]]
}

private func running(_ scan: ClaudeObservationScan) -> [String: AgentRunning] {
    Dictionary(uniqueKeysWithValues: scan.observations.compactMap { observation -> (String, AgentRunning)? in
        guard case let .running(value) = observation else { return nil }
        return (value.identity.session.session, value)
    })
}

/// One directory scanned again and again with the cache each scan returns.
private struct WarmScans {
    let root: URL
    var cache = ClaudeRecordCache()

    mutating func scan(now: Double) -> ClaudeObservationScan {
        let result = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install",
                                                  now: now, cache: cache)
        cache = result.cache
        return result.scan
    }

    /// `scan`, checked against a scan from nothing and against one replay of every record.
    mutating func checkedScan(now: Double, _ comment: Comment) -> ClaudeObservationScan {
        let warm = scan(now: now)
        #expect(warm == ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install", now: now),
                comment)
        #expect(warm == ClaudeObservationReader.referenceScan(events: root, sourceScope: root.path,
                                                              installationID: "install", now: now), comment)
        return warm
    }
}

@Test func aWarmClaudeScanEqualsAColdOneThroughEveryKindOfChange() throws {
    let root = try temporaryEvents()
    defer { try? FileManager.default.removeItem(at: root) }
    let age = ClaudeObservationReader.maximumUncheckedAge
    var scans = WarmScans(root: root)
    try write(prompt("a", "First"), named: "a1.json", in: root)
    // Text outside ASCII, and a command longer than an identifier, reach the row whole.
    let command = "cd /tmp/café && " + String(repeating: "echo → ", count: 60)
    try write(call("a", "t1", at: 99, command: command), named: "a2.json", in: root)
    try write(prompt("b", "Second", at: 2), named: "b1.json", in: root)
    var seen = running(scans.checkedScan(now: 100, "from nothing"))
    #expect(seen["a"]?.toolInput["command"] == command)
    #expect(seen["b"]?.prompt == "Second")

    try write(["hook_event_name": "PostToolUse", "session_id": "a", "captured_at": 101, "prompt_id": "p1",
               "tool_use_id": "t1"], named: "a3.json", in: root)
    #expect(running(scans.checkedScan(now: 102, "added"))["a"]?.toolName == nil)

    try write(prompt("a", "Replaced"), named: "a1.json", in: root)
    #expect(running(scans.checkedScan(now: 104, "replaced atomically"))["a"]?.prompt == "Replaced")

    // Never a record: unparsable, a list, over the size bound, and another installation's.
    try Data("{\"hook_event_name\": \"UserPromptSubmit\", \"session_id\": \"m\"".utf8)
        .write(to: root.appendingPathComponent("m1.json"), options: .atomic)
    try Data("[1, 2]".utf8).write(to: root.appendingPathComponent("m2.json"), options: .atomic)
    var oversized = prompt("m", "Too large", at: 3)
    oversized["padding"] = String(repeating: "x", count: ClaudeObservationReader.maximumRecordSize)
    try write(oversized, named: "m3.json", in: root)
    try write(prompt("m", "Someone else's", at: 3), named: "m4.json", in: root, installationID: "other")
    seen = running(scans.checkedScan(now: 106, "malformed added"))
    #expect(Set(seen.keys) == ["a", "b"])
    // They stay ignored once cached, and a later record of another session changes nothing about them.
    try write(prompt("c", "Third", at: 4), named: "c1.json", in: root)
    #expect(Set(running(scans.checkedScan(now: 108, "malformed cached")).keys) == ["a", "b", "c"])

    // Rewritten in place: the directory and the file's inode stay, so it is noticed at the full check.
    let path = root.appendingPathComponent("b1.json")
    let text = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: "Second", with: "Edited")
    var handle = try FileHandle(forWritingTo: path)
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
    #expect(running(scans.checkedScan(now: 100 + age, "rewritten in place"))["b"]?.prompt == "Edited")

    // Truncated in place: what is left is no record.
    handle = try FileHandle(forWritingTo: path)
    try handle.truncate(atOffset: 20)
    try handle.close()
    #expect(running(scans.checkedScan(now: 100 + 2 * age, "truncated"))["b"] == nil)

    try FileManager.default.removeItem(at: root.appendingPathComponent("a1.json"))
    #expect(running(scans.checkedScan(now: 100 + 2 * age + 2, "removed"))["a"] == nil)
}

@Test func anUnchangedClaudePassOpensNoRecordAndBuildsNoSession() throws {
    let root = try temporaryEvents()
    defer { try? FileManager.default.removeItem(at: root) }
    let fresh = ClaudeObservationReader.maximumToolFreshness
    var scans = WarmScans(root: root)
    try write(prompt("a", "First"), named: "a1.json", in: root)
    try write(call("a", "t1", at: 99), named: "a2.json", in: root)
    try write(prompt("b", "Second", at: 2), named: "b1.json", in: root)
    #expect(running(scans.checkedScan(now: 100, "from nothing"))["a"]?.toolName == "Bash")
    #expect(scans.cache.recordsRead == 3)
    #expect(scans.cache.sessionsBuilt == ["a", "b"])

    // The call is still fresh and nothing changed: the same answer, with nothing opened or built.
    for now in [100, 102, 99 + fresh] {
        #expect(running(scans.checkedScan(now: now, "fresh at \(now)"))["a"]?.toolName == "Bash")
        #expect(scans.cache.recordsRead == 0)
        #expect(scans.cache.sessionsBuilt == [])
    }
    // The call goes stale: its session alone is built again, from records already read.
    #expect(running(scans.checkedScan(now: 99 + fresh + 0.5, "stale"))["a"]?.toolName == nil)
    #expect(scans.cache.recordsRead == 0)
    #expect(scans.cache.sessionsBuilt == ["a"])
    // The full check looks at every file and opens none.
    for now in [99 + fresh + 2, 100 + 2 * ClaudeObservationReader.maximumUncheckedAge] {
        _ = scans.checkedScan(now: now, "idle at \(now)")
        #expect(scans.cache.recordsRead == 0)
        #expect(scans.cache.sessionsBuilt == [])
    }
}

@Test func onlyTheClaudeSessionWhoseRecordsChangedIsBuiltAgain() throws {
    let root = try temporaryEvents()
    defer { try? FileManager.default.removeItem(at: root) }
    var scans = WarmScans(root: root)
    for (index, session) in ["a", "b", "c"].enumerated() {
        try write(prompt(session, "Prompt \(session)", at: Double(index)), named: "\(session)1.json", in: root)
        try write(call(session, "t-\(session)", at: 10 + Double(index)), named: "\(session)2.json", in: root)
    }
    _ = scans.checkedScan(now: 100, "from nothing")
    #expect(scans.cache.sessionsBuilt == ["a", "b", "c"])

    try write(["hook_event_name": "PostToolUse", "session_id": "b", "captured_at": 101, "prompt_id": "p1",
               "tool_use_id": "t-b"], named: "b3.json", in: root)
    _ = scans.checkedScan(now: 102, "one record added")
    #expect(scans.cache.recordsRead == 1)
    #expect(scans.cache.sessionsBuilt == ["b"])

    try write(prompt("c", "Replaced", at: 2), named: "c1.json", in: root)
    #expect(running(scans.checkedScan(now: 104, "one record replaced"))["c"]?.prompt == "Replaced")
    #expect(scans.cache.recordsRead == 1)
    #expect(scans.cache.sessionsBuilt == ["c"])

    try FileManager.default.removeItem(at: root.appendingPathComponent("a2.json"))
    _ = scans.checkedScan(now: 106, "one record removed")
    #expect(scans.cache.recordsRead == 0)
    #expect(scans.cache.sessionsBuilt == ["a"])
}

@Test func aClaudeRecordThatDisappearsLeavesNothingInTheCache() throws {
    let root = try temporaryEvents()
    defer { try? FileManager.default.removeItem(at: root) }
    var scans = WarmScans(root: root)
    try write(prompt("a", "First"), named: "a1.json", in: root)
    try write(call("a", "t1", at: 5), named: "a2.json", in: root)
    try write(prompt("b", "Second", at: 2), named: "b1.json", in: root)
    try Data("not a record".utf8).write(to: root.appendingPathComponent("junk.json"), options: .atomic)
    _ = scans.checkedScan(now: 100, "from nothing")
    #expect(scans.cache.count == 4)
    #expect(scans.cache.heldSessions == ["a", "b"])

    try FileManager.default.removeItem(at: root.appendingPathComponent("b1.json"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("junk.json"))
    _ = scans.checkedScan(now: 102, "a session's only record and a malformed file removed")
    #expect(scans.cache.count == 2)
    #expect(scans.cache.heldSessions == ["a"])

    try FileManager.default.removeItem(at: root.appendingPathComponent("a1.json"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("a2.json"))
    #expect(scans.checkedScan(now: 104, "everything removed").observations.isEmpty)
    #expect(scans.cache.count == 0)
    #expect(scans.cache.heldSessions.isEmpty)
}
