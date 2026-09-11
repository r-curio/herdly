import Foundation
import Testing
@testable import SteerCore

@Test func setupPreviewRequiresConfigureAndPreservesExistingHooks() throws {
    let capabilities = CodexCapabilities(cli: true, desktop: true, ghostty: true, supported: true)
    let hooks = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/other"}]}]}}"#
    let plan = CodexSetupPlanner.plan(capabilities: capabilities,
                                      config: "[tui]\nfont_size = 14\n",
                                      hooks: Data(hooks.utf8),
                                      helperPath: URL(fileURLWithPath: "/tmp/Steer/SteerHook"),
                                      eventsPath: URL(fileURLWithPath: "/tmp/Steer/events"))
    #expect(plan.status == .ready)
    #expect(plan.requiresConfigure)
    #expect(plan.configChange == "[tui]\nfont_size = 14\nterminal_title = [\"session-id\"]\n")
    let object = try #require(JSONSerialization.jsonObject(with: plan.hooksChange) as? [String: Any])
    let stop = try #require(object["hooks"] as? [String: Any])["Stop"] as? [[String: Any]]
    #expect(stop?.count == 2)
    #expect((stop?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/usr/local/bin/other")
    #expect(plan.hooksChange != Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/other"}]}]}}"#.utf8))
    #expect(CodexSetupValidator.hasRequiredHooks(plan.hooksChange, command: plan.helperCommand))
    #expect(CodexSetupValidator.hasSessionTitle(in: plan.configChange))
}

@Test func setupPreviewRefusesMalformedConfigurationAndUnsupportedRuntime() {
    let unsupported = CodexSetupPlanner.plan(
        capabilities: CodexCapabilities(cli: false, desktop: false, ghostty: true, supported: false),
        config: "not = [valid",
        hooks: Data("{}".utf8),
        helperPath: URL(fileURLWithPath: "/tmp/helper"),
        eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(unsupported.status == .unsupported("No supported Codex runtime was detected."))

    let malformed = CodexSetupPlanner.plan(
        capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true),
        config: "[tui\n",
        hooks: Data("{}".utf8),
        helperPath: URL(fileURLWithPath: "/tmp/helper"),
        eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(malformed.status == .malformed("Codex config.toml is not valid enough to edit safely."))

    let unbalanced = CodexSetupPlanner.plan(
        capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true),
        config: "[tui]\nterminal_title = [\"session-id\"\n",
        hooks: Data("{}".utf8), helperPath: URL(fileURLWithPath: "/tmp/helper"), eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(unbalanced.status == .malformed("Codex config.toml is not valid enough to edit safely."))
}

@Test func setupInstallIsIdempotentAndUndoPreservesLaterConfigEdits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configRoot = root.appendingPathComponent("codex")
    let helperRoot = root.appendingPathComponent("Steer")
    let eventsRoot = helperRoot.appendingPathComponent("events")
    try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("[tui]\nfont_size = 14\n".utf8).write(to: configRoot.appendingPathComponent("config.toml"))
    let existing = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/keep"}]}]}}"#
    try Data(existing.utf8).write(to: configRoot.appendingPathComponent("hooks.json"))
    let helper = Data("helper-v1".utf8)
    let roots = CodexSetupRoots(configDirectory: configRoot, helperDirectory: helperRoot, eventsDirectory: eventsRoot)
    let plan = CodexSetupPlanner.plan(capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true),
                                      config: "[tui]\nfont_size = 14\n", hooks: Data(existing.utf8),
                                      helperPath: roots.helperURL, eventsPath: eventsRoot)
    let installer = CodexSetupInstaller()
    let firstStatus = try installer.install(plan, roots: roots, helper: helper,
                                  capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true))
    #expect(firstStatus == .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery."))
    #expect(try installer.install(plan, roots: roots, helper: helper,
                                  capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery."))
    #expect(((try FileManager.default.attributesOfItem(atPath: roots.helperURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0)
    let event: [String: String] = ["hook_event_name": "SessionStart", "session_id": UUID().uuidString, "received_at": "1"]
    try JSONSerialization.data(withJSONObject: event).write(to: eventsRoot.appendingPathComponent("event.json"))
    #expect(installer.status(roots: roots, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .connected)
    let installed = try String(contentsOf: roots.configURL)
    try Data((installed + "user_note = true\n").utf8).write(to: roots.configURL)
    #expect(throws: CodexSetupError.conflict("Codex or Steer's setup files changed after setup; undo made no changes.")) {
        _ = try installer.undo(roots: roots)
    }
    #expect(try String(contentsOf: roots.configURL) == installed + "user_note = true\n")
    try Data(installed.utf8).write(to: roots.configURL)
    #expect(try installer.undo(roots: roots) == .installed)
    #expect(try String(contentsOf: roots.configURL) == "[tui]\nfont_size = 14\n")
    let restoredHooks = try JSONSerialization.jsonObject(with: Data(contentsOf: roots.hooksURL)) as! [String: Any]
    let stop = (restoredHooks["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
    #expect((stop.first!["hooks"] as! [[String: Any]]).first!["command"] as! String == "/keep")
    #expect(!FileManager.default.fileExists(atPath: roots.helperURL.path))
}

@Test func setupInstallRejectsAConfigurationRaceWithoutWriting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configRoot = root.appendingPathComponent("codex")
    let helperRoot = root.appendingPathComponent("Steer")
    try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = "[tui]\n"
    let hooks = Data("{}".utf8)
    try Data(config.utf8).write(to: configRoot.appendingPathComponent("config.toml"))
    try hooks.write(to: configRoot.appendingPathComponent("hooks.json"))
    let roots = CodexSetupRoots(configDirectory: configRoot, helperDirectory: helperRoot, eventsDirectory: helperRoot.appendingPathComponent("events"))
    let plan = CodexSetupPlanner.plan(capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true),
                                      config: config, hooks: hooks, helperPath: roots.helperURL, eventsPath: roots.eventsDirectory)
    try Data("changed = true\n".utf8).write(to: roots.configURL)
    #expect(throws: CodexSetupError.conflict("Codex configuration changed after the preview. Review setup again.")) {
        _ = try CodexSetupInstaller().install(plan, roots: roots, helper: Data("helper".utf8), capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true))
    }
    #expect(try String(contentsOf: roots.configURL) == "changed = true\n")
    #expect(!FileManager.default.fileExists(atPath: roots.helperURL.path))
}

@Test func setupPreviewReopensTuiAfterALaterSection() {
    let plan = CodexSetupPlanner.plan(
        capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true),
        config: "[tui]\nfont_size = 14\n[network]\nproxy = \"none\"\n",
        hooks: Data("{}".utf8), helperPath: URL(fileURLWithPath: "/tmp/helper"), eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(plan.configChange == "[tui]\nfont_size = 14\nterminal_title = [\"session-id\"]\n[network]\nproxy = \"none\"\n")
}

@Test func setupInstallRollbackRestoresAfterInjectedWriteFailure() throws {
    struct Failure: Error {}
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configRoot = root.appendingPathComponent("codex")
    let helperRoot = root.appendingPathComponent("Steer")
    try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = "[tui]\n"
    let hooks = Data("{}".utf8)
    try Data(config.utf8).write(to: configRoot.appendingPathComponent("config.toml"))
    try hooks.write(to: configRoot.appendingPathComponent("hooks.json"))
    let roots = CodexSetupRoots(configDirectory: configRoot, helperDirectory: helperRoot, eventsDirectory: helperRoot.appendingPathComponent("events"))
    let plan = CodexSetupPlanner.plan(capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true), config: config, hooks: hooks, helperPath: roots.helperURL, eventsPath: roots.eventsDirectory)
    var failed = false
    let installer = CodexSetupInstaller { url in
        if url == roots.configURL && !failed { failed = true; throw Failure() }
    }
    #expect(throws: CodexSetupError.failed("Setup was not completed; the original configuration was restored.")) {
        _ = try installer.install(plan, roots: roots, helper: Data("helper".utf8), capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true))
    }
    #expect(try String(contentsOf: roots.configURL) == config)
    #expect(try Data(contentsOf: roots.hooksURL) == hooks)
    #expect(!FileManager.default.fileExists(atPath: roots.helperURL.path))
}

@Test func setupUndoRollbackRestoresInstalledStateAfterInjectedWriteFailure() throws {
    struct Failure: Error {}
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configRoot = root.appendingPathComponent("codex")
    let helperRoot = root.appendingPathComponent("Steer")
    try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = "[tui]\n"
    let hooks = Data("{}".utf8)
    try Data(config.utf8).write(to: configRoot.appendingPathComponent("config.toml"))
    try hooks.write(to: configRoot.appendingPathComponent("hooks.json"))
    let roots = CodexSetupRoots(configDirectory: configRoot, helperDirectory: helperRoot, eventsDirectory: helperRoot.appendingPathComponent("events"))
    let capabilities = CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true)
    let plan = CodexSetupPlanner.plan(capabilities: capabilities, config: config, hooks: hooks, helperPath: roots.helperURL, eventsPath: roots.eventsDirectory)
    let installer = CodexSetupInstaller()
    _ = try installer.install(plan, roots: roots, helper: Data("helper".utf8), capabilities: capabilities)
    let installedConfig = try String(contentsOf: roots.configURL)
    let installedHooks = try Data(contentsOf: roots.hooksURL)
    var writes = 0
    let failingUndo = CodexSetupInstaller { _ in
        writes += 1
        if writes == 2 { throw Failure() }
    }
    #expect(throws: CodexSetupError.failed("Undo was not completed; the installed configuration was restored.")) {
        _ = try failingUndo.undo(roots: roots)
    }
    #expect(try String(contentsOf: roots.configURL) == installedConfig)
    #expect(try Data(contentsOf: roots.hooksURL) == installedHooks)
    #expect(FileManager.default.fileExists(atPath: roots.helperURL.path))
    #expect(FileManager.default.fileExists(atPath: roots.stateURL.path))
}
