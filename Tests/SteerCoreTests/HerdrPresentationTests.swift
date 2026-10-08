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
    #expect(HerdrPresentation.unrelayedQuestionLine(openCause: .open(.herdrPaneNotFocused))
        == "Answer this in Codex. " + genericCodex)
    #expect(HerdrPresentation.unrelayedQuestionLine(openCause: .open(.ghosttyTab(.otherWindow)))
        == "Answer this in Codex. " + layoutLine)
}

// MARK: - Open and relay failures

@Test func herdrPresentationGroupsEveryOpenFailure() {
    let target = GhosttyTarget(window_id: "w", tab_id: "t", terminal_id: "s")
    let cases: [(HerdrOpenFailure, HerdrReasonGroup)] = [
        (.ghosttyTTYUnsupported, .ghosttyTooOld),
        (.sessionNotInHerdr, .generic),
        (.binding(.notScanned), .generic),
        (.binding(.binding(.split)), .layoutNotSupported),
        (.binding(.herdr(.integrationNotCurrent(.claude))), .integration(.claude)),
        (.clientTTYUnknown, .generic),
        (.ghosttyInventoryUnavailable, .generic),
        (.ghosttyTab(.noMatch), .generic),
        (.ghosttyTab(.split), .layoutNotSupported),
        (.ghosttyTab(.otherWindow), .layoutNotSupported),
        (.ghosttyTab(.ttyUnsupported), .ghosttyTooOld),
        (.focusRejected(.timeout), .generic),
        (.focusRejected(.requestRefused(code: "denied")), .generic),
        (.focusRejected(.split), .generic),
        (.herdrVerifyUnavailable(.binding(.multipleClients(2))), .layoutNotSupported),
        (.herdrVerifyUnavailable(.binding(.integrationNotCurrent(.codex, nil))), .integration(.codex)),
        (.herdrVerifyUnavailable(.herdr(.notRunning)), .generic),
        (.herdrBindingChanged, .generic),
        (.herdrPaneNotFocused, .generic),
        (.herdrClientChanged, .generic),
        (.ghosttySelectFailed, .generic),
        (.ghosttyVerifyInventoryUnavailable, .generic),
        (.ghosttyJoinChanged(.matched(target)), .generic),
        (.ghosttyJoinChanged(.noMatch), .generic),
        (.ghosttyJoinChanged(.split), .layoutNotSupported),
        (.ghosttyTabNotSelected, .generic),
    ]
    for (failure, group) in cases {
        #expect(HerdrPresentation.group(failure) == group, "\(failure)")
        #expect(HerdrUnavailableCause.open(failure).group == group, "\(failure)")
    }
}

@Test func herdrPresentationGroupsEveryRelayUnavailableReason() {
    let cases: [(HerdrQuestionRelayUnavailable, HerdrReasonGroup)] = [
        (.binding(.notScanned), .generic),
        (.binding(.binding(.namedSession)), .layoutNotSupported),
        (.binding(.herdr(.integrationNotCurrent(.codex))), .integration(.codex)),
        (.leftHerdr, .generic),
        (.paneChanged, .generic),
        (.answeredInRollout, .generic),
        (.turnEnded, .generic),
        (.rolloutUnreadable, .generic),
        (.agentNotBlocked(.working), .generic),
        (.agentNotBlocked(nil), .generic),
        (.daemonAnswerInProgress, .generic),
        (.herdrRefused(.timeout), .generic),
        (.herdrRefused(.split), .generic),
    ]
    for (reason, group) in cases {
        #expect(HerdrPresentation.group(reason) == group, "\(reason)")
        #expect(HerdrUnavailableCause.relay(reason).group == group, "\(reason)")
    }
}

@Test func herdrPresentationOpenFailureCardLineIsGroupedAndKeepsTheExactReasonInDiagnostics() {
    let paneNotFocused = HerdrUnavailableCause.open(.herdrPaneNotFocused)
    #expect(HerdrPresentation.cardLine(for: paneNotFocused, agent: .claude) == genericClaude)
    #expect(HerdrPresentation.cardLine(for: .open(.ghosttyTab(.split)), agent: .codex) == layoutLine)
    #expect(HerdrPresentation.cardLine(for: .open(.ghosttyTTYUnsupported), agent: .codex) == ghosttyLine)
    #expect(HerdrPresentation.cardLine(for: .open(.binding(.binding(.integrationNotCurrent(.codex, .outdated)))), agent: .codex)
        == "Run herdr integration install codex to return to herdr panes.")
    #expect(paneNotFocused.diagnostic.contains("verifyHerdr"))
    #expect(paneNotFocused.diagnostic.contains("herdrPaneNotFocused"))
    #expect(HerdrUnavailableCause.relay(.agentNotBlocked(.working)).diagnostic.contains("agentNotBlocked"))
}

@Test func herdrPresentationNamesTheHerdrPaneOnlyForTheHerdrRoute() {
    #expect(HerdrPresentation.keyDestination(for: .herdrRelay) == ("the herdr pane", "pane"))
    #expect(HerdrPresentation.keyDestination(for: .ghosttyRelay) == ("the Ghostty tab", "tab"))
    #expect(HerdrPresentation.keyDestination(for: .relayUnavailable(.leftHerdr)) == ("the Ghostty tab", "tab"))
}

@Test func herdrPresentationDoesNotAskForGhosttyControlsWhenTheRelayIsUnavailable() {
    #expect(HerdrPresentation.relayUnavailableLine(for: .binding(.notScanned))
        == "Steer can't answer this from here. Answer in Codex, or open its pane.")
    #expect(HerdrPresentation.relayUnavailableLine(for: .daemonAnswerInProgress)
        == "Steer can't answer this from here. Answer in Codex.")
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

@Test func herdrPresentationOffersOpenWithoutTTYOnlyForTheSoleTerminal() {
    let target = HerdrPaneTarget(sessionID: "s", agent: .claude, paneID: "w1:p1")
    let sole = GhosttyTarget(window_id: "w", tab_id: "t", terminal_id: "p")
    func availability(_ join: GhosttyTTYJoin?) -> HerdrOpenAvailability {
        HerdrPresentation.openAvailability(binding: .bound(target), ttySupport: .unsupported, soleTerminal: join)
    }
    #expect(availability(.matched(sole)) == .available)
    #expect(availability(nil) == .unavailable(.ghosttyTTYUnsupported))
    #expect(availability(.ttyUnsupported) == .unavailable(.ghosttyTTYUnsupported))
    #expect(availability(.split) == .unavailable(.ghosttyTTY(.split)))
    #expect(availability(.otherWindow) == .unavailable(.ghosttyTTY(.otherWindow)))
    // With `tty` the sole-terminal join is never consulted.
    #expect(HerdrPresentation.openAvailability(binding: .bound(target), ttySupport: .supported, soleTerminal: .split) == .available)
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

@Test func herdrSettingsRowListsClaudesIntegrationOnlyWhenClaudeWasSeen() {
    let outcome = scan(integration: [.codex: .notInstalled, .claude: .outdated])
    // Codex needs no herdr integration (ADR 0012), so its state is never a problem.
    let codexOnly = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true, outcome: outcome,
                                                  agentsSeen: [.codex], ttySupport: .supported)
    #expect(codexOnly.badge == .ready)
    #expect(codexOnly.problems.isEmpty)
    let claude = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true, outcome: outcome,
                                               agentsSeen: [.claude], ttySupport: .supported)
    #expect(claude.badge == .needsAttention)
    #expect(claude.badge?.title == "Needs attention")
    #expect(claude.problems == [.integration(.claude)])
    #expect(claude.problems.first?.command == "herdr integration install claude")
}

@Test func herdrSettingsRowListsEveryIndependentProblem() {
    let outcome = scan(integration: [.codex: .unparseable, .claude: .notInstalled])
    let row = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true, outcome: outcome,
                                            agentsSeen: [.codex, .claude], ttySupport: .unsupported)
    #expect(row.badge == .needsAttention)
    #expect(row.problems == [.integration(.claude), .ghosttyCannotIdentifyTab])
    #expect(row.problems.map(\.command) == ["herdr integration install claude", nil])
}

@Test func herdrSettingsRowListsHerdrUnavailableAndGhosttyTogether() {
    let row = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true,
                                            outcome: .unavailable(.untrustedSocket), agentsSeen: [.codex],
                                            ttySupport: .unsupported)
    #expect(row.badge == .needsAttention)
    #expect(row.problems == [.ghosttyCannotIdentifyTab, .herdrUnavailable])
    #expect(!row.problems.contains { $0.message.contains("untrustedSocket") })
}

@Test func herdrSettingsRowIsNotInUseWhileOnlyCodexOpenedTheGateAndHerdrIsNotRunning() {
    // A stale socket opens ADR 0012's Codex gate; with no server nothing runs in herdr.
    let codexOnly = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true,
                                                  outcome: .unavailable(.notRunning), agentsSeen: [], ttySupport: .supported)
    #expect(codexOnly.badge == .notInUse)
    #expect(codexOnly.problems.isEmpty)
    let claude = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true,
                                               outcome: .unavailable(.notRunning), agentsSeen: [.claude], ttySupport: .supported)
    #expect(claude.problems == [.herdrUnavailable])
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
