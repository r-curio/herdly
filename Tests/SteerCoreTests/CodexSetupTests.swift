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
                                      helperPath: roots.helperURL, eventsPath: eventsRoot)
    let installer = CodexSetupInstaller()
    let firstStatus = try installer.install(plan, roots: roots, helper: helper,
                                  capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true))
    #expect(firstStatus == .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery."))
    #expect(try installer.install(plan, roots: roots, helper: helper,
                                  capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery."))
    #expect(((try FileManager.default.attributesOfItem(atPath: roots.helperURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0)
    let staleEvent: [String: Any] = ["hook_event_name": "SessionStart", "session_id": UUID().uuidString, "source": CodexSetupRequirements.helperSource, "installation_id": plan.installationID, "received_at": "2026-01-01T00:00:00Z", "captured_at": 0]
    try JSONSerialization.data(withJSONObject: staleEvent).write(to: eventsRoot.appendingPathComponent("stale.json"))
    #expect(installer.status(roots: roots, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery."))
    let wrongIDEvent: [String: Any] = ["hook_event_name": "SessionStart", "session_id": UUID().uuidString, "source": CodexSetupRequirements.helperSource, "installation_id": UUID().uuidString, "received_at": "2026-09-12T00:00:00Z", "captured_at": Date().timeIntervalSince1970 + 1]
    try JSONSerialization.data(withJSONObject: wrongIDEvent).write(to: eventsRoot.appendingPathComponent("wrong-id.json"))
    #expect(installer.status(roots: roots, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery."))
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
    #expect(installer.status(roots: roots, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true)) == .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery."))
    let installed = try String(contentsOf: roots.configURL)
    try Data((installed + "user_note = true\n").utf8).write(to: roots.configURL)
    let rebaselinePlan = CodexSetupPlanner.plan(capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true),
                                                 config: installed + "user_note = true\n", hooks: try Data(contentsOf: roots.hooksURL),
                                                 helperPath: roots.helperURL, eventsPath: roots.eventsDirectory)
    #expect(throws: CodexSetupError.conflict("Existing Steer setup changed after setup; review setup before reconfiguring.")) {
        _ = try installer.install(rebaselinePlan, roots: roots, helper: helper, capabilities: CodexCapabilities(cli: true, desktop: false, ghostty: true, supported: true))
    }
    #expect(throws: CodexSetupError.conflict("Codex or Steer's setup files changed after setup; undo made no changes.")) {
        _ = try installer.undo(roots: roots)
    }
    #expect(try String(contentsOf: roots.configURL) == installed + "user_note = true\n")
    try Data(installed.utf8).write(to: roots.configURL)
    #expect(try installer.undo(roots: roots) == .notConfigured)
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
                                      helperPath: roots.helperURL, eventsPath: roots.eventsDirectory)
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
                                      helperPath: roots.helperURL, eventsPath: roots.eventsDirectory)
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
                                            helperPath: roots.helperURL, eventsPath: roots.eventsDirectory)
    #expect(!repairPlan.requiresConfigure)
    _ = try installer.install(repairPlan, roots: roots, helper: helper, capabilities: capabilities)
    #expect(installer.status(roots: roots, capabilities: capabilities) == .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery."))
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
    let plan = CodexSetupPlanner.plan(capabilities: capabilities, config: config, hooks: hooks, helperPath: roots.helperURL, eventsPath: roots.eventsDirectory)
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
