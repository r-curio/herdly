import Foundation
import Testing
@testable import HerdlyCore

// Not checks: each prints what one warm pass of a reader costs when nothing changed, on inputs sized
// like real use, so a change to a reader's caching is a number (#306). Run with
// `HERDLY_MEASURE_READERS=1 swift test -c release --filter readerCost`.

private let measuring = ProcessInfo.processInfo.environment["HERDLY_MEASURE_READERS"] != nil

private func temporaryDirectory(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-\(name)-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Median and mean milliseconds of `passes` runs of `body`, after one cold run reported apart.
private func report(_ name: String, passes: Int = 50, _ body: () -> Void) {
    func time() -> Double {
        let clock = ContinuousClock(), start = clock.now
        body()
        let taken = clock.now - start
        return Double(taken.components.attoseconds) / 1e15 + Double(taken.components.seconds) * 1_000
    }
    let cold = time()
    let warm = (0..<passes).map { _ in time() }.sorted()
    print(String(format: "reader cost, %@: cold %.3f ms; unchanged median %.3f ms, mean %.3f ms per pass (%d passes)", name,
                 cold, warm[warm.count / 2], warm.reduce(0, +) / Double(warm.count), warm.count))
}

/// A Codex sessions tree: 14 day directories over two months, six rollouts a day, the newest 24 of them
/// about 300 KB with an open turn.
private func writeSyntheticRollouts(in root: URL, now: Date) throws {
    let filler = String(repeating: "x", count: 900)
    var written = 0
    for day in 0..<14 {
        let directory = root.appendingPathComponent(day < 9 ? "2026/11/\(String(format: "%02d", 28 - day))"
                                                            : "2026/10/\(String(format: "%02d", 40 - day))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<6 {
            let session = UUID().uuidString.lowercased(), turn = UUID().uuidString.lowercased()
            var lines = ["{\"timestamp\":\"2026-11-28T02:30:01.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\","
                + "\"cwd\":\"/Users/someone/project\",\"originator\":\"codex_cli_rs\",\"source\":\"cli\"}}"]
            lines.append("{\"timestamp\":\"2026-11-28T02:38:36.020Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"\(turn)\"}}")
            for item in 0..<(written < 24 ? 300 : 3) {
                lines.append("{\"timestamp\":\"2026-11-28T02:39:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\","
                    + "\"turn_id\":\"\(turn)\",\"n\":\(item),\"text\":\"\(filler)\"}}")
            }
            lines.append("{\"timestamp\":\"2026-11-28T02:39:30.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\","
                + "\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"window_minutes\":10080,\"used_percent\":12.5,\"resets_at\":1900000000}}}}")
            let url = directory.appendingPathComponent("rollout-2026-11-28T02-30-0\(index)-\(session).jsonl")
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(written) * 20)],
                                                  ofItemAtPath: url.path)
            written += 1
        }
    }
}

@Test(.enabled(if: measuring))
func readerCostRolloutReaders() throws {
    let root = try temporaryDirectory("rollout-cost")
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    try writeSyntheticRollouts(in: root, now: now)
    report("SessionDiscovery.candidates") { _ = SessionDiscovery.candidates(root: root, now: now.timeIntervalSince1970) }
    report("CodexSubagentReader.activity") { _ = CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970) }
    report("CodexUsageReader.latest") { _ = CodexUsageReader.latest(root: root) }
}

/// A hook events directory: `records` records shared by 30 sessions, each naming a herdr pane, with a
/// session end every hundredth record.
private func writeSyntheticHookRecords(in root: URL, records: Int) throws {
    let sessions = (0..<30).map { _ in UUID().uuidString.lowercased() }
    for index in 0..<records {
        let record: [String: Any] = [
            "source": CodexSetupRequirements.helperSource,
            "hook_event_name": index % 100 == 99 ? "SessionEnd" : (index % 2 == 0 ? "PreToolUse" : "PostToolUse"),
            "session_id": sessions[index % sessions.count], "turn_id": UUID().uuidString.lowercased(),
            "received_at": "2026-11-28T02:\(String(format: "%02d", index / 60 % 60)):\(String(format: "%02d", index % 60)).250Z",
            "captured_at": 1_800_000_000.0 + Double(index), "tool_name": "Bash", "tool_use_id": "t\(index)",
            "tool_input": ["command": "swift test --filter Suite\(index)"],
            HerdrPaneID.recordKey: "w1:p\(index % sessions.count)", HerdrSocketPath.recordKey: "/tmp/herdr.sock",
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: root.appendingPathComponent(String(format: "r%05d.json", index)), options: .atomic)
    }
}

@Test(.enabled(if: measuring))
func readerCostHerdrHookRecords() throws {
    let root = try temporaryDirectory("herdr-cost")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSyntheticHookRecords(in: root, records: 3_000)
    var cache = HerdrHookRecordReader.read(directories: []).cache
    report("HerdrHookRecordReader.read") { cache = HerdrHookRecordReader.read(directories: [root], cache: cache).cache }
}

@Test(.enabled(if: measuring))
func readerCostReminderScan() throws {
    let events = try temporaryDirectory("reminder-cost"), rollouts = try temporaryDirectory("reminder-cost-rollouts")
    defer { try? FileManager.default.removeItem(at: events); try? FileManager.default.removeItem(at: rollouts) }
    try writeSyntheticHookRecords(in: events, records: 3_000)
    try writeSyntheticRollouts(in: rollouts, now: Date())
    var rolloutCache = RolloutCache(), hookCache = HookFileCache()
    report("ReminderReader.scan") {
        let scan = ReminderReader.scan(events: events, rollouts: rollouts, rolloutCache: rolloutCache, hookCache: hookCache)
        rolloutCache = scan.rolloutCache
        hookCache = scan.hookCache
    }
}

/// `ps -axo pid=,args=` text for `count` processes: mostly system daemons, some with paths outside
/// ASCII, two Codex TUIs and the desktop app's app-server.
func syntheticProcessList(count: Int) -> String {
    (0..<count).map { index -> String in
        let padded = String(repeating: " ", count: max(0, 5 - String(100 + index * 7).count)) + String(100 + index * 7)
        switch index {
        case 200, 400: return "\(padded) node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js --model gpt-5"
        case 300: return "\(padded) /Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://"
        case _ where index % 25 == 0:
            return "\(padded) /Users/someone/Bibliothèque/Outils/aide-\(index) --répertoire /Users/someone/Projets/été"
        default:
            return "\(padded) /System/Library/PrivateFrameworks/Service\(index).framework/Versions/A/Support/serviced --launchd"
                + " --identifier com.example.service\(index) --flag-\(index % 9)=value"
        }
    }.joined(separator: "\n") + "\n"
}

@Test(.enabled(if: measuring))
func readerCostCodexProcesses() {
    let list = syntheticProcessList(count: 600)
    report("CodexCLIProcesses.arguments + isRunning") {
        _ = CodexCLIProcesses.isRunning(processList: CodexCLIProcesses.arguments(processList: list))
    }
    // No Codex process: the whole listing is examined.
    let none = list.replacingOccurrences(of: "codex", with: "kodex")
    report("CodexCLIProcesses.arguments + isRunning, none running") {
        _ = CodexCLIProcesses.isRunning(processList: CodexCLIProcesses.arguments(processList: none))
    }
}
