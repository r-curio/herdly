import Foundation
import Testing
@testable import SteerCore

private let ghosttyLine = "Update Ghostty to return to herdr panes."
private let layoutLine = "Steer returns only to a single-pane herdr tab in one Ghostty window."
private let genericCodex = "Open in Codex is unavailable until Steer can verify the exact herdr pane."
private let genericClaude = "Open in Claude is unavailable until Steer can verify the exact herdr pane."

private func scan(integration: [HerdrAgentKind: HerdrIntegrationState] = [.codex: .current(version: 8),
                                                                         .claude: .current(version: 10)])
    -> HerdrScanOutcome {
    .available(HerdrScan(snapshot: HerdrSnapshot(version: "0.9.3", protocolVersion: 22, focusedWorkspaceID: nil,
                                                 focusedTabID: nil, focusedPaneID: nil, tabs: [], panes: [], layouts: []),
                         integration: HerdrIntegrationReport(states: integration),
                         client: .success(HerdrAttachedClient(pid: 93954, tty: "ttys015", serverPID: 900)),
                         serverStartedAt: 1_000))
}

// MARK: - Grouping every typed reason

@Test func herdrPresentationGroupsEverySessionLevelReason() {
    let cases: [(HerdrSessionUnavailable, HerdrReasonGroup)] = [
        (.ghosttyControlsOff, .generic),
        (.notScanned, .generic),
        (.serverIdentityUnknown, .generic),
        (.herdr(.notRunning), .generic),
        (.binding(.split), .layoutNotSupported),
        (.herdr(.integrationNotCurrent(.claude)), .integration(.claude)),
    ]
    for (reason, group) in cases {
        #expect(HerdrPresentation.group(reason) == group, "\(reason)")
        #expect(HerdrUnavailableCause.session(reason).group == group, "\(reason)")
    }
}

@Test func herdrPresentationGroupsEveryHerdrUnavailableReason() {
    let cases: [(HerdrUnavailableReason, HerdrReasonGroup)] = [
        (.herdrNotFound, .generic),
        (.notRunning, .generic),
        (.untrustedSocket, .generic),
        (.unsupportedProtocol(23), .generic),
        (.integrationNotCurrent(.codex), .integration(.codex)),
        (.integrationNotCurrent(.claude), .integration(.claude)),
        (.wrongClientCount(0), .generic),
        (.wrongClientCount(2), .layoutNotSupported),
        (.nonGhosttyClient, .generic),
        (.split, .layoutNotSupported),
        (.namedSession, .layoutNotSupported),
        (.voidBinding, .generic),
        (.timeout, .generic),
        (.malformedReply, .generic),
        (.requestRefused(code: "denied"), .generic),
    ]
    for (reason, group) in cases {
        #expect(HerdrPresentation.group(reason) == group, "\(reason)")
        #expect(HerdrPresentation.group(HerdrSessionUnavailable.herdr(reason)) == group, "\(reason)")
    }
}

@Test func herdrPresentationGroupsEveryBindingReason() {
    let cases: [(HerdrBindingUnavailable, HerdrReasonGroup)] = [
        (.sessionEnded, .generic),
        (.noHookRecord, .generic),
        (.notInHerdr, .generic),
        (.conflictingHookRecords, .generic),
        (.unsupportedProtocol(nil), .generic),
        (.unsupportedProtocol(21), .generic),
        (.socketUnknown, .generic),
        (.namedSession, .layoutNotSupported),
        (.herdrRestarted, .generic),
        (.paneReusedBySession("other"), .generic),
        (.conflictingPaneObservations, .generic),
        (.duplicateMatches(["w1:p1", "w1:p2"]), .generic),
        (.paneMissing, .generic),
        (.agentSessionNull, .generic),
        (.agentSessionMismatch, .generic),
        (.conflictingTitle, .generic),
        (.split, .layoutNotSupported),
        (.integrationNotCurrent(.codex, .outdated), .integration(.codex)),
        (.integrationNotCurrent(.claude, nil), .integration(.claude)),
        (.noClient, .generic),
        (.multipleClients(2), .layoutNotSupported),
        (.nonGhosttyClient, .generic),
    ]
    for (reason, group) in cases {
        #expect(HerdrPresentation.group(reason) == group, "\(reason)")
        #expect(HerdrUnavailableCause.session(.binding(reason)).group == group, "\(reason)")
    }
}

@Test func herdrPresentationGroupsEveryGhosttyTTYReason() {
    let target = GhosttyTarget(window_id: "w", tab_id: "t", terminal_id: "s")
    let cases: [(GhosttyTTYJoin, HerdrReasonGroup)] = [
        (.matched(target), .generic),
        (.ttyUnsupported, .ghosttyTooOld),
        (.inventoryUnavailable, .generic),
        (.invalidClientTTY, .generic),
        (.noMatch, .generic),
        (.emptyValue, .generic),
        (.multipleMatches, .generic),
        (.split, .layoutNotSupported),
        (.otherWindow, .layoutNotSupported),
    ]
    for (join, group) in cases {
        #expect(HerdrPresentation.group(join) == group, "\(join)")
        #expect(HerdrUnavailableCause.ghosttyTTY(join).group == group, "\(join)")
    }
    #expect(HerdrUnavailableCause.ghosttyTTYUnsupported.group == .ghosttyTooOld)
}

// MARK: - Card wording

@Test func herdrPresentationCardLinesUseTheAgreedWording() {
    #expect(HerdrPresentation.cardLine(for: .ghosttyTooOld, agent: .codex) == ghosttyLine)
    #expect(HerdrPresentation.cardLine(for: .layoutNotSupported, agent: .claude) == layoutLine)
    #expect(HerdrPresentation.cardLine(for: .generic, agent: .codex) == genericCodex)
    #expect(HerdrPresentation.cardLine(for: .generic, agent: .claude) == genericClaude)
    #expect(HerdrPresentation.cardLine(for: .integration(.codex), agent: .codex)
        == "Run herdr integration install codex to return to herdr panes.")
    #expect(HerdrPresentation.cardLine(for: .integration(.claude), agent: .claude)
        == "Run herdr integration install claude to return to herdr panes.")
}

@Test func herdrPresentationCardLinesNeverCarryTheExactReason() {
    let cause = HerdrUnavailableCause.session(.binding(.paneReusedBySession("secret-session")))
    let line = HerdrPresentation.cardLine(for: cause, agent: .codex)
    #expect(line == genericCodex)
    #expect(!line.contains("secret-session"))
    #expect(cause.diagnostic.contains("paneReusedBySession"))
    #expect(cause.diagnostic.contains("secret-session"))
    #expect(HerdrUnavailableCause.ghosttyTTY(.otherWindow).diagnostic.contains("otherWindow"))
}

@Test func herdrPresentationUnrelayedQuestionPrefixesOpensReason() {
    #expect(HerdrPresentation.unrelayedQuestionLine(openCause: .session(.binding(.split)))
        == "Answer this in Codex. " + layoutLine)
    #expect(HerdrPresentation.unrelayedQuestionLine(openCause: .session(.notScanned))
        == "Answer this in Codex. " + genericCodex)
    #expect(HerdrPresentation.unrelayedQuestionLine(openCause: .ghosttyTTYUnsupported)
        == "Answer this in Codex. " + ghosttyLine)
}

// MARK: - Open availability

@Test func herdrPresentationOpenAvailabilityFollowsBindingThenGhostty() {
    let target = HerdrPaneTarget(sessionID: "s", agent: .codex, paneID: "w1:p1")
    #expect(HerdrPresentation.openAvailability(binding: .notInHerdr, ttySupport: .unsupported) == .notInHerdr)
    #expect(HerdrPresentation.openAvailability(binding: .bound(target), ttySupport: .supported) == .available)
    #expect(HerdrPresentation.openAvailability(binding: .bound(target), ttySupport: nil) == .available)
    #expect(HerdrPresentation.openAvailability(binding: .bound(target), ttySupport: .unsupported)
        == .unavailable(.ghosttyTTYUnsupported))
    #expect(HerdrPresentation.openAvailability(binding: .unavailable(.binding(.split)), ttySupport: .unsupported)
        == .unavailable(.session(.binding(.split))))
}

// MARK: - Settings row

@Test func herdrSettingsRowIsNotInUseUntilASessionReportsHerdr() {
    let row = HerdrPresentation.settingsRow(inUse: false, ghosttyControlsEnabled: true, outcome: nil,
                                            agentsSeen: [], ttySupport: .unsupported)
    #expect(row == HerdrSettingsRow(badge: .notInUse, detail: "No herdr sessions seen.", problems: []))
    #expect(row.badge?.title == "Not in use")
    let off = HerdrPresentation.settingsRow(inUse: false, ghosttyControlsEnabled: false, outcome: nil,
                                            agentsSeen: [.codex], ttySupport: .unsupported)
    #expect(off.badge == .notInUse)
    #expect(off.problems.isEmpty)
}

@Test func herdrSettingsRowShowsNoBadgeWhileTheFirstScanRuns() {
    let row = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true, outcome: nil,
                                            agentsSeen: [.codex], ttySupport: .supported)
    #expect(row.badge == nil)
    #expect(row.problems.isEmpty)
}

@Test func herdrSettingsRowIsReadyWithNoProblems() {
    let row = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true, outcome: scan(),
                                            agentsSeen: [.codex, .claude], ttySupport: .supported)
    #expect(row.badge == .ready)
    #expect(row.badge?.title == "Ready")
    #expect(row.problems.isEmpty)
}

@Test func herdrSettingsRowListsIntegrationsOnlyForAgentsSeen() {
    let outcome = scan(integration: [.codex: .notInstalled, .claude: .outdated])
    let codexOnly = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true, outcome: outcome,
                                                  agentsSeen: [.codex], ttySupport: .supported)
    #expect(codexOnly.badge == .needsAttention)
    #expect(codexOnly.badge?.title == "Needs attention")
    #expect(codexOnly.problems == [.integration(.codex)])
    #expect(codexOnly.problems.first?.command == "herdr integration install codex")
}

@Test func herdrSettingsRowListsEveryIndependentProblem() {
    let outcome = scan(integration: [.codex: .unparseable, .claude: .notInstalled])
    let row = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true, outcome: outcome,
                                            agentsSeen: [.codex, .claude], ttySupport: .unsupported)
    #expect(row.badge == .needsAttention)
    #expect(row.problems == [.integration(.claude), .integration(.codex), .ghosttyCannotIdentifyTab])
    #expect(row.problems.map(\.command) == ["herdr integration install claude", "herdr integration install codex", nil])
}

@Test func herdrSettingsRowListsHerdrUnavailableAndGhosttyTogether() {
    let row = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true,
                                            outcome: .unavailable(.untrustedSocket), agentsSeen: [.codex],
                                            ttySupport: .unsupported)
    #expect(row.badge == .needsAttention)
    #expect(row.problems == [.ghosttyCannotIdentifyTab, .herdrUnavailable])
    #expect(!row.problems.contains { $0.message.contains("untrustedSocket") })
}

@Test func herdrSettingsRowMapsAScanLevelIntegrationFailureToItsCommand() {
    let row = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true,
                                            outcome: .unavailable(.integrationNotCurrent(.claude)),
                                            agentsSeen: [.claude], ttySupport: nil)
    #expect(row.problems == [.integration(.claude)])
}

@Test func herdrSettingsRowListsNoGhosttyProblemWhileSupportIsUnknown() {
    let row = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true, outcome: scan(),
                                            agentsSeen: [.codex], ttySupport: nil)
    #expect(row.badge == .ready)
}
