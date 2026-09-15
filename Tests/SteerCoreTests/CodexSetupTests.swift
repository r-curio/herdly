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
    #expect(plan.configChange == "[tui]\nfont_size = 14\nterminal_title = [\"session-id\"]\n\n[features]\nhooks = true\n")
    #expect(CodexSetupValidator.hasHooksEnabled(in: plan.configChange))
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

    for config in ["broken =", "x = [not valid TOML]", "[tui]\na = 1\n[tui]\nb = 2\n",
                   "foo bar = 1\n", "[foo bar]\na = 1\n", "name = \"bad\\q\"\n",
                   "name = \"bad\u{1}\"\n", "[\"bad\\q\"]\na = 1\n"] {
        let malformed = CodexSetupPlanner.plan(
            capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true),
            config: config, hooks: Data("{}".utf8), helperPath: URL(fileURLWithPath: "/tmp/helper"),
            eventsPath: URL(fileURLWithPath: "/tmp/events"))
        #expect(malformed.status == .malformed("Codex config.toml is not valid enough to edit safely."))
    }

    let duplicateKey = CodexSetupPlanner.plan(
        capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true),
        config: "[projects.\"/tmp/a\"]\nname = \"a\"\nname = \"b\"\n", hooks: Data("{}".utf8),
        helperPath: URL(fileURLWithPath: "/tmp/helper"), eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(duplicateKey.status == .malformed("Codex config.toml is not valid enough to edit safely."))
    let quotedProject = CodexSetupPlanner.plan(
        capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true),
        config: "[projects.\"/tmp/project with space\"]\nname = \"project\"\n", hooks: Data("{}".utf8),
        helperPath: URL(fileURLWithPath: "/tmp/helper"), eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(quotedProject.status == .ready)

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
                                      helperPath: roots.helperURL, eventsPath: eventsRoot, hooksPath: roots.hooksURL)
    let installer = CodexSetupInstaller()
    let firstStatus = try installer.install(plan, roots: roots, helper: helper,
                                  capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true))
    #expect(firstStatus == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))
    #expect(try installer.install(plan, roots: roots, helper: helper,
                                  capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))
    #expect(((try FileManager.default.attributesOfItem(atPath: roots.helperURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0)
    let staleEvent: [String: Any] = ["hook_event_name": "SessionStart", "session_id": UUID().uuidString, "source": CodexSetupRequirements.helperSource, "installation_id": plan.installationID, "received_at": "2026-01-01T00:00:00Z", "captured_at": 0]
    try JSONSerialization.data(withJSONObject: staleEvent).write(to: eventsRoot.appendingPathComponent("stale.json"))
    #expect(installer.status(roots: roots, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))
    let wrongIDEvent: [String: Any] = ["hook_event_name": "SessionStart", "session_id": UUID().uuidString, "source": CodexSetupRequirements.helperSource, "installation_id": UUID().uuidString, "received_at": "2026-09-12T00:00:00Z", "captured_at": Date().timeIntervalSince1970 + 1]
    try JSONSerialization.data(withJSONObject: wrongIDEvent).write(to: eventsRoot.appendingPathComponent("wrong-id.json"))
    #expect(installer.status(roots: roots, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))
    let event: [String: Any] = ["hook_event_name": "SessionStart", "session_id": UUID().uuidString, "source": CodexSetupRequirements.helperSource, "installation_id": plan.installationID, "received_at": "2026-09-12T00:00:00Z", "captured_at": Date().timeIntervalSince1970 + 1]
    try JSONSerialization.data(withJSONObject: event).write(to: eventsRoot.appendingPathComponent("event.json"))
    #expect(installer.status(roots: roots, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .connected)
    try FileManager.default.removeItem(at: eventsRoot.appendingPathComponent("event.json"))
    let configBeforeMalformed = try String(contentsOf: roots.configURL)
    try Data((configBeforeMalformed + "broken =\n").utf8).write(to: roots.configURL)
    #expect(installer.status(roots: roots, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .malformed("Codex config.toml is not valid enough to verify safely."))
    try Data(configBeforeMalformed.utf8).write(to: roots.configURL)
    let futureEvent: [String: Any] = ["hook_event_name": "SessionStart", "session_id": UUID().uuidString, "source": CodexSetupRequirements.helperSource, "installation_id": plan.installationID, "received_at": "2099-01-01T00:00:00Z", "captured_at": Date().timeIntervalSince1970 + 3600]
    try JSONSerialization.data(withJSONObject: futureEvent).write(to: eventsRoot.appendingPathComponent("future.json"))
    #expect(installer.status(roots: roots, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))
    let installed = try String(contentsOf: roots.configURL)
    let edited = installed.replacingOccurrences(of: "[features]\nhooks = true\n", with: "[features]\nhooks = true\nuser_note = true\n")
    #expect(edited != installed)
    try Data(edited.utf8).write(to: roots.configURL)
    // Codex rewrites config.toml on its own after setup; Steer keeps working and re-baselines.
    let rebaselinePlan = CodexSetupPlanner.plan(capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true),
                                                 config: edited, hooks: try Data(contentsOf: roots.hooksURL),
                                                 helperPath: roots.helperURL, eventsPath: roots.eventsDirectory, hooksPath: roots.hooksURL)
    #expect(!rebaselinePlan.requiresConfigure)
    #expect(installer.status(roots: roots, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))
    #expect(try installer.install(rebaselinePlan, roots: roots, helper: helper, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))
    #expect(try String(contentsOf: roots.configURL) == edited)
    // Undo removes only Steer's lines and trust tables; the user's later edit survives in the [features] table it shares.
    #expect(try installer.undo(roots: roots) == .notConfigured)
    let afterUndo = try String(contentsOf: roots.configURL)
    #expect(afterUndo == "[tui]\nfont_size = 14\n\n[features]\nuser_note = true\n", "actual: \(afterUndo.debugDescription)")
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
                                      config: config, hooks: hooks, helperPath: roots.helperURL, eventsPath: roots.eventsDirectory, hooksPath: roots.hooksURL)
    try Data("changed = true\n".utf8).write(to: roots.configURL)
    #expect(throws: CodexSetupError.conflict("Codex configuration changed after the preview. Review setup again.")) {
        _ = try CodexSetupInstaller().install(plan, roots: roots, helper: Data("helper".utf8), capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true))
    }
    #expect(try String(contentsOf: roots.configURL) == "changed = true\n")
    #expect(!FileManager.default.fileExists(atPath: roots.helperURL.path))
}

@Test func setupInstallRejectsAnIdenticalUnownedHelper() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configRoot = root.appendingPathComponent("codex")
    let helperRoot = root.appendingPathComponent("Steer")
    try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = "[tui]\n"
    let hooks = Data("{}".utf8)
    let helper = Data("same-bytes-but-unowned".utf8)
    try Data(config.utf8).write(to: configRoot.appendingPathComponent("config.toml"))
    try hooks.write(to: configRoot.appendingPathComponent("hooks.json"))
    try FileManager.default.createDirectory(at: helperRoot, withIntermediateDirectories: true)
    try helper.write(to: helperRoot.appendingPathComponent("SteerHook"))
    let roots = CodexSetupRoots(configDirectory: configRoot, helperDirectory: helperRoot,
                                eventsDirectory: helperRoot.appendingPathComponent("events"))
    let capabilities = CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true)
    let plan = CodexSetupPlanner.plan(capabilities: capabilities, config: config, hooks: hooks,
                                      helperPath: roots.helperURL, eventsPath: roots.eventsDirectory, hooksPath: roots.hooksURL)
    #expect(throws: CodexSetupError.conflict("A different file already exists at Steer's helper path.")) {
        _ = try CodexSetupInstaller().install(plan, roots: roots, helper: helper, capabilities: capabilities)
    }
    #expect(try String(contentsOf: roots.configURL) == config)
    #expect(try Data(contentsOf: roots.hooksURL) == hooks)
    #expect(!FileManager.default.fileExists(atPath: roots.stateURL.path))
}

@Test func setupRepairsMissingHelperWithoutLosingUndoSnapshots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configRoot = root.appendingPathComponent("codex")
    let helperRoot = root.appendingPathComponent("Steer")
    try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let originalConfig = "[tui]\nfont_size = 14\n"
    let originalHooks = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/keep"}]}]}}"#.utf8)
    try Data(originalConfig.utf8).write(to: configRoot.appendingPathComponent("config.toml"))
    try originalHooks.write(to: configRoot.appendingPathComponent("hooks.json"))
    let roots = CodexSetupRoots(configDirectory: configRoot, helperDirectory: helperRoot,
                                eventsDirectory: helperRoot.appendingPathComponent("events"))
    let capabilities = CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true)
    let helper = Data("helper".utf8)
    let plan = CodexSetupPlanner.plan(capabilities: capabilities, config: originalConfig, hooks: originalHooks,
                                      helperPath: roots.helperURL, eventsPath: roots.eventsDirectory, hooksPath: roots.hooksURL)
    let installer = CodexSetupInstaller()
    _ = try installer.install(plan, roots: roots, helper: helper, capabilities: capabilities)
    let sibling = helperRoot.appendingPathComponent("user-owned-note")
    try Data("keep me".utf8).write(to: sibling)
    let ownedEvent: [String: Any] = ["source": CodexSetupRequirements.helperSource,
                                     "installation_id": plan.installationID,
                                     "hook_event_name": "SessionStart", "session_id": UUID().uuidString,
                                     "received_at": "2026-01-01T00:00:00Z", "captured_at": 0]
    try JSONSerialization.data(withJSONObject: ownedEvent).write(to: roots.eventsDirectory.appendingPathComponent("owned.json"))
    try Data("keep this event directory file".utf8).write(to: roots.eventsDirectory.appendingPathComponent("user-note.txt"))
    #expect(FileManager.default.fileExists(atPath: helperRoot.appendingPathComponent("backups").path))
    try FileManager.default.removeItem(at: roots.helperURL)
    #expect(installer.status(roots: roots, capabilities: capabilities) == .repairRequired("Steer's helper is missing; Configure Codex to repair setup."))
    let installedConfig = try String(contentsOf: roots.configURL)
    let installedHooks = try Data(contentsOf: roots.hooksURL)
    let repairPlan = CodexSetupPlanner.plan(capabilities: capabilities, config: installedConfig, hooks: installedHooks,
                                            helperPath: roots.helperURL, eventsPath: roots.eventsDirectory, hooksPath: roots.hooksURL)
    #expect(!repairPlan.requiresConfigure)
    _ = try installer.install(repairPlan, roots: roots, helper: helper, capabilities: capabilities)
    #expect(installer.status(roots: roots, capabilities: capabilities) == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))
    #expect(try installer.undo(roots: roots) == .notConfigured)
    #expect(try String(contentsOf: roots.configURL) == originalConfig)
    #expect(try Data(contentsOf: roots.hooksURL) == originalHooks)
    #expect(FileManager.default.fileExists(atPath: roots.eventsDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: roots.eventsDirectory.appendingPathComponent("owned.json").path))
    #expect(FileManager.default.fileExists(atPath: roots.eventsDirectory.appendingPathComponent("user-note.txt").path))
    #expect(!FileManager.default.fileExists(atPath: helperRoot.appendingPathComponent("backups").path))
    #expect(FileManager.default.fileExists(atPath: sibling.path))
    #expect(FileManager.default.fileExists(atPath: helperRoot.path))
}

@Test func setupPreviewReopensTuiAfterALaterSection() {
    let plan = CodexSetupPlanner.plan(
        capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true),
        config: "[tui]\nfont_size = 14\n[network]\nproxy = \"none\"\n",
        hooks: Data("{}".utf8), helperPath: URL(fileURLWithPath: "/tmp/helper"), eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(plan.configChange == "[tui]\nfont_size = 14\nterminal_title = [\"session-id\"]\n[network]\nproxy = \"none\"\n\n[features]\nhooks = true\n")
}

@Test(arguments: CodexSetupRequirements.legacyHookTimeouts)
func setupMigratesLegacySteerTimeoutWithoutAddingDuplicateHandlers(legacyTimeout: Int) throws {
    let helper = URL(fileURLWithPath: "/tmp/steer/SteerHook")
    let events = URL(fileURLWithPath: "/tmp/steer/events")
    let id = UUID().uuidString
    let command = CodexSetupPlanner.command(helperPath: helper, eventsPath: events, installationID: id)
    let hooks: [String: Any] = ["hooks": Dictionary(uniqueKeysWithValues: CodexSetupRequirements.hookEvents.map { event in
        (event, [["hooks": [["type": "command", "command": command, "timeout": legacyTimeout]]]])
    })]
    let data = try JSONSerialization.data(withJSONObject: hooks)
    let plan = CodexSetupPlanner.plan(capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true),
                                      config: "[tui]\nterminal_title = [\"session-id\"]\n", hooks: data,
                                      helperPath: helper, eventsPath: events)
    #expect(plan.installationID == id)
    #expect(plan.requiresConfigure)
    guard let root = try JSONSerialization.jsonObject(with: plan.hooksChange) as? [String: Any],
          let migrated = root["hooks"] as? [String: Any] else {
        Issue.record("migrated hooks were not valid JSON")
        return
    }
    for event in CodexSetupRequirements.hookEvents {
        guard let entries = migrated[event] as? [[String: Any]], let nested = entries.first?["hooks"] as? [[String: Any]] else {
            Issue.record("missing migrated hooks for \(event)")
            continue
        }
        #expect(nested.count == 1)
        #expect((nested.first?["timeout"] as? NSNumber)?.intValue == CodexSetupRequirements.hookTimeout)
    }
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
    let plan = CodexSetupPlanner.plan(capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: false, supported: true), config: config, hooks: hooks, helperPath: roots.helperURL, eventsPath: roots.eventsDirectory, hooksPath: roots.hooksURL)
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
    let plan = CodexSetupPlanner.plan(capabilities: capabilities, config: config, hooks: hooks, helperPath: roots.helperURL, eventsPath: roots.eventsDirectory, hooksPath: roots.hooksURL)
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

@Test func setupUndoCleanupFailureRestoresOwnedEventsAndBackups() throws {
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
    let plan = CodexSetupPlanner.plan(capabilities: capabilities, config: config, hooks: hooks, helperPath: roots.helperURL, eventsPath: roots.eventsDirectory, hooksPath: roots.hooksURL)
    _ = try CodexSetupInstaller().install(plan, roots: roots, helper: Data("helper".utf8), capabilities: capabilities)

    let sessionID = UUID().uuidString
    let ownedEvent = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "SessionStart",
        "session_id": sessionID,
        "source": CodexSetupRequirements.helperSource,
        "installation_id": plan.installationID,
        "received_at": "2026-09-12T00:00:00Z",
        "captured_at": Date().timeIntervalSince1970
    ])
    try FileManager.default.createDirectory(at: roots.eventsDirectory, withIntermediateDirectories: true)
    let ownedEventURL = roots.eventsDirectory.appendingPathComponent("owned.json")
    let foreignEventURL = roots.eventsDirectory.appendingPathComponent("foreign.json")
    try ownedEvent.write(to: ownedEventURL)
    try Data("keep".utf8).write(to: foreignEventURL)
    let backupsDirectory = helperRoot.appendingPathComponent("backups")
    let backup = try #require(FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil).first)
    var eventWasRemovedBeforeFailure = false
    let failingUndo = CodexSetupInstaller(beforeCleanup: { _ in
        eventWasRemovedBeforeFailure = !FileManager.default.fileExists(atPath: ownedEventURL.path)
        throw Failure()
    })

    #expect(throws: CodexSetupError.failed("Undo was not completed; the installed configuration was restored.")) {
        _ = try failingUndo.undo(roots: roots)
    }
    #expect(eventWasRemovedBeforeFailure)
    #expect(FileManager.default.fileExists(atPath: ownedEventURL.path))
    #expect(try Data(contentsOf: ownedEventURL) == ownedEvent)
    #expect(FileManager.default.fileExists(atPath: foreignEventURL.path))
    #expect(FileManager.default.fileExists(atPath: backup.path))
    #expect(try String(contentsOf: backup.appendingPathComponent("config.toml")) == config)
    #expect(try Data(contentsOf: backup.appendingPathComponent("hooks.json")) == hooks)
    #expect(FileManager.default.fileExists(atPath: roots.helperURL.path))
    #expect(FileManager.default.fileExists(atPath: roots.stateURL.path))
}

@Test func setupEnablesCodexHooksFeatureWithoutOverridingTheUsersChoice() {
    let capabilities = CodexCapabilities(cli: true, desktop: true, ghostty: true, supported: true)
    let helper = URL(fileURLWithPath: "/tmp/Steer/SteerHook"), events = URL(fileURLWithPath: "/tmp/Steer/events")
    // An existing [features] table gets the flag inserted before the next table, keeping other keys.
    let inserted = CodexSetupPlanner.plan(capabilities: capabilities,
                                          config: "[tui]\nterminal_title = [\"session-id\"]\n\n[features]\nmemories = true\n\n[mcp_servers.x]\nurl = \"u\"\n",
                                          hooks: Data("{}".utf8), helperPath: helper, eventsPath: events)
    #expect(inserted.status == .ready)
    #expect(inserted.configChange == "[tui]\nterminal_title = [\"session-id\"]\n\n[features]\nmemories = true\nhooks = true\n\n[mcp_servers.x]\nurl = \"u\"\n")
    #expect(inserted.requiresConfigure)

    // Already enabled: the config is left untouched.
    let enabled = CodexSetupPlanner.plan(capabilities: capabilities,
                                         config: "[features]\nhooks = true\n[tui]\nterminal_title = [\"session-id\"]\n",
                                         hooks: Data("{}".utf8), helperPath: helper, eventsPath: events)
    #expect(enabled.configChange == "[features]\nhooks = true\n[tui]\nterminal_title = [\"session-id\"]\n")

    // Explicitly disabled: Steer refuses rather than flipping the user's setting.
    let disabled = CodexSetupPlanner.plan(capabilities: capabilities,
                                          config: "[features]\nhooks = false\n",
                                          hooks: Data("{}".utf8), helperPath: helper, eventsPath: events)
    #expect(disabled.status == .conflict("Codex has hooks disabled (features.hooks = false); enable them in config.toml before connecting Steer."))
    #expect(!disabled.requiresConfigure)
}

@Test func setupRepairsAnEarlierInstallThatNeverEnabledCodexHooks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-hooks-repair-" + UUID().uuidString)
    let configRoot = root.appendingPathComponent("codex"), helperRoot = root.appendingPathComponent("steer")
    let eventsRoot = helperRoot.appendingPathComponent("events")
    try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = "[tui]\nfont_size = 14\n"
    try Data(original.utf8).write(to: configRoot.appendingPathComponent("config.toml"))
    let capabilities = CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)
    let roots = CodexSetupRoots(configDirectory: configRoot, helperDirectory: helperRoot, eventsDirectory: eventsRoot)
    let installer = CodexSetupInstaller()
    let plan = CodexSetupPlanner.plan(capabilities: capabilities, config: original, hooks: Data("{}".utf8),
                                      helperPath: roots.helperURL, eventsPath: eventsRoot, hooksPath: roots.hooksURL)
    _ = try installer.install(plan, roots: roots, helper: Data("helper-v1".utf8), capabilities: capabilities)

    // Rewind to what an earlier Steer version installed: the same files without the hooks flag.
    let legacyConfig = plan.configChange.replacingOccurrences(of: "\n[features]\nhooks = true\n", with: "")
    #expect(legacyConfig != plan.configChange)
    try Data(legacyConfig.utf8).write(to: roots.configURL)
    var state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: roots.stateURL)) as? [String: Any])
    state["installedConfig"] = legacyConfig
    try JSONSerialization.data(withJSONObject: state).write(to: roots.stateURL)
    #expect(installer.status(roots: roots, capabilities: capabilities)
            == .repairRequired("Codex hooks are not enabled in config.toml; Configure Codex to repair setup."))

    // Configure Codex again: the plan from the current files adds the flag and the install repairs in place.
    let repairPlan = CodexSetupPlanner.plan(capabilities: capabilities, config: legacyConfig,
                                            hooks: try Data(contentsOf: roots.hooksURL),
                                            helperPath: roots.helperURL, eventsPath: eventsRoot, hooksPath: roots.hooksURL)
    #expect(repairPlan.status == .ready && repairPlan.requiresConfigure)
    let repaired = try installer.install(repairPlan, roots: roots, helper: Data("helper-v1".utf8), capabilities: capabilities)
    #expect(repaired == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))
    #expect(CodexSetupValidator.hasHooksEnabled(in: try String(contentsOf: roots.configURL)))

    // Undo still returns the file the user had before Steer ever touched it.
    #expect(try installer.undo(roots: roots) == .notConfigured)
    #expect(try String(contentsOf: roots.configURL) == original)
}

@Test func setupSurvivesCodexRewritingItsOwnFilesAndUndoRemovesOnlySteersLines() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-drift-" + UUID().uuidString)
    let configRoot = root.appendingPathComponent("codex"), helperRoot = root.appendingPathComponent("steer")
    let eventsRoot = helperRoot.appendingPathComponent("events")
    try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = "model_reasoning_effort = \"medium\"\n\n[features]\nmemories = true\n"
    let originalHooks = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/keep"}]}]}}"#.utf8)
    try Data(original.utf8).write(to: configRoot.appendingPathComponent("config.toml"))
    try originalHooks.write(to: configRoot.appendingPathComponent("hooks.json"))
    let capabilities = CodexCapabilities(cli: true, desktop: true, ghostty: true, supported: true)
    let roots = CodexSetupRoots(configDirectory: configRoot, helperDirectory: helperRoot, eventsDirectory: eventsRoot)
    let installer = CodexSetupInstaller()
    let plan = CodexSetupPlanner.plan(capabilities: capabilities, config: original, hooks: originalHooks,
                                      helperPath: roots.helperURL, eventsPath: eventsRoot, hooksPath: roots.hooksURL)
    _ = try installer.install(plan, roots: roots, helper: Data("helper-v1".utf8), capabilities: capabilities)

    // Codex changes a setting and records hook trust; another tool adds its own hook.
    let drifted = try String(contentsOf: roots.configURL)
        .replacingOccurrences(of: "\"medium\"", with: "\"low\"") + "\n[hooks.state.\"x\"]\ntrusted_hash = \"sha256:abc\"\n"
    try Data(drifted.utf8).write(to: roots.configURL)
    var hooksObject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: roots.hooksURL)) as? [String: Any])
    var hooksTable = try #require(hooksObject["hooks"] as? [String: Any])
    hooksTable["PreCompact"] = [["hooks": [["type": "command", "command": "/other"]]]]
    hooksObject["hooks"] = hooksTable
    try JSONSerialization.data(withJSONObject: hooksObject).write(to: roots.hooksURL)

    // Still configured: Steer's own lines and entries are present.
    #expect(installer.status(roots: roots, capabilities: capabilities) == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))

    // Undo keeps every foreign change and strips exactly Steer's contribution.
    #expect(try installer.undo(roots: roots) == .notConfigured)
    #expect(try String(contentsOf: roots.configURL) == "model_reasoning_effort = \"low\"\n\n[features]\nmemories = true\n\n[hooks.state.\"x\"]\ntrusted_hash = \"sha256:abc\"\n")
    let restored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: roots.hooksURL)) as? [String: Any])
    let restoredHooks = try #require(restored["hooks"] as? [String: Any])
    #expect(Set(restoredHooks.keys) == ["Stop", "PreCompact"])
    #expect(((restoredHooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/keep")
    #expect(!FileManager.default.fileExists(atPath: roots.helperURL.path))
    #expect(!FileManager.default.fileExists(atPath: roots.stateURL.path))
}

@Test func hookTrustHashMatchesCodexForNormalizedHandlers() {
    // Vectors reproduce Codex's own trust hashes (verified against seven entries a Codex 0.145.0 CLI
    // and 0.153.4 desktop build recorded in a real config.toml).
    let command = "'/tmp/Steer/SteerHook' --events-dir '/tmp/Steer/events' --installation-id '0F4C0E52-4B3B-4E2B-9C3D-7A1B2C3D4E5F'"
    #expect(CodexHookTrust.hash(event: "SessionStart", command: command, timeout: 38) == "sha256:8ef43d663dd92b22e404378d324d4071c04db964092d87f4d8653295e28f5366")
    // SessionEnd is clamped to three seconds before hashing, so 38 and 3 hash the same.
    #expect(CodexHookTrust.hash(event: "SessionEnd", command: command, timeout: 38) == "sha256:8b8e974bb8349a515f4b0903a9515f0b4475a1ea5af59a2f6ab14ff2a9957ec7")
    #expect(CodexHookTrust.hash(event: "SessionEnd", command: command, timeout: 3) == "sha256:8b8e974bb8349a515f4b0903a9515f0b4475a1ea5af59a2f6ab14ff2a9957ec7")
    #expect(CodexHookTrust.hash(event: "PreToolUse", command: command, timeout: 38) != nil)
    #expect(CodexHookTrust.hash(event: "PostToolUse", command: command, timeout: 38) != nil)
    #expect(CodexHookTrust.table(hooksPath: "/Users/me/.codex/hooks.json", event: "Stop", group: 1, handler: 0)
            == "hooks.state.\"/Users/me/.codex/hooks.json:stop:1:0\"")
}

@Test func setupRecordsCodexTrustForItsOwnHooksAndUndoRestoresWhatWasThere() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-trust-" + UUID().uuidString)
    let configRoot = root.appendingPathComponent("codex"), helperRoot = root.appendingPathComponent("steer")
    let eventsRoot = helperRoot.appendingPathComponent("events")
    try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let roots = CodexSetupRoots(configDirectory: configRoot, helperDirectory: helperRoot, eventsDirectory: eventsRoot)
    let capabilities = CodexCapabilities(cli: true, desktop: true, ghostty: true, supported: true)
    // A foreign Stop hook sits first, so Steer's Stop handler lands at group 1; a stale trust value
    // already occupies Steer's SessionStart key and must come back on undo.
    let staleKey = "hooks.state.\"\(roots.hooksURL.path):session_start:0:0\""
    let original = "[tui]\nterminal_title = [\"session-id\"]\n\n[features]\nhooks = true\n\n[\(staleKey)]\ntrusted_hash = \"sha256:stale\"\n"
    let originalHooks = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/keep"}]}]}}"#.utf8)
    try Data(original.utf8).write(to: roots.configURL)
    try originalHooks.write(to: roots.hooksURL)
    let installer = CodexSetupInstaller()
    let plan = CodexSetupPlanner.plan(capabilities: capabilities, config: original, hooks: originalHooks,
                                      helperPath: roots.helperURL, eventsPath: eventsRoot, hooksPath: roots.hooksURL)
    #expect(plan.status == .ready && plan.requiresConfigure)
    let entries = CodexHookTrust.entries(hooksPath: roots.hooksURL.path, hooks: plan.hooksChange, command: plan.helperCommand)
    #expect(entries.count == CodexSetupRequirements.hookEvents.count)
    #expect(entries.contains { $0.table == "hooks.state.\"\(roots.hooksURL.path):stop:1:0\"" })
    for entry in entries {
        #expect(CodexSetupValidator.configValue(in: plan.configChange, table: entry.table, key: "trusted_hash") == "\"\(entry.hash)\"")
    }
    #expect(!plan.configChange.contains("sha256:stale"))

    _ = try installer.install(plan, roots: roots, helper: Data("helper-v1".utf8), capabilities: capabilities)
    #expect(installer.status(roots: roots, capabilities: capabilities) == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))

    // Trust lost (Codex marks a changed hook for review): repair re-records it.
    let installed = try String(contentsOf: roots.configURL)
    try Data(installed.replacingOccurrences(of: entries[0].hash, with: "sha256:changed").utf8).write(to: roots.configURL)
    #expect(installer.status(roots: roots, capabilities: capabilities) == .repairRequired("Codex has not recorded trust for Steer's hooks; Configure Codex to repair setup."))
    let repairPlan = CodexSetupPlanner.plan(capabilities: capabilities, config: try String(contentsOf: roots.configURL),
                                            hooks: try Data(contentsOf: roots.hooksURL), helperPath: roots.helperURL,
                                            eventsPath: eventsRoot, hooksPath: roots.hooksURL)
    _ = try installer.install(repairPlan, roots: roots, helper: Data("helper-v1".utf8), capabilities: capabilities)
    #expect(installer.status(roots: roots, capabilities: capabilities) == .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Steer's hooks."))

    // Codex edits an unrelated key after setup; undo still strips Steer's trust entries and puts the stale value back.
    let drifted = (try String(contentsOf: roots.configURL)) + "\nmodel = \"x\"\n"
    try Data(drifted.utf8).write(to: roots.configURL)
    #expect(try installer.undo(roots: roots) == .notConfigured)
    let after = try String(contentsOf: roots.configURL)
    #expect(!after.contains("sha256:" + String(entries[0].hash.dropFirst(7))))
    #expect(CodexSetupValidator.configValue(in: after, table: staleKey, key: "trusted_hash") == "\"sha256:stale\"")
    #expect(!after.contains(":stop:1:0"))
    #expect(after.contains("model = \"x\""))
}
