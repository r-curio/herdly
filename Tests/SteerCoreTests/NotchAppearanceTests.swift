import Foundation
import Testing
@testable import SteerCore

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
    let folders = ["a": "/Users/me/steer/", "b": nil, "c": "/Users/me/steer"]

    let groups = QueueGroups.make(queue.items(at: 4), grouping: .project) { folders[$0.session.session] ?? nil }

    #expect(groups.map(\.heading) == ["steer", "Other"])
    #expect(groups.first?.items.map(\.session.session) == ["a", "c"])
}

@Test func appearanceDefaultsMatchTheDesignedInstrument() {
    let appearance = NotchAppearance.standard

    #expect(appearance.leftWing == .spritesAndCount)
    #expect(appearance.centerLabel == .taskName)
    #expect(appearance.usage == .compact)
    #expect(appearance.indicator == .sprite)
    #expect(appearance.sort == .needsAttention)
    #expect(appearance.grouping == .none)
    #expect(appearance.earlier == .fiveMinutes)
}

@Test func appearanceStoreRoundTripsEachProfileSeparatelyAndIgnoresUnknownValues() {
    var stored: [String: String] = [:]
    var external = NotchAppearance.standard
    external.indicator = .tint
    external.sort = .lastUpdate
    external.earlier = .never
    external.save(profile: .externalDisplay) { stored[$0] = $1 }
    stored["appearance.macBookNotch.indicator"] = "glow"

    let loadedExternal = NotchAppearance.load(profile: .externalDisplay) { stored[$0] }
    let loadedMacBook = NotchAppearance.load(profile: .macBookNotch) { stored[$0] }

    #expect(loadedExternal == external)
    #expect(loadedMacBook == .standard)
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
    presentation.present(id, now: 0, holdUntilInteraction: true)

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
