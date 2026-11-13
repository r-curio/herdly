import Foundation
import SwiftUI
import Testing
@testable import HerdlyApp
@testable import HerdlyCore

private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude", session: "quiet-1", surface: .cli)
private let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "3f9a2c1e-0000-4000-8000-0000000000aa", surface: .cli)
private let t0: Double = 1_800_000_000

// MARK: The rule (#419)

@Test func aSessionBecomesQuietAtExactlyTenMinutesWithoutActivity() {
    #expect(!QuietRule.isQuiet(lastActivity: t0, now: t0 + 599))
    #expect(!QuietRule.isQuiet(lastActivity: t0, now: t0 + 599.999))
    #expect(QuietRule.isQuiet(lastActivity: t0, now: t0 + 600))
    #expect(QuietRule.isQuiet(lastActivity: t0, now: t0 + 3_600))
    #expect(QuietRule.quietAt(lastActivity: t0) == t0 + 600)
}

@Test func aSessionWithNoKnownActivityTimeIsNeverQuiet() {
    #expect(!QuietRule.isQuiet(lastActivity: nil, now: t0 + 86_400))
    #expect(QuietRule.quietAt(lastActivity: nil) == nil)
    #expect(!QuietRule.isQuiet(lastActivity: .nan, now: t0))
    #expect(!QuietRule.isQuiet(lastActivity: t0, now: .infinity))
}

@Test func aClockThatRunsBackwardsNeverMakesASessionQuiet() {
    #expect(!QuietRule.isQuiet(lastActivity: t0, now: t0 - 3_600))
}

// MARK: Rows in the queue

private func working(_ session: AgentSessionIdentity = claude, turn: String = "t1", arrivedAt: Double = t0 - 1_200,
                     updatedAt: Double? = nil, activityAt: Double?, subagents: [SubagentActivity] = []) -> AgentRunning {
    AgentRunning(session: session, turn: turn, arrivedAt: arrivedAt, updatedAt: updatedAt ?? activityAt,
                 subagents: subagents, activityAt: activityAt)
}

extension AgentAttentionItem {
    /// A working row on its own, as the queue would list it.
    fileprivate static func running(_ running: AgentRunning) throws -> AgentAttentionItem {
        var queue = AgentAttentionQueue()
        queue.apply(.running(running))
        return try #require(queue.items(at: running.arrivedAt).first { $0.id == .running(running.id) })
    }
}

private func runningRow(_ queue: AgentAttentionQueue, _ session: AgentSessionIdentity = claude, at now: Double) -> AgentAttentionItem? {
    queue.items(at: now).first { $0.session == session && $0.kind == .running }
}

@Test func aWorkingRowIsQuietFromTenMinutesAfterItsLatestActivityAndClearsOnTheNext() throws {
    var queue = AgentAttentionQueue()
    queue.apply(.running(working(activityAt: t0)), now: t0)
    let row = try #require(runningRow(queue, at: t0 + 599))
    #expect(!row.isQuiet(at: t0 + 599))
    #expect(row.isQuiet(at: t0 + 600))
    #expect(row.quietAt == t0 + 600)

    // The next tool event: quiet clears at once and the clock starts again.
    queue.apply(.running(working(activityAt: t0 + 900)), now: t0 + 900)
    let after = try #require(runningRow(queue, at: t0 + 900))
    #expect(!after.isQuiet(at: t0 + 900))
    #expect(!after.isQuiet(at: t0 + 1_499))
    #expect(after.isQuiet(at: t0 + 1_500))
}

@Test func aSubagentsActivityKeepsItsSessionFromGoingQuiet() throws {
    let explore = SubagentActivity(id: "a1", name: "Explore", startedAt: t0 + 60, lastActivityAt: t0 + 500)
    let row = try AgentAttentionItem.running(working(activityAt: t0, subagents: [explore]))
    #expect(row.running?.lastActivityAt == t0 + 500)
    #expect(!row.isQuiet(at: t0 + 1_099))
    #expect(row.isQuiet(at: t0 + 1_100))
    // A subagent the source gives no activity time adds nothing.
    let silent = SubagentActivity(id: "a2", name: "Plan", startedAt: t0 + 60)
    #expect(try AgentAttentionItem.running(working(activityAt: t0, subagents: [silent])).quietAt == t0 + 600)
}

@Test func aRowKnownOnlyFromAScanIsNeverQuiet() throws {
    var queue = AgentAttentionQueue()
    queue.apply(ClaudeInventoryScan(sourceScope: claude.sourceScope, observedAt: t0, sessions: [
        ClaudeInventorySession(sessionID: claude.session, kind: .interactive, startedAt: t0 - 7_200,
                               lifecycle: .interactive(status: "busy"), statusUpdatedAt: t0 - 7_200)
    ]), now: t0)
    let row = try #require(runningRow(queue, at: t0 + 86_400))
    #expect(row.running?.activityAt == nil)
    #expect(row.quietAt == nil)
    #expect(!row.isQuiet(at: t0 + 86_400))
}

@Test func aScanOrStatusChangeNeverResetsQuiet() throws {
    var queue = AgentAttentionQueue()
    queue.apply(.running(working(activityAt: t0)), now: t0)
    // Inventory keeps reporting the session busy, with a fresh status change, long after its last tool event.
    queue.apply(ClaudeInventoryScan(sourceScope: claude.sourceScope, observedAt: t0 + 700, sessions: [
        ClaudeInventorySession(sessionID: claude.session, kind: .interactive, startedAt: t0 - 7_200,
                               lifecycle: .interactive(status: "busy"), statusUpdatedAt: t0 + 690)
    ]), now: t0 + 700)
    let row = try #require(runningRow(queue, at: t0 + 700))
    #expect(row.isQuiet(at: t0 + 700))
}

@Test func aWaitingRowIsNeverQuiet() {
    let waiting = AgentRunning(session: claude, turn: "t1", arrivedAt: t0, status: .waiting, activityAt: t0)
    var queue = AgentAttentionQueue()
    queue.apply(.running(waiting), now: t0)
    let row = queue.items(at: t0 + 3_600).first { $0.session == claude }
    #expect(row?.kind == .waiting)
    #expect(row?.quietAt == nil)
    #expect(row?.isQuiet(at: t0 + 3_600) == false)
}

@Test func becomingQuietChangesNoRowCountOrOrderSoNothingSoundsOrSpotlights() {
    var queue = AgentAttentionQueue()
    queue.apply(.running(working(activityAt: t0)), now: t0)
    queue.apply(.running(working(codex, arrivedAt: t0 - 60, activityAt: t0 + 30)), now: t0 + 30)
    queue.apply(.outcome(AgentOutcome(session: AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude",
                                                                   session: "done-1", surface: .cli),
                                      turn: "t9", status: .finished, arrivedAt: t0 + 40)), now: t0 + 40)
    let before = queue.items(at: t0 + 599)
    let after = queue.items(at: t0 + 600)
    // The queue's rows, kinds and order are what sounds, spotlights and phone alerts read; quiet is not among them.
    #expect(before == after)
    #expect(after.first { $0.session == claude }?.isQuiet(at: t0 + 600) == true)
    #expect(queue.workingCount == 2)
    #expect(queue.toCheckCount(at: t0 + 600, earlier: .fiveMinutes) == queue.toCheckCount(at: t0 + 599, earlier: .fiveMinutes))
    #expect(AgentStripSummary.make(items: after, now: t0 + 600).toCheck == AgentStripSummary.make(items: before, now: t0 + 599).toCheck)
}

@Test func aQuietRowStaysInsideTheWorkingFold() throws {
    var queue = AgentAttentionQueue()
    queue.apply(.running(working(activityAt: t0)), now: t0)
    queue.apply(.approval(AgentApproval(session: codex, turn: "t2", call: "c1", arrivedAt: t0 + 590)), now: t0 + 590)
    let items = queue.items(at: t0 + 600)
    let quiet = try #require(items.first { $0.session == claude })
    #expect(quiet.isQuiet(at: t0 + 600))
    let sections = QueueSections.make(items, grouping: .none, project: { _ in nil }, kindSections: true)
    #expect(sections.foldsWorking)
    #expect(sections.workingCount == 1)
    #expect(sections.working.flatMap(\.items).map(\.id) == [quiet.id])
    #expect(!sections.selectableItems(workingOpen: false).contains { $0.id == quiet.id })
}

@Test func theNotchRedrawsOnlyAtTheMomentsARowBecomesQuiet() {
    let start = Date(timeIntervalSince1970: t0)
    func dates(_ schedule: QuietSchedule, _ count: Int = 5) -> [Double] {
        Array(schedule.entries(from: start, mode: .normal).prefix(count)).map(\.timeIntervalSince1970)
    }
    // The first draw, then each change still ahead; a change already passed, or no change, adds nothing.
    #expect(dates(QuietSchedule(changes: [t0 + 720, t0 - 60, t0 + 600])) == [t0, t0 + 600, t0 + 720])
    #expect(dates(QuietSchedule(changes: [])) == [t0])
    #expect(dates(QuietSchedule(changes: [t0 - 60])) == [t0])
    // The opened row's line: nothing until the row turns quiet, then every 30 s.
    #expect(dates(QuietSchedule(changes: [t0 + 600], every: 30)) == [t0, t0 + 600, t0 + 630, t0 + 660, t0 + 690])
    #expect(dates(QuietSchedule(changes: [t0 - 60], every: 30), 3) == [t0, t0 + 30, t0 + 60])
    #expect(dates(QuietSchedule(changes: [], every: 30)) == [t0])
}

// MARK: The opened row's line

@Test func theOpenedRowSaysHowLongSinceTheLastActivity() {
    let running = working(activityAt: t0)
    #expect(QuietLine.make(running, now: t0 + 599) == nil)
    let line = QuietLine.make(running, now: t0 + 14 * 60 + 20)
    #expect(line?.text == "14m since the last activity")
    #expect(line?.spoken == "14 minutes since the last activity")
    #expect(QuietLine.make(running, now: t0 + 2 * 3_600)?.text == "2h since the last activity")
}

@Test func whileACommandIsOpenTheLineCountsFromItsStart() {
    let running = AgentRunning(session: claude, turn: "t1", arrivedAt: t0 - 600, toolName: "Bash",
                               toolInput: ["command": "npm run test:e2e"], activityAt: t0,
                               openCall: OpenCall(name: "Bash", input: ["command": "npm run test:e2e"], startedAt: t0 - 240))
    #expect(QuietLine.make(running, now: t0 + 600)?.text == "14m since this command started")
    #expect(QuietLine.make(running, now: t0 + 600)?.spoken == "14 minutes since this command started")
}

@Test func withoutAShownCallStartTheLineFallsBackToTheLastActivity() {
    // A call the source reports without its start counts from the last activity.
    let unknownStart = AgentRunning(session: claude, turn: "t1", arrivedAt: t0 - 600, toolName: "Bash",
                                    toolInput: ["command": "npm test"], activityAt: t0)
    #expect(QuietLine.make(unknownStart, now: t0 + 840)?.text == "14m since the last activity")
}

@Test func aQuietRowStoppedOnAnyOpenCallCountsFromThatCallsStart() {
    // Not only a shell command: any unfinished call (owner decision on #419) is "this command".
    let read = AgentRunning(session: claude, turn: "t1", arrivedAt: t0 - 600, activityAt: t0 - 240,
                            openCall: OpenCall(name: "Read", input: ["file_path": "/tmp/a.swift"], startedAt: t0 - 240))
    #expect(read.shownCall(at: t0 + 600) == ShownCall(name: "Read", input: ["file_path": "/tmp/a.swift"], startedAt: t0 - 240))
    #expect(QuietLine.make(read, now: t0 + 600)?.text == "14m since this command started")
}

@Test func aSubagentActiveAfterTheCallStartedDelaysQuietButTheLineStillCountsFromTheCall() {
    let explore = SubagentActivity(id: "a1", name: "Explore", startedAt: t0 - 300, lastActivityAt: t0)
    let row = AgentRunning(session: claude, turn: "t1", arrivedAt: t0 - 600, subagents: [explore], activityAt: t0 - 240,
                           openCall: OpenCall(name: "WebFetch", input: [:], startedAt: t0 - 240))
    #expect(QuietLine.make(row, now: t0 + 599) == nil)
    #expect(QuietLine.make(row, now: t0 + 600)?.text == "14m since this command started")
}

// MARK: The strip

@Test func aQuietSessionsSpriteStandsStillInTheStripAndTheSteppingSpriteSkipsIt() {
    let other = AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude", session: "busy-2", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.running(working(arrivedAt: t0 - 1_200, activityAt: t0)), now: t0)
    queue.apply(.running(working(other, arrivedAt: t0 - 600, activityAt: t0 + 590)), now: t0 + 590)
    let items = queue.items(at: t0 + 600)

    let summary = AgentStripSummary.make(items: items, now: t0 + 600)
    #expect(summary.working)
    #expect(summary.sessions.map(\.session) == [claude, other])
    #expect(summary.sessions.map(\.state) == [.quiet, .stepping])
    #expect(summary.sessions.map(\.stepping) == [false, true])
    #expect(summary.busy?.session == other)
    // Open, the wing's one sprite is the first session that still steps.
    let open = StripWing.make(summary: summary, leftWing: .spritesAndCount, expanded: true)
    #expect(open.sprites == [.session(summary.sessions[1])])

    // A minute earlier neither is quiet, and the first working session steps as before.
    #expect(AgentStripSummary.make(items: items, now: t0 + 599).busy?.session == claude)
}

@Test func whenEveryWorkingSessionIsQuietNothingInTheStripSteps() {
    var queue = AgentAttentionQueue()
    queue.apply(.running(working(activityAt: t0)), now: t0)
    let summary = AgentStripSummary.make(items: queue.items(at: t0 + 600), now: t0 + 600)
    #expect(summary.working)
    #expect(summary.busy == nil)
    #expect(summary.sessions.allSatisfy { !$0.stepping })
    // Open, the top session's standing sprite; count only, no stepping sprite.
    #expect(StripWing.make(summary: summary, leftWing: .spritesAndCount, expanded: true).sprites == [.session(summary.sessions[0])])
    #expect(StripWing.make(summary: summary, leftWing: .countOnly, expanded: false).sprites.isEmpty)
}
