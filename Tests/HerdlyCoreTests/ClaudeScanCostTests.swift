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
