import Foundation
import Testing
@testable import SteerCore
@testable import SteerApp

private let sessionA = "00000000-0000-4000-8000-000000000001"
private let sessionB = "00000000-0000-4000-8000-000000000002"

private func usageSession(_ index: Int) -> String {
    String(format: "00000000-0000-4000-8000-%012d", index)
}

private func usagePayload(session: String = sessionA, five: (Double, Double)? = (12, 1_000), seven: (Double, Double)? = (42, 2_000), spend: (Double, Double)? = (99, 3_000)) -> Data {
    func window(_ value: (Double, Double)) -> [String: Any] {
        ["used_percentage": value.0, "resets_at": value.1]
    }
    var limits: [String: Any] = [:]
    if let five { limits["five_hour"] = window(five) }
    if let seven { limits["seven_day"] = window(seven) }
    if let spend { limits["spend_limit"] = window(spend) }
    return try! JSONSerialization.data(withJSONObject: ["session_id": session, "rate_limits": limits])
}

@Test func claudeUsageKeepsSubscriptionWindowsIndependentAndNeverReadsSpendLimit() throws {
    let record = try #require(ClaudeUsageReader.sanitizedRecord(usagePayload()))
    let reading = try #require(ClaudeUsageReader.parse(record, sourceScope: "/root-a", now: 0))
    #expect(reading.sourceScope == "/root-a")
    #expect(reading.sessionID == sessionA)
    #expect(reading.fiveHour?.usedPercentage == 12)
    #expect(reading.sevenDay?.usedPercentage == 42)
    #expect(reading.current(now: 1_001)?.fiveHour == nil)
    #expect(reading.current(now: 1_001)?.sevenDay?.usedPercentage == 42)

    let missingFive = try #require(ClaudeUsageReader.parse(
        ClaudeUsageReader.sanitizedRecord(usagePayload(five: nil))!, sourceScope: "/root-a", now: 0))
    #expect(missingFive.fiveHour == nil)
    #expect(missingFive.sevenDay?.usedPercentage == 42)
    #expect(ClaudeUsageReader.parse(ClaudeUsageReader.sanitizedRecord(usagePayload(session: ""))!, sourceScope: "/root-a", now: 0) == nil)
    #expect(ClaudeUsageReader.parse(ClaudeUsageReader.sanitizedRecord(usagePayload(session: "session-a"))!, sourceScope: "/root-a", now: 0) == nil)
}

@Test func claudeUsageLatestTreatsNewestMalformedRecordAsUnavailableAndKeepsRootsSeparate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-usage-" + UUID().uuidString)
    let other = directory.appendingPathComponent("other", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(ClaudeUsageReader.record(usagePayload(), to: directory, observedAt: 1))
    #expect(ClaudeUsageReader.latest(root: directory, sourceScope: "/root-a", now: 0)?.sourceScope == "/root-a")
    let newest = directory.appendingPathComponent(ClaudeUsageReader.latestRecordName)
    try Data("not json".utf8).write(to: newest)
    #expect(ClaudeUsageReader.latest(root: directory, sourceScope: "/root-a", now: 0) == nil)

    #expect(ClaudeUsageReader.record(usagePayload(session: sessionB, five: (7, 2_000), seven: nil), to: other, observedAt: 2))
    #expect(ClaudeUsageReader.latest(root: other, sourceScope: "/root-b", now: 0)?.sourceScope == "/root-b")
    #expect(ClaudeUsageReader.latest(root: other, sourceScope: "/root-b", now: 0)?.sessionID == sessionB)
}

@Test func claudeUsageRejectsOversizedRecordsAndKeepsOwnedStorageBounded() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-usage-bounded-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oversized = Data(repeating: 0x78, count: ClaudeUsageReader.maximumRecordBytes + 1)
    #expect(ClaudeUsageReader.sanitizedRecord(oversized, observedAt: 1) == nil)
    #expect(!ClaudeUsageReader.record(oversized, to: directory, observedAt: 1))

    for index in 1...5_000 {
        #expect(ClaudeUsageReader.record(usagePayload(session: usageSession(index)), to: directory, observedAt: Double(index)))
    }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.filter { $0.lastPathComponent.hasPrefix("steer-usage-") }.isEmpty)
    #expect(files.filter { $0.lastPathComponent == ClaudeUsageReader.latestRecordName }.count == 1)
    #expect(ClaudeUsageReader.latest(root: directory, sourceScope: "/root-a", now: 0)?.sessionID == usageSession(5_000))
    try Data(repeating: 0x78, count: ClaudeUsageReader.maximumRecordBytes + 1)
        .write(to: directory.appendingPathComponent(ClaudeUsageReader.latestRecordName), options: .atomic)
    #expect(ClaudeUsageReader.latest(root: directory, sourceScope: "/root-a", now: 0) == nil)
}

@Test func claudeUsageDoesNotTrustAForgedOwnedFilename() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-usage-forged-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let record = directory.appendingPathComponent(ClaudeUsageReader.latestRecordName)
    let forged = Data(#"{"source":"steer-claude-usage-v1"}"#.utf8)
    try forged.write(to: record)
    #expect(!ClaudeUsageReader.record(usagePayload(), to: directory, observedAt: 2))
    #expect(try Data(contentsOf: record) == forged)
}

@Test func claudeUsageIgnoresAnOverCapDirectoryOfUnrelatedFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-usage-over-cap-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(ClaudeUsageReader.record(usagePayload(), to: directory, observedAt: 1))
    for index in 0...ClaudeUsageReader.maximumFiles {
        try Data("unrelated".utf8).write(to: directory.appendingPathComponent("user-\(index).json"))
    }
    #expect(ClaudeUsageReader.latest(root: directory, sourceScope: "/root-a", now: 0)?.sessionID == sessionA)
}

@Test func claudeStatusLineCommandQuotesTheExistingCommandAndProbeRejectsSlowDescendants() {
    let command = ClaudeStatusLineBridge.command(helperPath: URL(fileURLWithPath: "/tmp/Steer Hook"),
                                                  usagePath: URL(fileURLWithPath: "/tmp/usage"),
                                                  existingCommand: "printf '%s\\n' \"$PWD\"; exit 7")
    #expect(command.contains("--claude-status-line"))
    #expect(command.contains("--existing-command 'printf "))
    #expect(command.contains("exit 7'"))
    #expect(ClaudeStatusLineCompatibility.probe(command: "cat"))
    #expect(!ClaudeStatusLineCompatibility.probe(command: "sleep 2", timeout: 0.05))
    #expect(!ClaudeStatusLineCompatibility.probe(command: "sleep 2 & exit 0"))
    #expect(!ClaudeStatusLineCompatibility.probe(command: "sleep 2 >/dev/null & exit 0"))
}

@Test func claudeUsageSetupComposesReversiblyAndDetectsStatusLineConflicts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-usage-setup-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let setupRoots = ClaudeSetupRoots(configDirectory: config,
                                      helperDirectory: support.appendingPathComponent("claude", isDirectory: true),
                                      eventsDirectory: support.appendingPathComponent("claude-events", isDirectory: true))
    let original = Data(#"{"model":"opus","statusLine":{"type":"command","command":"cat","padding":2}}"#.utf8)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try original.write(to: setupRoots.settingsURL)
    let plan = ClaudeSetupPlanner.plan(capabilities: ClaudeCapabilities(installed: true, supported: true, version: "2.1.273"),
                                       settings: original, helperPath: setupRoots.helperURL,
                                       eventsPath: setupRoots.eventsDirectory, usageEnabled: true,
                                       statusLineCompatible: true)
    #expect(plan.usageStatus == .ready)
    #expect(plan.settingsChange != original)
    let installer = ClaudeSetupInstaller()
    _ = try installer.install(plan, roots: setupRoots, helper: Data("helper".utf8),
                              capabilities: ClaudeCapabilities(installed: true, supported: true, version: "2.1.273"))
    let installed = try Data(contentsOf: setupRoots.settingsURL)
    #expect(String(data: installed, encoding: .utf8)?.contains("--claude-status-line") == true)

    var changed = try #require(JSONSerialization.jsonObject(with: installed) as? [String: Any])
    changed["model"] = "sonnet"
    try JSONSerialization.data(withJSONObject: changed).write(to: setupRoots.settingsURL)
    _ = try installer.undo(roots: setupRoots)
    let restored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: setupRoots.settingsURL)) as? [String: Any])
    #expect(restored["model"] as? String == "sonnet")
    #expect((restored["statusLine"] as? [String: Any])?["command"] as? String == "cat")

    try original.write(to: setupRoots.settingsURL, options: .atomic)
    let secondPlan = ClaudeSetupPlanner.plan(capabilities: ClaudeCapabilities(installed: true, supported: true, version: "2.1.273"),
                                             settings: original, helperPath: setupRoots.helperURL,
                                             eventsPath: setupRoots.eventsDirectory, usageEnabled: true,
                                             statusLineCompatible: true)
    _ = try installer.install(secondPlan, roots: setupRoots, helper: Data("helper".utf8),
                              capabilities: ClaudeCapabilities(installed: true, supported: true, version: "2.1.273"))
    var userChanged = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: setupRoots.settingsURL)) as? [String: Any])
    userChanged["statusLine"] = ["type": "command", "command": "printf user"]
    try JSONSerialization.data(withJSONObject: userChanged).write(to: setupRoots.settingsURL)
    #expect(installer.status(roots: setupRoots, capabilities: ClaudeCapabilities(installed: true, supported: true, version: "2.1.273"))
            == .conflict("Steer's Claude usage status line was changed; review setup before repair."))
    #expect(throws: ClaudeSetupError.conflict("Steer's Claude usage status line was changed; undo made no changes.")) {
        _ = try installer.undo(roots: setupRoots)
    }
}

@Test func claudeUsageCanBeDisabledWithoutUndoingClaudeConnection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-usage-disable-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let setupRoots = ClaudeSetupRoots(configDirectory: config,
                                      helperDirectory: support.appendingPathComponent("claude", isDirectory: true),
                                      eventsDirectory: support.appendingPathComponent("claude-events", isDirectory: true))
    let original = Data(#"{"statusLine":{"type":"command","command":"cat"}}"#.utf8)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try original.write(to: setupRoots.settingsURL)
    let capabilities = ClaudeCapabilities(installed: true, supported: true, version: "2.1.273")
    let installer = ClaudeSetupInstaller()
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original, helperPath: setupRoots.helperURL,
                                       eventsPath: setupRoots.eventsDirectory, usageEnabled: true,
                                       statusLineCompatible: true)
    _ = try installer.install(plan, roots: setupRoots, helper: Data("helper".utf8), capabilities: capabilities)
    let installed = try Data(contentsOf: setupRoots.settingsURL)
    let disablePlan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: installed, helperPath: setupRoots.helperURL,
                                              eventsPath: setupRoots.eventsDirectory, usageEnabled: false,
                                              installRecordPresent: true)
    _ = try installer.install(disablePlan, roots: setupRoots, helper: Data("helper".utf8), capabilities: capabilities)
    let disabled = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: setupRoots.settingsURL)) as? [String: Any])
    #expect((disabled["statusLine"] as? [String: Any])?["command"] as? String == "cat")
    #expect(FileManager.default.fileExists(atPath: setupRoots.helperURL.path))
}

@Test func claudeUsageUndoRemovesOnlyItsRecordAfterManyRefreshes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-usage-undo-bounded-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let setupRoots = ClaudeSetupRoots(configDirectory: config,
                                      helperDirectory: support.appendingPathComponent("claude", isDirectory: true),
                                      eventsDirectory: support.appendingPathComponent("claude-events", isDirectory: true))
    let original = Data(#"{"statusLine":{"type":"command","command":"cat"}}"#.utf8)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try original.write(to: setupRoots.settingsURL)
    let capabilities = ClaudeCapabilities(installed: true, supported: true, version: "2.1.273")
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original, helperPath: setupRoots.helperURL,
                                       eventsPath: setupRoots.eventsDirectory, usageEnabled: true,
                                       statusLineCompatible: true)
    let installer = ClaudeSetupInstaller()
    _ = try installer.install(plan, roots: setupRoots, helper: Data("helper".utf8), capabilities: capabilities)
    for index in 1...5_000 {
        #expect(ClaudeUsageReader.record(usagePayload(session: usageSession(index)), to: setupRoots.usageDirectory, observedAt: Double(index)))
    }
    let unrelated = setupRoots.usageDirectory.appendingPathComponent("user-owned.json")
    let unrelatedData = Data("leave me".utf8)
    try unrelatedData.write(to: unrelated)

    #expect(try installer.undo(roots: setupRoots) == .notConfigured)
    #expect(!FileManager.default.fileExists(atPath: setupRoots.usageDirectory.appendingPathComponent(ClaudeUsageReader.latestRecordName).path))
    #expect(try Data(contentsOf: unrelated) == unrelatedData)
}

@Test func incompatibleClaudeStatusLineLeavesCoreConnectionIntact() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-usage-incompatible-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let setupRoots = ClaudeSetupRoots(configDirectory: config,
                                      helperDirectory: support.appendingPathComponent("claude", isDirectory: true),
                                      eventsDirectory: support.appendingPathComponent("claude-events", isDirectory: true))
    let original = Data(#"{"statusLine":{"type":"command","command":"sleep 2 & exit 0"}}"#.utf8)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try original.write(to: setupRoots.settingsURL)
    let capabilities = ClaudeCapabilities(installed: true, supported: true, version: "2.1.273")
    let plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: original, helperPath: setupRoots.helperURL,
                                       eventsPath: setupRoots.eventsDirectory, usageEnabled: true,
                                       statusLineCompatible: false)
    #expect(plan.usageStatus == .unavailable(ClaudeStatusLineCompatibility.failureMessage))
    #expect(String(data: plan.settingsChange, encoding: .utf8)?.contains("--claude-status-line") != true)
    _ = try ClaudeSetupInstaller().install(plan, roots: setupRoots, helper: Data("helper".utf8), capabilities: capabilities)
    let installed = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: setupRoots.settingsURL)) as? [String: Any])
    #expect((installed["statusLine"] as? [String: Any])?["command"] as? String == "sleep 2 & exit 0")
    #expect(FileManager.default.fileExists(atPath: setupRoots.helperURL.path))
}
