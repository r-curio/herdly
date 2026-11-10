import Foundation
import Testing
@testable import HerdlyCore

// Claude's SubagentStart/SubagentStop and the PreToolUse/PostToolUse fired inside a subagent carry
// `agent_id` and `agent_type` (#395). These checks read them through the public scan.

private func events(_ records: [[String: Any]]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-subagents-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (index, var record) in records.enumerated() {
        record["source"] = ClaudeSetupRequirements.helperSource
        record["installation_id"] = "install"
        try JSONSerialization.data(withJSONObject: record).write(to: root.appendingPathComponent("event-\(index).json"))
    }
    return root
}

private func record(_ event: String, at capturedAt: Double, prompt: String? = "p1", agent: Any? = nil,
                    type: Any? = nil, tool: String? = nil, call: String? = nil,
                    input: [String: Any] = [:], session: String = "session-1") -> [String: Any] {
    var value: [String: Any] = ["hook_event_name": event, "session_id": session, "captured_at": capturedAt]
    if let prompt { value["prompt_id"] = prompt }
    if let agent { value["agent_id"] = agent }
    if let type { value["agent_type"] = type }
    if let tool { value["tool_name"] = tool }
    if let call { value["tool_use_id"] = call }
    if !input.isEmpty { value["tool_input"] = input }
    return value
}

private var prompt: [String: Any] { record("UserPromptSubmit", at: 1) }

private func running(_ records: [[String: Any]], now: Double = 10) throws -> AgentRunning? {
    let root = try events(records)
    defer { try? FileManager.default.removeItem(at: root) }
    return ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install", now: now)
        .observations.compactMap { observation -> AgentRunning? in
            if case let .running(value) = observation { return value }
            return nil
        }.first
}

@Test func claudeSubagentShowsItsLatestActionUntilItStops() throws {
    let started = [prompt,
                   record("SubagentStart", at: 2, agent: "a1", type: "Explore"),
                   record("PreToolUse", at: 3, agent: "a1", type: "Explore", tool: "Bash", call: "t1",
                          input: ["command": "rg subagent"])]
    let subagent = try #require(try running(started)?.subagents.first)
    #expect(subagent.id == "a1")
    #expect(subagent.name == "Explore")
    #expect(subagent.role == nil)
    #expect(subagent.asked == nil)
    #expect(subagent.startedAt == 2)
    #expect(subagent.latestAction == RunningRowDetails.Now(text: "$ rg subagent", full: nil, disclosureTitle: nil,
                                                           isUnknown: false))

    let finishedTool = started + [record("PostToolUse", at: 4, agent: "a1", type: "Explore", call: "t1")]
    #expect(try running(finishedTool)?.subagents.first?.latestAction == nil)
    #expect(try running(finishedTool)?.subagents.count == 1)

    let stopped = finishedTool + [record("SubagentStop", at: 5, agent: "a1", type: "Explore")]
    #expect(try running(stopped)?.subagents.isEmpty == true)
}

@Test func claudeParallelSubagentsOfOneTypeAreNumberedByStartOrder() throws {
    let records = [prompt,
                   // Written out of order on disk; the capture time decides the start order.
                   record("SubagentStart", at: 4, agent: "late", type: "Explore"),
                   record("SubagentStart", at: 2, agent: "early", type: "Explore"),
                   record("SubagentStart", at: 3, agent: "plan", type: "Plan"),
                   record("SubagentStart", at: 5, agent: "blank", type: ""),
                   record("SubagentStart", at: 6, agent: "untyped")]
    let subagents = try #require(try running(records)?.subagents)
    #expect(subagents.map(\.id) == ["early", "plan", "late", "blank", "untyped"])
    #expect(subagents.map(\.name) == ["Explore", "Plan", "Explore 2", "Subagent", "Subagent 2"])
    #expect(subagents.map(\.startedAt) == [2, 3, 4, 5, 6])
}

@Test func claudeNestedSubagentsAreListedFlatUnderTheSession() throws {
    // A subagent's own subagent fires the same hooks in the same session.
    let records = [prompt,
                   record("SubagentStart", at: 2, agent: "outer", type: "general-purpose"),
                   record("PreToolUse", at: 3, agent: "outer", type: "general-purpose", tool: "Agent", call: "spawn"),
                   record("SubagentStart", at: 4, agent: "inner", type: "Explore"),
                   record("PreToolUse", at: 5, agent: "inner", type: "Explore", tool: "Read", call: "r1",
                          input: ["file_path": "/tmp/lab/a.swift"])]
    let subagents = try #require(try running(records)?.subagents)
    #expect(subagents.map(\.name) == ["general-purpose", "Explore"])
    #expect(subagents.last?.latestAction?.text == "Read /tmp/lab/a.swift")
}

@Test func claudeSubagentToolCallLeavesTheSessionsOwnNowUnchanged() throws {
    let records = [prompt,
                   record("PreToolUse", at: 2, tool: "Bash", call: "own", input: ["command": "swift build"]),
                   record("SubagentStart", at: 3, agent: "a1", type: "Explore"),
                   record("PreToolUse", at: 4, agent: "a1", type: "Explore", tool: "Bash", call: "sub",
                          input: ["command": "rg foo"])]
    let row = try #require(try running(records))
    #expect(row.toolName == "Bash")
    #expect(row.toolInput["command"] == "swift build")
    #expect(row.subagents.first?.latestAction?.text == "$ rg foo")

    // The session's own call finishing leaves no "now"; the subagent's call never takes it over.
    let ownDone = records + [record("PostToolUse", at: 5, call: "own")]
    let after = try #require(try running(ownDone))
    #expect(after.toolName == nil)
    #expect(after.subagents.first?.latestAction?.text == "$ rg foo")

    // Without SubagentStart (pruned, or before Herdly started), the call is still kept off "now".
    let unknown = [prompt, record("PreToolUse", at: 4, agent: "a9", tool: "Bash", call: "sub", input: ["command": "ls"])]
    let unknownRow = try #require(try running(unknown))
    #expect(unknownRow.toolName == nil)
    #expect(unknownRow.subagents.isEmpty)
}

@Test func claudeSubagentCallsStillMatchTheirApproval() throws {
    let records = [prompt,
                   record("SubagentStart", at: 2, agent: "a1", type: "Explore"),
                   record("PreToolUse", at: 3, agent: "a1", type: "Explore", tool: "Bash", call: "sub",
                          input: ["command": "touch marker"]),
                   record("PermissionRequest", at: 3.5, agent: "a1", type: "Explore", tool: "Bash",
                          input: ["command": "touch marker"])]
    let root = try events(records)
    defer { try? FileManager.default.removeItem(at: root) }
    let approvals = ClaudeObservationReader.scan(events: root, sourceScope: root.path, installationID: "install", now: 10)
        .observations.compactMap { observation -> AgentApproval? in
            if case let .approval(value) = observation { return value }
            return nil
        }
    #expect(approvals.map(\.identity.call) == ["sub"])
}

@Test func claudeTurnOrSessionEndClearsEverySubagent() throws {
    let started = [prompt,
                   record("SubagentStart", at: 2, agent: "a1", type: "Explore"),
                   record("SubagentStart", at: 3, agent: "a2", type: "Plan"),
                   record("PreToolUse", at: 4, agent: "a1", type: "Explore", tool: "Bash", call: "t1",
                          input: ["command": "ls"])]
    #expect(try running(started)?.subagents.count == 2)
    #expect(try running(started + [record("Stop", at: 5)])?.subagents.isEmpty == true)
    #expect(try running(started + [record("StopFailure", at: 5)]) == nil)
    // After SessionEnd the turn shows no running row at all; a new prompt in the session starts with none.
    let resumed = started + [record("SessionEnd", at: 5, prompt: nil), record("UserPromptSubmit", at: 6, prompt: "p2")]
    #expect(try running(resumed)?.subagents.isEmpty == true)
}

@Test func claudeMalformedAgentIDIsIgnoredWithoutClearingOtherSubagents() throws {
    let oversized = String(repeating: "a", count: ClaudeObservationReader.maximumIdentifier + 1)
    let records = [prompt,
                   record("SubagentStart", at: 2, agent: "a1", type: "Explore"),
                   record("PreToolUse", at: 3, agent: "a1", type: "Explore", tool: "Bash", call: "t1",
                          input: ["command": "ls"]),
                   record("SubagentStart", at: 4, agent: oversized, type: "Plan"),
                   record("SubagentStart", at: 5, agent: 42, type: "Plan"),
                   record("SubagentStart", at: 6, agent: "bad\nid", type: "Plan"),
                   record("SubagentStop", at: 7, agent: oversized),
                   record("SubagentStop", at: 8, agent: ""),
                   record("PreToolUse", at: 9, agent: 42, tool: "Bash", call: "t2", input: ["command": "pwd"]),
                   record("SubagentStart", at: 9.5, agent: "a2", type: String(repeating: "x", count: 300))]
    let row = try #require(try running(records))
    #expect(row.subagents.map(\.id) == ["a1", "a2"])
    #expect(row.subagents.map(\.name) == ["Explore", "Subagent"])
    #expect(row.subagents.first?.latestAction?.text == "$ ls")
    // A call with a malformed agent id is still a subagent's, so it does not become the session's "now".
    #expect(row.toolName == nil)
}

@Test func claudeRecordsWithoutAgentIDKeepTodaysNow() throws {
    let records = [prompt,
                   record("PreToolUse", at: 2, tool: "Bash", call: "a", input: ["command": "first"]),
                   record("PreToolUse", at: 3, tool: "Read", call: "b", input: ["file_path": "/tmp/lab/b.txt"]),
                   record("PostToolUse", at: 4, call: "b")]
    let row = try #require(try running(records))
    #expect(row.toolName == "Bash")
    #expect(row.toolInput["command"] == "first")
    #expect(row.subagents.isEmpty)
    // A stale call falls back to the prompt as before.
    #expect(try running(records, now: 2 + ClaudeObservationReader.maximumToolFreshness + 1)?.toolName == nil)
}

@Test func claudeSubagentLatestActionFollowsTheSessionsFreshnessBound() throws {
    let records = [prompt,
                   record("SubagentStart", at: 2, agent: "a1", type: "Explore"),
                   record("PreToolUse", at: 3, agent: "a1", type: "Explore", tool: "Bash", call: "t1",
                          input: ["command": "sleep 100"])]
    let stale = try #require(try running(records, now: 3 + ClaudeObservationReader.maximumToolFreshness + 1))
    #expect(stale.subagents.map(\.id) == ["a1"])
    #expect(stale.subagents.first?.latestAction == nil)
}
