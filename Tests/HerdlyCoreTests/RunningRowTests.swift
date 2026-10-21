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
    let details = RunningRowDetails.make(running(tool: "Bash", input: ["command": "swift test --filter QueueRow"]), host: .ghostty)
    #expect(details.now == RunningRowDetails.Now(text: "$ swift test --filter QueueRow", full: nil,
                                                 disclosureTitle: nil, isUnknown: false))
}

@Test func aLongOrMultiLineCommandIsShortenedAndMarkedWithItsFullCommandBehindADisclosure() {
    let long = "swift test " + String(repeating: "--filter x ", count: 20)
    let details = RunningRowDetails.make(running(tool: "exec_command", input: ["cmd": long]), host: nil)
    #expect(details.now?.text.hasPrefix("$ swift test --filter x") == true)
    #expect(details.now?.text.hasSuffix("…") == true)
    #expect(details.now?.text.count == RunningRowDetails.lineLimit + "$ ".count + 1)
    #expect(details.now?.full == long)
    #expect(details.now?.disclosureTitle == "Show full command")

    let script = "cd Sources\nswift build"
    let multiLine = RunningRowDetails.make(running(tool: "Bash", input: ["command": script]), host: nil)
    #expect(multiLine.now?.text == "$ cd Sources…")
    #expect(multiLine.now?.full == script)
    #expect(multiLine.now?.disclosureTitle == "Show full command")
}

@Test func anotherToolReadsAsItsNameAndTarget() {
    let edit = RunningRowDetails.make(running(tool: "Edit", input: ["file_path": "/Users/u/code/herdly/NotchView.swift"]), host: nil)
    #expect(edit.now?.text == "Edit /Users/u/code/herdly/NotchView.swift")
    #expect(edit.now?.full == nil && edit.now?.disclosureTitle == nil)

    let deepPath = "/Users/u/" + String(repeating: "nested/", count: 30) + "file.swift"
    let deep = RunningRowDetails.make(running(tool: "Read", input: ["file_path": deepPath]), host: nil)
    #expect(deep.now?.text.hasSuffix("…") == true)
    #expect(deep.now?.full == "Read " + deepPath)
    #expect(deep.now?.disclosureTitle == "Show full action")

    // A tool Herdly has no reading for still names itself.
    let unknownTool = RunningRowDetails.make(running(tool: "WebFetch"), host: nil)
    #expect(unknownTool.now?.text == "WebFetch" && unknownTool.now?.isUnknown == false)
}

@Test func yourLastPromptIsShortenedWithItsFullTextBehindShowFullPrompt() {
    let short = RunningRowDetails.make(running(prompt: "  Fix the sort order  "), host: nil)
    #expect(short.you == RunningRowDetails.You(text: "Fix the sort order", full: nil, disclosureTitle: nil, keptOnlyStart: false))
    // No action yet: the "now" line is left out rather than repeating the prompt.
    #expect(short.now == nil)

    let prompt = "Make the running rows one line.\nOpening one shows now, you and where."
    let long = RunningRowDetails.make(running(prompt: prompt), host: nil)
    #expect(long.you?.text == "Make the running rows one line.…")
    #expect(long.you?.full == prompt)
    #expect(long.you?.disclosureTitle == "Show full prompt")
}

@Test func aPromptHerdlyKeptOnlyTheStartOfSaysSo() {
    let kept = RunningRowDetails.make(running(prompt: "Refactor the queue", promptShortened: true), host: nil)
    #expect(kept.you?.text == "Refactor the queue…")
    #expect(kept.you?.full == "Refactor the queue")
    #expect(kept.you?.disclosureTitle == "Show more of prompt")
    #expect(kept.you?.keptOnlyStart == true)
}

@Test func withNeitherAnActionNorAPromptNowReadsUnknown() {
    let details = RunningRowDetails.make(running(prompt: "   "), host: nil)
    #expect(details.now == RunningRowDetails.Now(text: "Unknown", full: nil, disclosureTitle: nil, isUnknown: true))
    #expect(details.you == nil)
    #expect(details.now?.text.isEmpty == false)
}

@Test func whereNamesTheSourceAndTheTerminalHerdlyLastSaw() {
    #expect(RunningRowDetails.make(running(codexCLI), host: .ghostty).place == "Codex CLI · Ghostty")
    #expect(RunningRowDetails.make(running(codexCLI), host: nil).place == "Codex CLI")
    #expect(RunningRowDetails.make(running(codexDesktop), host: nil).place == "Codex Desktop")
    #expect(RunningRowDetails.make(running(claude), host: .iTerm2).place == "Claude Code · iTerm2")
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
