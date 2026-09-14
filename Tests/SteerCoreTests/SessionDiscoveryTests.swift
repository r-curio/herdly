import Foundation
import Testing
@testable import SteerCore

private let session = UUID(uuidString: "0199A000-0000-7000-8000-0000000000D5")!
private let turn = UUID(uuidString: "01A09DC7-DB50-7E92-8FF1-70ACD1B0B9EA")!

private func meta(source: String = "\"cli\"", id: UUID = session, cwd: String = "/Users/me/project") -> String {
    "{\"timestamp\":\"2026-09-14T02:30:01.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id.uuidString.lowercased())\","
        + "\"cwd\":\"\(cwd)\",\"originator\":\"codex_cli_rs\",\"cli_version\":\"0.153.4\",\"source\":\(source)}}"
}

private func started(_ turn: UUID, at: String = "2026-09-14T02:38:36.020Z") -> String {
    "{\"timestamp\":\"\(at)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"\(turn.uuidString.lowercased())\",\"started_at\":1789353516}}"
}

private func ended(_ turn: UUID, kind: String = "task_complete") -> String {
    "{\"timestamp\":\"2026-09-14T02:40:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(kind)\",\"turn_id\":\"\(turn.uuidString.lowercased())\"}}"
}

private func rollout(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

@Test func discoveryReadsAnOpenTurnFromACLIRollout() {
    let open = SessionDiscovery.parse(rollout([meta(), started(turn)]))
    #expect(open == DiscoveredTurn(session: session, source: .cli, turn: turn, startedAt: "2026-09-14T02:38:36.020Z"))
}

@Test func discoveryYieldsNothingOnceTheLastTurnEnded() {
    #expect(SessionDiscovery.parse(rollout([meta(), started(turn), ended(turn)])) == nil)
    #expect(SessionDiscovery.parse(rollout([meta(), started(turn), ended(turn, kind: "turn_aborted")])) == nil)
    // A later turn after an ended one is the open turn; an end for another turn does not close it.
    let next = UUID()
    let later = SessionDiscovery.parse(rollout([meta(), started(turn), ended(turn), started(next, at: "2026-09-14T03:00:00.000Z"), ended(UUID())]))
    #expect(later?.turn == next)
    #expect(later?.startedAt == "2026-09-14T03:00:00.000Z")
}

@Test func discoveryOnlyReadsUserSessionsOnTheCLIAndDesktopSurfaces() {
    let desktop = SessionDiscovery.parse(rollout([meta(source: "\"vscode\""), started(turn)]))
    #expect(desktop?.source == .desktop)
    let subagent = "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(session)\",\"depth\":1}}}"
    #expect(SessionDiscovery.parse(rollout([meta(source: subagent), started(turn)])) == nil)
    #expect(SessionDiscovery.parse(rollout([meta(source: "\"exec\""), started(turn)])) == nil)
    #expect(SessionDiscovery.parse(rollout([started(turn), meta()])) == nil) // session_meta must come first
    #expect(SessionDiscovery.parse(rollout(["{\"type\":\"session_meta\",\"payload\":{\"id\":\"x\",\"source\":\"cli\"}}", started(turn)])) == nil)
    #expect(SessionDiscovery.parse(Data()) == nil)
}

private func sessionsTree() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("2026/09/14"), withIntermediateDirectories: true)
    return root
}

private func write(_ lines: [String], as name: String, in root: URL, modified: Date) throws -> URL {
    let url = root.appendingPathComponent("2026/09/14/" + name)
    try rollout(lines).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
}

@Test func discoveryTakesOnlyRecentlyWrittenRollouts() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1789353600)
    let fresh = UUID(), stale = UUID(), finished = UUID()
    _ = try write([meta(id: fresh), started(turn)], as: "rollout-a-\(fresh.uuidString.lowercased()).jsonl", in: root, modified: now.addingTimeInterval(-30))
    _ = try write([meta(id: stale), started(UUID())], as: "rollout-b-\(stale.uuidString.lowercased()).jsonl", in: root,
                  modified: now.addingTimeInterval(-SessionDiscovery.maximumAge - 1))
    _ = try write([meta(id: finished), started(turn), ended(turn)], as: "rollout-c-\(finished.uuidString.lowercased()).jsonl", in: root, modified: now)
    let linked = root.appendingPathComponent("2026/09/14/rollout-d-link.jsonl")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root.appendingPathComponent("2026/09/14/rollout-a-\(fresh.uuidString.lowercased()).jsonl"))
    let found = SessionDiscovery.candidates(root: root, now: now.timeIntervalSince1970)
    #expect(found.map(\.session) == [fresh])
    #expect(found.first?.turn == turn)
}

@Test func discoveryReadsTheTailOfALargeRolloutAndKeepsTheSessionIdentity() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1789353600)
    let filler = "{\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"text\":\"" + String(repeating: "x", count: 4096) + "\"}}"
    let lines = [meta()] + Array(repeating: filler, count: (SessionDiscovery.tailBytes / 4096) + 4) + [started(turn)]
    _ = try write(lines, as: "rollout-big-\(session.uuidString.lowercased()).jsonl", in: root, modified: now)
    let found = SessionDiscovery.candidates(root: root, now: now.timeIntervalSince1970)
    #expect(found == [DiscoveredTurn(session: session, source: .cli, turn: turn, startedAt: "2026-09-14T02:38:36.020Z")])
}

@Test func discoveredTurnsAreShownAsWorkingOnlyWithLivenessEvidence() {
    let cli = DiscoveredTurn(session: session, source: .cli, turn: turn, startedAt: "2026-09-14T02:38:36.020Z")
    let desktopSession = UUID(), desktopTurn = UUID()
    let desktop = DiscoveredTurn(session: desktopSession, source: .desktop, turn: desktopTurn, startedAt: "2026-09-14T02:39:00.000Z")
    let none = SessionLiveness(desktopRunning: false, cliProcessRunning: false, cliSessionsInGhostty: [], sessionEnds: [:])
    #expect(SessionDiscovery.running([cli, desktop], liveness: none).isEmpty)
    let desktopOnly = SessionLiveness(desktopRunning: true, cliProcessRunning: false, cliSessionsInGhostty: [], sessionEnds: [:])
    #expect(SessionDiscovery.running([cli, desktop], liveness: desktopOnly)
            == [AttentionRunning(source: .desktop, session: desktopSession, turn: desktopTurn, arrivedAt: 1789353540)])
    let process = SessionLiveness(desktopRunning: false, cliProcessRunning: true, cliSessionsInGhostty: [], sessionEnds: [:])
    #expect(SessionDiscovery.running([cli, desktop], liveness: process)
            == [AttentionRunning(source: .cli, session: session, turn: turn, arrivedAt: 1789353516.02)])
    let tab = SessionLiveness(desktopRunning: false, cliProcessRunning: false, cliSessionsInGhostty: [session], sessionEnds: [:])
    #expect(SessionDiscovery.running([cli], liveness: tab).map(\.session) == [session])
    // A SessionEnd hook after the turn started outranks every other sign of life.
    let ended = SessionLiveness(desktopRunning: true, cliProcessRunning: true, cliSessionsInGhostty: [session],
                                sessionEnds: [session: 1789353517, desktopSession: 1789353000])
    #expect(SessionDiscovery.running([cli, desktop], liveness: ended).map(\.session) == [desktopSession])
}

@Test func codexCLIProcessesAreRecognizedByTheirExecutableName() {
    let listing = """
    /sbin/launchd
    /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
    /opt/homebrew/Caskroom/codex/0.145.0/codex-aarch64-apple-darwin
    """
    #expect(CodexCLIProcesses.isRunning(processList: listing))
    #expect(CodexCLIProcesses.isRunning(processList: "/usr/local/bin/codex --model gpt-5\n"))
    #expect(CodexCLIProcesses.isRunning(processList: "node /usr/local/lib/node_modules/@openai/codex/bin/codex.js\n"))
    #expect(!CodexCLIProcesses.isRunning(processList: "/Applications/ChatGPT.app/Contents/Resources/codex app-server\n"))
    #expect(!CodexCLIProcesses.isRunning(processList: "/usr/bin/codexplorer\n/Users/me/codex-notes/editor\n"))
    #expect(!CodexCLIProcesses.isRunning(processList: ""))
}

@Test func ghosttyReportsWhichSessionsHaveATabTitledForThem() throws {
    let other = UUID()
    let json = """
    {"status":"ok","windows":[{"id":"w1","tabs":[{"id":"t1","terminals":[{"id":"s1","name":"\(GhosttyMatch.title(session))"}]},
    {"id":"t2","terminals":[{"id":"s2","name":"zsh"},{"id":"s3","name":"\(GhosttyMatch.title(other))"}]}]}],"selected":null}
    """
    let snapshot = try JSONDecoder().decode(GhosttySnapshot.self, from: Data(json.utf8))
    #expect(GhosttyMatch.sessions(in: snapshot, among: [session, other, UUID()]) == [session, other])
    let failed = try JSONDecoder().decode(GhosttySnapshot.self, from: Data("{\"status\":\"error\",\"windows\":[],\"selected\":null}".utf8))
    #expect(GhosttyMatch.sessions(in: failed, among: [session]).isEmpty)
}

@Test func discoveredRunningWorkMergesWithLaterHookEventsAndNeverNotifies() {
    var queue = AttentionQueue()
    let discovered = AttentionRunning(source: .cli, session: session, turn: turn, arrivedAt: 1789353516.02)
    queue.apply(scan: ReminderScan(), desktopEvents: [], now: 1789353600)
    queue.apply(discovered: [discovered])
    #expect(queue.items.map(\.kind) == [.running])
    #expect(queue.workingCount == 1)
    #expect(queue.toCheckCount == 0)
    // A hook for the same session merges into the same row, and the observed event's row stands
    // even when the inferred start would sort later.
    var scan = ReminderScan()
    scan.cliSessions = [session]
    scan.cliState = CLIState.replay([.turnStarted(session: session, turn: turn, receivedAt: "2026-09-14T02:38:36.000Z")])
    queue.apply(scan: scan, desktopEvents: [], now: 1789353601)
    queue.apply(discovered: [discovered])
    #expect(queue.items.count == 1)
    #expect(queue.items.first?.running?.turn == turn)
    #expect(queue.items.first?.running?.arrivedAt == 1789353516)
    // Completion evidence for that turn ends it; the discovered turn cannot revive it.
    scan.cliState = CLIState.replay([.turnStarted(session: session, turn: turn, receivedAt: "2026-09-14T02:38:36.500Z"),
                                     .turnCompleted(session: session, turn: turn, receivedAt: "2026-09-14T02:50:00.000Z")])
    scan.completed = [TurnIdentity(session: session, turn: turn)]
    queue.apply(scan: scan, desktopEvents: [], now: 1789353602)
    queue.apply(discovered: [discovered])
    #expect(queue.items.filter { $0.kind == .running }.isEmpty)
    #expect(queue.toCheckCount == 0) // discovery never made a completion
}

private func itemCompleted(_ turn: UUID, at: String) -> String {
    "{\"timestamp\":\"\(at)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"turn_id\":\"\(turn.uuidString.lowercased())\",\"item\":{\"type\":\"reasoning\"}}}"
}

private func toolCall(_ turn: UUID, at: String) -> String {
    "{\"timestamp\":\"\(at)\",\"type\":\"response_item\",\"payload\":{\"type\":\"custom_tool_call\",\"name\":\"shell\",\"call_id\":\"c1\","
        + "\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"\(turn.uuidString.lowercased())\"}}}"
}

@Test func discoveryInfersTheOpenTurnFromLaterEventsWhenItsStartIsBeyondTheTail() {
    // A long turn's task_started line lies megabytes before the tail; every later item still names the turn.
    let tail = [toolCall(turn, at: "2026-09-14T07:20:00.000Z"), itemCompleted(turn, at: "2026-09-14T07:21:00.000Z")]
    let open = SessionDiscovery.open(meta: Data(meta().utf8), lines: tail.map { Data($0.utf8) }[...])
    #expect(open == DiscoveredTurn(session: session, source: .cli, turn: turn, startedAt: "2026-09-14T07:20:00.000Z"))
    // The end of that turn closes it even when its start was never seen.
    #expect(SessionDiscovery.open(meta: Data(meta().utf8), lines: (tail + [ended(turn)]).map { Data($0.utf8) }[...]) == nil)
    // A new turn's items after an ended one open the new turn.
    let next = UUID()
    let reopened = SessionDiscovery.open(meta: Data(meta().utf8),
                                         lines: (tail + [ended(turn), itemCompleted(next, at: "2026-09-14T07:30:00.000Z")]).map { Data($0.utf8) }[...])
    #expect(reopened?.turn == next)
    #expect(reopened?.startedAt == "2026-09-14T07:30:00.000Z")
    // A trailing line for an ended turn (a token count after task_complete) does not reopen it.
    let trailing = SessionDiscovery.open(meta: Data(meta().utf8),
                                         lines: (tail + [ended(turn), itemCompleted(turn, at: "2026-09-14T07:31:00.000Z")]).map { Data($0.utf8) }[...])
    #expect(trailing == nil)
}

@Test func discoverySkipsLinesItCannotReadIncludingAPartialTail() {
    let noisy = [meta(), "not json", started(turn),
                 "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}", // no turn id: not evidence
                 "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"" + turn.uuidString.lowercased()] // cut mid-append
    let open = SessionDiscovery.parse(rollout(noisy))
    #expect(open?.turn == turn)
    // The cut first line of a tail read still needs the session_meta line to identify the session.
    #expect(SessionDiscovery.parse(Data(("ion_meta\",\"payload\":{}}\n" + started(turn) + "\n").utf8)) == nil)
}
