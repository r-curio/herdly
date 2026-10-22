import Foundation
import Testing
@testable import HerdlyCore

private func codex(cliVersion: String? = "0.140.2", cliSupported: Bool = false, cliInstalled: Bool = true,
                   cliInstall: CodexCLIInstall = .homebrewCask(brew: "/opt/homebrew/bin/brew"),
                   desktopSupported: Bool = false, desktopInstalled: Bool = true,
                   desktopPath: String? = "/Applications/ChatGPT.app") -> CodexCapabilities {
    CodexCapabilities(cli: cliSupported, desktop: desktopSupported, ghostty: false,
                      supported: cliSupported || desktopSupported, cliVersion: cliVersion,
                      desktopVersion: "26.721.31836", cliInstalled: cliInstalled, desktopInstalled: desktopInstalled,
                      cliInstall: cliInstall, desktopPath: desktopPath)
}

private let claudeCommand = AgentUpdateCommand(executable: "/Users/me/.local/bin/claude", arguments: ["update"])
private let brewCommand = AgentUpdateCommand(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "--cask", "codex"])

private func finished(_ status: Int32, out: String = "", err: String = "") -> AgentUpdateRunResult {
    .finished(status: status, output: Data(out.utf8), errors: Data(err.utf8))
}

// MARK: Install method and row actions

@Test func aCLIInsideTheHomebrewCaskroomIsTheCaskWithBrewFromItsPrefix() {
    #expect(CodexCLIInstall.classify(resolvedPath: "/opt/homebrew/Caskroom/codex/0.145.0/codex-aarch64-apple-darwin")
            == .homebrewCask(brew: "/opt/homebrew/bin/brew"))
    #expect(CodexCLIInstall.classify(resolvedPath: "/usr/local/Caskroom/codex/0.140.2/codex-x86_64-apple-darwin")
            == .homebrewCask(brew: "/usr/local/bin/brew"))
}

@Test func anyOtherOrMissingCLIPathIsAnUnknownInstall() {
    #expect(CodexCLIInstall.classify(resolvedPath: "/opt/homebrew/Cellar/codex/0.140.2/bin/codex") == .unknown)
    #expect(CodexCLIInstall.classify(resolvedPath: "/opt/homebrew/Caskroom/codex-nightly/1/codex") == .unknown)
    #expect(CodexCLIInstall.classify(resolvedPath: "/Users/me/.npm-global/lib/node_modules/@openai/codex/bin/codex.js") == .unknown)
    #expect(CodexCLIInstall.classify(resolvedPath: "/Caskroom/codex/1/codex") == .unknown)
    #expect(CodexCLIInstall.classify(resolvedPath: nil) == .unknown)
}

@Test func outdatedCaskCLIOffersBrewUpgrade() {
    #expect(AgentRowAction.codex(.codexCLI, codex()) == .update(brewCommand))
}

@Test func outdatedCLIInstalledAnotherWayOffersNoButton() {
    #expect(AgentRowAction.codex(.codexCLI, codex(cliInstall: .unknown)) == .none)
}

@Test func outdatedDesktopOffersOpenCodexForTheSelectedApp() {
    #expect(AgentRowAction.codex(.codexDesktop, codex()) == .openApp("/Applications/ChatGPT.app"))
    #expect(AgentRowAction.codex(.codexDesktop, codex(desktopPath: nil)) == .none)
}

@Test func missingOrSupportedSurfacesAndOtherProblemsOfferNoButton() {
    #expect(AgentRowAction.codex(.codexCLI, codex(cliInstalled: false)) == .none)
    #expect(AgentRowAction.codex(.codexCLI, codex(cliSupported: true)) == .none)
    #expect(AgentRowAction.codex(.codexDesktop, codex(desktopInstalled: false)) == .none)
    #expect(AgentRowAction.codex(.status, codex()) == .none)
    #expect(AgentRowAction.claude(.newHooks, ClaudeCapabilities(installed: true, supported: false,
                                                                executablePath: claudeCommand.executable)) == .none)
    #expect(AgentRowAction.claude(.usage, ClaudeCapabilities(installed: true, supported: false,
                                                             executablePath: claudeCommand.executable)) == .none)
}

@Test func outdatedClaudeAlwaysOffersClaudeUpdate() {
    let outdated = ClaudeCapabilities(installed: true, supported: false, version: "2.1.240",
                                      executablePath: claudeCommand.executable)
    #expect(AgentRowAction.claude(.claudeVersion, outdated) == .update(claudeCommand))
    #expect(AgentRowAction.claude(.claudeVersion, ClaudeCapabilities(installed: true, supported: true,
                                                                     executablePath: claudeCommand.executable)) == .none)
    #expect(AgentRowAction.claude(.claudeVersion, ClaudeCapabilities(installed: true, supported: false)) == .none)
}

@Test func theUnknownInstallFootnoteShowsOnlyWhileTheCLIRowHasNoButton() {
    #expect(AgentUpdates.codexInstallNote(codex(cliInstall: .unknown))
            == "Herdly can't tell how Codex CLI was installed, so it can't update it for you. Update it the way you installed it, then choose Review Again from the ⋯ menu.")
    #expect(AgentUpdates.codexInstallNote(codex()) == nil)
    #expect(AgentUpdates.codexInstallNote(codex(cliSupported: true, cliInstall: .unknown)) == nil)
    #expect(AgentUpdates.codexInstallNote(codex(cliInstalled: false, cliInstall: .unknown)) == nil)
}

// MARK: Row presentation

@Test func idleRowKeepsItsOrangeTextAndNamesTheAppForVoiceOver() {
    let row = AgentUpdates().row(.claudeCode, value: "Update to 2.1.273 or later", action: .update(claudeCommand))
    #expect(row == AgentUpdateRow(tone: .attention, text: "Update to 2.1.273 or later",
                                  button: .init(title: "Update", accessibilityLabel: "Update Claude Code", enabled: true)))
    let desktop = AgentUpdates().row(.codexDesktop, value: "Update to 26.901.51231 or later", action: .openApp("/A.app"))
    #expect(desktop.button == .init(title: "Open Codex", accessibilityLabel: "Open Codex", enabled: true))
    #expect(AgentUpdates().row(.codexCLI, value: "x", action: .none).button == nil)
}

@Test func updatingRowIsGreyWithItsButtonDisabled() {
    var updates = AgentUpdates()
    let result1 = updates.begin(.codexCLI)
    #expect(result1)
    let row = updates.row(.codexCLI, value: "Update to 0.145.0 or later", action: .update(brewCommand))
    #expect(row == AgentUpdateRow(tone: .progress, text: "Updating…",
                                  button: .init(title: "Update", accessibilityLabel: "Update Codex CLI", enabled: false)))
}

@Test func openedDesktopWaitsForCodexWithItsButtonStillEnabled() {
    var updates = AgentUpdates()
    updates.openedApp(.codexDesktop)
    #expect(updates.state(.codexDesktop) == .waitingForApp)
    let row = updates.row(.codexDesktop, value: "Update to 26.901.51231 or later", action: .openApp("/A.app"))
    #expect(row == AgentUpdateRow(tone: .progress, text: "Waiting for Codex to update itself",
                                  button: .init(title: "Open Codex", accessibilityLabel: "Open Codex", enabled: true)))
}

@Test func failedRowIsRedWithTryAgain() {
    var updates = AgentUpdates()
    _ = updates.begin(.claudeCode)
    updates.finish(.claudeCode, command: claudeCommand, result: .timedOut, version: "2.1.240", meetsMinimum: false, now: 10)
    let row = updates.row(.claudeCode, value: "Update to 2.1.273 or later", action: .update(claudeCommand))
    #expect(row == AgentUpdateRow(tone: .failure, text: "Couldn't update: took too long",
                                  button: .init(title: "Try Again", accessibilityLabel: "Update Claude Code again", enabled: true)))
}

// MARK: Transitions

@Test func aSecondStartOnAnUpdatingRowDoesNothing() {
    var updates = AgentUpdates()
    let result2 = updates.begin(.claudeCode)
    #expect(result2)
    let result3 = updates.begin(.claudeCode)
    #expect(!result3)
    #expect(updates.state(.claudeCode) == .updating)
}

@Test func rowsUpdateIndependently() {
    var updates = AgentUpdates()
    let result4 = updates.begin(.claudeCode)
    #expect(result4)
    let result5 = updates.begin(.codexCLI)
    #expect(result5)
    updates.finish(.codexCLI, command: brewCommand, result: finished(1, err: "Error: Another `brew update` process is already running."),
                   version: "0.140.2", meetsMinimum: false, now: 5)
    #expect(updates.state(.claudeCode) == .updating)
    #expect(updates.state(.codexCLI) == .failed("Another `brew update` process is already running."))
    let result6 = updates.begin(.codexCLI)
    #expect(result6)
}

@Test func successClearsTheRowAndRequiresARestartWithAFootnote() {
    var updates = AgentUpdates()
    _ = updates.begin(.claudeCode)
    let message = updates.finish(.claudeCode, command: claudeCommand, result: finished(0, out: "Successfully updated"),
                                 version: "2.1.308", meetsMinimum: true, now: 100)
    #expect(updates.state(.claudeCode) == .idle)
    #expect(message == "Updated Claude Code to 2.1.308. Sessions already open keep the old version until you restart them.")
    #expect(updates.restartRequired(.claude))
    #expect(!updates.restartRequired(.codex))
    #expect(updates.header(.attention("Not ready"), for: .claude) == .attention("Restart required"))
    #expect(updates.header(.connected, for: .codex) == .connected)
}

@Test func aZeroExitThatLeavesTheVersionOutdatedIsNotASuccess() {
    var updates = AgentUpdates()
    _ = updates.begin(.claudeCode)
    let message = updates.finish(.claudeCode, command: claudeCommand, result: finished(0), version: "2.1.240",
                                 meetsMinimum: false, now: 100)
    #expect(message == nil)
    #expect(updates.state(.claudeCode) == .failed("still 2.1.240 afterwards"))
    #expect(!updates.restartRequired(.claude))
    _ = updates.begin(.claudeCode)
    updates.finish(.claudeCode, command: claudeCommand, result: finished(0), version: nil, meetsMinimum: false, now: 100)
    #expect(updates.state(.claudeCode) == .failed("couldn't read the new version"))
}

@Test func aFailureLeavesTheHeaderStatusUnchanged() {
    var updates = AgentUpdates()
    _ = updates.begin(.codexCLI)
    updates.finish(.codexCLI, command: brewCommand, result: .couldNotStart, version: "0.140.2", meetsMinimum: false, now: 1)
    #expect(updates.state(.codexCLI) == .failed("brew not found"))
    #expect(updates.header(.attention("Not ready"), for: .codex) == .attention("Not ready"))
}

@Test func aLateResultForARowNotUpdatingIsIgnored() {
    var updates = AgentUpdates()
    let message = updates.finish(.claudeCode, command: claudeCommand, result: finished(0), version: "2.1.308",
                                 meetsMinimum: true, now: 1)
    #expect(message == nil)
    #expect(updates.state(.claudeCode) == .idle)
    #expect(!updates.restartRequired(.claude))
}

@Test func theDesktopRowStopsWaitingOnceDetectionSeesTheMinimum() {
    var updates = AgentUpdates()
    updates.openedApp(.codexDesktop)
    let result7 = updates.detected(.codexDesktop, version: "26.800.1", meetsMinimum: false, now: 5)
    #expect(result7 == nil)
    #expect(updates.state(.codexDesktop) == .waitingForApp)
    let message = updates.detected(.codexDesktop, version: "26.1016.51333", meetsMinimum: true, now: 6)
    #expect(updates.state(.codexDesktop) == .idle)
    #expect(message == "Updated Codex desktop to 26.1016.51333. Sessions already open keep the old version until you restart them.")
    #expect(updates.restartRequired(.codex))
}

@Test func detectionDoesNotTouchARowThatIsNotWaiting() {
    var updates = AgentUpdates()
    let result8 = updates.detected(.codexDesktop, version: "26.1016.51333", meetsMinimum: true, now: 6)
    #expect(result8 == nil)
    #expect(!updates.restartRequired(.codex))
}

@Test func bothCodexSurfacesUpdatedShareOneFootnote() {
    var updates = AgentUpdates()
    _ = updates.begin(.codexCLI)
    updates.finish(.codexCLI, command: brewCommand, result: finished(0), version: "0.146.1", meetsMinimum: true, now: 1)
    updates.openedApp(.codexDesktop)
    let message = updates.detected(.codexDesktop, version: "26.1016.51333", meetsMinimum: true, now: 2)
    #expect(message == "Updated Codex CLI to 0.146.1 and Codex desktop to 26.1016.51333. Sessions already open keep the old version until you restart them.")
}

// MARK: Restart required

@Test func restartRequiredClearsOnlyOnTheMatchingAgentsNextSessionStart() {
    var updates = AgentUpdates()
    _ = updates.begin(.claudeCode)
    updates.finish(.claudeCode, command: claudeCommand, result: finished(0), version: "2.1.308", meetsMinimum: true, now: 100)
    _ = updates.begin(.codexCLI)
    updates.finish(.codexCLI, command: brewCommand, result: finished(0), version: "0.146.1", meetsMinimum: true, now: 200)

    updates.sessionStarted(.codex, at: 150)       // before the Codex update: an old session
    #expect(updates.restartRequired(.codex))
    updates.sessionStarted(.codex, at: 250)
    #expect(!updates.restartRequired(.codex))
    #expect(updates.restartRequired(.claude))
    #expect(updates.header(.connected, for: .codex) == .connected)

    updates.sessionStarted(.claude, at: 99)
    #expect(updates.restartRequired(.claude))
    updates.sessionStarted(.claude, at: 100)
    #expect(!updates.restartRequired(.claude))
}

@Test func restartRequiredNeverReplacesChecking() {
    var updates = AgentUpdates()
    _ = updates.begin(.claudeCode)
    updates.finish(.claudeCode, command: claudeCommand, result: finished(0), version: "2.1.308", meetsMinimum: true, now: 1)
    #expect(updates.header(.checking, for: .claude) == .checking)
}

// MARK: Failure reasons from runner output

@Test func failureReasonPrefersTheLastErrorLineOfStderr() {
    let err = "==> Upgrading codex\n\u{1B}[31mError:\u{1B}[0m Download failed: no internet connection\nHint: try again later\n"
    #expect(AgentUpdateFailure.reason(finished(1, err: err), command: brewCommand) == "Download failed: no internet connection")
}

@Test func failureReasonFallsBackToTheLastMeaningfulLine() {
    #expect(AgentUpdateFailure.reason(finished(2, err: "something broke\n  \n---\n"), command: claudeCommand) == "something broke")
    #expect(AgentUpdateFailure.reason(finished(2, out: "network unreachable\n"), command: claudeCommand) == "network unreachable")
}

@Test func emptyOrMalformedOutputStillGivesAPlainReason() {
    #expect(AgentUpdateFailure.reason(finished(3), command: claudeCommand) == "claude exited with status 3")
    let malformed = AgentUpdateRunResult.finished(status: 4, output: Data([0xFF, 0xFE, 0x00]), errors: Data([0xC3, 0x28, 0x0A]))
    #expect(AgentUpdateFailure.reason(malformed, command: brewCommand) == "brew exited with status 4")
}

@Test func longReasonsAreShortenedOnAWordBoundary() {
    let long = "Error: " + Array(repeating: "verylongword", count: 12).joined(separator: " ")
    let reason = AgentUpdateFailure.reason(finished(1, err: long), command: brewCommand)
    #expect(reason?.hasSuffix("…") == true)
    #expect((reason?.count ?? 0) <= AgentUpdateFailure.maximumReasonLength)
    #expect(reason?.hasPrefix("verylongword verylongword") == true)
}

@Test func timeoutAndMissingToolHaveFixedReasons() {
    #expect(AgentUpdateFailure.reason(.timedOut, command: claudeCommand) == "took too long")
    #expect(AgentUpdateFailure.reason(.couldNotStart, command: claudeCommand) == "claude not found")
    #expect(AgentUpdateFailure.reason(finished(0, err: "warning"), command: claudeCommand) == nil)
}

@Test func codexSessionStartsComeFromEitherSurfaceAndIgnoreUnreadableTimes() {
    let session = UUID()
    let cli: [CLIEvent] = [.sessionStarted(session: session, receivedAt: "2026-10-22T10:00:00Z"),
                           .turnStarted(session: session, turn: UUID(), receivedAt: "2026-10-22T12:00:00Z")]
    let desktop: [DesktopEvent] = [.sessionStarted(session: UUID(), receivedAt: "2026-10-22T11:00:00.500Z"),
                                   .sessionStarted(session: UUID(), receivedAt: "not a time")]
    #expect(AgentUpdates.latestCodexSessionStart(cliEvents: cli, desktopEvents: desktop)
            == RolloutTimestamp.parse("2026-10-22T11:00:00.500Z"))
    #expect(AgentUpdates.latestCodexSessionStart(cliEvents: [], desktopEvents: [.sessionStarted(session: session, receivedAt: "")]) == nil)
}
