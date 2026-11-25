import Foundation
import Testing
@testable import HerdlyCore

// Settings › Agents rows (#481, Paper "Agents tab like Terminals", A1–A8).

private func codexCaps(cli: (installed: Bool, supported: Bool) = (true, true),
                       desktop: (installed: Bool, supported: Bool) = (true, true)) -> CodexCapabilities {
    CodexCapabilities(cli: cli.supported, desktop: desktop.supported, ghostty: false,
                      supported: cli.supported || desktop.supported,
                      cliVersion: cli.installed ? "0.150.0" : nil, desktopVersion: desktop.installed ? "26.1015.1" : nil,
                      cliInstalled: cli.installed, desktopInstalled: desktop.installed)
}

private let claudeCaps = ClaudeCapabilities(installed: true, supported: true, version: "2.1.300")
private let oldAwaitingText = "Configured; start a new Claude session in this root to verify delivery. Sessions already running may still report activity; restart them so Herdly can match their terminal tabs."
private let codexAwaitingText = "Configured; start a new Codex session to verify delivery. Existing sessions keep running without Herdly's hooks."

private func codexRow(_ status: CodexConnectionStatus?, capabilities: CodexCapabilities = codexCaps(),
                      installed: Bool = true, planReady: Bool = true,
                      restartAfterUpdate: Bool = false, statusText: String = "Status text") -> AgentSettingsRow {
    AgentSettingsRow.codex(capabilities, status: status, statusText: statusText, installed: installed,
                           planReady: planReady,
                           restartAfterUpdate: restartAfterUpdate)
}

private func claudeRow(_ status: ClaudeConnectionStatus?, capabilities: ClaudeCapabilities = claudeCaps,
                       installed: Bool = true, planReady: Bool = true, requiresConfigure: Bool = false,
                       addsHooks: Bool = false, plannedUsage: ClaudeUsageSetupStatus? = .ready,
                       usageInstalled: Bool = true, usageStatus: ClaudeUsageSetupStatus = .ready,
                       restartAfterUpdate: Bool = false, statusText: String = "Status text") -> AgentSettingsRow {
    AgentSettingsRow.claude(capabilities, status: status, statusText: statusText, installed: installed,
                            setup: ClaudeFolderSetup(planReady: planReady, requiresConfigure: requiresConfigure,
                                                     addsHooks: addsHooks, plannedUsage: plannedUsage,
                                                     usageInstalled: usageInstalled, usageStatus: usageStatus),
                            restartAfterUpdate: restartAfterUpdate)
}

@Test func restartLinesNameTheCommandForEachAgentAndReason() {
    #expect(AgentRestartReason.update.line(for: .claude) == "Run `claude` in a new terminal tab to finish updating")
    #expect(AgentRestartReason.setup.line(for: .claude) == "Run `claude` in a new terminal tab to finish setup")
    #expect(AgentRestartReason.update.line(for: .codex)
        == "Quit and reopen Codex, or run `codex` in a new terminal tab, to finish updating")
    #expect(AgentRestartReason.setup.line(for: .codex)
        == "Quit and reopen Codex, or run `codex` in a new terminal tab, and allow Herdly's hooks if Codex asks")
}

@Test func connectedRowsAreReadyWithTheSwitchOnAndNoLines() {
    let codex = codexRow(.connected)
    #expect(codex == AgentSettingsRow(badge: .ready, hooksInstalled: true, setupCanRun: false, lines: []))
    #expect(codex.switchEnabled)
    #expect(codex.accessibilityLabel(name: "Codex") == "Codex, Ready")
    #expect(claudeRow(.connected) == AgentSettingsRow(badge: .ready, hooksInstalled: true, setupCanRun: false, lines: []))
}

@Test func bothAgentsReadCheckingUntilTheFirstDetection() {
    for row in [codexRow(nil, installed: true), claudeRow(nil, installed: true)] {
        #expect(row.badge == nil)
        #expect(!row.switchEnabled)
        #expect(row.lines.isEmpty)
        #expect(AgentSwitchChange.change(to: false, row) == nil)
    }
    #expect(codexRow(nil).accessibilityLabel(name: "Codex") == "Codex, Checking")
}

@Test func anUpdateAsksForARestartWithTheUpdateLine() {
    let claude = claudeRow(.connected, restartAfterUpdate: true)
    #expect(claude.badge == .restartRequired)
    #expect(claude.lines == [.restart("Run `claude` in a new terminal tab to finish updating")])
    #expect(claude.accessibilityLabel(name: "Claude Code") == "Claude Code, Restart required")
    let codex = codexRow(.connected, restartAfterUpdate: true)
    #expect(codex.badge == .restartRequired)
    #expect(codex.lines == [.restart("Quit and reopen Codex, or run `codex` in a new terminal tab, to finish updating")])
}

@Test func aSessionStartAfterTheUpdateClearsTheRestartLine() {
    var updates = AgentUpdates()
    let command = AgentUpdateCommand(executable: "/opt/homebrew/bin/claude", arguments: ["update"])
    let began = updates.begin(.claudeCode)
    #expect(began)
    updates.finish(.claudeCode, command: command, result: .finished(status: 0, output: .init(), errors: .init()),
                   detection: AgentUpdateDetection(version: "2.1.300", meetsMinimum: true), now: 100)
    #expect(claudeRow(.connected, restartAfterUpdate: updates.restartRequired(.claude)).badge == .restartRequired)
    updates.sessionStarted(.codex, at: 200)
    #expect(claudeRow(.connected, restartAfterUpdate: updates.restartRequired(.claude)).badge == .restartRequired)
    updates.sessionStarted(.claude, at: 200)
    let cleared = claudeRow(.connected, restartAfterUpdate: updates.restartRequired(.claude))
    #expect(cleared.badge == .ready && cleared.lines.isEmpty)
}

@Test func firstSetupAwaitingASessionSaysFinishSetupNotTheOldStatusText() {
    let claude = claudeRow(.configuredAwaitingRestart(oldAwaitingText), statusText: oldAwaitingText)
    #expect(claude.badge == .restartRequired)
    #expect(claude.lines == [.restart("Run `claude` in a new terminal tab to finish setup")])
    let codex = codexRow(.configuredAwaitingRestart(codexAwaitingText), statusText: codexAwaitingText)
    #expect(codex.badge == .restartRequired)
    #expect(codex.lines == [.restart("Quit and reopen Codex, or run `codex` in a new terminal tab, and allow Herdly's hooks if Codex asks")])
}

@Test func notConfiguredReadsOffWithASwitchThatTurnsOn() {
    let codex = codexRow(.notConfigured, installed: false)
    #expect(codex == AgentSettingsRow(badge: .off, hooksInstalled: false, setupCanRun: true, lines: []))
    #expect(AgentSwitchChange.change(to: true, codex) == .configure)
    #expect(codex.accessibilityLabel(name: "Codex") == "Codex, Off")
    let claude = claudeRow(.notConfigured, installed: false, usageInstalled: false, usageStatus: .unavailable("x"))
    #expect(claude == AgentSettingsRow(badge: .off, hooksInstalled: false, setupCanRun: true, lines: []))
    #expect(AgentSwitchChange.change(to: true, claude) == .configure)
}

@Test func aPreviewThatIsNotReadyKeepsAnOffSwitchDisabledWithAReason() {
    let codex = codexRow(.notConfigured, installed: false, planReady: false)
    #expect(!codex.switchEnabled)
    #expect(AgentSwitchChange.change(to: true, codex) == nil)
    #expect(codex.lines == [.note("Herdly can't set this up yet. Choose Review Again from the ⋯ menu.")])
    let claude = claudeRow(.notConfigured, installed: false, planReady: false)
    #expect(!claude.switchEnabled)
    #expect(AgentSwitchChange.change(to: true, claude) == nil)
    #expect(claude.lines == [.note("Herdly can't set this up yet. Choose Review Again from the ⋯ menu.")])
}

@Test func installedHooksCanAlwaysBeTurnedOffEvenWhenSetupCannotRun() {
    let codexText = "Codex config.toml is not valid enough to verify safely."
    let codex = codexRow(.malformed(codexText), planReady: false, statusText: codexText)
    #expect(codex.switchEnabled && codex.canTurnOff && !codex.canTurnOn)
    #expect(AgentSwitchChange.change(to: false, codex) == .undo)
    #expect(AgentSwitchChange.change(to: true, codex) == nil)
    // Claude Code uninstalled after setup: Undo stays reachable.
    let claude = claudeRow(.unsupported("Claude Code version unknown is older than the tested minimum 2.1.273."),
                           capabilities: ClaudeCapabilities(installed: false, supported: false), planReady: false)
    #expect(claude.switchEnabled && claude.canTurnOff)
    #expect(AgentSwitchChange.change(to: false, claude) == .undo)
    #expect(claude.lines == [.note("Claude Code isn't installed")])
}

@Test func aMissingAgentDisablesTheSwitchAndSaysWhy() {
    let codex = codexRow(.unsupported("No supported Codex runtime was detected."),
                         capabilities: codexCaps(cli: (false, false), desktop: (false, false)),
                         installed: false, planReady: false)
    #expect(codex == AgentSettingsRow(badge: .off, hooksInstalled: false, setupCanRun: false,
                                      lines: [.note("Codex isn't installed")]))
    #expect(!codex.switchEnabled)
    let claude = claudeRow(.unsupported("Claude Code version unknown is older than the tested minimum 2.1.273."),
                           capabilities: ClaudeCapabilities(installed: false, supported: false),
                           installed: false, planReady: false)
    #expect(claude == AgentSettingsRow(badge: .off, hooksInstalled: false, setupCanRun: false,
                                       lines: [.note("Claude Code isn't installed")]))
}

@Test func anOutdatedAgentKeepsItsVersionLineAndCannotBeSwitchedOn() {
    let claude = claudeRow(.unsupported("Claude Code 2.1.4 is older than the tested minimum 2.1.273."),
                           capabilities: ClaudeCapabilities(installed: true, supported: false, version: "2.1.4"),
                           installed: false, planReady: false)
    #expect(claude.badge == .off)
    #expect(!claude.switchEnabled)
    #expect(claude.lines == [.problem(AgentProblem(kind: .claudeVersion, label: "Claude Code", value: "Update to 2.1.273 or later"),
                                      configures: false)])
    let codex = codexRow(.connected, capabilities: codexCaps(cli: (true, true), desktop: (true, false)))
    #expect(codex.badge == .needsAttention)
    #expect(codex.lines == [.problem(AgentProblem(kind: .codexDesktop, label: "Codex desktop", value: "Update to 26.901.51231 or later"),
                                     configures: false)])
}

@Test func hooksWithoutAnInstallRecordNeedAttentionAndClaimNoRestart() {
    // Herdly's hook entries are in settings.json but its install record is gone: detection reads a
    // conflict, the preview refuses to run, and the switch shows no installed hooks. An update since
    // then can't be finished by a restart Herdly could verify, so the row shows only the conflict.
    let text = "Herdly Claude setup state is missing; review this root's settings.json before reconnecting."
    let row = claudeRow(.conflict(text), installed: false, planReady: false, restartAfterUpdate: true, statusText: text)
    #expect(row.badge == .needsAttention)
    #expect(row.lines == [.problem(AgentProblem(kind: .status, label: "Status", value: text), configures: false)])
    #expect(!row.switchEnabled)
    #expect(AgentSwitchChange.change(to: true, row) == nil)
}

@Test func theSwitchTurnsOnOnlyWithoutAnInstallRecordForBothAgents() {
    // Repair statuses only arise once Herdly's install record exists, so the switch is already on and
    // the repair runs from the status line's Configure. With no record, only Not configured turns on.
    let codexText = "Herdly's Codex hook entries are missing; Configure Codex to repair setup."
    let claudeText = "Herdly's Claude hook entries are missing; Configure Claude to repair setup."
    for row in [codexRow(.repairRequired(codexText), installed: false, statusText: codexText),
                claudeRow(.repairRequired(claudeText), installed: false, requiresConfigure: true, statusText: claudeText)] {
        #expect(!row.canTurnOn)
        #expect(AgentSwitchChange.change(to: true, row) == nil)
    }
    for row in [codexRow(.notConfigured, installed: false), claudeRow(.notConfigured, installed: false)] {
        #expect(row.canTurnOn)
    }
    for row in [codexRow(.repairRequired(codexText), statusText: codexText),
                claudeRow(.repairRequired(claudeText), requiresConfigure: true, statusText: claudeText)] {
        #expect(!row.canTurnOn && row.canTurnOff)
        #expect(row.lines.contains { if case .problem(_, configures: true) = $0 { true } else { false } })
    }
}

@Test func anInstalledRowNeverOffersTurningOn() {
    let row = AgentSettingsRow(badge: .ready, hooksInstalled: true, setupCanRun: true, lines: [])
    #expect(!row.canTurnOn)
    #expect(AgentSwitchChange.change(to: true, row) == nil)
}

@Test func aRepairLineOffersConfigureWhileTheSwitchStaysOn() {
    let text = "Herdly's Claude hook entries are missing; Configure Claude to repair setup."
    let claude = claudeRow(.repairRequired(text), requiresConfigure: true, statusText: text)
    #expect(claude.badge == .needsAttention)
    #expect(claude.hooksInstalled && claude.switchEnabled)
    #expect(claude.lines == [.problem(AgentProblem(kind: .status, label: "Status", value: text), configures: true)])
    let codexText = "Herdly's Codex hook entries are missing; Configure Codex to repair setup."
    let codex = codexRow(.repairRequired(codexText), statusText: codexText)
    #expect(codex.lines == [.problem(AgentProblem(kind: .status, label: "Status", value: codexText), configures: true)])
}

@Test func usageNeverAsksForConfigureAndWaitsQuietlyWhenNotYetAdded() {
    // Detection adds the bridge on its own (#481, owner decision): a folder whose bridge isn't in place
    // yet gets one quiet line, never a Configure button, and stays Ready.
    let row = claudeRow(.connected, requiresConfigure: false, plannedUsage: .ready, usageInstalled: false,
                        usageStatus: .unavailable("Claude usage unavailable: the status-line compatibility probe did not pass; Claude connection remains active."))
    #expect(row.badge == .ready)
    #expect(row.lines == [.note("Usage limits are unavailable until Herdly can add its status line")])
}

@Test func anIncompatibleStatusLineReadsUsageUnavailableWithoutAskingToConfigure() {
    let message = ClaudeUsageSetupStatus.compatibilityFailureMessage
    let row = claudeRow(.connected, plannedUsage: .unavailable(message), usageInstalled: false,
                        usageStatus: .unavailable(message))
    #expect(row.badge == .ready)
    #expect(row.lines == [.note(message)])
}

@Test func newHooksAndOtherPendingSetupOfferConfigureOnAWorkingFolder() {
    let hooks = claudeRow(.connected, requiresConfigure: true, addsHooks: true)
    #expect(hooks.badge == .ready)
    #expect(hooks.lines == [.problem(AgentProblem(kind: .newHooks, label: "New hooks",
                                                  value: "New hooks are available, such as file approvals"), configures: true)])
    let other = claudeRow(.connected, requiresConfigure: true)
    #expect(other.badge == .ready)
    #expect(other.lines == [.problem(AgentProblem(kind: .pendingSetup, label: "Setup",
                                                  value: "Herdly's setup for this folder has changes to apply"), configures: true)])
}

@Test func problemLineTextNamesTheAppForVersionsOnly() {
    let version = AgentProblem(kind: .codexCLI, label: "Codex CLI", value: "Update to 0.145.0 or later")
    #expect(AgentRowLine.text(version, value: "Updating…") == "Codex CLI: Updating…")
    let status = AgentProblem(kind: .status, label: "Status", value: "Not ready.")
    #expect(AgentRowLine.text(status, value: status.value) == "Not ready.")
    #expect(AgentUpdateTarget(.pendingSetup) == nil)
}

@Test func folderSetupCountsOnlyAReadyPreview() {
    let setup = ClaudeFolderSetup(plan: nil, usageInstalled: true, usageStatus: .ready)
    #expect(setup == ClaudeFolderSetup(planReady: false, usageInstalled: true, usageStatus: .ready))
}

// MARK: - Diagnostics wording

@Test func surfaceVersionSaysWhyAVersionIsNotUsable() {
    #expect(AgentDiagnostics.surfaceVersion(installed: false, supported: false, version: nil, minimum: "1.3") == "Not installed")
    #expect(AgentDiagnostics.surfaceVersion(installed: true, supported: false, version: "1.2", minimum: "1.3") == "1.2 · needs 1.3 or later")
    #expect(AgentDiagnostics.surfaceVersion(installed: true, supported: true, version: nil, minimum: "1.3") == "Installed")
}

@Test func codexDiagnosticsListEachSurfaceThenHooksAndStatus() {
    let text = AgentDiagnostics.codex(codexCaps(cli: (true, true), desktop: (true, false)), installed: true,
                                      statusText: "Codex event delivery connected")
    #expect(text == """
        Codex CLI 0.150.0: available
        Codex desktop 26.1015.1: unsupported; requires ≥ \(CodexSetupRequirements.minimumDesktopVersion)
        Ghostty: unavailable
        Herdly hooks: installed
        Status: Codex event delivery connected
        """)
}

@Test func claudeDiagnosticsNameVersionFolderUsageAndSessions() {
    let text = AgentDiagnostics.claude(claudeCaps, displayPath: "~/.claude", installed: true, statusText: "Connected",
                                       usageInstalled: true, usage: .reading("5h 12% · 7d 42%"),
                                       activeSessions: "No active sessions need restart.")
    #expect(text == """
        Claude Code 2.1.300: supported
        Folder: ~/.claude
        Herdly hooks: installed
        Status: Connected
        Usage limits: 5h 12% · 7d 42%
        Active sessions: No active sessions need restart.
        """)
    let off = AgentDiagnostics.claude(ClaudeCapabilities(installed: false, supported: false), displayPath: "~/.c",
                                      installed: false, statusText: "Not configured", usageInstalled: false,
                                      usage: .unavailable, activeSessions: "x")
    #expect(off.hasPrefix("Claude Code version unknown: not installed\n"))
    #expect(off.contains("Usage limits: not installed"))
}

@Test func usagePlanSaysWhatConfigureDoesWithTheStatusLine() {
    #expect(AgentDiagnostics.usagePlan(.ready, usageInstalled: false) == "usage limits (always on): wraps the existing status line")
    #expect(AgentDiagnostics.usagePlan(.ready, usageInstalled: true) == "usage limits (always on): installed")
    #expect(AgentDiagnostics.usagePlan(.unavailable("probe failed"), usageInstalled: false)
        == "usage limits (always on): unavailable; status line left as it is (probe failed)")
    #expect(AgentDiagnostics.usageText(.unavailable) == "no current window")
}

@Test func claudeSetupChangesListTheOwnedFilesAndTheUsagePlan() throws {
    let plan = ClaudeSetupPlanner.plan(capabilities: ClaudeCapabilities(installed: true, supported: true, version: "2.1.300"),
                                       settings: Data("{}".utf8), helperPath: URL(fileURLWithPath: "/s/claude/HerdlyHook"),
                                       eventsPath: URL(fileURLWithPath: "/s/events"),
                                       policy: ClaudeSetupPolicy(titleSettingRequired: false), usageEnabled: true)
    let text = AgentDiagnostics.claudeSetupChanges(plan, settingsPath: "/c/settings.json", helperPath: "/s/claude/HerdlyHook",
                                                   eventsPath: "/s/events", statePath: "/s/claude/install.json",
                                                   backupsPath: "/s/claude/backups", usageInstalled: false)
    let lines = text.components(separatedBy: "\n")
    #expect(lines.first == "settings.json: /c/settings.json")
    #expect(lines.contains("  hooks.SessionStart matcher=<any> command=\(plan.ownedHooks.first { $0.event == "SessionStart" }?.command ?? "") timeout=\(ClaudeSetupRequirements.hookTimeout)"))
    #expect(lines.contains("  env.\(ClaudeSetupRequirements.titleDisableEnvironmentKey): not needed (Claude binds by tty here); left as it is"))
    #expect(lines.contains("owned install record: /s/claude/install.json"))
    #expect(lines.last == "usage limits (always on): wraps the existing status line")
}
