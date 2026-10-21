import Testing
@testable import HerdlyCore

private func codex(cli: (installed: Bool, supported: Bool, version: String?),
                   desktop: (installed: Bool, supported: Bool, version: String?)) -> CodexCapabilities {
    CodexCapabilities(cli: cli.supported, desktop: desktop.supported, ghostty: false,
                      supported: cli.supported || desktop.supported,
                      cliVersion: cli.version, desktopVersion: desktop.version,
                      cliInstalled: cli.installed, desktopInstalled: desktop.installed)
}

@Test func codexSubtitleNamesEachSurfaceVersion() {
    let summary = AgentSummary.codex(codex(cli: (true, true, "0.150.0"), desktop: (true, true, "26.1015.1")),
                                     connected: true, statusText: "Codex event delivery connected")
    #expect(summary.subtitle == "CLI 0.150.0 · Desktop 26.1015.1")
    #expect(summary.problems.isEmpty)
}

@Test func codexMissingSurfaceIsOnlyInTheSubtitleWhileTheOtherIsSupported() {
    let summary = AgentSummary.codex(codex(cli: (true, true, "0.150.0"), desktop: (false, false, nil)),
                                     connected: true, statusText: "Codex event delivery connected")
    #expect(summary.subtitle == "CLI 0.150.0 · Desktop not installed")
    #expect(summary.problems.isEmpty)
}

@Test func codexUnsupportedSurfaceAsksForTheMinimumVersion() {
    let summary = AgentSummary.codex(codex(cli: (true, true, "0.150.0"), desktop: (true, false, "26.800.1")),
                                     connected: true, statusText: "Codex event delivery connected")
    #expect(summary.subtitle == "CLI 0.150.0 · Desktop 26.800.1")
    #expect(summary.problems == [AgentProblem(label: "Codex desktop", value: "Update to 26.901.51231 or later")])
}

@Test func codexNotConnectedShowsTheStatusTextAfterSurfaceProblems() {
    let summary = AgentSummary.codex(codex(cli: (true, false, nil), desktop: (false, false, nil)),
                                     connected: false, statusText: "Codex detected; Herdly is not configured.")
    #expect(summary.subtitle == "CLI version unknown · Desktop not installed")
    #expect(summary.problems == [
        AgentProblem(label: "Codex CLI", value: "Update to 0.145.0 or later"),
        AgentProblem(label: "Codex desktop", value: "Not installed"),
        AgentProblem(label: "Status", value: "Codex detected; Herdly is not configured.")
    ])
}

@Test func claudeSubtitleIsVersionAndFolder() {
    let summary = AgentSummary.claude(ClaudeCapabilities(installed: true, supported: true, version: "2.1.300"),
                                      displayPath: "~/.claude", status: .connected, statusText: "Connected",
                                      addsHooks: false)
    #expect(summary.subtitle == "2.1.300 · ~/.claude")
    #expect(summary.problems.isEmpty)
}

@Test func claudeUnsupportedVersionReplacesTheMatchingStatusRow() {
    let summary = AgentSummary.claude(ClaudeCapabilities(installed: true, supported: false, version: "2.1.4"),
                                      displayPath: "~/.claude",
                                      status: .unsupported("Claude Code 2.1.4 is older than the tested minimum 2.1.273."),
                                      statusText: "Claude Code 2.1.4 is older than the tested minimum 2.1.273.",
                                      addsHooks: false)
    #expect(summary.problems == [AgentProblem(label: "Claude Code", value: "Update to 2.1.273 or later")])
}

@Test func claudeNotDetectedAndNotConnectedShowsStatus() {
    let summary = AgentSummary.claude(ClaudeCapabilities(installed: false, supported: false),
                                      displayPath: "~/work/.claude", status: .notConfigured,
                                      statusText: "Not configured", addsHooks: false)
    #expect(summary.subtitle == "Not detected · ~/work/.claude")
    #expect(summary.problems == [AgentProblem(label: "Status", value: "Not configured")])
}

@Test func claudeMissingHooksIsAProblemOnlyWhileInstalled() {
    let connected = AgentSummary.claude(ClaudeCapabilities(installed: true, supported: true, version: "2.1.300"),
                                        displayPath: "~/.claude", status: .connected, statusText: "Connected",
                                        addsHooks: true)
    #expect(connected.problems == [AgentProblem(label: "New hooks", value: "Configure to add them, such as file approvals")])

    let restarting = AgentSummary.claude(ClaudeCapabilities(installed: true, supported: true, version: "2.1.300"),
                                         displayPath: "~/.claude", status: .configuredAwaitingRestart("Restart Claude Code."),
                                         statusText: "Restart Claude Code.", addsHooks: true)
    #expect(restarting.problems == [
        AgentProblem(label: "Status", value: "Restart Claude Code."),
        AgentProblem(label: "New hooks", value: "Configure to add them, such as file approvals")
    ])

    let fresh = AgentSummary.claude(ClaudeCapabilities(installed: true, supported: true, version: "2.1.300"),
                                    displayPath: "~/.claude", status: .notConfigured, statusText: "Not configured",
                                    addsHooks: true)
    #expect(fresh.problems == [AgentProblem(label: "Status", value: "Not configured")])
}

@Test func claudeUsageValueIsShortWhenAReadingIsCurrent() {
    let reading = ClaudeUsageReading(sourceScope: "/r", sessionID: "s",
                                     fiveHour: ClaudeUsageWindow(usedPercentage: 32.2, resetsAt: 2_000),
                                     sevenDay: ClaudeUsageWindow(usedPercentage: 61, resetsAt: 9_000),
                                     observedAt: 900)
    #expect(AgentSummary.claudeUsage(reading, status: .ready, now: 1_000) == "5h 32% · 7d 61%")
    #expect(AgentSummary.claudeUsage(reading, status: .ready, now: 5_000) == "5h unavailable · 7d 61%")
    #expect(AgentSummary.claudeUsage(reading, status: .ready, now: 10_000) == "No current reading")
    #expect(AgentSummary.claudeUsage(nil, status: .off, now: 1_000) == "No current reading")
    #expect(AgentSummary.claudeUsage(reading, status: .conflict("Status line conflict"), now: 1_000) == "Status line conflict")
    #expect(AgentSummary.claudeUsage(reading, status: .unavailable("Probe failed"), now: 1_000) == "Probe failed")
}
