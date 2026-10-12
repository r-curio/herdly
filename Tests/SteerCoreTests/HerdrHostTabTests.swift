import Foundation
import Testing
@testable import SteerCore

// ADR 0014 moves herdr's gate and client join from Ghostty-only to any enabled terminal host (#241).
// The Ghostty case keeps ADR 0011's rules unchanged; another host's client joins by tty
// (`MultiplexerHostTab`) and its tab is raised by that host's own Open.

private let paneID = "w1:p1"
private let session = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
private let target = HerdrPaneTarget(sessionID: session, agent: .codex, paneID: paneID)
private let clientTTY = "/dev/ttys015"

private func chain(host: String) -> [HerdrProcessAncestor] {
    [HerdrProcessAncestor(pid: 93954, command: "herdr", tty: "ttys015"),
     HerdrProcessAncestor(pid: 93950, command: "zsh", tty: "ttys015"),
     HerdrProcessAncestor(pid: 93949, command: "login", tty: "ttys015"),
     HerdrProcessAncestor(pid: 828, command: host, tty: nil)]
}

private let one = HerdrClientListing(serverPIDs: [900], clientPIDs: [93954])

@Test func herdrClientVerdictKeepsTheGhosttyOnlyRuleByDefault() {
    #expect(HerdrAttachedClient.verdict(listing: one, ancestry: { _ in chain(host: "ghostty") })
            == .success(HerdrAttachedClient(pid: 93954, tty: "ttys015", serverPID: 900)))
    #expect(HerdrAttachedClient.verdict(listing: one, ancestry: { _ in chain(host: "iTerm2") }) == .failure(.nonGhosttyClient))
    #expect(HerdrScanRequest().clientHostCommands == ["ghostty"])
    #expect(HerdrBindingInputs.scanRequest(paneIDs: [], codex: .none).clientHostCommands == ["ghostty"])
}

@Test func herdrClientVerdictAcceptsAClientHostedByAnyEnabledTerminal() {
    let hosts = TerminalHost.executableNames(of: [.iTerm2, .terminalApp])
    #expect(hosts == ["iTerm2", "Terminal"])
    #expect(HerdrAttachedClient.verdict(listing: one, ancestry: { _ in chain(host: "iTerm2") }, hostCommands: hosts)
            == .success(HerdrAttachedClient(pid: 93954, tty: "ttys015", serverPID: 900)))
    #expect(HerdrAttachedClient.verdict(listing: one, ancestry: { _ in chain(host: "Terminal") }, hostCommands: hosts)
            == .success(HerdrAttachedClient(pid: 93954, tty: "ttys015", serverPID: 900)))
    // A host that is switched off never hosts the client Steer targets.
    #expect(HerdrAttachedClient.verdict(listing: one, ancestry: { _ in chain(host: "ghostty") }, hostCommands: hosts)
            == .failure(.nonGhosttyClient))
    #expect(HerdrBindingInputs.scanRequest(paneIDs: [], codex: .none, clientHostCommands: hosts).clientHostCommands == hosts)
    #expect(TerminalHost.executableNames(of: [.ghostty, .wezTerm]) == ["ghostty", "wezterm-gui"])
}

private func scan(clientTTY: String? = "ttys015", focused: String = paneID) -> HerdrScanOutcome {
    let panes = [HerdrPane(paneID: paneID, tabID: "w1:t1", workspaceID: "w1", focused: focused == paneID, agent: "codex",
                           agentStatus: .done, agentSession: nil, terminalTitle: nil)]
    let snapshot = HerdrSnapshot(version: "0.9.3", protocolVersion: 22, focusedWorkspaceID: "w1", focusedTabID: "w1:t1",
                                 focusedPaneID: focused, tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", focused: true, paneCount: 1)],
                                 panes: panes, layouts: [])
    return .available(HerdrScan(snapshot: snapshot, integration: HerdrIntegrationReport(states: [:]),
                                client: .success(HerdrAttachedClient(pid: 501, tty: clientTTY, serverPID: 400)),
                                serverStartedAt: 1_000))
}

private let hostTab = TerminalTabTarget(host: .iTerm2, tabID: "GUID-1", tty: clientTTY)

@Test func herdrOpenInAnotherHostJoinsItsClientToThatHostsTab() {
    let plan = HerdrHostOpen.plan(binding: .bound(target), outcome: scan(), join: { tty in
        tty == clientTTY ? .tab(hostTab) : .miss(.fallBack(.noUniqueTarget, candidates: 0))
    })
    #expect(plan == .success(HerdrHostOpenPlan(pane: target, clientPID: 501, clientTTY: clientTTY, host: .tab(hostTab))))
    // The herdr half fails first, with herdr's own reason; a host-tab miss keeps ADR 0015's outcome.
    #expect(HerdrHostOpen.plan(binding: .notInHerdr, outcome: scan(), join: { _ in .tab(hostTab) })
            == .failure(.herdr(.sessionNotInHerdr)))
    #expect(HerdrHostOpen.plan(binding: .bound(target), outcome: scan(clientTTY: nil), join: { _ in .tab(hostTab) })
            == .failure(.herdr(.clientTTYUnknown)))
    #expect(HerdrHostOpen.plan(binding: .bound(target), outcome: scan(), join: { _ in .miss(.unavailable(.hostUnreadable(.iTerm2))) })
            == .failure(.host(.unavailable(.hostUnreadable(.iTerm2)))))
}

@Test func herdrOpenInAnotherHostVerifiesThePaneAsGhosttysDoes() {
    let plan = HerdrHostOpenPlan(pane: target, clientPID: 501, clientTTY: clientTTY, host: .tab(hostTab))
    #expect(HerdrHostOpen.verifyPane(plan, binding: .bound(target), outcome: scan()) == nil)
    #expect(HerdrHostOpen.verifyPane(plan, binding: .bound(target), outcome: scan(focused: "w1:p9"))
            == .herdr(.herdrPaneNotFocused))
    #expect(HerdrHostOpen.verifyPane(plan, binding: .bound(target), outcome: scan(clientTTY: "ttys099"))
            == .herdr(.herdrClientChanged))
}
