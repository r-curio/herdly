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
                                     status: .connected, statusText: "Codex event delivery connected")
    #expect(summary.subtitle == "CLI 0.150.0 · Desktop 26.1015.1")
    #expect(summary.problems.isEmpty)
}

@Test func codexMissingSurfaceIsOnlyInTheSubtitleWhileTheOtherIsSupported() {
    let summary = AgentSummary.codex(codex(cli: (true, true, "0.150.0"), desktop: (false, false, nil)),
                                     status: .connected, statusText: "Codex event delivery connected")
    #expect(summary.subtitle == "CLI 0.150.0 · Desktop not installed")
    #expect(summary.problems.isEmpty)
}

@Test func codexUnsupportedSurfaceAsksForTheMinimumVersion() {
    let summary = AgentSummary.codex(codex(cli: (true, true, "0.150.0"), desktop: (true, false, "26.800.1")),
                                     status: .connected, statusText: "Codex event delivery connected")
    #expect(summary.subtitle == "CLI 0.150.0 · Desktop 26.800.1")
    #expect(summary.problems == [AgentProblem(kind: .codexDesktop, label: "Codex desktop", value: "Update to 26.901.51231 or later")])
}

@Test func codexNotConnectedShowsTheStatusTextAfterSurfaceProblems() {
    let summary = AgentSummary.codex(codex(cli: (true, false, nil), desktop: (false, false, nil)),
                                     status: .notConfigured, statusText: "Codex detected; Herdly is not configured.")
    #expect(summary.subtitle == "CLI version unknown · Desktop not installed")
    #expect(summary.problems == [
        AgentProblem(kind: .codexCLI, label: "Codex CLI", value: "Update to 0.145.0 or later"),
        AgentProblem(kind: .codexDesktop, label: "Codex desktop", value: "Not installed"),
        AgentProblem(kind: .status, label: "Status", value: "Codex detected; Herdly is not configured.")
    ])
}

@Test func claudeSubtitleIsVersionAndFolder() {
    let summary = AgentSummary.claude(checked: true, ClaudeCapabilities(installed: true, supported: true, version: "2.1.300"),
                                      displayPath: "~/.claude", status: .connected, statusText: "Connected",
                                      addsHooks: false)
    #expect(summary.subtitle == "2.1.300 · ~/.claude")
    #expect(summary.problems.isEmpty)
}

@Test func claudeUnsupportedVersionReplacesTheMatchingStatusRow() {
    let summary = AgentSummary.claude(checked: true, ClaudeCapabilities(installed: true, supported: false, version: "2.1.4"),
                                      displayPath: "~/.claude",
                                      status: .unsupported("Claude Code 2.1.4 is older than the tested minimum 2.1.273."),
                                      statusText: "Claude Code 2.1.4 is older than the tested minimum 2.1.273.",
                                      addsHooks: false)
    #expect(summary.problems == [AgentProblem(kind: .claudeVersion, label: "Claude Code", value: "Update to 2.1.273 or later")])
}

@Test func claudeNotDetectedAndNotConnectedShowsStatus() {
    let summary = AgentSummary.claude(checked: true, ClaudeCapabilities(installed: false, supported: false),
                                      displayPath: "~/work/.claude", status: .notConfigured,
                                      statusText: "Not configured", addsHooks: false)
    #expect(summary.subtitle == "Not detected · ~/work/.claude")
    #expect(summary.problems == [AgentProblem(kind: .status, label: "Status", value: "Not configured")])
}

@Test func claudeMissingHooksIsAProblemOnlyWhileInstalled() {
    let connected = AgentSummary.claude(checked: true, ClaudeCapabilities(installed: true, supported: true, version: "2.1.300"),
                                        displayPath: "~/.claude", status: .connected, statusText: "Connected",
                                        addsHooks: true)
    #expect(connected.problems == [AgentProblem(kind: .newHooks, label: "New hooks", value: "Configure to add them, such as file approvals")])

    let restarting = AgentSummary.claude(checked: true, ClaudeCapabilities(installed: true, supported: true, version: "2.1.300"),
                                         displayPath: "~/.claude", status: .configuredAwaitingRestart("Restart Claude Code."),
                                         statusText: "Restart Claude Code.", addsHooks: true)
    #expect(restarting.problems == [
        AgentProblem(kind: .status, label: "Status", value: "Restart Claude Code."),
        AgentProblem(kind: .newHooks, label: "New hooks", value: "Configure to add them, such as file approvals")
    ])

    let fresh = AgentSummary.claude(checked: true, ClaudeCapabilities(installed: true, supported: true, version: "2.1.300"),
                                    displayPath: "~/.claude", status: .notConfigured, statusText: "Not configured",
                                    addsHooks: true)
    #expect(fresh.problems == [AgentProblem(kind: .status, label: "Status", value: "Not configured")])
}

@Test func codexHeaderStatusAndStatusRowComeFromOneReading() {
    let caps = codex(cli: (true, true, "0.150.0"), desktop: (true, true, "26.1015.1"))
    let checking = AgentSummary.codex(caps, status: nil, statusText: "Codex detected; Herdly is not configured.")
    #expect(checking.status == .checking)
    #expect(checking.status.title == "Checking")
    #expect(checking.problems.isEmpty)

    let connected = AgentSummary.codex(caps, status: .connected, statusText: "Codex event delivery connected")
    #expect(connected.status == .connected)
    #expect(connected.status.title == "Connected")

    let restarting = AgentSummary.codex(caps, status: .configuredAwaitingRestart("Restart Codex sessions."),
                                        statusText: "Restart Codex sessions.")
    #expect(restarting.status == .attention("Restart required"))
    #expect(restarting.problems == [AgentProblem(kind: .status, label: "Status", value: "Restart Codex sessions.")])

    let fresh = AgentSummary.codex(caps, status: .notConfigured, statusText: "Codex detected; Herdly is not configured.")
    #expect(fresh.status == .attention("Not configured"))
    #expect(fresh.problems == [AgentProblem(kind: .status, label: "Status", value: "Codex detected; Herdly is not configured.")])

    let permission = AgentSummary.codex(caps, status: .permissionRequired("Trust the hooks."), statusText: "Trust the hooks.")
    #expect(permission.status == .attention("Permission required"))
}

@Test func codexVersionsAreNotJudgedBeforeTheFirstDetection() {
    let unknown = CodexCapabilities(cli: false, desktop: false, ghostty: false, supported: false)
    let checking = AgentSummary.codex(unknown, status: nil, statusText: "")
    #expect(checking.subtitle == "Checking…")
    #expect(checking.problems.isEmpty)
}

@Test func claudeHeaderStatusMatchesTodaysWording() {
    let caps = ClaudeCapabilities(installed: true, supported: true, version: "2.1.300")
    #expect(AgentSummary.claude(checked: true, caps, displayPath: "~/.claude", status: .connected, statusText: "Connected",
                                addsHooks: false).status == .connected)
    #expect(AgentSummary.claude(checked: true, caps, displayPath: "~/.claude", status: .configuredAwaitingRestart("Restart."),
                                statusText: "Restart.", addsHooks: false).status == .attention("Restart required"))
    #expect(AgentSummary.claude(checked: true, caps, displayPath: "~/.claude", status: .notConfigured,
                                statusText: "Not configured", addsHooks: false).status == .attention("Not ready"))
}

@Test func claudeUsageValueIsShortWhenAReadingIsCurrent() {
    let reading = ClaudeUsageReading(sourceScope: "/r", sessionID: "s",
                                     fiveHour: ClaudeUsageWindow(usedPercentage: 32.2, resetsAt: 2_000),
                                     sevenDay: ClaudeUsageWindow(usedPercentage: 61, resetsAt: 9_000),
                                     observedAt: 900)
    #expect(AgentSummary.claudeUsage(reading, status: .ready, now: 1_000) == .reading("5h 32% · 7d 61%"))
    #expect(AgentSummary.claudeUsage(reading, status: .ready, now: 5_000) == .reading("5h unavailable · 7d 61%"))
    #expect(AgentSummary.claudeUsage(reading, status: .ready, now: 10_000) == .unavailable)
    #expect(AgentSummary.claudeUsage(nil, status: .off, now: 1_000) == .unavailable)
    #expect(AgentUsage.unavailable.problem == nil)
    #expect(AgentUsage.reading("5h 32% · 7d 61%").problem == nil)
}

@Test func claudeUsageThatCannotBeReadIsAProblem() {
    let conflict = AgentSummary.claudeUsage(nil, status: .conflict("Status line conflict"), now: 1_000)
    #expect(conflict == .problem("Status line conflict"))
    #expect(conflict.problem == AgentProblem(kind: .usage, label: "Usage limits", value: "Status line conflict"))
    #expect(AgentSummary.claudeUsage(nil, status: .unavailable("Probe failed"), now: 1_000) == .problem("Probe failed"))
}

@Test func claudeIsCheckingUntilTheFirstDetection() {
    let summary = AgentSummary.claude(checked: false, ClaudeCapabilities(installed: false, supported: false),
                                      displayPath: "~/.claude", status: .unavailable("Checking Claude Code setup…"),
                                      statusText: "Checking Claude Code setup…", addsHooks: false)
    #expect(summary.status == .checking)
    #expect(summary.subtitle == "Checking…")
    #expect(summary.problems.isEmpty)
}

@Test func claudeWithoutAnyFolderStillHasAHeader() {
    #expect(AgentSummary.claudeWithoutFolders(checked: false)
            == AgentSummary(subtitle: "Checking…", status: .checking, problems: []))
    #expect(AgentSummary.claudeWithoutFolders(checked: true)
            == AgentSummary(subtitle: "No Claude folder", status: .attention("Not ready"), problems: []))
}

@Test func codexUnsupportedStatusIsCoveredByTheVersionRows() {
    let caps = codex(cli: (true, false, "0.100.0"), desktop: (false, false, nil))
    let summary = AgentSummary.codex(caps, status: .unsupported("Codex CLI 0.100.0 is older than the tested minimum 0.145.0."),
                                     statusText: "Codex CLI 0.100.0 is older than the tested minimum 0.145.0.")
    #expect(summary.problems == [
        AgentProblem(kind: .codexCLI, label: "Codex CLI", value: "Update to 0.145.0 or later"),
        AgentProblem(kind: .codexDesktop, label: "Codex desktop", value: "Not installed")
    ])

    let unexplained = AgentSummary.codex(codex(cli: (true, true, "0.150.0"), desktop: (false, false, nil)),
                                         status: .unsupported("Unsupported platform."), statusText: "Unsupported platform.")
    #expect(unexplained.problems == [AgentProblem(kind: .status, label: "Status", value: "Unsupported platform.")])
}

@Test func claudeUndoNeedsAReadyPlanAndAnInstalledSetup() {
    #expect(ClaudeConnectionStatus.connected.offersUndo(planReady: true))
    #expect(ClaudeConnectionStatus.configuredAwaitingRestart("Restart.").offersUndo(planReady: true))
    #expect(ClaudeConnectionStatus.repairRequired("Repair.").offersUndo(planReady: true))
    #expect(!ClaudeConnectionStatus.notConfigured.offersUndo(planReady: true))
    #expect(!ClaudeConnectionStatus.connected.offersUndo(planReady: false))
}

@Test func problemRowsAreIdentifiedByKind() {
    let problem = AgentProblem(kind: .status, label: "Status", value: "Not configured")
    #expect(problem.id == .status)
}
