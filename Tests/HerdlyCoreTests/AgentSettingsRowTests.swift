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

private func claudeRow(_ status: ClaudeConnectionStatus, capabilities: ClaudeCapabilities = claudeCaps,
                       installed: Bool = true, planReady: Bool = true, requiresConfigure: Bool = false,
                       addsHooks: Bool = false, plannedUsage: ClaudeUsageSetupStatus? = .ready,
                       usageInstalled: Bool = true, usageStatus: ClaudeUsageSetupStatus = .ready,
                       restartAfterUpdate: Bool = false, statusText: String = "Status text") -> AgentSettingsRow {
    AgentSettingsRow.claude(checked: true, capabilities, status: status, statusText: statusText, installed: installed,
                            planReady: planReady, requiresConfigure: requiresConfigure, addsHooks: addsHooks,
                            plannedUsage: plannedUsage, usageInstalled: usageInstalled, usageStatus: usageStatus,
                            restartAfterUpdate: restartAfterUpdate)
}

@Test func restartLinesNameTheCommandForEachAgentAndReason() {
    #expect(AgentRestartReason.update.line(for: .claude) == "Run `claude` in a new terminal tab to finish updating")
    #expect(AgentRestartReason.setup.line(for: .claude) == "Run `claude` in a new terminal tab to finish setup")
    #expect(AgentRestartReason.update.line(for: .codex)
        == "Quit and reopen Codex, or run `codex` in a new terminal tab, to finish updating")
    #expect(AgentRestartReason.setup.line(for: .codex)
        == "Quit and reopen Codex, or run `codex` in a new terminal tab, to finish setup")
}

@Test func connectedRowsAreReadyWithTheSwitchOnAndNoLines() {
    let codex = AgentSettingsRow.codex(codexCaps(), status: .connected, statusText: "Codex event delivery connected",
                                       installed: true, planReady: true, restartAfterUpdate: false)
    #expect(codex == AgentSettingsRow(badge: .ready, hooksInstalled: true, switchEnabled: true, lines: []))
    #expect(codex.accessibilityLabel(name: "Codex") == "Codex, Ready")
    let claude = claudeRow(.connected)
    #expect(claude == AgentSettingsRow(badge: .ready, hooksInstalled: true, switchEnabled: true, lines: []))
}

@Test func rowsReadCheckingUntilTheFirstDetection() {
    let codex = AgentSettingsRow.codex(codexCaps(), status: nil, statusText: "", installed: false, planReady: false,
                                       restartAfterUpdate: false)
    #expect(codex.badge == nil && !codex.switchEnabled && codex.lines.isEmpty)
    #expect(codex.accessibilityLabel(name: "Codex") == "Codex, Checking")
    let claude = AgentSettingsRow.claude(checked: false, claudeCaps, status: .unavailable("Checking"), statusText: "",
                                         installed: false, planReady: false, requiresConfigure: false, addsHooks: false,
                                         plannedUsage: nil, usageInstalled: false, usageStatus: .off,
                                         restartAfterUpdate: false)
    #expect(claude.badge == nil && !claude.switchEnabled)
}

@Test func anUpdateAsksForARestartWithTheUpdateLine() {
    let claude = claudeRow(.connected, restartAfterUpdate: true)
    #expect(claude.badge == .restartRequired)
    #expect(claude.lines == [.restart("Run `claude` in a new terminal tab to finish updating")])
    #expect(claude.accessibilityLabel(name: "Claude Code") == "Claude Code, Restart required")
    let codex = AgentSettingsRow.codex(codexCaps(), status: .connected, statusText: "", installed: true, planReady: true,
                                       restartAfterUpdate: true)
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
    let codexText = "Configured; start a new Codex session to verify delivery. Existing sessions keep running without Herdly's hooks."
    let codex = AgentSettingsRow.codex(codexCaps(), status: .configuredAwaitingRestart(codexText), statusText: codexText,
                                       installed: true, planReady: true, restartAfterUpdate: false)
    #expect(codex.badge == .restartRequired)
    #expect(codex.lines == [.restart("Quit and reopen Codex, or run `codex` in a new terminal tab, to finish setup")])
}

@Test func notConfiguredReadsOffWithAnEnabledSwitchAndNoStatusLine() {
    let codex = AgentSettingsRow.codex(codexCaps(), status: .notConfigured, statusText: "Codex detected; Herdly is not configured.",
                                       installed: false, planReady: true, restartAfterUpdate: false)
    #expect(codex == AgentSettingsRow(badge: .off, hooksInstalled: false, switchEnabled: true, lines: []))
    #expect(codex.accessibilityLabel(name: "Codex") == "Codex, Off")
    let claude = claudeRow(.notConfigured, installed: false, usageInstalled: false, usageStatus: .unavailable("x"))
    #expect(claude == AgentSettingsRow(badge: .off, hooksInstalled: false, switchEnabled: true, lines: []))
}

@Test func aMissingAgentDisablesTheSwitchAndSaysWhy() {
    let codex = AgentSettingsRow.codex(codexCaps(cli: (false, false), desktop: (false, false)),
                                       status: .unsupported("No supported Codex runtime was detected."),
                                       statusText: "No supported Codex runtime was detected.",
                                       installed: false, planReady: false, restartAfterUpdate: false)
    #expect(codex == AgentSettingsRow(badge: .off, hooksInstalled: false, switchEnabled: false,
                                      lines: [.note("Codex isn't installed")]))
    let claude = claudeRow(.unsupported("Claude Code version unknown is older than the tested minimum 2.1.273."),
                           capabilities: ClaudeCapabilities(installed: false, supported: false),
                           installed: false, planReady: false)
    #expect(claude == AgentSettingsRow(badge: .off, hooksInstalled: false, switchEnabled: false,
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
    let codex = AgentSettingsRow.codex(codexCaps(cli: (true, true), desktop: (true, false)), status: .connected,
                                       statusText: "", installed: true, planReady: true, restartAfterUpdate: false)
    #expect(codex.badge == .needsAttention)
    #expect(codex.lines == [.problem(AgentProblem(kind: .codexDesktop, label: "Codex desktop", value: "Update to 26.901.51231 or later"),
                                     configures: false)])
}

@Test func aRepairLineOffersConfigureWhileTheSwitchStaysOn() {
    let text = "Herdly's Claude hook entries are missing; Configure Claude to repair setup."
    let claude = claudeRow(.repairRequired(text), requiresConfigure: true, statusText: text)
    #expect(claude.badge == .needsAttention)
    #expect(claude.hooksInstalled && claude.switchEnabled)
    #expect(claude.lines == [.problem(AgentProblem(kind: .status, label: "Status", value: text), configures: true)])
    let codexText = "Herdly's Codex hook entries are missing; Configure Codex to repair setup."
    let codex = AgentSettingsRow.codex(codexCaps(), status: .repairRequired(codexText), statusText: codexText,
                                       installed: true, planReady: true, restartAfterUpdate: false)
    #expect(codex.lines == [.problem(AgentProblem(kind: .status, label: "Status", value: codexText), configures: true)])
}

@Test func aFolderSetUpBeforeUsageWasAlwaysOnOffersConfigureAndStaysReady() {
    // Usage was opt-in before #481: a connected folder without the bridge, whose status line could be wrapped.
    let row = claudeRow(.connected, requiresConfigure: true, plannedUsage: .ready, usageInstalled: false,
                        usageStatus: .unavailable("Claude usage unavailable: the status-line compatibility probe did not pass; Claude connection remains active."))
    #expect(row.badge == .ready)
    #expect(row.lines == [.problem(AgentProblem(kind: .usage, label: "Usage limits",
                                                value: "Usage limits need Herdly to wrap your status line"), configures: true)])
}

@Test func anIncompatibleStatusLineReadsUsageUnavailableWithoutAskingToConfigure() {
    let message = ClaudeUsageSetupStatus.compatibilityFailureMessage
    let row = claudeRow(.connected, plannedUsage: .unavailable(message), usageInstalled: false,
                        usageStatus: .unavailable(message))
    #expect(row.badge == .ready)
    #expect(row.lines == [.note(message)])
}

@Test func newHooksOfferConfigureOnAWorkingFolder() {
    let row = claudeRow(.connected, requiresConfigure: true, addsHooks: true)
    #expect(row.badge == .ready)
    #expect(row.lines == [.problem(AgentProblem(kind: .newHooks, label: "New hooks",
                                                value: "New hooks are available, such as file approvals"), configures: true)])
}

@Test func problemLineTextNamesTheAppForVersionsOnly() {
    let version = AgentProblem(kind: .codexCLI, label: "Codex CLI", value: "Update to 0.145.0 or later")
    #expect(AgentRowLine.text(version, value: "Updating…") == "Codex CLI: Updating…")
    let status = AgentProblem(kind: .status, label: "Status", value: "Not ready.")
    #expect(AgentRowLine.text(status, value: status.value) == "Not ready.")
}
