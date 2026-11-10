import Foundation
import Testing
@testable import HerdlyCore

// Fixture lines follow the shapes recorded from Codex desktop engine 0.164.0-alpha.11.1 on
// 2026-11-05 (a root thread that spawned three research agents), redacted to structural fields with
// invented text. A subagent's rollout opens with its own `session_meta`, repeats the parent's header
// and history (the fork), and starts its own history at `subagent_history_start_ordinal`. Every line
// carries an `ordinal`.

private let now = Date(timeIntervalSince1970: 1793847300)
private let rootSession = UUID(uuidString: "0B5E55E0-0000-7000-8000-00000000000A")!
private let rootTurn = UUID(uuidString: "0B5E55E0-0000-7000-8000-00000000000B")!

private func id(_ value: UUID) -> String { value.uuidString.lowercased() }

private func json(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func line(_ ordinal: Int?, _ type: String, at: String = "2026-11-05T02:54:40.000Z", _ payload: [String: Any]) -> String {
    var object: [String: Any] = ["timestamp": at, "type": type, "payload": payload]
    if let ordinal { object["ordinal"] = ordinal }
    return json(object)
}

private func rootMeta(_ session: UUID = rootSession, ordinal: Int? = 0) -> String {
    line(ordinal, "session_meta", at: "2026-11-05T02:54:00.700Z",
         ["id": id(session), "session_id": id(session), "timestamp": "2026-11-05T02:54:00.634Z",
          "originator": "Codex Desktop", "cli_version": "0.164.0-alpha.11.1", "source": "vscode"])
}

private func childMeta(_ child: UUID, parent: UUID = rootSession, root: UUID = rootSession, depth: Int = 1,
                       nickname: String? = "Kierkegaard", path: String? = "/root/quiet_resorts", role: String? = nil,
                       startedAt: String = "2026-11-05T02:54:48.902Z", startOrdinal: Int? = 4) -> String {
    var spawn: [String: Any] = ["parent_thread_id": id(parent), "depth": depth,
                                "agent_nickname": nickname ?? NSNull(), "agent_path": path ?? NSNull(),
                                "agent_role": role ?? NSNull()]
    var payload: [String: Any] = ["id": id(child), "session_id": id(root), "forked_from_id": id(parent),
                                  "parent_thread_id": id(parent), "timestamp": startedAt,
                                  "originator": "Codex Desktop", "cli_version": "0.164.0-alpha.11.1",
                                  "source": ["subagent": ["thread_spawn": spawn]], "thread_source": "subagent",
                                  "history_mode": "paginated", "multi_agent_version": "v2"]
    if let nickname { payload["agent_nickname"] = nickname }
    if let path { payload["agent_path"] = path }
    if let startOrdinal { payload["subagent_history_start_ordinal"] = startOrdinal }
    return line(0, "session_meta", at: "2026-11-05T02:54:48.971Z", payload)
}

private func started(_ turn: UUID, ordinal: Int?, at: String = "2026-11-05T02:54:49.000Z") -> String {
    line(ordinal, "event_msg", at: at, ["type": "task_started", "turn_id": id(turn)])
}

private func ended(_ turn: UUID, ordinal: Int?, kind: String = "task_complete") -> String {
    line(ordinal, "event_msg", at: "2026-11-05T02:55:30.000Z", ["type": kind, "turn_id": id(turn)])
}

private func userMessage(_ text: String, turn: UUID, ordinal: Int?) -> String {
    line(ordinal, "response_item", ["type": "message", "role": "user",
                                    "content": [["type": "input_text", "text": text]],
                                    "internal_chat_message_metadata_passthrough": ["turn_id": id(turn)]])
}

/// The task as the recorded engine hands it over: plaintext routing lines, the task itself encrypted.
private func newTask(path: String, payload: String = "", turn: UUID, ordinal: Int?) -> String {
    line(ordinal, "response_item", ["type": "agent_message", "author": "/root", "recipient": path,
                                    "content": [["type": "input_text",
                                                 "text": "Message Type: NEW_TASK\nTask name: \(path)\nSender: /root\nPayload:\n\(payload)"],
                                                ["type": "encrypted_content", "encrypted_content": "gAAAA-redacted"]],
                                    "internal_chat_message_metadata_passthrough": ["turn_id": id(turn)]])
}

private func execCall(_ command: String, call: String, turn: UUID, ordinal: Int?) -> String {
    let literal = String(decoding: try! JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed]), as: UTF8.self)
    let input = "const r = await tools.exec_command({\"cmd\":\(literal)});"
    return line(ordinal, "response_item", ["type": "custom_tool_call", "status": "completed", "call_id": call,
                                           "name": "exec", "input": input,
                                           "internal_chat_message_metadata_passthrough": ["turn_id": id(turn)]])
}

private func callOutput(_ call: String, turn: UUID, ordinal: Int?) -> String {
    line(ordinal, "response_item", ["type": "custom_tool_call_output", "call_id": call,
                                    "output": [["type": "input_text", "text": "Script completed\nWall time 2.2 seconds\nOutput:\n"]],
                                    "internal_chat_message_metadata_passthrough": ["turn_id": id(turn)]])
}

/// The forked prefix: the parent's header and the parent's own turn up to the spawn.
private func forkedHistory() -> [String] {
    [rootMeta(ordinal: 1), started(rootTurn, ordinal: 2), userMessage("parent prompt, not the child's task", turn: rootTurn, ordinal: 3)]
}

private func sessionsTree() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("2026/11/05"), withIntermediateDirectories: true)
    return root
}

@discardableResult
private func write(_ lines: [String], session: UUID, time: String, in root: URL, modified: Date = now) throws -> URL {
    let url = root.appendingPathComponent("2026/11/05/rollout-2026-11-05T\(time)-\(id(session)).jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
}

private func writeRoot(in root: URL) throws {
    try write([rootMeta(), started(rootTurn, ordinal: 1)], session: rootSession, time: "10-54-00", in: root)
}

@Test func aRunningCodexSubagentIsListedUnderItsRootSessionWithItsLatestCall() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    let child = UUID(), childTurn = UUID()
    try write([childMeta(child)] + forkedHistory() + [
        started(childTurn, ordinal: 4),
        newTask(path: "/root/quiet_resorts", payload: "Find three quiet beach stays", turn: childTurn, ordinal: 5),
        execCall("rg -n beach notes.md", call: "c1", turn: childTurn, ordinal: 6),
    ], session: child, time: "10-54-48", in: root)

    let activity = CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)

    #expect(activity == [rootSession: [SubagentActivity(
        id: id(child), name: "Kierkegaard", role: nil, asked: "Find three quiet beach stays",
        startedAt: 1793847288.902,
        latestAction: RunningRowDetails.now(toolName: "exec_command", toolInput: ["cmd": "rg -n beach notes.md"]))]])
}

private func runningChild(_ child: UUID, turn: UUID = UUID(), parent: UUID = rootSession, depth: Int = 1,
                          nickname: String? = "Kierkegaard", path: String? = "/root/quiet_resorts", role: String? = nil,
                          startedAt: String = "2026-11-05T02:54:48.902Z", extra: [String] = []) -> [String] {
    [childMeta(child, parent: parent, depth: depth, nickname: nickname, path: path, role: role, startedAt: startedAt)]
        + forkedHistory() + [started(turn, ordinal: 4), newTask(path: path ?? "/root/agent", turn: turn, ordinal: 5)] + extra
}

@Test func twoRunningSubagentsAreListedOldestFirstAndAFinishedCallLeavesNoAction() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    let first = UUID(), second = UUID(), firstTurn = UUID()
    try write(runningChild(first, turn: firstTurn, nickname: "Cicero", path: "/root/budget_resorts",
                           startedAt: "2026-11-05T02:54:35.902Z",
                           extra: [execCall("ls", call: "c1", turn: firstTurn, ordinal: 6), callOutput("c1", turn: firstTurn, ordinal: 7)]),
              session: first, time: "10-54-35", in: root)
    try write(runningChild(second, nickname: "Raman", path: "/root/luxury_resorts", startedAt: "2026-11-05T02:54:41.500Z"),
              session: second, time: "10-54-41", in: root)

    let listed = CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession] ?? []

    #expect(listed.map(\.name) == ["Cicero", "Raman"])
    #expect(listed.map(\.id) == [id(first), id(second)])
    #expect(listed.allSatisfy { $0.latestAction == nil })
    // The recorded engine encrypts the handed-over task, so nothing readable is "asked".
    #expect(listed.allSatisfy { $0.asked == nil })
}

@Test func aSubagentWhoseTurnEndedOrWhoseRolloutIsGoneIsNotListed() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    let done = UUID(), doneTurn = UUID(), aborted = UUID(), abortedTurn = UUID(), live = UUID()
    try write(runningChild(done, turn: doneTurn, extra: [ended(doneTurn, ordinal: 6)]), session: done, time: "10-54-35", in: root)
    try write(runningChild(aborted, turn: abortedTurn, extra: [ended(abortedTurn, ordinal: 6, kind: "turn_aborted")]),
              session: aborted, time: "10-54-36", in: root)
    let liveFile = try write(runningChild(live, nickname: "Raman"), session: live, time: "10-54-41", in: root)
    #expect(CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession]?.map(\.id) == [id(live)])

    try FileManager.default.removeItem(at: liveFile)
    #expect(CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession] == nil)
}

@Test func theForkedParentHeaderIsAcceptedAndOnlyTheChildsOwnHistoryCounts() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    // The forked prefix has an open parent turn and a parent call; neither is the child's.
    let child = UUID(), childTurn = UUID()
    try write([childMeta(child), rootMeta(ordinal: 1), started(rootTurn, ordinal: 2),
               execCall("parent command", call: "p1", turn: rootTurn, ordinal: 3),
               started(childTurn, ordinal: 4), userMessage("Compare three quiet resorts", turn: childTurn, ordinal: 5)],
              session: child, time: "10-54-48", in: root)
    let listed = CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession]
    #expect(listed?.map(\.asked) == ["Compare three quiet resorts"])
    #expect(listed?.first?.latestAction == nil)

    // The fork ended the parent's spawning turn in its copy; the child's own turn is still open.
    try write([childMeta(child), rootMeta(ordinal: 1), started(rootTurn, ordinal: 2), ended(rootTurn, ordinal: 3, kind: "turn_aborted"),
               started(childTurn, ordinal: 4)], session: child, time: "10-54-48", in: root)
    #expect(CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession]?.count == 1)

    // A repeated header naming another thread is corruption: the child contributes nothing.
    try write([childMeta(child), rootMeta(UUID(), ordinal: 1), started(childTurn, ordinal: 4)], session: child, time: "10-54-48", in: root)
    #expect(CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession] == nil)
}

@Test func aSubagentOfAnotherSessionIsNeverListedUnderThisOne() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    let other = UUID(), stranger = UUID(), mixed = UUID()
    try write(runningChild(stranger, parent: other), session: stranger, time: "10-54-50", in: root)
    // A header whose parent fields disagree names no parent at all.
    var lines = runningChild(mixed)
    lines[0] = lines[0].replacingOccurrences(of: "\"forked_from_id\":\"\(id(rootSession))\"", with: "\"forked_from_id\":\"\(id(other))\"")
    try write(lines, session: mixed, time: "10-54-51", in: root)
    let activity = CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)
    #expect(activity[rootSession] == nil)
    #expect(activity[other]?.map(\.id) == [id(stranger)])
}

@Test func aPartialOrMalformedSubagentContributesNothingAndKeepsTheOthers() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    let good = UUID(), partial = UUID(), malformed = UUID(), undated = UUID(), linked = UUID()
    try write(runningChild(good), session: good, time: "10-54-35", in: root)
    // A header still being written, with no newline yet.
    let partialURL = root.appendingPathComponent("2026/11/05/rollout-2026-11-05T10-54-36-\(id(partial)).jsonl")
    try Data(String(childMeta(partial).prefix(120)).utf8).write(to: partialURL)
    try write(["{\"type\":\"session_meta\",\"payload\":"] + runningChild(malformed).dropFirst(), session: malformed, time: "10-54-37", in: root)
    // A header with no start time cannot say how long the subagent has run.
    var header = try #require(try JSONSerialization.jsonObject(with: Data(childMeta(undated).utf8)) as? [String: Any])
    var payload = try #require(header["payload"] as? [String: Any])
    payload.removeValue(forKey: "timestamp")
    header["payload"] = payload
    header.removeValue(forKey: "timestamp")
    try write([json(header)] + runningChild(undated).dropFirst(), session: undated, time: "10-54-38", in: root)
    // A symlink to a running child's rollout is never read.
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
    try Data((runningChild(linked).joined(separator: "\n") + "\n").utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("2026/11/05/rollout-2026-11-05T10-54-40-\(id(linked)).jsonl"),
                                               withDestinationURL: outside)
    // A partial last line mid-append is skipped; the rest of the good child still reads.
    try write(runningChild(good) + ["{\"timestamp\":\"2026-11-05T02:55:00.000Z\",\"type\":\"response_item\",\"payl"],
              session: good, time: "10-54-35", in: root)

    #expect(CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession]?.map(\.id) == [id(good)])
}

@Test func aSubagentIsNamedByNicknameThenPathThenSubagentAndKeepsARoleWhenGiven() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    let nicknamed = UUID(), pathOnly = UUID(), unnamed = UUID()
    try write(runningChild(nicknamed, nickname: "Kierkegaard", role: "explorer", startedAt: "2026-11-05T02:54:40.000Z"),
              session: nicknamed, time: "10-54-40", in: root)
    try write(runningChild(pathOnly, nickname: nil, path: "/root/quiet_resorts", startedAt: "2026-11-05T02:54:41.000Z"),
              session: pathOnly, time: "10-54-41", in: root)
    try write(runningChild(unnamed, nickname: nil, path: nil, startedAt: "2026-11-05T02:54:42.000Z"),
              session: unnamed, time: "10-54-42", in: root)
    let listed = CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession] ?? []
    #expect(listed.map(\.name) == ["Kierkegaard", "quiet_resorts", SubagentActivity.unnamed])
    #expect(listed.map(\.role) == ["explorer", nil, nil])
}

@Test func aNestedSubagentIsListedFlatUnderTheRootSession() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    let child = UUID(), grandchild = UUID()
    try write(runningChild(child, nickname: "Cicero", startedAt: "2026-11-05T02:54:40.000Z"), session: child, time: "10-54-40", in: root)
    try write(runningChild(grandchild, parent: child, depth: 2, nickname: "Hypatia", path: "/root/budget_resorts/prices",
                           startedAt: "2026-11-05T02:54:45.000Z"), session: grandchild, time: "10-54-45", in: root)
    let activity = CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)
    #expect(activity[rootSession]?.map(\.name) == ["Cicero", "Hypatia"])
    #expect(activity[child] == nil)
}

@Test func onlyRecentRolloutsAreProbedAndAtMostTheChildProbeLimit() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    let stale = UUID(), buried = UUID()
    try write(runningChild(stale), session: stale, time: "09-00-00", in: root,
              modified: now.addingTimeInterval(-SessionDiscovery.maximumAge - 1))
    // A running child older than every probed rollout is past the per-scan bound.
    try write(runningChild(buried), session: buried, time: "10-00-00", in: root, modified: now.addingTimeInterval(-600))
    for index in 0..<ReminderReader.maximumChildProbes {
        let other = UUID()
        try write([rootMeta(other)], session: other, time: String(format: "11-%02d-%02d", index / 60, index % 60), in: root,
                  modified: now.addingTimeInterval(-Double(index % 60)))
    }
    #expect(CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970).isEmpty)
}

@Test func aCodexWorkingRowCarriesItsSessionsSubagentsAndDropsAFinishedOneOnTheNextSync() {
    let running = AttentionRunning(source: .desktop, session: rootSession, turn: rootTurn, arrivedAt: 1793847268)
    let other = AttentionRunning(source: .cli, session: UUID(), turn: UUID(), arrivedAt: 1793847270)
    let cicero = SubagentActivity(id: "a", name: "Cicero", startedAt: 1793847275)
    let raman = SubagentActivity(id: "b", name: "Raman", startedAt: 1793847281)
    var queue = AgentAttentionQueue()
    queue.apply(CodexAttentionAdapter.observations(running: [running, other], subagents: [rootSession: [raman, cicero]]),
                now: 1793847300)
    let rows = Dictionary(uniqueKeysWithValues: queue.items.compactMap(\.running).map { ($0.identity.session.session, $0) })
    #expect(rows[rootSession.uuidString]?.subagents == [cicero, raman])
    #expect(rows[other.session.uuidString]?.subagents == [])

    // Cicero finished: the next scan no longer lists it, and the row drops it at once.
    queue.apply(CodexAttentionAdapter.observations(running: [running, other], subagents: [rootSession: [raman]]), now: 1793847302)
    #expect(queue.items.compactMap(\.running).first { $0.identity.session.session == rootSession.uuidString }?.subagents == [raman])
}

@Test func aSubagentRolloutLargerThanItsHeadIsReadFromItsTail() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    // Recorded children run to a few hundred KB: past the head, within one tail read, so the tail
    // starts with the child's own header.
    let filler = line(3, "response_item", ["type": "reasoning", "encrypted_content": String(repeating: "x", count: 4096)])
    let child = UUID(), childTurn = UUID()
    try write([childMeta(child)] + Array(repeating: filler, count: SessionDiscovery.headBytes / 4096 + 2)
              + [started(childTurn, ordinal: 4), execCall("ls", call: "c1", turn: childTurn, ordinal: 5)],
              session: child, time: "10-54-48", in: root)
    let small = CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession]
    #expect(small?.first?.latestAction?.text == "$ ls")

    // Past one tail read the cut first line is skipped and the child still reads.
    try write([childMeta(child)] + Array(repeating: filler, count: SessionDiscovery.tailBytes / 4096 + 2)
              + [started(childTurn, ordinal: 4), execCall("ls", call: "c1", turn: childTurn, ordinal: 5)],
              session: child, time: "10-54-48", in: root)
    #expect(CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession]?.first?.latestAction?.text == "$ ls")
}

@Test func aNestedSubagentWhoseMiddleRolloutIsMissingFallsBackToTheRootItsHeaderNames() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    // The depth-1 agent's rollout is not on disk; its child still names the root as `session_id`.
    let missingMiddle = UUID(), grandchild = UUID()
    try write(runningChild(grandchild, parent: missingMiddle, depth: 2, nickname: "Hypatia"),
              session: grandchild, time: "10-54-45", in: root)
    let activity = CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)
    #expect(activity[rootSession]?.map(\.name) == ["Hypatia"])
    #expect(activity[missingMiddle] == nil)
}

@Test func atMostTheNewestTailBudgetOfSubagentRolloutsAreReadPerScan() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    let budget = CodexSubagentReader.maximumTails
    var children: [UUID] = []
    for index in 0...budget {
        let child = UUID()
        children.append(child)
        try write(runningChild(child, nickname: "Agent\(index)", startedAt: String(format: "2026-11-05T02:%02d:00.000Z", index)),
                  session: child, time: String(format: "10-%02d-00", index), in: root,
                  modified: now.addingTimeInterval(-Double(budget - index) - 1))
    }
    let listed = CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession] ?? []
    // The least recently written one is past the budget.
    #expect(listed.count == budget)
    #expect(!listed.map(\.id).contains(id(children[0])))
}

@Test func aSubagentRolloutIsReadAgainOnlyWhenItChanges() throws {
    let root = try sessionsTree()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeRoot(in: root)
    let child = UUID(), childTurn = UUID()
    let url = try write(runningChild(child, turn: childTurn, nickname: "Raman"), session: child, time: "10-54-41", in: root)
    func listed() -> [SubagentActivity] { CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970)[rootSession] ?? [] }
    func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }
    #expect(listed().map(\.id) == [id(child)])
    #expect(listed().first?.latestAction == nil)

    // Unchanged: not opened again, so it is still listed while unreadable.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    #expect(listed().map(\.id) == [id(child)])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

    // A new call, then the turn's end, are each seen on the next read.
    try append(execCall("rg -n beach notes.md", call: "c9", turn: childTurn, ordinal: 20))
    #expect(listed().first?.latestAction != nil)
    try append(ended(childTurn, ordinal: 21))
    #expect(listed().isEmpty)
    // The root's own rollout is not a subagent's, read or kept.
    #expect(CodexSubagentReader.activity(root: root, now: now.timeIntervalSince1970).isEmpty)
}
