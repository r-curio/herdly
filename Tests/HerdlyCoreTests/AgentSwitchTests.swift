import Foundation
import Testing
@testable import HerdlyCore
@testable import HerdlyApp

// Settings › Agents switches and always-on Claude features (#481, A3–A4). Every file lives in a
// temporary directory; the real ~/.codex and ~/.claude are never read or written.

private let claudeCapabilities = ClaudeCapabilities(installed: true, supported: true, version: "2.1.300")

private func temporaryRoot(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("herdly-\(name)-" + UUID().uuidString, isDirectory: true)
}

/// The folder's setup as the Claude row reads it, from a temporary config folder and support folder.
private func claudeSnapshot(_ config: URL, support: URL) -> ClaudeSetupDetection.Snapshot {
    ClaudeSetupDetection.setupSnapshot(root: config, applicationSupport: support, capabilities: claudeCapabilities,
                                       inventoryStatus: .available(restartCount: 0), titleSettingRequired: false)
}

private func claudeRow(_ snapshot: ClaudeSetupDetection.Snapshot) -> AgentSettingsRow {
    AgentSettingsRow.claude(snapshot.capabilities, status: snapshot.status,
                            statusText: ClaudeSetupModel.statusText(snapshot.status), installed: snapshot.installed,
                            setup: ClaudeFolderSetup(plan: snapshot.plan, usageInstalled: snapshot.usageInstalled,
                                                     usageStatus: snapshot.usageStatus),
                            restartAfterUpdate: false)
}

@Test func theSwitchRunsConfigureWhenTurnedOnAndUndoWhenTurnedOff() {
    let off = AgentSettingsRow(badge: .off, hooksInstalled: false, canTurnOn: true, lines: [])
    let on = AgentSettingsRow(badge: .ready, hooksInstalled: true, canTurnOn: false, lines: [])
    let blocked = AgentSettingsRow(badge: .off, hooksInstalled: false, canTurnOn: false, lines: [.note("Codex isn't installed")])
    #expect(AgentSwitchChange.change(to: true, off) == .configure)
    #expect(AgentSwitchChange.change(to: false, on) == .undo)
    #expect(AgentSwitchChange.change(to: true, on) == nil)
    #expect(AgentSwitchChange.change(to: false, off) == nil)
    #expect(AgentSwitchChange.change(to: true, blocked) == nil)
}

@Test func codexSwitchOffRemovesExactlyWhatUndoRemovesAndOnReinstalls() throws {
    let root = temporaryRoot("codex-switch")
    defer { try? FileManager.default.removeItem(at: root) }
    let roots = CodexSetupRoots(configDirectory: root.appendingPathComponent("codex", isDirectory: true),
                                helperDirectory: root.appendingPathComponent("Herdly", isDirectory: true),
                                eventsDirectory: root.appendingPathComponent("Herdly/events", isDirectory: true))
    try FileManager.default.createDirectory(at: roots.configDirectory, withIntermediateDirectories: true)
    let config = Data("[tui]\nfont_size = 14\n".utf8)
    let hooks = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/keep"}]}]}}"#.utf8)
    try config.write(to: roots.configURL)
    try hooks.write(to: roots.hooksURL)
    let capabilities = CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true,
                                         cliVersion: "0.150.0", cliInstalled: true)
    let installer = CodexSetupInstaller()

    func row() -> AgentSettingsRow {
        let snapshot = CodexSetupDetection.setupSnapshot(roots: roots, capabilities: capabilities)
        let ready: Bool = if let plan = snapshot.plan, case .ready = plan.status { true } else { false }
        return AgentSettingsRow.codex(capabilities, status: snapshot.status, statusText: "", installed: snapshot.installed,
                                      planReady: ready, ghosttyAutomationVerified: true, restartAfterUpdate: false)
    }
    func configure() throws {
        let snapshot = CodexSetupDetection.setupSnapshot(roots: roots, capabilities: capabilities)
        _ = try installer.install(try #require(snapshot.plan), roots: roots, helper: Data("helper".utf8),
                                  capabilities: capabilities)
    }

    #expect(row().badge == .off)
    #expect(AgentSwitchChange.change(to: true, row()) == .configure)
    try configure()
    #expect(row().hooksInstalled)
    #expect(row().badge == .restartRequired)
    #expect(row().lines == [.restart("Quit and reopen Codex, or run `codex` in a new terminal tab, to finish setup"),
                            .note("If Codex asks whether to trust Herdly's hooks, allow them")])

    #expect(AgentSwitchChange.change(to: false, row()) == .undo)
    #expect(try installer.undo(roots: roots) == .notConfigured)
    #expect(try Data(contentsOf: roots.configURL) == config)
    #expect(try Data(contentsOf: roots.hooksURL) == hooks)
    #expect(!FileManager.default.fileExists(atPath: roots.helperURL.path))
    #expect(!FileManager.default.fileExists(atPath: roots.stateURL.path))
    #expect(row() == AgentSettingsRow(badge: .off, hooksInstalled: false, canTurnOn: true, lines: []))

    #expect(AgentSwitchChange.change(to: true, row()) == .configure)
    try configure()
    #expect(row().hooksInstalled)
    #expect(FileManager.default.fileExists(atPath: roots.helperURL.path))
}

@Test func claudeSwitchOffRestoresSettingsByteForByteAndOnReinstalls() throws {
    let root = temporaryRoot("claude-switch")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let original = Data(#"{"model":"opus","statusLine":{"type":"command","command":"cat","padding":2}}"#.utf8)
    let roots = ClaudeSetupDetection.setupRoots(configDirectory: config, applicationSupport: support)
    try original.write(to: roots.settingsURL)
    let installer = ClaudeSetupInstaller()

    func configure() throws {
        let plan = try #require(claudeSnapshot(config, support: support).plan)
        _ = try installer.install(plan, roots: roots, helper: Data("helper".utf8), capabilities: claudeCapabilities)
    }

    let before = claudeRow(claudeSnapshot(config, support: support))
    #expect(before == AgentSettingsRow(badge: .off, hooksInstalled: false, canTurnOn: true, lines: []))
    #expect(AgentSwitchChange.change(to: true, before) == .configure)
    try configure()
    let installedRow = claudeRow(claudeSnapshot(config, support: support))
    #expect(installedRow.hooksInstalled)
    #expect(installedRow.badge == .restartRequired)
    #expect(installedRow.lines == [.restart("Run `claude` in a new terminal tab to finish setup")])
    // Usage is on without any opt-in: the user's status line is wrapped.
    #expect(String(data: try Data(contentsOf: roots.settingsURL), encoding: .utf8)?.contains("--claude-status-line") == true)

    #expect(AgentSwitchChange.change(to: false, installedRow) == .undo)
    #expect(try installer.undo(roots: roots) == .notConfigured)
    #expect(try Data(contentsOf: roots.settingsURL) == original)
    #expect(!FileManager.default.fileExists(atPath: roots.stateURL.path))
    #expect(!FileManager.default.fileExists(atPath: roots.helperURL.path))
    #expect(claudeRow(claudeSnapshot(config, support: support)).badge == .off)

    try configure()
    #expect(claudeRow(claudeSnapshot(config, support: support)).hooksInstalled)
}

@Test func aFolderConfiguredWithUsageOffNowGetsUsage() throws {
    let root = temporaryRoot("claude-usage-migration")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let roots = ClaudeSetupDetection.setupRoots(configDirectory: config, applicationSupport: support)
    let original = Data(#"{"statusLine":{"type":"command","command":"cat"}}"#.utf8)
    try original.write(to: roots.settingsURL)
    // Set up the way earlier versions did with usage left off.
    let offPlan = ClaudeSetupPlanner.plan(capabilities: claudeCapabilities, settings: original, helperPath: roots.helperURL,
                                          eventsPath: roots.eventsDirectory, sourceScope: config,
                                          policy: ClaudeSetupPolicy(titleSettingRequired: false), usageEnabled: false,
                                          settingsExisted: true, installRecordPresent: false)
    let installer = ClaudeSetupInstaller()
    _ = try installer.install(offPlan, roots: roots, helper: Data("helper".utf8), capabilities: claudeCapabilities)

    let upgraded = claudeSnapshot(config, support: support)
    let plan = try #require(upgraded.plan)
    #expect(plan.usageEnabled)
    #expect(plan.usageStatus == .ready)
    #expect(!upgraded.usageInstalled)
    #expect(claudeRow(upgraded).lines.contains(.problem(
        AgentProblem(kind: .usage, label: "Usage limits", value: "Usage limits need Herdly to wrap your status line"),
        configures: true)))

    _ = try installer.install(plan, roots: roots, helper: Data("helper".utf8), capabilities: claudeCapabilities)
    let after = claudeSnapshot(config, support: support)
    #expect(after.usageInstalled)
    #expect(after.usageStatus == .ready)
    #expect(!claudeRow(after).lines.contains { if case .problem = $0 { true } else { false } })
}

@Test func anIncompatibleStatusLineStaysByteIdenticalAndUsageReadsUnavailable() throws {
    let root = temporaryRoot("claude-usage-incompatible")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let roots = ClaudeSetupDetection.setupRoots(configDirectory: config, applicationSupport: support)
    let original = Data(#"{"statusLine":{"command":"sleep 2 & exit 0","type":"command"}}"#.utf8)
    try original.write(to: roots.settingsURL)
    let originalStatusLine = try #require(ClaudeSetupPlanner.memberData(original, key: "statusLine"))

    let snapshot = claudeSnapshot(config, support: support)
    let plan = try #require(snapshot.plan)
    #expect(plan.usageStatus == .unavailable(ClaudeUsageSetupStatus.compatibilityFailureMessage))
    #expect(ClaudeSetupPlanner.memberData(plan.settingsChange, key: "statusLine") == originalStatusLine)

    _ = try ClaudeSetupInstaller().install(plan, roots: roots, helper: Data("helper".utf8), capabilities: claudeCapabilities)
    let installed = try Data(contentsOf: roots.settingsURL)
    #expect(ClaudeSetupPlanner.memberData(installed, key: "statusLine") == originalStatusLine)
    let after = claudeSnapshot(config, support: support)
    #expect(!after.usageInstalled)
    let row = claudeRow(after)
    #expect(row.badge == .restartRequired)
    #expect(row.lines.contains { if case .note = $0 { true } else { false } })
    #expect(!row.lines.contains { if case .problem = $0 { true } else { false } })
}
