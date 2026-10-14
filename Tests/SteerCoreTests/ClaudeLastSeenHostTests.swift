import Testing
@testable import SteerCore

// #280, MVP acceptance §3d H7 for a Claude CLI card: the app its process last walked to names the line once
// the session is no longer live. Walks and running apps are fixtures; nothing is contacted or launched.

private func line(_ lastSeen: TerminalHost?, _ presence: ClaudeInventoryPresence,
                  running: Set<TerminalHost>) -> String? {
    ClaudeLastSeenHost.openLine(lastSeen: lastSeen, presence: presence, isRunning: { running.contains($0) })?.cardLine
}

@Test func aClaudeCardWhoseTerminalQuitSaysTheAppIsNotRunning() {
    // The live H7 run: Terminal.app quit and the Claude process ended with it.
    #expect(line(.terminalApp, .absent, running: []) == "Terminal.app isn't running.")
    // Inventories not yet complete: the app is still known not to be running.
    #expect(line(.terminalApp, .unknown, running: []) == "Terminal.app isn't running.")
    for host in TerminalHost.terminals {
        #expect(line(host, .absent, running: []) == "\(host.displayName) isn't running.")
    }
}

@Test func aClaudeCardWhoseTerminalRelaunchedWithoutItSaysTheSessionEnded() {
    #expect(line(.terminalApp, .absent, running: [.terminalApp]) == "This session has ended.")
    // Running again but liveness unverified: the current message stays.
    #expect(line(.terminalApp, .unknown, running: [.terminalApp]) == nil)
}

@Test func anUnrelatedHostDoesNotNameAClaudeCard() {
    // iTerm2 is not running, but the session was last seen in Terminal.app, which is.
    #expect(line(.terminalApp, .absent, running: [.terminalApp]) == "This session has ended.")
    #expect(line(.terminalApp, .unknown, running: [.terminalApp, .ghostty]) == nil)
    // No app recorded, or a multiplexer: the current message stays.
    #expect(line(nil, .absent, running: []) == nil)
    #expect(line(.tmux, .absent, running: []) == nil)
    // A live session keeps its own route and scan.
    #expect(line(.terminalApp, .live, running: []) == nil)
}

@Test func onlyAVerifiedRegisteredProcessIsWalkedToATerminalApp() {
    let registered = TerminalSessionProcess.registered(ClaudeSessionRegistry.Process(pid: 41, procStart: "100"))
    #expect(ClaudeLastSeenHost.pidToWalk(process: registered,
                                         observed: TerminalProcessObservation(pid: 41, procStart: "100", tty: nil)) == 41)
    // A reused PID, a gone process, or no single registered process is never walked.
    #expect(ClaudeLastSeenHost.pidToWalk(process: registered,
                                         observed: TerminalProcessObservation(pid: 41, procStart: "200", tty: nil)) == nil)
    #expect(ClaudeLastSeenHost.pidToWalk(process: registered, observed: nil) == nil)
    #expect(ClaudeLastSeenHost.pidToWalk(process: .ambiguous, observed: nil) == nil)
    #expect(ClaudeLastSeenHost.host(from: .reached(.terminalApp)) == .terminalApp)
    #expect(ClaudeLastSeenHost.host(from: .reached(.tmux)) == nil)
    #expect(ClaudeLastSeenHost.host(from: .unsupportedApp) == nil)
    #expect(ClaudeLastSeenHost.host(from: .failed) == nil)
}
