import Foundation
import Testing
@testable import HerdlyCore

private func session(_ name: String, _ source: AgentSource = .codex) -> AgentSessionIdentity {
    AgentSessionIdentity(source: source, sourceScope: source.rawValue, session: name, surface: .cli)
}

@Test func lastUpdateSortKeepsLiveRequestsPinnedAndOrdersTheRestNewestFirst() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: session("approval"), turn: "t1", call: "a1", arrivedAt: 10)))
    queue.apply(.question(AgentQuestion(session: session("question"), turn: "t2", call: "q1", arrivedAt: 11)))
    queue.apply(.outcome(AgentOutcome(session: session("done"), turn: "t3", status: .finished, arrivedAt: 12)))
    queue.apply(.running(AgentRunning(session: session("busy"), turn: "t4", arrivedAt: 5, updatedAt: 30)))

    let attention = queue.items(at: 31, sort: .needsAttention).map(\.session.session)
    let latest = queue.items(at: 31, sort: .lastUpdate).map(\.session.session)

    #expect(attention == ["approval", "question", "done", "busy"])
    #expect(latest == ["approval", "question", "busy", "done"])
}

@Test func expiredApprovalLosesItsPinUnderLastUpdateSort() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: session("approval"), turn: "t1", call: "a1", arrivedAt: 10)))
    queue.apply(.running(AgentRunning(session: session("busy"), turn: "t2", arrivedAt: 5, updatedAt: 50)))

    let latest = queue.items(at: 60, sort: .lastUpdate)

    #expect(latest.map(\.kind) == [.running, .handedBackApproval])
}

@Test func earlierDelayIsConfigurableAndNeverKeepsOutcomesCurrent() {
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: session("done"), turn: "t1", status: .finished, arrivedAt: 0)))

    #expect(queue.items(at: 119, earlier: .twoMinutes).first?.kind == .outcome)
    #expect(queue.items(at: 120, earlier: .twoMinutes).first?.kind == .earlierOutcome)
    #expect(queue.items(at: 300).first?.kind == .earlierOutcome)
    #expect(queue.items(at: 100_000, earlier: .never).first?.kind == .outcome)
    #expect(EarlierDelay.fiveMinutes.seconds == AgentAttentionQueue.earlierAfter)
}

@Test func groupingKeepsQueuePriorityBetweenGroupsAndLabelsEachOnce() {
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: session("busy"), turn: "t1", arrivedAt: 1)))
    queue.apply(.outcome(AgentOutcome(session: session("done", .claude), turn: "t2", status: .finished, arrivedAt: 2)))
    queue.apply(.approval(AgentApproval(session: session("approval"), turn: "t3", call: "a1", arrivedAt: 3)))
    let items = queue.items(at: 4)

    let byState = QueueGroups.make(items, grouping: .state, project: { _ in nil })
    let byAgent = QueueGroups.make(items, grouping: .agent, project: { _ in nil })
    let none = QueueGroups.make(items, grouping: .none, project: { _ in nil })

    #expect(byState.map(\.heading) == ["Needs you", "Done", "Working"])
    #expect(byAgent.map(\.heading) == ["Codex", "Claude"])
    #expect(byAgent.first?.items.map(\.session.session) == ["approval", "busy"])
    #expect(none.count == 1 && none.first?.heading == nil && none.first?.items.count == 3)
}

@Test func projectGroupingUsesTheFolderNameAndKeepsUnknownProjectsTogether() {
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: session("a"), turn: "t1", arrivedAt: 1)))
    queue.apply(.running(AgentRunning(session: session("b"), turn: "t2", arrivedAt: 2)))
    queue.apply(.running(AgentRunning(session: session("c"), turn: "t3", arrivedAt: 3)))
    let folders = ["a": "/Users/me/herdly/", "b": nil, "c": "/Users/me/herdly"]

    let groups = QueueGroups.make(queue.items(at: 4), grouping: .project) { folders[$0.session.session] ?? nil }

    #expect(groups.map(\.heading) == ["herdly", "Other"])
    #expect(groups.first?.items.map(\.session.session) == ["a", "c"])
}

@Test func appearanceDefaultsMatchTheDesignedInstrument() {
    let appearance = NotchAppearance.standard

    #expect(appearance.leftWing == .spritesAndCount)
    #expect(appearance.centerLabel == .taskName)
    #expect(appearance.usage == .compact)
    #expect(appearance.sprite == .sheep)
    #expect(appearance.sort == .needsAttention)
    #expect(appearance.grouping == .none)
    #expect(appearance.earlier == .fiveMinutes)
    #expect(appearance.panelWidth == .standard)
    #expect(appearance.labelFormat == .repoAtBranch)
}

@Test(arguments: QueueLabelFormat.allCases)
func labelFormatRoundTripsPerProfileAndAnUnknownValueFallsBack(format: QueueLabelFormat) {
    var stored: [String: String] = [:]
    var appearance = NotchAppearance.standard
    appearance.labelFormat = format
    appearance.save(profile: .macBookNotch) { stored[$0] = $1 }
    stored["appearance.externalDisplay.labelFormat"] = "repoAndPath"

    #expect(NotchAppearance.load(profile: .macBookNotch) { stored[$0] }.labelFormat == format)
    #expect(NotchAppearance.load(profile: .externalDisplay) { stored[$0] }.labelFormat == .repoAtBranch)
    // A profile saved before the field existed reads the default.
    stored.removeValue(forKey: "appearance.macBookNotch.labelFormat")
    #expect(NotchAppearance.load(profile: .macBookNotch) { stored[$0] }.labelFormat == .repoAtBranch)
}

@Test func appearanceStoreRoundTripsEachProfileSeparatelyAndIgnoresUnknownValues() {
    var stored: [String: String] = [:]
    var external = NotchAppearance.standard
    external.sprite = .cow
    external.sort = .lastUpdate
    external.earlier = .never
    external.usage = .weeklyOnly
    external.panelWidth = .extraWide
    external.save(profile: .externalDisplay) { stored[$0] = $1 }
    stored["appearance.macBookNotch.sprite"] = "alpaca"
    stored["appearance.macBookNotch.panelWidth"] = "huge"

    let loadedExternal = NotchAppearance.load(profile: .externalDisplay) { stored[$0] }
    let loadedMacBook = NotchAppearance.load(profile: .macBookNotch) { stored[$0] }

    #expect(loadedExternal == external)
    #expect(loadedMacBook == .standard)
}

@Test(arguments: SpriteKind.allCases)
func eachSpriteKindRoundTripsForEachProfile(kind: SpriteKind) {
    var stored: [String: String] = [:]
    var appearance = NotchAppearance.standard
    appearance.sprite = kind
    appearance.save(profile: .macBookNotch) { stored[$0] = $1 }

    #expect(stored["appearance.macBookNotch.sprite"] == kind.rawValue)
    #expect(NotchAppearance.load(profile: .macBookNotch) { stored[$0] }.sprite == kind)
    // The other profile keeps its own choice.
    #expect(NotchAppearance.load(profile: .externalDisplay) { stored[$0] }.sprite == .sheep)
}

@Test func unknownSavedSpriteLoadsSheep() {
    let stored = ["appearance.externalDisplay.sprite": "alpaca", "appearance.externalDisplay.sort": "lastUpdate"]

    let loaded = NotchAppearance.load(profile: .externalDisplay) { stored[$0] }

    #expect(loaded.sprite == .sheep)
    #expect(loaded.sort == .lastUpdate)
}

@Test(arguments: ["dot", "bar", "tint", "sprite"])
func savedIndicatorStyleNoLongerChangesTheAppearance(style: String) {
    // A profile saved before the sprite set: the old indicator key is ignored and nothing is written for sprite.
    let stored = ["appearance.macBookNotch.indicator": style, "appearance.macBookNotch.grouping": "agent"]
    var expected = NotchAppearance.standard
    expected.grouping = .agent

    let loaded = NotchAppearance.load(profile: .macBookNotch) { stored[$0] }

    #expect(loaded == expected)
    #expect(loaded.sprite == .sheep)
}

@Test func savingNoLongerWritesTheIndicatorKey() {
    var stored: [String: String] = [:]
    NotchAppearance.standard.save(profile: .externalDisplay) { stored[$0] = $1 }

    #expect(stored["appearance.externalDisplay.indicator"] == nil)
    #expect(stored["appearance.externalDisplay.sprite"] == "sheep")
}

@Test func spritePickerOffersSheepFirstThenTheOtherKinds() {
    #expect(SpriteKind.allCases == [.sheep, .critter, .sheepdog, .cow, .blob])
    #expect(SpriteKind.allCases.map(\.name) == ["Sheep", "Critter", "Sheepdog", "Cow", "Blob"])
}

@Test(arguments: SpriteKind.allCases)
func eachSpriteKindIsTwoSameSizedFramesWithinTheEighteenByTenPointBox(kind: SpriteKind) {
    #expect(kind.frames.count == 2)
    #expect(kind.frames[0] != kind.frames[1], "the working step must change something")
    for frame in kind.frames {
        #expect(frame.count == kind.rows)
        #expect(frame.allSatisfy { $0.count == kind.columns })
        #expect(frame.allSatisfy { $0.allSatisfy { "#+.".contains($0) } })
    }
    // Two points per cell: at most 18 by 10 points.
    #expect(kind.columns <= 9 && kind.rows <= 5)
}

@Test func spriteSizesMatchTheirArtboards() {
    #expect(SpriteKind.allCases.map { [$0.columns, $0.rows] } == [[9, 5], [6, 4], [9, 5], [9, 5], [7, 5]])
    #expect(SpriteKind.critter.frames == [[".++.++", "######", "#+##+#", ".#..#."],
                                          [".++.++", "######", "#+##+#", "#....#"]])
}

@Test func theRowSlotIsSizedForTheWidestAndTallestKinds() {
    // Sheep, Sheepdog and Cow are 9 cells wide; every kind but Critter is 5 tall.
    #expect(SpriteKind.maximumColumns == 9)
    #expect(SpriteKind.maximumRows == 5)
}

@Test func threeOfTheWidestSpritesFitTheLeftWing() {
    let widest = SpriteKind.maximumColumns
    // Two points per cell, 6pt between sprites. The strip draws the wing 8pt narrower than its
    // body and sets the first sprite 4pt in, leaving 100pt of the 112pt wing for its content.
    let needed = CGFloat(3 * widest * 2 + 2 * 6)

    #expect(needed == 66)
    #expect(needed <= NotchPlacement.leadingWing - 8 - 4)
}

@Test func centerLabelOnlyAppliesWhereThereIsNoCameraHousing() {
    var appearance = NotchAppearance.standard
    appearance.centerLabel = .sessionName

    #expect(appearance.effectiveCenterLabel(on: .externalDisplay) == .sessionName)
    #expect(appearance.effectiveCenterLabel(on: .macBookNotch) == .off)
}

@Test func spotlightCanHoldUntilTheUserActsWithoutExtendingAfterInteraction() {
    let id = AgentAttentionID.running(AgentTurnIdentity(session: session("busy"), turn: "t1"))
    var presentation = NotchPresentationController()
    presentation.present(id, now: 0, duration: .untilIAct)

    #expect(presentation.update(interacting: false, now: 100) == .agentSpotlight(id))
    #expect(presentation.update(interacting: true, now: 101) == .agentSpotlight(id))
    #expect(presentation.update(interacting: false, now: 101.1) != .agentSpotlight(id))
}

@Test func ordinarySpotlightStillClosesAfterThreeSeconds() {
    let id = AgentAttentionID.running(AgentTurnIdentity(session: session("busy"), turn: "t1"))
    var presentation = NotchPresentationController()
    presentation.present(id, now: 0)

    #expect(presentation.update(interacting: false, now: 2.9) == .agentSpotlight(id))
    #expect(presentation.update(interacting: false, now: 3) != .agentSpotlight(id))
}

@Test func lastUpdateSortKeepsEarlierOutcomesTogetherAtTheEnd() {
    var queue = AgentAttentionQueue()
    queue.apply(.outcome(AgentOutcome(session: session("old"), turn: "t1", status: .finished, arrivedAt: 0)))
    queue.apply(.outcome(AgentOutcome(session: session("older"), turn: "t2", status: .failed, arrivedAt: -10)))
    queue.apply(.running(AgentRunning(session: session("stale"), turn: "t3", arrivedAt: -100, updatedAt: -50)))
    queue.apply(.outcome(AgentOutcome(session: session("fresh"), turn: "t4", status: .finished, arrivedAt: 590)))

    let latest = queue.items(at: 600, sort: .lastUpdate)

    // The stale running row is older than both earlier outcomes yet stays above them.
    #expect(latest.map(\.session.session) == ["fresh", "stale", "old", "older"])
    #expect(latest.map(\.kind) == [.outcome, .running, .earlierOutcome, .earlierOutcome])
}

@Test func defaultItemsKeepPriorityOrderWhateverTheQueueSort() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: session("handed"), turn: "t1", call: "a1", arrivedAt: 0)))
    queue.apply(.running(AgentRunning(session: session("busy"), turn: "t2", arrivedAt: 5, updatedAt: 50)))

    // The strip and spotlight read the default order: the handed-back request still leads.
    #expect(queue.items(at: 60).map(\.kind) == [.handedBackApproval, .running])
    #expect(queue.items(at: 60, sort: .lastUpdate).map(\.kind) == [.running, .handedBackApproval])
}

@Test func queueSectionsFoldWorkingRowsBelowEverythingThatNeedsTheUser() {
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: session("busy"), turn: "t1", arrivedAt: 1)))
    queue.apply(.outcome(AgentOutcome(session: session("done"), turn: "t2", status: .finished, arrivedAt: 2)))
    queue.apply(.question(AgentQuestion(session: session("question"), turn: "t3", call: "q1", arrivedAt: 3)))
    queue.apply(.approval(AgentApproval(session: session("approval"), turn: "t4", call: "a1", arrivedAt: 4)))
    queue.apply(.running(AgentRunning(session: session("other", .claude), turn: "t5", arrivedAt: 5)))
    let items = queue.items(at: 6)

    let none = QueueSections.make(items, grouping: .none, project: { _ in nil }, kindSections: true)
    let byState = QueueSections.make(items, grouping: .state, project: { _ in nil })
    let byAgent = QueueSections.make(items, grouping: .agent, project: { _ in nil })

    // The split matches the to-check badge and keeps queue order inside each part.
    #expect(none.foldsWorking && none.workingCount == 2)
    // Without grouping, kind sections replace the old "Needs you" heading (D13).
    #expect(none.attention.map(\.heading) == ["Approve", "Answer", "Check"])
    #expect(none.attention.flatMap(\.items).map(\.session.session) == ["approval", "question", "done"])
    #expect(none.working.flatMap(\.items).map(\.session.session) == ["busy", "other"])
    #expect(none.attention.flatMap(\.items).count == AgentStripSummary.make(items: items).toCheck)
    // The fold names the working rows, so State grouping drops its own "Working" heading.
    #expect(byState.attention.map(\.heading) == ["Needs you", "Done"])
    #expect(byState.working.map(\.heading) == [nil])
    #expect(byAgent.working.map(\.heading) == ["Codex", "Claude"])
}

@Test func queueSectionsShowWorkingRowsUnfoldedWhenNothingNeedsTheUser() {
    var queue = AgentAttentionQueue()
    queue.apply(.running(AgentRunning(session: session("busy"), turn: "t1", arrivedAt: 1)))
    let workingOnly = QueueSections.make(queue.items(at: 2), grouping: .state, project: { _ in nil })

    #expect(!workingOnly.foldsWorking && workingOnly.attention.isEmpty)
    #expect(workingOnly.working.map(\.heading) == ["Working"])

    var requests = AgentAttentionQueue()
    requests.apply(.approval(AgentApproval(session: session("approval"), turn: "t1", call: "a1", arrivedAt: 1)))
    let requestsOnly = QueueSections.make(requests.items(at: 2), grouping: .none, project: { _ in nil })

    #expect(!requestsOnly.foldsWorking && requestsOnly.working.isEmpty)
    #expect(requestsOnly.attention.map(\.heading) == [nil])
}

@Test func unsentTextKeepsTheCardOpenThroughAnInteractionGap() {
    let id = AgentAttentionID.question(AgentCallIdentity(session: session("asks", .claude), turn: "t1", call: "q1"))
    var presentation = NotchPresentationController()
    presentation.present(id, now: 0)

    // The pointer slips off and focus is lost while an answer is half typed: the card stays.
    #expect(presentation.update(interacting: true, now: 1) == .agentSpotlight(id))
    #expect(presentation.update(interacting: false, draftInProgress: true, now: 10) == .agentSpotlight(id))
    #expect(presentation.update(interacting: true, draftInProgress: true, now: 11) == .agentSpotlight(id))
    // Once the text is sent or cleared, it closes when interaction ends, as before.
    #expect(presentation.update(interacting: false, now: 12) == .collapsed)
}

@Test func unsentTextBlocksAFreshSpotlightButOpensNothingByItself() {
    let id = AgentAttentionID.question(AgentCallIdentity(session: session("asks", .claude), turn: "t1", call: "q1"))
    var presentation = NotchPresentationController()

    #expect(presentation.acceptsAgentSpotlight(interacting: true, draftInProgress: true, now: 0) == false)
    #expect(presentation.acceptsAgentSpotlight(interacting: true, draftInProgress: false, now: 0))
    #expect(presentation.update(interacting: false, draftInProgress: true, now: 0) == .collapsed)

    // Escape collapses even with text still in the field.
    presentation.present(id, now: 1)
    presentation.collapse()
    #expect(presentation.update(interacting: false, draftInProgress: true, now: 1.1) == .collapsed)
}
