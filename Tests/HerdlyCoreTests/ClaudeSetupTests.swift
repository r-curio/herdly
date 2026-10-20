import Foundation
import Testing
@testable import HerdlyCore
@testable import HerdlyApp

private let capabilities = ClaudeCapabilities(installed: true, supported: true, version: "2.1.273")

private func roots(in directory: URL, name: String = "claude") -> ClaudeSetupRoots {
    let root = directory.appendingPathComponent(name, isDirectory: true)
    let support = directory.appendingPathComponent("support", isDirectory: true)
    return ClaudeSetupRoots(configDirectory: root,
                            helperDirectory: support.appendingPathComponent(name, isDirectory: true),
                            eventsDirectory: support.appendingPathComponent(name + "-events", isDirectory: true))
}

private func settingsObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func claudeSetupPreviewAddsOwnedHooksAndLeavesUsageOff() throws {
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: Data("{}".utf8),
                                       helperPath: URL(fileURLWithPath: "/tmp/HerdlyHook"),
                                       eventsPath: URL(fileURLWithPath: "/tmp/herdly-claude-events"))

    #expect(plan.status == .ready)
    #expect(plan.requiresConfigure)
    #expect(plan.usageEnabled == false)
    #expect(plan.ownedHooks.count == ClaudeSetupRequirements.hookDefinitions.count)
    #expect(plan.ownedEnvironment == [ClaudeSetupRequirements.titleDisableEnvironmentKey: ClaudeSetupRequirements.titleDisableEnvironmentValue])
    #expect(plan.ownedHooks.contains { $0.event == "SessionStart" && $0.command.contains("--terminal-title") })
    #expect(plan.ownedHooks.contains {
        $0.event == "PreToolUse" && $0.matcher == "AskUserQuestion" && $0.command.contains("--question-helper")
    })
    let questionCommand = ClaudeSetupPlanner.command(helperPath: URL(fileURLWithPath: "/tmp/HerdlyHook"),
                                                     eventsPath: URL(fileURLWithPath: "/tmp/events"),
                                                     installationID: "install-1", questionHelper: true,
                                                     sourceScope: URL(fileURLWithPath: "/tmp/claude-root"))
    #expect(questionCommand.contains("--source-scope '/tmp/claude-root'"))
    #expect(plan.ownedHooks.contains { $0.event == "PermissionRequest" && $0.matcher == "Bash" })
    let settings = try settingsObject(plan.settingsChange)
    #expect((settings["permissions"] as? [String: Any]) == nil)
    #expect((settings["statusLine"] as? [String: Any]) == nil)
    #expect((settings["env"] as? [String: Any])?[ClaudeSetupRequirements.titleDisableEnvironmentKey] as? String
            == ClaudeSetupRequirements.titleDisableEnvironmentValue)
}

@Test func claudeSetupSnapshotPreservesPlannerFailureState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-snapshot-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try Data(#"{"hooks":{"Stop":{}}}"#.utf8).write(to: config.appendingPathComponent("settings.json"))

    let snapshot = ClaudeSetupDetection.setupSnapshot(
        root: config,
        applicationSupport: support,
        capabilities: capabilities,
        inventoryStatus: .unavailable("test inventory unavailable")
    )
    #expect(snapshot.status == .malformed("Claude settings.json has an unsupported hooks shape and was not changed."))
    #expect(snapshot.plan?.status == .malformed("Claude settings.json has an unsupported hooks shape and was not changed."))
}

@Test func claudeSetupSnapshotPreservesPlannerConflictStateWithoutInventory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-conflict-snapshot-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try Data(#"{"env":{"CLAUDE_CODE_DISABLE_TERMINAL_TITLE":"0"}}"#.utf8)
        .write(to: config.appendingPathComponent("settings.json"))

    let snapshot = ClaudeSetupDetection.setupSnapshot(
        root: config,
        applicationSupport: support,
        capabilities: capabilities,
        inventoryStatus: .unavailable("test inventory unavailable")
    )
    #expect(snapshot.status == .conflict("Claude's automatic terminal title setting is owned by another value; review settings.json before reconnecting."))
    #expect(snapshot.plan?.status == .conflict("Claude's automatic terminal title setting is owned by another value; review settings.json before reconnecting."))
}

@Test func claudeSetupSnapshotBlocksReadyPlanWithoutInventory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-unavailable-snapshot-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: config.appendingPathComponent("settings.json"))

    let snapshot = ClaudeSetupDetection.setupSnapshot(
        root: config,
        applicationSupport: support,
        capabilities: capabilities,
        inventoryStatus: .unavailable("test inventory unavailable")
    )
    #expect(snapshot.status == .unavailable("Claude setup is blocked until the selected root's agents inventory is available."))
    #expect(snapshot.plan == nil)
}

@Test func claudeSetupActiveSessionSummaryValidatesBoundedInventory() throws {
    let data = Data(#"""
    [
        {"sessionId":"11111111-1111-4111-8111-111111111111","kind":"interactive","cwd":"/tmp/one","name":"one","status":"idle","startedAt":"2026-09-20T00:00:00Z"},
        {"sessionId":"22222222-2222-4222-8222-222222222222","kind":"background","cwd":"/tmp/two","name":"two","status":"busy","state":"working","startedAt":"2026-09-20T00:00:00Z"},
        {"sessionId":"33333333-3333-4333-8333-333333333333","kind":"background","cwd":"/tmp/three","name":"three","status":"busy","state":"done","startedAt":"2026-09-20T00:00:00Z"}
    ]
    """#.utf8)
    #expect(ClaudeSetupDetection.activeSessionSummary(data) == .available(restartCount: 2))
    #expect(ClaudeSetupDetection.activeSessionSummary(Data("{}".utf8))
            == .unavailable("Unavailable: Claude returned an invalid agents inventory."))
    let duplicate = Data(#"""
    [
        {"sessionId":"11111111-1111-4111-8111-111111111111","kind":"interactive","cwd":"/tmp/one","name":"one","status":"idle","startedAt":"2026-09-20T00:00:00Z"},
        {"sessionId":"11111111-1111-4111-8111-111111111111","kind":"interactive","cwd":"/tmp/one","name":"one","status":"busy","startedAt":"2026-09-20T00:00:00Z"}
    ]
    """#.utf8)
    #expect(ClaudeSetupDetection.activeSessionSummary(duplicate)
            == .unavailable("Unavailable: Claude returned an incomplete or duplicate agents inventory."))

    #expect(ClaudeSetupDetection.activeSessionSummary(data, installedAt: 2_000_000_000,
                                                     deliveredSessionIDs: ["11111111-1111-4111-8111-111111111111"])
            == .available(restartCount: 1))

    let missingStartedAt = Data(#"[{"sessionId":"11111111-1111-4111-8111-111111111111","kind":"interactive","status":"idle"}]"#.utf8)
    #expect(ClaudeSetupDetection.activeSessionSummary(missingStartedAt)
            == .unavailable("Unavailable: Claude returned an incomplete or duplicate agents inventory."))
}

@Test func claudeInventorySubprocessHasHardTimeoutAndBoundedDrain() throws {
    // These calls check the drain, not the deadline (the hang below does), so they get a deadline a
    // loaded test machine should not reach: with the 2 s default, full-suite runs timed out here.
    let completed = ClaudeSetupDetection.runBounded(URL(fileURLWithPath: "/bin/echo"), arguments: ["ok"], timeout: 30)
    #expect(completed?.status == 0)
    #expect(String(data: completed?.output ?? Data(), encoding: .utf8) == "ok\n")

    let inventory = #"[{"sessionId":"11111111-1111-4111-8111-111111111111","kind":"interactive","cwd":"/tmp/one","name":"one","status":"idle","startedAt":1}]"#
    for _ in 0..<20 {
        let result = ClaudeSetupDetection.runBounded(URL(fileURLWithPath: "/usr/bin/printf"),
                                                     arguments: ["%s", inventory], timeout: 30)
        #expect(result?.status == 0)
        #expect(String(data: result?.output ?? Data(), encoding: .utf8) == inventory)
    }

    let script = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-hang-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: script) }
    try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do printf x; done\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

    let started = Date()
    let result = ClaudeSetupDetection.runBounded(URL(fileURLWithPath: "/bin/sh"), arguments: [script.path], timeout: 0.05)
    #expect(result == nil)
    #expect(Date().timeIntervalSince(started) < 1)
}

@Test func claudeSetupPreservesUnrelatedSettingsBytes() throws {
    let original = Data("{\"permissions\": { \"allow\": [\"Read\"] }, \"hooks\": {} }".utf8)
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                       helperPath: URL(fileURLWithPath: "/tmp/HerdlyHook"),
                                       eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(plan.status == .ready)
    let changed = try #require(String(data: plan.settingsChange, encoding: .utf8))
    #expect(changed.hasPrefix("{\"permissions\": { \"allow\": [\"Read\"] }, \"hooks\": "))
    let changedSettings = try settingsObject(plan.settingsChange)
    #expect((changedSettings["env"] as? [String: Any])?[ClaudeSetupRequirements.titleDisableEnvironmentKey] as? String
            == ClaudeSetupRequirements.titleDisableEnvironmentValue)

    let missingRecord = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: plan.settingsChange,
                                                helperPath: URL(fileURLWithPath: "/tmp/HerdlyHook"),
                                                eventsPath: URL(fileURLWithPath: "/tmp/events"),
                                                installRecordPresent: false)
    #expect(missingRecord.status == .conflict("Herdly Claude setup state is missing; review this root's settings.json before reconnecting."))
}

@Test func claudeSetupPreservesForeignHooksAndRejectsPolicyOrShadowing() throws {
    let original = Data(#"{"permissions":{"deny":["Bash(rm -rf /)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/keep","timeout":4}]}]}}"#.utf8)
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                       helperPath: URL(fileURLWithPath: "/tmp/HerdlyHook"),
                                       eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(plan.status == .ready)
    let settings = try settingsObject(plan.settingsChange)
    let permissions = try #require(settings["permissions"] as? [String: Any])
    #expect(permissions["deny"] as? [String] == ["Bash(rm -rf /)"])
    let hooks = try #require(settings["hooks"] as? [String: Any])
    let stop = try #require(hooks["Stop"] as? [[String: Any]])
    #expect(((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "/keep")

    let managed = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                          helperPath: URL(fileURLWithPath: "/tmp/HerdlyHook"),
                                          eventsPath: URL(fileURLWithPath: "/tmp/events"),
                                          policy: ClaudeSetupPolicy(managedHooksOnly: true))
    #expect(managed.status == .blockedByPolicy("Claude managed policy allows only managed hooks; Herdly did not change settings."))

    let shadowed = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                           helperPath: URL(fileURLWithPath: "/tmp/HerdlyHook"),
                                           eventsPath: URL(fileURLWithPath: "/tmp/events"),
                                           policy: ClaudeSetupPolicy(shadowedBy: "project settings.json"))
    #expect(shadowed.status == .shadowed("Claude settings are shadowed by project settings.json; Herdly did not change settings."))
}

@Test func claudeSetupPreservesUnrelatedEnvironmentBytesAndRejectsTitleConflict() throws {
    let original = Data("{\"env\": { \"KEEP\": \"value\", \"NESTED\": { \"x\": 1 } }, \"hooks\": {} }".utf8)
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                       helperPath: URL(fileURLWithPath: "/tmp/HerdlyHook"),
                                       eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(plan.status == .ready)
    let changed = try #require(String(data: plan.settingsChange, encoding: .utf8))
    #expect(changed.contains("\"env\": { \"KEEP\": \"value\", \"NESTED\": { \"x\": 1 }"))

    let preexisting = Data("{\"env\": { \"KEEP\": \"value\", \"CLAUDE_CODE_DISABLE_TERMINAL_TITLE\": \"1\" }}".utf8)
    let preexistingPlan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: preexisting,
                                                   helperPath: URL(fileURLWithPath: "/tmp/HerdlyHook"),
                                                   eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(preexistingPlan.status == .ready)
    #expect(preexistingPlan.ownedEnvironment.isEmpty)

    let conflicting = Data("{\"env\": { \"CLAUDE_CODE_DISABLE_TERMINAL_TITLE\": \"0\" }}".utf8)
    #expect(ClaudeSetupPlanner.plan(capabilities: capabilities, settings: conflicting,
                                    helperPath: URL(fileURLWithPath: "/tmp/HerdlyHook"),
                                    eventsPath: URL(fileURLWithPath: "/tmp/events")).status
            == .conflict("Claude's automatic terminal title setting is owned by another value; review settings.json before reconnecting."))
}

@Test func claudeSetupFailsClosedForKnownProjectShadowing() throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-project-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: project) }
    let projectConfig = project.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: projectConfig, withIntermediateDirectories: true)
    try Data(#"{"disableAllHooks":true}"#.utf8).write(to: projectConfig.appendingPathComponent("settings.local.json"))

    let policy = ClaudeSetupDetection.policy(for: project.appendingPathComponent("user-root", isDirectory: true),
                                             projectDirectory: project)
    #expect(policy == ClaudeSetupPolicy(shadowedBy: "project settings at \(projectConfig.path)/settings.local.json disables all hooks"))
    #expect(ClaudeSetupDetection.policy(for: project.appendingPathComponent("user-root", isDirectory: true))
            == ClaudeSetupPolicy())
}

@Test func claudeSetupRepairOwnsTitleKeyOnlyWhenItReaddsAUserRemovedValue() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-title-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let setupRoots = roots(in: root)
    let helper = Data("helper-v1".utf8)
    let installer = ClaudeSetupInstaller()
    let original = Data("{\"env\": { \"CLAUDE_CODE_DISABLE_TERMINAL_TITLE\": \"1\" }}".utf8)
    try FileManager.default.createDirectory(at: setupRoots.configDirectory, withIntermediateDirectories: true)
    try original.write(to: setupRoots.settingsURL)
    let firstPlan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                             helperPath: setupRoots.helperURL, eventsPath: setupRoots.eventsDirectory)
    #expect(firstPlan.ownedEnvironment.isEmpty)
    _ = try installer.install(firstPlan, roots: setupRoots, helper: helper, capabilities: capabilities)

    var removed = try settingsObject(Data(contentsOf: setupRoots.settingsURL))
    removed.removeValue(forKey: "env")
    try JSONSerialization.data(withJSONObject: removed).write(to: setupRoots.settingsURL)
    #expect(installer.status(roots: setupRoots, capabilities: capabilities)
            == .repairRequired("Herdly's terminal title setting is missing; Configure Claude to repair setup."))
    let repairPlan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: try Data(contentsOf: setupRoots.settingsURL),
                                               helperPath: setupRoots.helperURL, eventsPath: setupRoots.eventsDirectory)
    #expect(repairPlan.ownedEnvironment == [ClaudeSetupRequirements.titleDisableEnvironmentKey: ClaudeSetupRequirements.titleDisableEnvironmentValue])
    _ = try installer.install(repairPlan, roots: setupRoots, helper: helper, capabilities: capabilities)

    var drifted = try settingsObject(Data(contentsOf: setupRoots.settingsURL))
    drifted["model"] = "user-changed"
    try JSONSerialization.data(withJSONObject: drifted).write(to: setupRoots.settingsURL)
    _ = try installer.undo(roots: setupRoots)
    let restored = try settingsObject(Data(contentsOf: setupRoots.settingsURL))
    #expect(restored["env"] == nil)
}

@Test func claudeSetupInstallReinstallRepairAndUndoKeepOtherRootIndependent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = roots(in: root, name: "first")
    let second = roots(in: root, name: "second")
    let helper = Data("helper-v1".utf8)
    let installer = ClaudeSetupInstaller()
    let original = Data(#"{"env": { "KEEP": "value", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1" }, "permissions":{"allow":["Read"]},"statusLine":{"type":"command","command":"existing"}}"#.utf8)

    try FileManager.default.createDirectory(at: first.configDirectory, withIntermediateDirectories: true)
    try original.write(to: first.settingsURL)
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                       helperPath: first.helperURL, eventsPath: first.eventsDirectory)
    #expect(plan.ownedEnvironment.isEmpty)
    #expect(try installer.install(plan, roots: first, helper: helper, capabilities: capabilities)
            == .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Existing sessions keep running without Herdly's hooks."))
    #expect(installer.status(roots: first, capabilities: capabilities)
            == .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Existing sessions keep running without Herdly's hooks."))

    let installedSettings = try Data(contentsOf: first.settingsURL)
    let stablePlan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: installedSettings,
                                             helperPath: first.helperURL, eventsPath: first.eventsDirectory)
    #expect(stablePlan.settingsChange == installedSettings)
    #expect(stablePlan.requiresConfigure == false)

    let secondPlan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: Data("{}".utf8),
                                              helperPath: second.helperURL, eventsPath: second.eventsDirectory)
    _ = try installer.install(secondPlan, roots: second, helper: helper, capabilities: capabilities)
    #expect(FileManager.default.fileExists(atPath: first.stateURL.path))
    #expect(FileManager.default.fileExists(atPath: second.stateURL.path))

    // Old events and later non-SessionStart events never prove a new root connection.
    let stateData = try Data(contentsOf: first.stateURL)
    let state = try #require(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
    let installationID = try #require(state["installationID"] as? String)
    let installedAt = try #require(state["installedAt"] as? Double)
    try FileManager.default.createDirectory(at: first.eventsDirectory, withIntermediateDirectories: true)
    let staleEvent = Data(#"{"hook_event_name":"SessionStart","session_start_source":"startup","source":"herdly-claude-hook-v1","installation_id":"PLACEHOLDER","session_id":"session-old","received_at":"2026-09-20T00:00:00Z","captured_at":PLACEHOLDER_TIME}"#.utf8)
    try Data(String(data: staleEvent, encoding: .utf8)!
        .replacingOccurrences(of: "PLACEHOLDER_TIME", with: String(installedAt - 60))
        .replacingOccurrences(of: "PLACEHOLDER", with: installationID).utf8)
        .write(to: first.eventsDirectory.appendingPathComponent("stale.json"))
    #expect(installer.status(roots: first, capabilities: capabilities)
            == .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Existing sessions keep running without Herdly's hooks."))
    let nonSessionEvent = Data(#"{"hook_event_name":"PreToolUse","source":"herdly-claude-hook-v1","installation_id":"PLACEHOLDER","session_id":"session-new","received_at":"2026-09-20T00:00:00Z","captured_at":PLACEHOLDER_TIME}"#.utf8)
    try Data(String(data: nonSessionEvent, encoding: .utf8)!
        .replacingOccurrences(of: "PLACEHOLDER_TIME", with: String(Date().timeIntervalSince1970))
        .replacingOccurrences(of: "PLACEHOLDER", with: installationID).utf8)
        .write(to: first.eventsDirectory.appendingPathComponent("non-session.json"))
    #expect(installer.status(roots: first, capabilities: capabilities)
            == .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Existing sessions keep running without Herdly's hooks."))
    let resumedEvent = Data(#"{"hook_event_name":"SessionStart","session_start_source":"resume","source":"herdly-claude-hook-v1","installation_id":"PLACEHOLDER","session_id":"session-old","received_at":"2026-09-20T00:00:00Z","captured_at":PLACEHOLDER_TIME}"#.utf8)
    try Data(String(data: resumedEvent, encoding: .utf8)!
        .replacingOccurrences(of: "PLACEHOLDER_TIME", with: String(Date().timeIntervalSince1970))
        .replacingOccurrences(of: "PLACEHOLDER", with: installationID).utf8)
        .write(to: first.eventsDirectory.appendingPathComponent("resumed.json"))
    #expect(installer.status(roots: first, capabilities: capabilities)
            == .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Existing sessions keep running without Herdly's hooks."))

    let event = Data(#"{"hook_event_name":"SessionStart","session_start_source":"startup","source":"herdly-claude-hook-v1","installation_id":"PLACEHOLDER","session_id":"session-a","received_at":"2026-09-20T00:00:00Z","captured_at":PLACEHOLDER_TIME}"#.utf8)
    let eventData = Data(String(data: event, encoding: .utf8)!
        .replacingOccurrences(of: "PLACEHOLDER_TIME", with: String(Date().timeIntervalSince1970))
        .replacingOccurrences(of: "PLACEHOLDER", with: installationID).utf8)
    try eventData.write(to: first.eventsDirectory.appendingPathComponent("event.json"))
    #expect(installer.status(roots: first, capabilities: capabilities) == .connected)
    // Busy sessions keep thousands of tool records inside their one-hour retention (4,785 were seen
    // live). Newer tool records past the old 4,096-entry cap do not hide the startup proof, where the
    // root once flipped to unavailable.
    let toolRecord = Data(#"{"hook_event_name":"PreToolUse","source":"herdly-claude-hook-v1"}"#.utf8)
    let toolCount = 4096
    for index in 0..<toolCount {
        try toolRecord.write(to: first.eventsDirectory.appendingPathComponent("tool-\(index).json"))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: first.eventsDirectory.path).count > 4096)
    #expect(installer.status(roots: first, capabilities: capabilities) == .connected)
    for index in 0..<toolCount {
        try FileManager.default.removeItem(at: first.eventsDirectory.appendingPathComponent("tool-\(index).json"))
    }

    // Removing one exact hook is repairable; a foreign hook remains untouched.
    var changed = try settingsObject(Data(contentsOf: first.settingsURL))
    var hooks = try #require(changed["hooks"] as? [String: Any])
    hooks.removeValue(forKey: "SubagentStop")
    changed["hooks"] = hooks
    try JSONSerialization.data(withJSONObject: changed, options: [.prettyPrinted, .sortedKeys]).write(to: first.settingsURL)
    #expect(installer.status(roots: first, capabilities: capabilities)
            == .repairRequired("Herdly's Claude hook entries are missing; Configure Claude to repair setup."))
    let repair = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: try Data(contentsOf: first.settingsURL),
                                         helperPath: first.helperURL, eventsPath: first.eventsDirectory)
    _ = try installer.install(repair, roots: first, helper: helper, capabilities: capabilities)

    var drifted = try settingsObject(Data(contentsOf: first.settingsURL))
    drifted["model"] = "user-changed"
    try JSONSerialization.data(withJSONObject: drifted, options: [.prettyPrinted, .sortedKeys]).write(to: first.settingsURL)
    #expect(try installer.undo(roots: first) == .notConfigured)
    let restored = try settingsObject(Data(contentsOf: first.settingsURL))
    #expect(restored["model"] as? String == "user-changed")
    #expect((restored["permissions"] as? [String: Any])?["allow"] as? [String] == ["Read"])
    #expect((restored["statusLine"] as? [String: Any])?["command"] as? String == "existing")
    #expect((restored["env"] as? [String: Any])?["KEEP"] as? String == "value")
    #expect((restored["env"] as? [String: Any])?[ClaudeSetupRequirements.titleDisableEnvironmentKey] as? String
            == ClaudeSetupRequirements.titleDisableEnvironmentValue)
    #expect(!FileManager.default.fileExists(atPath: first.stateURL.path))
    #expect(FileManager.default.fileExists(atPath: second.stateURL.path))
}

@Test func claudeSetupRejectsChangedOwnedHookAndMalformedSettingsWithoutWriting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-conflict-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let setupRoots = roots(in: root)
    let original = Data("{}".utf8)
    let installer = ClaudeSetupInstaller()
    try FileManager.default.createDirectory(at: setupRoots.configDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: setupRoots.helperDirectory, withIntermediateDirectories: true)
    try original.write(to: setupRoots.settingsURL)
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                       helperPath: setupRoots.helperURL, eventsPath: setupRoots.eventsDirectory)
    try Data("not json".utf8).write(to: setupRoots.stateURL)
    #expect(throws: ClaudeSetupError.conflict("Herdly Claude setup state is missing or inconsistent; review setup before changing this root.")) {
        _ = try installer.install(plan, roots: setupRoots, helper: Data("helper".utf8), capabilities: capabilities)
    }
    try FileManager.default.removeItem(at: setupRoots.stateURL)
    _ = try installer.install(plan, roots: setupRoots, helper: Data("helper".utf8), capabilities: capabilities)
    let installed = try settingsObject(Data(contentsOf: setupRoots.settingsURL))
    var hooks = try #require(installed["hooks"] as? [String: Any])
    var starts = try #require(hooks["SessionStart"] as? [[String: Any]])
    var extraField = installed
    var extraHooks = try #require(extraField["hooks"] as? [String: Any])
    var extraStarts = try #require(extraHooks["SessionStart"] as? [[String: Any]])
    var extraHandlers = try #require(extraStarts[0]["hooks"] as? [[String: Any]])
    extraHandlers[0]["description"] = "user mutation"
    extraStarts[0]["hooks"] = extraHandlers
    extraHooks["SessionStart"] = extraStarts
    extraField["hooks"] = extraHooks
    #expect(ClaudeSetupPlanner.plan(capabilities: capabilities,
                                    settings: try JSONSerialization.data(withJSONObject: extraField),
                                    helperPath: setupRoots.helperURL,
                                    eventsPath: setupRoots.eventsDirectory).status
            == .conflict("A Herdly-owned Claude hook was changed; review setup before repair."))

    var shadowedHook = installed
    var shadowedHooks = try #require(shadowedHook["hooks"] as? [String: Any])
    var shadowedStarts = try #require(shadowedHooks["SessionStart"] as? [[String: Any]])
    shadowedStarts[0]["matcher"] = "Bash"
    shadowedHooks["SessionStart"] = shadowedStarts
    shadowedHook["hooks"] = shadowedHooks
    #expect(ClaudeSetupPlanner.plan(capabilities: capabilities,
                                    settings: try JSONSerialization.data(withJSONObject: shadowedHook),
                                    helperPath: setupRoots.helperURL,
                                    eventsPath: setupRoots.eventsDirectory).status
            == .conflict("A Herdly-owned Claude hook was changed; review setup before repair."))

    starts[0]["hooks"] = [["type": "command", "command": "/different", "timeout": 10]]
    hooks["SessionStart"] = starts
    var changed = installed
    changed["hooks"] = hooks
    try JSONSerialization.data(withJSONObject: changed, options: [.prettyPrinted, .sortedKeys]).write(to: setupRoots.settingsURL)
    #expect(installer.status(roots: setupRoots, capabilities: capabilities)
            == .conflict("A Herdly-owned Claude hook was changed; review setup before repair."))
    #expect(throws: ClaudeSetupError.conflict("A Herdly-owned Claude hook was changed; undo made no changes.")) {
        _ = try installer.undo(roots: setupRoots)
    }

    try Data("not json".utf8).write(to: setupRoots.settingsURL)
    let malformed = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: Data("not json".utf8),
                                             helperPath: setupRoots.helperURL, eventsPath: setupRoots.eventsDirectory)
    #expect(malformed.status == .malformed("Claude settings.json is not valid JSON and was not changed."))

    let malformedHooks = ClaudeSetupPlanner.plan(capabilities: capabilities,
                                                 settings: Data(#"{"hooks":{"Stop":{}}}"#.utf8),
                                                 helperPath: setupRoots.helperURL,
                                                 eventsPath: setupRoots.eventsDirectory)
    #expect(malformedHooks.status == .malformed("Claude settings.json has an unsupported hooks shape and was not changed."))
}

@Test func claudeSetupRefreshesItsOwnUnchangedHelperAndConfigureAcceptsANewerOne() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-refresh-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = roots(in: root)
    let installer = ClaudeSetupInstaller()
    #expect(try installer.refreshHelper(roots: paths, helper: Data("helper-v2".utf8)) == .skipped("Claude setup is not installed."))
    try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
    try Data(#"{"model":"keep"}"#.utf8).write(to: paths.settingsURL)
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: try Data(contentsOf: paths.settingsURL),
                                       helperPath: paths.helperURL, eventsPath: paths.eventsDirectory)
    _ = try installer.install(plan, roots: paths, helper: Data("helper-v1".utf8), capabilities: capabilities)
    let installedStatus = installer.status(roots: paths, capabilities: capabilities)
    let settings = try Data(contentsOf: paths.settingsURL)

    #expect(try installer.refreshHelper(roots: paths, helper: Data("helper-v1".utf8)) == .current)
    #expect(try installer.refreshHelper(roots: paths, helper: Data("helper-v2".utf8)) == .updated)
    #expect(try Data(contentsOf: paths.helperURL) == Data("helper-v2".utf8))
    #expect(((try FileManager.default.attributesOfItem(atPath: paths.helperURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) == 0o755)
    #expect(installer.status(roots: paths, capabilities: capabilities) == installedStatus)
    #expect(try Data(contentsOf: paths.settingsURL) == settings)
    #expect(try installer.refreshHelper(roots: paths, helper: Data("helper-v2".utf8)) == .current)

    // Configure from a newer app replaces Herdly's own unchanged helper instead of reporting a conflict.
    let repair = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: settings,
                                         helperPath: paths.helperURL, eventsPath: paths.eventsDirectory)
    #expect(try installer.install(repair, roots: paths, helper: Data("helper-v3".utf8), capabilities: capabilities) == installedStatus)
    #expect(try Data(contentsOf: paths.helperURL) == Data("helper-v3".utf8))

    // A helper changed by someone else is never replaced, by refresh or by Configure.
    try Data("user-edited".utf8).write(to: paths.helperURL)
    #expect(try installer.refreshHelper(roots: paths, helper: Data("helper-v4".utf8))
            == .skipped("Herdly's Claude helper differs from the one it installed."))
    #expect(throws: ClaudeSetupError.conflict("A different file already exists at Herdly's Claude helper path.")) {
        _ = try installer.install(repair, roots: paths, helper: Data("helper-v4".utf8), capabilities: capabilities)
    }
    #expect(try Data(contentsOf: paths.helperURL) == Data("user-edited".utf8))
    try Data("helper-v3".utf8).write(to: paths.helperURL)

    #expect(try installer.undo(roots: paths) == .notConfigured)
    #expect(!FileManager.default.fileExists(atPath: paths.helperURL.path))
    #expect(try Data(contentsOf: paths.settingsURL) == Data(#"{"model":"keep"}"#.utf8))
}

@Test func claudeSetupHelperRefreshSkipsAnInconsistentRecord() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-refresh-bad-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = roots(in: root)
    try FileManager.default.createDirectory(at: paths.helperDirectory, withIntermediateDirectories: true)
    try Data("helper-v1".utf8).write(to: paths.helperURL)
    try Data("not json".utf8).write(to: paths.stateURL)
    #expect(try ClaudeSetupInstaller().refreshHelper(roots: paths, helper: Data("helper-v2".utf8))
            == .skipped("Herdly Claude setup state is missing or inconsistent."))
    #expect(try Data(contentsOf: paths.helperURL) == Data("helper-v1".utf8))
}

@Test func claudeSetupAddsTheFileApprovalHookBesideTheExactBashEntry() throws {
    let helper = URL(fileURLWithPath: "/tmp/HerdlyHook"), events = URL(fileURLWithPath: "/tmp/events")
    let fresh = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: Data("{}".utf8), helperPath: helper, eventsPath: events)
    #expect(fresh.addsHooks)
    #expect(fresh.ownedHooks.contains { $0.event == "PermissionRequest" && $0.matcher == "Bash" })
    #expect(fresh.ownedHooks.contains { $0.event == "PermissionRequest" && $0.matcher == ClaudeDirectApproval.fileMatcher })
    #expect(fresh.ownedHooks.contains { $0.event == "PermissionRequest" && $0.matcher == ClaudeDirectApproval.webMatcher })

    // Already configured by this release: nothing to add.
    let current = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: fresh.settingsChange, helperPath: helper, eventsPath: events)
    #expect(current.status == .ready)
    #expect(current.addsHooks == false)
    #expect(current.requiresConfigure == false)

    // Configured by an earlier release that had only the Bash entry: Configure adds the file entry and
    // leaves the existing Bash entry exactly as it was.
    var older = try settingsObject(fresh.settingsChange)
    var hooks = try #require(older["hooks"] as? [String: Any])
    let groups = try #require(hooks["PermissionRequest"] as? [[String: Any]])
    let bash = groups.filter { $0["matcher"] as? String == "Bash" }
    #expect(bash.count == 1)
    hooks["PermissionRequest"] = bash
    older["hooks"] = hooks
    let olderData = try JSONSerialization.data(withJSONObject: older, options: [.sortedKeys])
    let upgrade = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: olderData, helperPath: helper, eventsPath: events)
    #expect(upgrade.status == .ready)
    #expect(upgrade.addsHooks)
    #expect(upgrade.requiresConfigure)
    let upgraded = try #require(try settingsObject(upgrade.settingsChange)["hooks"] as? [String: Any])
    let permissionGroups = try #require(upgraded["PermissionRequest"] as? [[String: Any]])
    #expect(permissionGroups.compactMap { $0["matcher"] as? String }
            == ["Bash", ClaudeDirectApproval.fileMatcher, ClaudeDirectApproval.webMatcher])
    #expect(NSDictionary(dictionary: permissionGroups[0]).isEqual(to: bash[0]))
}
