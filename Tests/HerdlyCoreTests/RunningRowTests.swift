import Foundation
import Testing
@testable import HerdlyCore

private let codexCLI = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "3f9a2c1e-0000-4000-8000-000000000001", surface: .cli)
private let codexDesktop = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "3f9a2c1e-0000-4000-8000-000000000002", surface: .desktop)
private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude", session: "abcdef12-3456", surface: .cli)

private func runningID(_ session: AgentSessionIdentity, _ turn: String = "t1") -> AgentAttentionID {
    .running(AgentTurnIdentity(session: session, turn: turn))
}

// MARK: One open running row (#319)

/// Queue rows: a working Codex CLI turn, a working Claude turn, a waiting Claude turn, an approval
/// and a result, in that order.
private func rows() -> [AgentAttentionItem] {
    let waitingClaude = AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude", session: "waiting-1", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: codexCLI, turn: "t1", arrivedAt: 1)))
    queue.apply(.running(AgentRunning(session: claude, turn: "t1", arrivedAt: 2)))
    queue.apply(.running(AgentRunning(session: waitingClaude, turn: "t1", arrivedAt: 3, status: .waiting)))
    queue.apply(.approval(AgentApproval(session: codexDesktop, turn: "t2", call: "a1", arrivedAt: 4)))
    queue.apply(.outcome(AgentOutcome(session: codexDesktop, turn: "t3", status: .finished, arrivedAt: 5)))
    return queue.items(at: 6)
}

private func row(_ kind: AgentAttentionKind, _ session: AgentSessionIdentity? = nil) -> AgentAttentionItem {
    rows().first { $0.kind == kind && (session == nil || $0.session == session) }!
}

@Test func clickingARunningRowOpensItAndASecondClickClosesIt() {
    var open = OpenRunningRow()
    #expect(open.open == nil)
    open.toggle(row(.running, codexCLI))
    #expect(open.open == runningID(codexCLI))
    #expect(open.isOpen(runningID(codexCLI)))
    open.toggle(row(.running, codexCLI))
    #expect(open.open == nil)
}

@Test func clickingAnotherRunningRowMovesTheOpenState() {
    var open = OpenRunningRow()
    open.toggle(row(.running, codexCLI))
    open.toggle(row(.running, claude))
    #expect(open.open == runningID(claude))
    #expect(!open.isOpen(runningID(codexCLI)))
}

@Test func onlyWorkingRowsOpenInPlace() {
    var open = OpenRunningRow()
    open.toggle(row(.running, codexCLI))
    // A waiting Claude turn keeps its body, an approval opens as its own card, and a result keeps
    // its body; none of them moves or closes the open row.
    open.toggle(row(.waiting))
    open.toggle(row(.actionableApproval))
    open.toggle(row(.outcome))
    #expect(open.open == runningID(codexCLI))
}

@Test func escapeClosesAnOpenRowFirstAndOnlyThenFallsThrough() {
    var open = OpenRunningRow()
    open.toggle(row(.running, codexCLI))
    let closedRow = open.escape()
    #expect(closedRow)
    #expect(open.open == nil)
    // Nothing open: Escape is not handled here, so the panel collapses.
    let handled = open.escape()
    #expect(!handled)
}

@Test func theOpenRowClosesWhenItLeavesTheVisibleRows() {
    var open = OpenRunningRow()
    open.toggle(row(.running, codexCLI))
    open.reconcile(visible: rows())
    #expect(open.open == runningID(codexCLI))
    // Its turn ended, or the "N working" fold closed over it.
    open.reconcile(visible: rows().filter { $0.session != codexCLI })
    #expect(open.open == nil)
}

@Test func theOpenRowClosesWhenItsTurnStopsWorking() {
    var open = OpenRunningRow()
    open.toggle(row(.running, claude))
    // The same turn now waits on the user: same id, but no longer a one-line working row.
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: claude, turn: "t1", arrivedAt: 2, updatedAt: 9, status: .waiting)))
    open.reconcile(visible: queue.items(at: 10))
    #expect(open.open == nil)
}

@Test func closeClearsTheOpenRow() {
    var open = OpenRunningRow()
    open.toggle(row(.running, codexCLI))
    open.close()
    #expect(open == OpenRunningRow())
}

// MARK: Open row details: now, you, where (#319, F3)

private func running(_ session: AgentSessionIdentity = codexCLI, prompt: String? = nil, promptShortened: Bool = false,
                     tool: String? = nil, input: [String: String] = [:]) -> AgentRunning {
    AgentRunning(session: session, turn: "t1", arrivedAt: 1, prompt: prompt, promptShortened: promptShortened,
                 toolName: tool, toolInput: input)
}

@Test func aShellCommandReadsAsDollarAndTheCommandInFull() {
    let details = RunningRowDetails.make(running(tool: "Bash", input: ["command": "swift test --filter QueueRow"]), host: .ghostty, now: 0)
    #expect(details.now == RunningRowDetails.Now(text: "$ swift test --filter QueueRow", full: nil,
                                                 disclosureTitle: nil, isUnknown: false))
}

@Test func aLongOrMultiLineCommandIsShortenedAndMarkedWithItsFullCommandBehindADisclosure() {
    let long = "swift test " + String(repeating: "--filter x ", count: 20)
    let details = RunningRowDetails.make(running(tool: "exec_command", input: ["cmd": long]), host: nil, now: 0)
    #expect(details.now?.text.hasPrefix("$ swift test --filter x") == true)
    #expect(details.now?.text.hasSuffix("…") == true)
    #expect(details.now?.text.count == RunningRowDetails.lineLimit + "$ ".count + 1)
    #expect(details.now?.full == long)
    #expect(details.now?.disclosureTitle == "Show full command")

    let script = "cd Sources\nswift build"
    let multiLine = RunningRowDetails.make(running(tool: "Bash", input: ["command": script]), host: nil, now: 0)
    #expect(multiLine.now?.text == "$ cd Sources…")
    #expect(multiLine.now?.full == script)
    #expect(multiLine.now?.disclosureTitle == "Show full command")
}

@Test func anotherToolReadsAsItsNameAndTarget() {
    let edit = RunningRowDetails.make(running(tool: "Edit", input: ["file_path": "/Users/u/code/herdly/NotchView.swift"]), host: nil, now: 0)
    #expect(edit.now?.text == "Edit /Users/u/code/herdly/NotchView.swift")
    #expect(edit.now?.full == nil && edit.now?.disclosureTitle == nil)

    let deepPath = "/Users/u/" + String(repeating: "nested/", count: 30) + "file.swift"
    let deep = RunningRowDetails.make(running(tool: "Read", input: ["file_path": deepPath]), host: nil, now: 0)
    #expect(deep.now?.text.hasSuffix("…") == true)
    #expect(deep.now?.full == "Read " + deepPath)
    #expect(deep.now?.disclosureTitle == "Show full action")

    // A tool Herdly has no reading for still names itself.
    let unknownTool = RunningRowDetails.make(running(tool: "WebFetch"), host: nil, now: 0)
    #expect(unknownTool.now?.text == "WebFetch" && unknownTool.now?.isUnknown == false)
}

@Test func yourLastPromptIsShortenedWithItsFullTextBehindShowFullPrompt() {
    let short = RunningRowDetails.make(running(prompt: "  Fix the sort order  "), host: nil, now: 0)
    #expect(short.you == RunningRowDetails.You(text: "Fix the sort order", full: nil, disclosureTitle: nil, keptOnlyStart: false))
    // No action yet: the "now" line is left out rather than repeating the prompt.
    #expect(short.now == nil)

    let prompt = "Make the running rows one line.\nOpening one shows now, you and where."
    let long = RunningRowDetails.make(running(prompt: prompt), host: nil, now: 0)
    #expect(long.you?.text == "Make the running rows one line.…")
    #expect(long.you?.full == prompt)
    #expect(long.you?.disclosureTitle == "Show full prompt")
}

@Test func aPromptHerdlyKeptOnlyTheStartOfSaysSo() {
    let kept = RunningRowDetails.make(running(prompt: "Refactor the queue", promptShortened: true), host: nil, now: 0)
    #expect(kept.you?.text == "Refactor the queue…")
    #expect(kept.you?.full == "Refactor the queue")
    #expect(kept.you?.disclosureTitle == "Show more of prompt")
    #expect(kept.you?.keptOnlyStart == true)
}

@Test func withNeitherAnActionNorAPromptNowReadsUnknown() {
    let details = RunningRowDetails.make(running(prompt: "   "), host: nil, now: 0)
    #expect(details.now == RunningRowDetails.Now(text: "Unknown", full: nil, disclosureTitle: nil, isUnknown: true))
    #expect(details.you == nil)
    #expect(details.now?.text.isEmpty == false)
}

@Test func whereNamesTheSourceAndTheTerminalHerdlyLastSaw() {
    #expect(RunningRowDetails.make(running(codexCLI), host: .ghostty, now: 0).place == "Codex CLI · Ghostty")
    #expect(RunningRowDetails.make(running(codexCLI), host: nil, now: 0).place == "Codex CLI")
    #expect(RunningRowDetails.make(running(codexDesktop), host: nil, now: 0).place == "Codex Desktop")
    #expect(RunningRowDetails.make(running(claude), host: .iTerm2, now: 0).place == "Claude Code · iTerm2")
}

@Test func toggleReportsWhetherTheRowOpensInPlace() {
    var open = OpenRunningRow()
    let opened = open.toggle(row(.running, codexCLI))
    let closed = open.toggle(row(.running, codexCLI))
    let waiting = open.toggle(row(.waiting))
    let approval = open.toggle(row(.actionableApproval))
    #expect(opened && closed)
    #expect(!waiting && !approval)
    #expect(open.open == nil)
}

@Test func sourceLabelNamesTheAgentSurface() {
    #expect(codexCLI.sourceLabel == "Codex CLI")
    #expect(codexDesktop.sourceLabel == "Codex Desktop")
    #expect(claude.sourceLabel == "Claude Code")
    let claudeDesktop = AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude", session: "d1", surface: .desktop)
    #expect(claudeDesktop.sourceLabel == "Claude Code")
}

@Test func agentSourceDisplayNameIsTheShortAgentName() {
    #expect(AgentSource.codex.displayName == "Codex")
    #expect(AgentSource.claude.displayName == "Claude")
}

// MARK: Subagent switcher in the opened row (#397, Paper H2 "E · Switcher")

private let explore = SubagentActivity(id: "agent-a", name: "Explore", startedAt: 10,
                                       latestAction: RunningRowDetails.now(toolName: "Grep", toolInput: ["pattern": "closes #27"]))
private let plan = SubagentActivity(id: "agent-b", name: "Plan", startedAt: 20)

/// The Claude row from `rows()`, working with the given running subagents.
private func claudeRow(subagents: [SubagentActivity]) -> AgentAttentionItem {
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: claude, turn: "t1", arrivedAt: 2, subagents: subagents)))
    return queue.items(at: 6).first { $0.kind == .running }!
}

@Test func theSessionIsShownEachTimeARowOpens() {
    let row = claudeRow(subagents: [explore, plan])
    var open = OpenRunningRow()
    open.toggle(row)
    #expect(open.shown == .session)
    #expect(open.shownSubagent(in: row) == nil)
}

@Test func selectingARunningSubagentShowsItsLines() {
    let row = claudeRow(subagents: [explore, plan])
    var open = OpenRunningRow()
    open.toggle(row)
    let r1 = open.select(.subagent("agent-b"), in: row)
    #expect(r1)
    #expect(open.shown == .subagent("agent-b"))
    #expect(open.shownSubagent(in: row) == plan)
    let r2 = open.select(.session, in: row)
    #expect(r2)
    #expect(open.shown == .session)
}

@Test func selectingAnUnknownSubagentOrInAClosedRowIsIgnored() {
    let row = claudeRow(subagents: [explore])
    var open = OpenRunningRow()
    // Nothing open yet: no selection to make.
    let r3 = open.select(.subagent("agent-a"), in: row)
    #expect(!r3)
    #expect(open.shown == .session)
    open.toggle(row)
    let r4 = open.select(.subagent("agent-z"), in: row)
    #expect(!r4)
    #expect(open.shown == .session)
    // A row other than the open one does not take the selection.
    let r5 = open.select(.subagent("agent-a"), in: rows().first { $0.session == codexCLI }!)
    #expect(!r5)
    #expect(open.shown == .session)
}

@Test func aShownSubagentThatEndsReturnsTheSelectionToTheSession() {
    let row = claudeRow(subagents: [explore, plan])
    var open = OpenRunningRow()
    open.toggle(row)
    open.select(.subagent("agent-a"), in: row)
    let after = claudeRow(subagents: [plan])
    // Read at once from the current subagents, before any reconcile runs.
    #expect(open.shownSubagent(in: after) == nil)
    open.reconcile(visible: [after])
    #expect(open.open == row.id)
    #expect(open.shown == .session)
}

@Test func anotherSubagentEndingKeepsTheSelection() {
    let row = claudeRow(subagents: [explore, plan])
    var open = OpenRunningRow()
    open.toggle(row)
    open.select(.subagent("agent-b"), in: row)
    open.reconcile(visible: [claudeRow(subagents: [plan])])
    #expect(open.shown == .subagent("agent-b"))
}

@Test func closingAndReopeningTheRowShowsTheSessionAgain() {
    let row = claudeRow(subagents: [explore])
    var open = OpenRunningRow()
    open.toggle(row)
    open.select(.subagent("agent-a"), in: row)
    open.toggle(row)
    open.toggle(row)
    #expect(open.shown == .session)
    open.select(.subagent("agent-a"), in: row)
    let r6 = open.escape()
    #expect(r6)
    open.toggle(row)
    #expect(open.shown == .session)
    open.select(.subagent("agent-a"), in: row)
    open.close()
    #expect(open.shown == .session)
}

@Test func movingTheOpenStateToAnotherRowShowsItsSession() {
    let row = claudeRow(subagents: [explore])
    var open = OpenRunningRow()
    open.toggle(row)
    open.select(.subagent("agent-a"), in: row)
    open.toggle(rows().first { $0.session == codexCLI }!)
    #expect(open.shown == .session)
}

@Test func aSubagentsLinesAreNowAskedRoleAndFor() {
    let codex = SubagentActivity(id: "c1", name: "Ptolemy", role: "explorer", asked: "Find every workflow that closes issues",
                                 startedAt: 1_000, latestAction: RunningRowDetails.now(toolName: "Bash", toolInput: ["command": "ls"]))
    let details = SubagentDetails.make(codex, now: 1_000 + 125)
    #expect(details.now.text == "$ ls")
    #expect(!details.now.isUnknown)
    #expect(details.asked?.text == "Find every workflow that closes issues")
    #expect(details.asked?.full == nil)
    #expect(details.role == "explorer")
    #expect(details.age == "2m")
}

@Test func aSubagentWithNothingKnownReadsUnknownAndLeavesTheRestOut() {
    let details = SubagentDetails.make(SubagentActivity(id: "a", name: "Explore", role: " ", asked: "  ", startedAt: 50), now: 60)
    #expect(details.now.text == "Unknown")
    #expect(details.now.isUnknown)
    #expect(details.asked == nil)
    #expect(details.role == nil)
    #expect(details.age == "<1m")
}

@Test func aLongTaskIsShortenedWithItsFullTextBehindADisclosure() {
    let task = String(repeating: "a", count: RunningRowDetails.lineLimit + 5)
    let details = SubagentDetails.make(SubagentActivity(id: "a", name: "x", asked: task + "\nmore", startedAt: 0), now: 0)
    #expect(details.asked?.text == String(repeating: "a", count: RunningRowDetails.lineLimit) + "…")
    #expect(details.asked?.full == task + "\nmore")
    #expect(details.asked?.disclosureTitle == "Show full task")
}

// MARK: Keyboard focus when a switcher well's subagent finishes (#397, review round 1)

@Test func focusOnAFinishedSubagentsWellMovesToSessionWhileWellsRemain() {
    let next = OpenRunningRow.focusAfterSubagentsChange(lastFocused: .subagent("agent-a"), running: ["agent-b"])
    #expect(next == .well(.session))
}

@Test func focusOnTheLastSubagentsWellMovesToOpenWhenTheSwitcherLeaves() {
    let next = OpenRunningRow.focusAfterSubagentsChange(lastFocused: .subagent("agent-a"), running: [])
    #expect(next == .open)
}

@Test func focusOnSessionOrAStillRunningSubagentOrNowhereIsLeftAlone() {
    #expect(OpenRunningRow.focusAfterSubagentsChange(lastFocused: .subagent("agent-b"), running: ["agent-b"]) == nil)
    #expect(OpenRunningRow.focusAfterSubagentsChange(lastFocused: .session, running: []) == nil)
    #expect(OpenRunningRow.focusAfterSubagentsChange(lastFocused: nil, running: []) == nil)
}

@Test func aWellLosingFocusBecauseItsSubagentLeftIsStillRemembered() {
    // SwiftUI may clear the focus binding before the subagent list change is seen.
    #expect(OpenRunningRow.rememberedFocus(previous: .subagent("agent-a"), now: nil, running: ["agent-b"]) == .subagent("agent-a"))
}

@Test func focusTheUserMovedElsewhereIsForgotten() {
    // Its subagent still runs, so the well lost focus because the user moved it.
    #expect(OpenRunningRow.rememberedFocus(previous: .subagent("agent-a"), now: nil, running: ["agent-a"]) == nil)
    #expect(OpenRunningRow.rememberedFocus(previous: .session, now: nil, running: []) == nil)
    #expect(OpenRunningRow.rememberedFocus(previous: .session, now: .subagent("agent-a"), running: ["agent-a"]) == .subagent("agent-a"))
}
