import Testing
@testable import HerdlyCore

// ADR 0015 applied to herdr's Open (ADR 0011): which typed failures fall back to raising the app that
// hosts herdr's client, and which keep their unavailable reason. Walks and running apps are fixtures.

private let switches = TerminalHostSwitches(enabled: [.ghostty, .herdr])

@Test func herdrLayoutAndMatchFailuresFallBack() {
    let cases: [(HerdrOpenFailure, OpenFallbackReason)] = [
        (.ghosttyTTYUnsupported, .noUniqueTarget),
        (.ghosttyTab(.ttyUnsupported), .noUniqueTarget),
        (.ghosttyTab(.noMatch), .noUniqueTarget),
        (.ghosttyTab(.emptyValue), .noUniqueTarget),
        (.ghosttyTab(.multipleMatches), .noUniqueTarget),
        (.ghosttyTab(.split), .unsupportedLayout),
        (.ghosttyTab(.otherWindow), .unsupportedLayout),
        (.binding(.binding(.split)), .unsupportedLayout),
        (.binding(.binding(.multipleClients(2))), .unsupportedLayout),
        (.binding(.binding(.nonGhosttyClient)), .unsupportedLayout),
        (.binding(.herdr(.split)), .unsupportedLayout),
        (.binding(.herdr(.wrongClientCount(2))), .unsupportedLayout),
        (.binding(.herdr(.nonGhosttyClient)), .unsupportedLayout),
        (.binding(.binding(.duplicateMatches(["w1:p1", "w1:p2"]))), .noUniqueTarget),
        (.binding(.binding(.duplicateTitles(["w1:p1", "w1:p2"]))), .noUniqueTarget),
        (.binding(.binding(.sessionPrefixNotUnique(2))), .noUniqueTarget),
        // ADR 0016: a pane focus or pane verification that fails falls back without touching the tab.
        (.focusRejected(.timeout), .notVerified),
        (.focusRejected(.requestRefused(code: "x")), .notVerified),
        (.herdrPaneNotFocused, .notVerified),
        (.herdrBindingChanged, .notVerified),
        (.herdrClientChanged, .notVerified),
        // The pane verified but its Ghostty tab could not be raised or verified: a partial reach.
        (.ghosttySelectFailed, .partialReach),
        (.ghosttyVerifyInventoryUnavailable, .partialReach),
        (.ghosttyJoinChanged(.noMatch), .partialReach),
        (.ghosttyTabNotSelected, .partialReach),
    ]
    for (failure, reason) in cases {
        #expect(HerdrOpenFallback.reason(for: failure) == reason, "\(failure)")
    }
}

@Test func herdrUnreadableEndedOrUnjoinedFailuresStayUnavailable() {
    let cases: [HerdrOpenFailure] = [
        .sessionNotInHerdr, .clientTTYUnknown, .ghosttyInventoryUnavailable,
        .ghosttyTab(.inventoryUnavailable), .ghosttyTab(.invalidClientTTY),
        .binding(.herdr(.notRunning)), .binding(.herdr(.untrustedSocket)), .binding(.herdr(.herdrNotFound)),
        .binding(.herdr(.unsupportedProtocol(9))), .binding(.herdr(.timeout)),
        .binding(.herdr(.integrationNotCurrent(.claude))), .binding(.herdr(.wrongClientCount(0))),
        .binding(.binding(.sessionEnded)), .binding(.binding(.integrationNotCurrent(.claude, nil))),
        .binding(.binding(.noClient)), .binding(.binding(.paneMissing)), .binding(.binding(.namedSession)),
        .binding(.herdrSwitchedOff), .binding(.ghosttyControlsOff), .binding(.notScanned),
        .binding(.serverIdentityUnknown),
        .focusRejected(.notRunning), .focusRejected(.untrustedSocket),
        .herdrVerifyUnavailable(.herdr(.untrustedSocket)),
    ]
    for failure in cases {
        #expect(HerdrOpenFallback.reason(for: failure) == nil, "\(failure)")
    }
    // A fallback-shaped cause found by the verification scan keeps its own reason.
    #expect(HerdrOpenFallback.reason(for: .herdrVerifyUnavailable(.binding(.split))) == .unsupportedLayout)
}

@Test func herdrFallbackRaisesTheAppHostingItsClients() {
    let raised = HerdrOpenFallback.resolve(.ghosttyTab(.split), agent: .codex, clientWalks: [.reached(.ghostty)],
                                           switches: switches, isRunning: { $0 == .ghostty })
    #expect(raised == .fellBack(.ghostty, .unsupportedLayout))
    #expect(raised?.acknowledges == false)
    // Two clients in Ghostty: still one app.
    #expect(HerdrOpenFallback.resolve(.binding(.binding(.multipleClients(2))), agent: .claude,
                                      clientWalks: [.reached(.ghostty), .reached(.ghostty)], switches: switches,
                                      isRunning: { _ in true }) == .fellBack(.ghostty, .unsupportedLayout))
}

@Test func herdrFallbackWithoutAnIdentifiableClientAppIsUnavailable() {
    #expect(HerdrOpenFallback.resolve(.ghosttyTab(.split), agent: .claude, clientWalks: [], switches: switches,
                                      isRunning: { _ in true }) == .unavailable(.appNotIdentified))
    #expect(HerdrOpenFallback.resolve(.binding(.binding(.multipleClients(2))), agent: .claude,
                                      clientWalks: [.reached(.ghostty), .reached(.wezTerm)], switches: switches,
                                      isRunning: { _ in true }) == .unavailable(.appNotIdentified))
    // herdr in a switched-off iTerm2: Claude still falls back, Codex cannot be identified.
    #expect(HerdrOpenFallback.resolve(.binding(.binding(.nonGhosttyClient)), agent: .claude,
                                      clientWalks: [.reached(.iTerm2)], switches: switches,
                                      isRunning: { _ in true }) == .fellBack(.iTerm2, .unsupportedLayout))
    #expect(HerdrOpenFallback.resolve(.binding(.binding(.nonGhosttyClient)), agent: .codex,
                                      clientWalks: [.reached(.iTerm2)], switches: switches,
                                      isRunning: { _ in true }) == .unavailable(.appNotIdentified))
}

@Test func herdrFailureThatIsNotAFallbackKeepsItsOwnReason() {
    #expect(HerdrOpenFallback.resolve(.binding(.herdr(.untrustedSocket)), agent: .claude,
                                      clientWalks: [.reached(.ghostty)], switches: switches,
                                      isRunning: { _ in true }) == nil)
}

@Test func herdrFallbackNeverAcknowledges() {
    // Only a verified Open acknowledges; a fallback leaves every completion queued.
    let completions = [TerminalCompletionCandidate(id: "turn-1", arrivedAt: 10)]
    #expect(HerdrOpenAcknowledgment.afterOpen(completions, result: .unavailable(.ghosttyTab(.split))).isEmpty)
}

@Test func herdrScanKeepsEveryAttachedClientForTheFallbackWalk() {
    let snapshot = HerdrSnapshot(version: "0.9.3", protocolVersion: 22, focusedWorkspaceID: nil, focusedTabID: nil,
                                 focusedPaneID: nil, tabs: [], panes: [], layouts: [])
    let two = HerdrScan(snapshot: snapshot, integration: HerdrIntegrationReport(states: [:]),
                        client: .failure(.wrongClientCount(2)), clientPIDs: [601, 602])
    #expect(HerdrOpenFallback.clientPIDs(.available(two)) == [601, 602])
    let one = HerdrScan(snapshot: snapshot, integration: HerdrIntegrationReport(states: [:]),
                        client: .success(HerdrAttachedClient(pid: 501, tty: "ttys015", serverPID: 400)))
    #expect(HerdrOpenFallback.clientPIDs(.available(one)) == [501])
    #expect(HerdrOpenFallback.clientPIDs(.unavailable(.notRunning)).isEmpty)
    #expect(HerdrOpenFallback.clientPIDs(nil).isEmpty)
}
