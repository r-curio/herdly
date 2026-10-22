import Foundation
import Testing
@testable import HerdlyCore

private func session(_ name: String, _ source: AgentSource = .codex) -> AgentSessionIdentity {
    AgentSessionIdentity(source: source, sourceScope: source.rawValue, session: name, surface: .cli)
}

// MARK: Approval order (D12)

@Test(arguments: QueueSort.allCases)
func liveApprovalsLeadTheOpenQueueBySoonestDeadline(sort: QueueSort) {
    var queue = AgentAttentionQueue()
    // Arrival order a, b, c; deadline order c, a, b.
    queue.apply(.approval(AgentApproval(session: session("a"), turn: "t1", call: "a1", arrivedAt: 10, expiresAt: 50)))
    queue.apply(.approval(AgentApproval(session: session("b"), turn: "t2", call: "b1", arrivedAt: 11, expiresAt: 60)))
    queue.apply(.approval(AgentApproval(session: session("c"), turn: "t3", call: "c1", arrivedAt: 12, expiresAt: 40)))
    queue.apply(.question(AgentQuestion(session: session("q"), turn: "t4", call: "q1", arrivedAt: 1)))
    queue.apply(.outcome(AgentOutcome(session: session("done"), turn: "t5", status: .finished, arrivedAt: 2)))

    let rows = queue.items(at: 20, sort: sort).map(\.session.session)
    #expect(rows == ["c", "a", "b", "q", "done"])
}

@Test(arguments: QueueSort.allCases)
func aMergedApprovalSortsByItsSoonestDeadline(sort: QueueSort) {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: session("first"), turn: "t1", call: "a1", arrivedAt: 10, expiresAt: 40)))
    queue.apply(.approval(AgentApproval(session: session("merged"), turn: "t2", call: "m1", arrivedAt: 11, expiresAt: 70)))
    // The same request seen again with an earlier deadline: the merged request keeps min(expiresAt).
    queue.apply(.approval(AgentApproval(session: session("merged"), turn: "t2", call: "m1", arrivedAt: 12, expiresAt: 35)))

    #expect(queue.items(at: 20, sort: sort).map(\.session.session) == ["merged", "first"])
}

@Test func equalDeadlinesFallBackToArrivalThenIdentity() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: session("late"), turn: "t1", call: "a1", arrivedAt: 12, expiresAt: 40)))
    queue.apply(.approval(AgentApproval(session: session("y"), turn: "t2", call: "a1", arrivedAt: 10, expiresAt: 40)))
    queue.apply(.approval(AgentApproval(session: session("x"), turn: "t3", call: "a1", arrivedAt: 10, expiresAt: 40)))

    #expect(queue.items(at: 20).map(\.session.session) == ["x", "y", "late"])
}

@Test func deadlineOrderIsTheQueuePriorityButNotWhatIsSpotlitOnArrival() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: session("old"), turn: "t1", call: "a1", arrivedAt: 10, expiresAt: 50)))
    queue.apply(.approval(AgentApproval(session: session("soon"), turn: "t2", call: "a1", arrivedAt: 11, expiresAt: 30)))

    // D12 changes the priority order itself, so the strip and every reader of it follow it.
    let rows = queue.items(at: 20)
    #expect(rows.map(\.session.session) == ["soon", "old"])
    // Two requests fresh in the same scan: the spotlight still opens the one that arrived first.
    #expect(AgentPresentationSelection.highestPriority(in: rows, candidates: Set(rows.map(\.id))) == rows[1].id)
    // Only one of them fresh: that one, whatever its place.
    #expect(AgentPresentationSelection.highestPriority(in: rows, candidates: [rows[0].id]) == rows[0].id)
    // An expired request is handed back and leaves the live group, whatever its deadline was.
    #expect(queue.items(at: 35).map(\.kind) == [.actionableApproval, .handedBackApproval])
    // Deadlines and counts are untouched.
    #expect(queue.items(at: 20).compactMap(\.approval?.expiresAt) == [30, 50])
    #expect(queue.toCheckCount == 2)
}

// MARK: Kind sections (D13)

/// A queue with `approvals` live approvals, `questions` waiting questions, `results` finished results,
/// and `running` working rows, each in its own session.
private func queue(approvals: Int = 0, questions: Int = 0, results: Int = 0, running: Int = 0) -> [AgentAttentionItem] {
    var queue = AgentAttentionQueue()
    for index in 0..<approvals {
        queue.apply(.approval(AgentApproval(session: session("approve-\(index)"), turn: "t", call: "a",
                                            arrivedAt: Double(index), expiresAt: 100 + Double(index))))
    }
    for index in 0..<questions {
        queue.apply(.question(AgentQuestion(session: session("answer-\(index)"), turn: "t", call: "q", arrivedAt: Double(index))))
    }
    for index in 0..<results {
        queue.apply(.outcome(AgentOutcome(session: session("check-\(index)"), turn: "t", status: .finished, arrivedAt: 50 + Double(index))))
    }
    for index in 0..<running {
        queue.apply(.running(AgentRunning(session: session("run-\(index)"), turn: "t", arrivedAt: Double(index))))
    }
    return queue.items(at: 60)
}

private func kindSections(_ items: [AgentAttentionItem], open: Set<QueueKindSection> = []) -> QueueSections {
    QueueSections.make(items, grouping: .none, project: { _ in nil }, kindSections: true, openSections: open)
}

@Test func rowsThatNeedTheUserSitUnderApproveAnswerAndCheck() {
    var raw = AgentAttentionQueue()
    raw.apply(.approval(AgentApproval(session: session("live"), turn: "t", call: "a", arrivedAt: 1)))
    raw.apply(.approval(AgentApproval(session: session("handed"), turn: "t", call: "a", arrivedAt: 0, expiresAt: 5)))
    raw.apply(.question(AgentQuestion(session: session("asked"), turn: "t", call: "q", arrivedAt: 2)))
    raw.apply(.outcome(AgentOutcome(session: session("done"), turn: "t", status: .failed, arrivedAt: 3)))
    raw.apply(.running(AgentRunning(session: session("idle", .claude), turn: "t", arrivedAt: 4, status: .waiting)))
    raw.apply(.running(AgentRunning(session: session("busy"), turn: "t", arrivedAt: 5)))
    let sections = kindSections(raw.items(at: 10))

    #expect(sections.attention.map(\.heading) == ["Approve", "Answer", "Check"])
    #expect(sections.attention.map(\.section) == [.approve, .answer, .check])
    #expect(sections.attention.map(\.count) == [1, 1, 3])
    #expect(sections.attention[2].items.map(\.session.session) == ["handed", "idle", "done"])
    // Running rows keep their "N working" fold, with no heading of their own.
    #expect(sections.foldsWorking && sections.workingCount == 1)
    #expect(sections.working.map(\.heading) == [nil])
}

@Test func anEmptySectionAndItsHeadingDisappear() {
    let sections = kindSections(queue(approvals: 1, results: 2))
    #expect(sections.attention.map(\.heading) == ["Approve", "Check"])

}

@Test func onlyRunningWorkSitsUnderAWorkingHeadingWithItsCount() {
    // F1 (#319): with nothing needing the user, the working rows are the queue, under "Working 4".
    let working = kindSections(queue(running: 4))
    #expect(working.attention.isEmpty && !working.foldsWorking)
    #expect(working.working.map(\.heading) == ["Working"])
    #expect(working.working.map(\.section) == [.working])
    #expect(working.working.map(\.count) == [4])
    // It never folds: every working row is on screen and selectable.
    #expect(working.working[0].folded == 0)
    #expect(working.selectableRows(workingOpen: false).count == 4)
    #expect(working.working[0].items.map(\.session.session) == ["run-0", "run-1", "run-2", "run-3"])
}

@Test func theWorkingFoldAndOtherGroupingsKeepNoWorkingSection() {
    // F2: behind the "N working" fold the rows carry no heading; the fold names them.
    let folded = kindSections(queue(results: 1, running: 2))
    #expect(folded.foldsWorking && folded.working.map(\.heading) == [nil])
    // A card, or a grouped queue, keeps its own headings.
    let card = QueueSections.make(queue(running: 1), grouping: .none, project: { _ in nil })
    #expect(card.working.map(\.heading) == [nil] && card.working.map(\.section) == [nil])
    let byAgent = QueueSections.make(queue(running: 2), grouping: .agent, project: { _ in nil }, kindSections: true)
    #expect(byAgent.working.map(\.heading) == ["Codex"] && byAgent.working.map(\.section) == [nil])
}

@Test func otherGroupingsAndCardsKeepTheirOwnHeadings() {
    let items = queue(approvals: 1, questions: 5, results: 14, running: 1)
    let byState = QueueSections.make(items, grouping: .state, project: { _ in nil }, kindSections: true)
    #expect(byState.attention.map(\.heading) == ["Needs you", "Done"])
    #expect(byState.attention.allSatisfy { $0.folded == 0 })
    // A spotlight or clicked card is one row with no heading.
    let card = QueueSections.make(Array(items.prefix(1)), grouping: .none, project: { _ in nil })
    #expect(card.attention.map(\.heading) == [nil])
}

// MARK: "+N more" fold (D13)

@Test func theCalmerGlanceArtboardFitsWithoutFolding() {
    // 5ZV-0: Approve 2, Answer 3, Check 5 is ten rows, inside the eleven-line budget.
    let sections = kindSections(queue(approvals: 2, questions: 3, results: 5))
    #expect(sections.attention.map(\.items.count) == [2, 3, 5])
    #expect(sections.attention.map(\.folded) == [0, 0, 0])
}

@Test func theThirtyFiveThingsArtboardFoldsAnswerAndCheck() {
    // 4C9-0: 4 approvals, 8 questions, 14 results.
    let sections = kindSections(queue(approvals: 4, questions: 8, results: 14, running: 9))
    #expect(sections.attention.map(\.heading) == ["Approve", "Answer", "Check"])
    #expect(sections.attention.map(\.count) == [4, 8, 14])
    #expect(sections.attention.map(\.items.count) == [4, 3, 2])
    #expect(sections.attention.map(\.folded) == [0, 5, 12])
    // The rows shown are each section's first rows, in queue order.
    #expect(sections.attention[1].items.map(\.session.session) == ["answer-0", "answer-1", "answer-2"])
}

@Test func foldAllocationFollowsTheElevenLineBudget() {
    // Everything fits: nothing folds, even a section longer than three rows.
    #expect(QueueFold.shownRows(approvals: 0, sections: [5, 6]) == [5, 6])
    #expect(QueueFold.shownRows(approvals: 4, sections: [3, 4]) == [3, 4])
    // One row too many: the earlier section folds to three, the last takes what is left.
    #expect(QueueFold.shownRows(approvals: 4, sections: [8, 14]) == [3, 2])
    #expect(QueueFold.shownRows(approvals: 0, sections: [12]) == [10])
    // A section never folds a single row: it shows that row instead.
    #expect(QueueFold.shownRows(approvals: 0, sections: [4, 9]) == [4, 6])
    // Two lines left for three rows: one row and its "+2 more".
    #expect(QueueFold.shownRows(approvals: 9, sections: [3]) == [1])
    // Live approvals never fold, however many there are; every later section keeps one row.
    #expect(QueueFold.shownRows(approvals: 20, sections: [8, 14]) == [1, 1])
    #expect(QueueFold.shownRows(approvals: 20, sections: [2, 1]) == [2, 1])
    #expect(QueueFold.shownRows(approvals: 11, sections: [1, 3]) == [1, 1])
    #expect(QueueFold.shownRows(approvals: 0, sections: []) == [])
}

@Test func approvalsNeverFold() {
    let sections = kindSections(queue(approvals: 15, questions: 4, results: 4))
    #expect(sections.attention.map(\.items.count) == [15, 1, 1])
    #expect(sections.attention.map(\.folded) == [0, 3, 3])
}

@Test func anOpenedFoldShowsTheRestOfThatSectionOnly() {
    let items = queue(approvals: 4, questions: 8, results: 14)
    let opened = kindSections(items, open: [.answer])
    #expect(opened.attention.map(\.items.count) == [4, 8, 2])
    #expect(opened.attention.map(\.folded) == [0, 0, 12])
}

@Test func keyboardSelectionSkipsFoldedRows() {
    let items = queue(approvals: 4, questions: 8, results: 14, running: 1)
    let sections = kindSections(items)
    let rows = sections.selectableRows(workingOpen: false)
    #expect(rows.count == 4 + 3 + 2)
    #expect(rows == sections.attention.flatMap(\.items).map(\.id))
    let folded = Set(items.map(\.id)).subtracting(rows)
    #expect(folded.count == 5 + 12 + 1)

    var selection = QueueRowSelection(selected: items.first { $0.session.session == "answer-6" }?.id)
    selection.reconcile(rows: rows)
    #expect(selection.selected == nil)
}

// MARK: Earlier inside a folded section

/// `fresh` current results then `earlier` results that moved under Earlier, after 4 approvals and
/// 8 questions, so Check folds to two rows.
private func foldedCheck(fresh: Int, earlier: Int) -> QueueSections {
    var queue = AgentAttentionQueue()
    for index in 0..<4 {
        queue.apply(.approval(AgentApproval(session: session("approve-\(index)"), turn: "t", call: "a", arrivedAt: 1_000)))
    }
    for index in 0..<8 {
        queue.apply(.question(AgentQuestion(session: session("answer-\(index)"), turn: "t", call: "q", arrivedAt: 1_000)))
    }
    for index in 0..<earlier {
        queue.apply(.outcome(AgentOutcome(session: session("old-\(index)"), turn: "t", status: .finished, arrivedAt: Double(index))))
    }
    for index in 0..<fresh {
        queue.apply(.outcome(AgentOutcome(session: session("new-\(index)"), turn: "t", status: .finished, arrivedAt: 990 + Double(index))))
    }
    return kindSections(queue.items(at: 1_001))
}

@Test func earlierCountsEveryEarlierResultInAFoldedSection() {
    // Check shows two Earlier rows and folds twelve: the heading counts all fourteen.
    let check = foldedCheck(fresh: 0, earlier: 14).attention[2]
    #expect(check.section == .check && check.items.count == 2 && check.folded == 12)
    #expect(check.earlierIDs.count == 14)
    // Dismiss all clears exactly the results it counts: every Earlier row, shown or folded, and nothing else.
    #expect(Set(check.earlierIDs).isSuperset(of: check.items.map(\.id)))

    // One current result shown, one Earlier shown, the rest folded.
    let mixed = foldedCheck(fresh: 1, earlier: 9).attention[2]
    #expect(mixed.items.map(\.kind) == [.outcome, .earlierOutcome])
    #expect(mixed.earlierIDs.count == 9)
    #expect(!mixed.earlierIDs.contains(mixed.items[0].id))
}

@Test func anUnfoldedGroupCountsItsOwnEarlierRows() {
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: session("old"), turn: "t", status: .finished, arrivedAt: 0)))
    queue.apply(.outcome(AgentOutcome(session: session("new"), turn: "t", status: .finished, arrivedAt: 990)))
    let byState = QueueSections.make(queue.items(at: 1_000), grouping: .state, project: { _ in nil })
    #expect(byState.attention.map(\.earlierIDs.count) == [1])
}

@Test func equalArrivalsSpotlightByIdentityNotDeadline() {
    var queue = AgentAttentionQueue()
    // Same arrival; "b" has the sooner deadline so it leads the queue, but before #314 the
    // identity tie-break ("a" before "b") chose which opened on arrival, and it still does.
    queue.apply(.approval(AgentApproval(session: session("a"), turn: "t", call: "c", arrivedAt: 10, expiresAt: 50)))
    queue.apply(.approval(AgentApproval(session: session("b"), turn: "t", call: "c", arrivedAt: 10, expiresAt: 30)))
    let rows = queue.items(at: 20)
    #expect(rows.map(\.session.session) == ["b", "a"])
    #expect(AgentPresentationSelection.highestPriority(in: rows, candidates: Set(rows.map(\.id))) == rows[1].id)
    // List order does not matter.
    #expect(AgentPresentationSelection.highestPriority(in: rows.reversed(), candidates: Set(rows.map(\.id))) == rows[1].id)
}

@Test func selectableItemsAreTheOnScreenRowsInReadingOrder() {
    let sections = kindSections(queue(approvals: 1, results: 1, running: 2))
    #expect(sections.selectableItems(workingOpen: false).map(\.session.session) == ["approve-0", "check-0"])
    #expect(sections.selectableItems(workingOpen: true).map(\.session.session) == ["approve-0", "check-0", "run-0", "run-1"])
    #expect(sections.selectableItems(workingOpen: true).map(\.id) == sections.selectableRows(workingOpen: true))
}

// MARK: Earlier fold (D34)

/// `fresh` current results then `earlier` results that moved under Earlier, plus `approvals` live
/// approvals and `running` working rows, each in its own session.
private func earlierQueue(approvals: Int = 0, fresh: Int = 0, earlier: Int = 0, running: Int = 0) -> [AgentAttentionItem] {
    var queue = AgentAttentionQueue()
    for index in 0..<approvals {
        queue.apply(.approval(AgentApproval(session: session("approve-\(index)"), turn: "t", call: "a", arrivedAt: 1_000)))
    }
    for index in 0..<earlier {
        queue.apply(.outcome(AgentOutcome(session: session("old-\(index)"), turn: "t", status: .finished, arrivedAt: Double(index))))
    }
    for index in 0..<fresh {
        queue.apply(.outcome(AgentOutcome(session: session("new-\(index)"), turn: "t", status: .finished, arrivedAt: 990 + Double(index))))
    }
    for index in 0..<running {
        queue.apply(.running(AgentRunning(session: session("run-\(index)"), turn: "t", arrivedAt: 995 + Double(index))))
    }
    return queue.items(at: 1_001)
}

private func earlierSections(_ items: [AgentAttentionItem], _ choice: EarlierFold.Choice = .automatic,
                             grouping: QueueGrouping = .none) -> QueueSections {
    QueueSections.make(items, grouping: grouping, project: { _ in nil }, kindSections: true, earlier: choice)
}

@Test func earlierFoldsWhileAnotherRowNeedsTheUser() {
    // A recent result needs checking: Earlier opens folded (A3).
    let sections = earlierSections(earlierQueue(fresh: 1, earlier: 3))
    #expect(sections.earlierFolded)
    let check = sections.attention[0]
    #expect(check.earlierFolded)
    // The folded rows stay in the group, so the heading keeps its place, but none is shown.
    #expect(check.shownItems.map(\.kind) == [.outcome])
    #expect(check.folded == 0)
    // An approval counts too, even with no recent result.
    #expect(earlierSections(earlierQueue(approvals: 1, earlier: 2)).earlierFolded)
}

@Test func earlierShowsOpenWhenNothingElseNeedsTheUser() {
    // A5: Earlier results alone, or beside working rows, show open.
    #expect(!earlierSections(earlierQueue(earlier: 3)).earlierFolded)
    let withWork = earlierSections(earlierQueue(earlier: 3, running: 2))
    #expect(!withWork.earlierFolded)
    #expect(withWork.attention[0].shownItems.count == 3)
    // No Earlier rows: nothing to fold.
    #expect(!earlierSections(earlierQueue(fresh: 2)).earlierFolded)
}

@Test func theUserCanFoldAnEarlierThatShowedOpen() {
    // With nothing else to check Earlier shows open; a click on its heading folds it all the same.
    let folded = earlierSections(earlierQueue(earlier: 3, running: 1), .folded)
    #expect(folded.earlierFolded)
    #expect(folded.selectableItems(workingOpen: true).allSatisfy { $0.kind != .earlierOutcome })
}

@Test func anEarlierFoldTheUserOpenedStaysOpen() {
    // A4: once opened it shows its rows whatever else needs the user.
    let opened = earlierSections(earlierQueue(approvals: 1, fresh: 1, earlier: 3), .opened)
    #expect(!opened.earlierFolded)
    #expect(opened.attention[1].shownItems.map(\.kind) == [.outcome, .earlierOutcome, .earlierOutcome, .earlierOutcome])
}

@Test func theArrowsSkipTheRowsOfAFoldedEarlier() {
    let items = earlierQueue(fresh: 1, earlier: 3, running: 1)
    let folded = earlierSections(items)
    let earlier = items.filter { $0.kind == .earlierOutcome }.map(\.id)
    let fresh = items.first { $0.kind == .outcome }!.id
    // The folded heading is one stop, held by its first Earlier result; the rows behind it are not.
    let rows = folded.selectableRows(workingOpen: false)
    #expect(rows == [fresh, earlier[0]])
    #expect(folded.earlierHeadingStops == [earlier[0]])
    #expect(folded.selectableItems(workingOpen: false).map(\.id) == [fresh])
    var selection = QueueRowSelection(selected: earlier[1])
    selection.reconcile(rows: rows)
    #expect(selection.selected == nil)
    // Opened, every Earlier row is a stop and the heading is not.
    let opened = earlierSections(items, .opened)
    #expect(opened.selectableRows(workingOpen: false) == [fresh] + earlier)
    #expect(opened.earlierHeadingStops.isEmpty)
}

@Test func dismissAllCountsTheFoldedEarlierRows() {
    let items = earlierQueue(fresh: 1, earlier: 4)
    let check = earlierSections(items).attention[0]
    #expect(check.earlierFolded)
    #expect(check.earlierIDs == items.filter { $0.kind == .earlierOutcome }.map(\.id))
    #expect(!check.earlierIDs.contains(items.first { $0.kind == .outcome }!.id))
}

@Test func aFoldedEarlierLeavesTheMoreRowsBudgetToTheRowsOnScreen() {
    // 4 approvals and 9 recent results fold Check behind "+N more"; folded Earlier rows take no
    // budget and are not behind the pill, which counts only the hidden recent results.
    let items = earlierQueue(approvals: 4, fresh: 9, earlier: 5)
    let check = earlierSections(items).attention[1]
    #expect(check.earlierFolded)
    let shownFresh = check.shownItems.filter { $0.kind == .outcome }.count
    #expect(check.folded == 9 - shownFresh)
    #expect(check.items.filter { $0.kind == .earlierOutcome }.count == 5)
    #expect(check.count == 14)
}

@Test func everyGroupingFoldsEarlier() {
    let items = earlierQueue(fresh: 1, earlier: 2)
    let byState = earlierSections(items, grouping: .state)
    #expect(byState.earlierFolded)
    #expect(byState.attention.allSatisfy { $0.earlierIDs.isEmpty || $0.earlierFolded })
    #expect(byState.selectableItems(workingOpen: false).allSatisfy { $0.kind != .earlierOutcome })
    // A card is never folded.
    let card = QueueSections.make(items.filter { $0.kind == .earlierOutcome }.prefix(1).map { $0 },
                                  grouping: .none, project: { _ in nil })
    #expect(!card.earlierFolded)
}

@Test func theMoreRowsPillFollowsTheLastRowOutsideEarlier() {
    // Check spills behind "+N more" with a folded Earlier: the pill sits after the last recent
    // result, before the Earlier heading, so it never reads as Earlier's.
    let check = earlierSections(earlierQueue(approvals: 4, fresh: 9, earlier: 5)).attention[1]
    let lines = check.lines
    let pill = lines.firstIndex(of: .moreRows)
    let heading = lines.firstIndex { if case .earlierHeading = $0 { true } else { false } }
    #expect(pill != nil && heading != nil && pill! + 1 == heading!)
    #expect(lines.filter { if case .row(let item) = $0 { item.kind == .earlierOutcome } else { false } }.isEmpty)
    // Opened, the Earlier rows follow their heading and the pill still precedes it.
    let opened = earlierSections(earlierQueue(approvals: 4, fresh: 9, earlier: 5), .opened).attention[1]
    if let pill = opened.lines.firstIndex(of: .moreRows),
       let heading = opened.lines.firstIndex(where: { if case .earlierHeading = $0 { true } else { false } }) {
        #expect(pill < heading)
    }
}

@Test func aFoldedEarlierHeadingNamesItsArrowStop() {
    let items = earlierQueue(fresh: 1, earlier: 3)
    let first = items.first { $0.kind == .earlierOutcome }!.id
    let folded = earlierSections(items).attention[0]
    #expect(folded.earlierHeadingStop == first)
    #expect(folded.lines.contains(.earlierHeading(stop: first)))
    let opened = earlierSections(items, .opened).attention[0]
    #expect(opened.earlierHeadingStop == nil)
    #expect(opened.lines.contains(.earlierHeading(stop: nil)))
    #expect(opened.lines.count == 1 + 1 + 3)
}

@Test func foldingEarlierLeavesTheToCheckCountAlone() {
    // The badge and settings count come from the queue, not the sections: Earlier results are
    // never counted, folded or not (D22, D34).
    var queue = AgentAttentionQueue()
    for index in 0..<3 {
        queue.apply(.outcome(AgentOutcome(session: session("old-\(index)"), turn: "t", status: .finished, arrivedAt: Double(index))))
    }
    queue.apply(.outcome(AgentOutcome(session: session("new"), turn: "t", status: .finished, arrivedAt: 990)))
    let items = queue.items(at: 1_001)
    let count = queue.toCheckCount(at: 1_001, earlier: .fiveMinutes)
    #expect(count == 1)
    for choice in [EarlierFold.Choice.automatic, .opened, .folded] {
        _ = earlierSections(items, choice)
        #expect(queue.toCheckCount(at: 1_001, earlier: .fiveMinutes) == count)
    }
    #expect(earlierSections(items).earlierFolded)
}
