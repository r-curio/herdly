import Testing
@testable import HerdlyCore

@Test func theRefreshTickSlowsOnlyWhenNothingTimeSensitiveIsShowing() {
    #expect(RefreshCadence.interval(presenting: false, interacting: false, actionableApproval: false) == RefreshCadence.idle)
    #expect(RefreshCadence.interval(presenting: true, interacting: false, actionableApproval: false) == RefreshCadence.active)
    #expect(RefreshCadence.interval(presenting: false, interacting: true, actionableApproval: false) == RefreshCadence.active)
    // An approval's deadline can pass while the notch is collapsed: hand back without waiting a second.
    #expect(RefreshCadence.interval(presenting: false, interacting: false, actionableApproval: true) == RefreshCadence.active)
    #expect(RefreshCadence.active < RefreshCadence.idle)
}

@Test func oneDueHostBringsEveryEligibleHostIntoTheSharedRead() {
    let eligible = ["terminalApp": 10.0, "tmux": 11.5, "zellij": 0]
    #expect(SharedTabScan.hostsToRead(eligible: eligible, now: 9) == ["terminalApp", "tmux", "zellij"])
    #expect(SharedTabScan.hostsToRead(eligible: ["terminalApp": 10.0, "tmux": 11.5], now: 9.99) == [])
    // The due boundary is inclusive, as each host's own `uptime >= nextScan` gate was.
    #expect(SharedTabScan.hostsToRead(eligible: ["terminalApp": 10.0, "tmux": 11.5], now: 10) == ["terminalApp", "tmux"])
}

@Test func noEligibleHostTakesNoSharedRead() {
    #expect(SharedTabScan.hostsToRead(eligible: [String: Double](), now: 100).isEmpty)
}
