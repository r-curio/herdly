import Foundation
import Testing
@testable import SteerCore

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
                                       helperPath: URL(fileURLWithPath: "/tmp/SteerHook"),
                                       eventsPath: URL(fileURLWithPath: "/tmp/steer-claude-events"))

    #expect(plan.status == .ready)
    #expect(plan.requiresConfigure)
    #expect(plan.usageEnabled == false)
    #expect(plan.ownedHooks.count == ClaudeSetupRequirements.hookDefinitions.count)
    #expect(plan.ownedHooks.contains { $0.event == "SessionStart" && $0.command.contains("--terminal-title") })
    #expect(plan.ownedHooks.contains { $0.event == "PermissionRequest" && $0.matcher == "Bash" })
    let settings = try settingsObject(plan.settingsChange)
    #expect((settings["permissions"] as? [String: Any]) == nil)
    #expect((settings["statusLine"] as? [String: Any]) == nil)
}

@Test func claudeSetupPreservesUnrelatedSettingsBytes() throws {
    let original = Data("{\"permissions\": { \"allow\": [\"Read\"] }, \"hooks\": {} }".utf8)
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                       helperPath: URL(fileURLWithPath: "/tmp/SteerHook"),
                                       eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(plan.status == .ready)
    let changed = try #require(String(data: plan.settingsChange, encoding: .utf8))
    #expect(changed.hasPrefix("{\"permissions\": { \"allow\": [\"Read\"] }, \"hooks\": "))
    #expect(changed.hasSuffix(" }"))

    let missingRecord = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: plan.settingsChange,
                                                helperPath: URL(fileURLWithPath: "/tmp/SteerHook"),
                                                eventsPath: URL(fileURLWithPath: "/tmp/events"),
                                                installRecordPresent: false)
    #expect(missingRecord.status == .conflict("Steer Claude setup state is missing; review this root's settings.json before reconnecting."))
}

@Test func claudeSetupPreservesForeignHooksAndRejectsPolicyOrShadowing() throws {
    let original = Data(#"{"permissions":{"deny":["Bash(rm -rf /)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/keep","timeout":4}]}]}}"#.utf8)
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                       helperPath: URL(fileURLWithPath: "/tmp/SteerHook"),
                                       eventsPath: URL(fileURLWithPath: "/tmp/events"))
    #expect(plan.status == .ready)
    let settings = try settingsObject(plan.settingsChange)
    let permissions = try #require(settings["permissions"] as? [String: Any])
    #expect(permissions["deny"] as? [String] == ["Bash(rm -rf /)"])
    let hooks = try #require(settings["hooks"] as? [String: Any])
    let stop = try #require(hooks["Stop"] as? [[String: Any]])
    #expect(((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "/keep")

    let managed = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                          helperPath: URL(fileURLWithPath: "/tmp/SteerHook"),
                                          eventsPath: URL(fileURLWithPath: "/tmp/events"),
                                          policy: ClaudeSetupPolicy(managedHooksOnly: true))
    #expect(managed.status == .blockedByPolicy("Claude managed policy allows only managed hooks; Steer did not change settings."))

    let shadowed = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                           helperPath: URL(fileURLWithPath: "/tmp/SteerHook"),
                                           eventsPath: URL(fileURLWithPath: "/tmp/events"),
                                           policy: ClaudeSetupPolicy(shadowedBy: "project settings.json"))
    #expect(shadowed.status == .shadowed("Claude settings are shadowed by project settings.json; Steer did not change settings."))
}

@Test func claudeSetupInstallReinstallRepairAndUndoKeepOtherRootIndependent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = roots(in: root, name: "first")
    let second = roots(in: root, name: "second")
    let helper = Data("helper-v1".utf8)
    let installer = ClaudeSetupInstaller()
    let original = Data(#"{"permissions":{"allow":["Read"]},"statusLine":{"type":"command","command":"existing"}}"#.utf8)

    try FileManager.default.createDirectory(at: first.configDirectory, withIntermediateDirectories: true)
    try original.write(to: first.settingsURL)
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original,
                                       helperPath: first.helperURL, eventsPath: first.eventsDirectory)
    #expect(try installer.install(plan, roots: first, helper: helper, capabilities: capabilities)
            == .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Existing sessions keep running without Steer's hooks."))
    #expect(installer.status(roots: first, capabilities: capabilities)
            == .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Existing sessions keep running without Steer's hooks."))

    let secondPlan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: Data("{}".utf8),
                                              helperPath: second.helperURL, eventsPath: second.eventsDirectory)
    _ = try installer.install(secondPlan, roots: second, helper: helper, capabilities: capabilities)
    #expect(FileManager.default.fileExists(atPath: first.stateURL.path))
    #expect(FileManager.default.fileExists(atPath: second.stateURL.path))

    // A valid exact-root event is the only transition from configured to connected.
    let event = Data(#"{"source":"steer-claude-hook-v1","installation_id":"PLACEHOLDER","session_id":"session-a","captured_at":PLACEHOLDER_TIME}"#.utf8)
    let stateData = try Data(contentsOf: first.stateURL)
    let state = try #require(JSONSerialization.jsonObject(with: stateData) as? [String: Any])
    let installationID = try #require(state["installationID"] as? String)
    let eventData = Data(String(data: event, encoding: .utf8)!
        .replacingOccurrences(of: "PLACEHOLDER_TIME", with: String(Date().timeIntervalSince1970))
        .replacingOccurrences(of: "PLACEHOLDER", with: installationID).utf8)
    try FileManager.default.createDirectory(at: first.eventsDirectory, withIntermediateDirectories: true)
    try eventData.write(to: first.eventsDirectory.appendingPathComponent("event.json"))
    #expect(installer.status(roots: first, capabilities: capabilities) == .connected)

    // Removing one exact hook is repairable; a foreign hook remains untouched.
    var changed = try settingsObject(Data(contentsOf: first.settingsURL))
    var hooks = try #require(changed["hooks"] as? [String: Any])
    hooks.removeValue(forKey: "SubagentStop")
    changed["hooks"] = hooks
    try JSONSerialization.data(withJSONObject: changed, options: [.prettyPrinted, .sortedKeys]).write(to: first.settingsURL)
    #expect(installer.status(roots: first, capabilities: capabilities)
            == .repairRequired("Steer's Claude hook entries are missing; Configure Claude to repair setup."))
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
    #expect(!FileManager.default.fileExists(atPath: first.stateURL.path))
    #expect(FileManager.default.fileExists(atPath: second.stateURL.path))
}

@Test func claudeSetupRejectsChangedOwnedHookAndMalformedSettingsWithoutWriting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-conflict-" + UUID().uuidString)
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
    #expect(throws: ClaudeSetupError.conflict("Steer Claude setup state is missing or inconsistent; review setup before changing this root.")) {
        _ = try installer.install(plan, roots: setupRoots, helper: Data("helper".utf8), capabilities: capabilities)
    }
    try FileManager.default.removeItem(at: setupRoots.stateURL)
    _ = try installer.install(plan, roots: setupRoots, helper: Data("helper".utf8), capabilities: capabilities)
    let installed = try settingsObject(Data(contentsOf: setupRoots.settingsURL))
    var hooks = try #require(installed["hooks"] as? [String: Any])
    var starts = try #require(hooks["SessionStart"] as? [[String: Any]])
    starts[0]["hooks"] = [["type": "command", "command": "/different", "timeout": 10]]
    hooks["SessionStart"] = starts
    var changed = installed
    changed["hooks"] = hooks
    try JSONSerialization.data(withJSONObject: changed, options: [.prettyPrinted, .sortedKeys]).write(to: setupRoots.settingsURL)
    #expect(installer.status(roots: setupRoots, capabilities: capabilities)
            == .conflict("A Steer-owned Claude hook was changed; review setup before repair."))
    #expect(throws: ClaudeSetupError.conflict("A Steer-owned Claude hook was changed; undo made no changes.")) {
        _ = try installer.undo(roots: setupRoots)
    }

    try Data("not json".utf8).write(to: setupRoots.settingsURL)
    let malformed = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: Data("not json".utf8),
                                             helperPath: setupRoots.helperURL, eventsPath: setupRoots.eventsDirectory)
    #expect(malformed.status == .malformed("Claude settings.json is not valid JSON and was not changed."))
}
