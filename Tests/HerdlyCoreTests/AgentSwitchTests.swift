import Foundation
import os
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
                                                     usageStatus: snapshot.usageStatus,
                                                     usageUpgrade: snapshot.usageUpgrade),
                            restartAfterUpdate: false)
}

@Test func theSwitchRunsConfigureWhenTurnedOnAndUndoWhenTurnedOff() {
    let off = AgentSettingsRow(badge: .off, hooksInstalled: false, setupCanRun: true, lines: [])
    let on = AgentSettingsRow(badge: .ready, hooksInstalled: true, setupCanRun: false, lines: [])
    let blocked = AgentSettingsRow(badge: .off, hooksInstalled: false, setupCanRun: false, lines: [.note("Codex isn't installed")])
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
                                      planReady: ready, restartAfterUpdate: false)
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
    #expect(row().lines == [.restart("Quit and reopen Codex, or run `codex` in a new terminal tab, and allow Herdly's hooks if Codex asks")])

    #expect(AgentSwitchChange.change(to: false, row()) == .undo)
    #expect(try installer.undo(roots: roots) == .notConfigured)
    #expect(try Data(contentsOf: roots.configURL) == config)
    #expect(try Data(contentsOf: roots.hooksURL) == hooks)
    #expect(!FileManager.default.fileExists(atPath: roots.helperURL.path))
    #expect(!FileManager.default.fileExists(atPath: roots.stateURL.path))
    #expect(row() == AgentSettingsRow(badge: .off, hooksInstalled: false, setupCanRun: true, lines: []))

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
    #expect(before == AgentSettingsRow(badge: .off, hooksInstalled: false, setupCanRun: true, lines: []))
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

/// A folder Herdly set up the way earlier versions did with usage left off, in temporary folders.
private func folderSetUpWithUsageOff(_ name: String, settings: Data) throws
    -> (root: URL, config: URL, support: URL, roots: ClaudeSetupRoots) {
    let root = temporaryRoot(name)
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let roots = ClaudeSetupDetection.setupRoots(configDirectory: config, applicationSupport: support)
    try settings.write(to: roots.settingsURL)
    let offPlan = ClaudeSetupPlanner.plan(capabilities: claudeCapabilities, settings: settings, helperPath: roots.helperURL,
                                          eventsPath: roots.eventsDirectory, sourceScope: config,
                                          policy: ClaudeSetupPolicy(titleSettingRequired: false), usageEnabled: false,
                                          settingsExisted: true, installRecordPresent: false)
    _ = try ClaudeSetupInstaller().install(offPlan, roots: roots, helper: Data("helper".utf8), capabilities: claudeCapabilities)
    return (root, config, support, roots)
}

@Test func aFolderConfiguredWithUsageOffGetsUsageAutomaticallyAndUndoRestoresIt() async throws {
    let original = Data(#"{"model":"opus","statusLine":{"type":"command","command":"cat","padding":2}}"#.utf8)
    let folder = try folderSetUpWithUsageOff("claude-usage-auto", settings: original)
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let beforeUpgrade = try Data(contentsOf: folder.roots.settingsURL)
    let backupsBefore = (try? FileManager.default.contentsOfDirectory(atPath: folder.roots.backupsURL.path)) ?? []

    // The next detection adds the bridge with no Configure click.
    let upgraded = claudeSnapshot(folder.config, support: folder.support)
    #expect(!upgraded.usageInstalled)
    #expect(await ClaudeSetupDetection.upgradeUsage(upgraded, applicationSupport: folder.support) == .applied)
    let after = claudeSnapshot(folder.config, support: folder.support)
    #expect(after.usageInstalled)
    #expect(after.usageStatus == .ready)
    #expect(after.status == upgraded.status)
    #expect(!claudeRow(after).lines.contains { if case .problem = $0 { true } else { false } })
    let bridged = try Data(contentsOf: folder.roots.settingsURL)
    #expect(String(data: bridged, encoding: .utf8)?.contains("--claude-status-line") == true)
    // Only the status line changed.
    var expected = try #require(JSONSerialization.jsonObject(with: beforeUpgrade) as? [String: Any])
    let written = try #require(JSONSerialization.jsonObject(with: bridged) as? [String: Any])
    expected["statusLine"] = written["statusLine"]
    #expect(NSDictionary(dictionary: expected).isEqual(to: written))
    // The settings were backed up as Configure backs them up.
    let backupsAfter = try FileManager.default.contentsOfDirectory(atPath: folder.roots.backupsURL.path)
    let newBackup = try #require(Set(backupsAfter).subtracting(backupsBefore).first)
    #expect(try Data(contentsOf: folder.roots.backupsURL.appendingPathComponent(newBackup).appendingPathComponent("settings.json"))
        == beforeUpgrade)

    // Runs once: a bridged line is never wrapped again.
    #expect(await ClaudeSetupDetection.upgradeUsage(after, applicationSupport: folder.support) == .skipped)
    #expect(try Data(contentsOf: folder.roots.settingsURL) == bridged)

    // Undo Setup restores the user's original settings byte for byte.
    #expect(try ClaudeSetupInstaller().undo(roots: folder.roots) == .notConfigured)
    #expect(try Data(contentsOf: folder.roots.settingsURL) == original)
}

@Test func automaticUsageAddsHerdlysStatusLineWhenThereIsNoneAndUndoRemovesIt() async throws {
    let original = Data(#"{"model":"opus"}"#.utf8)
    let folder = try folderSetUpWithUsageOff("claude-usage-auto-none", settings: original)
    defer { try? FileManager.default.removeItem(at: folder.root) }
    #expect(await ClaudeSetupDetection.upgradeUsage(claudeSnapshot(folder.config, support: folder.support),
                                              applicationSupport: folder.support) == .applied)
    #expect(String(data: try Data(contentsOf: folder.roots.settingsURL), encoding: .utf8)?.contains("--claude-status-line") == true)
    #expect(claudeSnapshot(folder.config, support: folder.support).usageInstalled)
    _ = try ClaudeSetupInstaller().undo(roots: folder.roots)
    #expect(try Data(contentsOf: folder.roots.settingsURL) == original)
}

@Test func automaticUsageNeverTouchesAFolderHerdlyHasNotSetUp() async throws {
    let root = temporaryRoot("claude-usage-auto-unset")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    let roots = ClaudeSetupDetection.setupRoots(configDirectory: config, applicationSupport: support)
    let original = Data(#"{"statusLine":{"type":"command","command":"cat"}}"#.utf8)
    try original.write(to: roots.settingsURL)
    let snapshot = claudeSnapshot(config, support: support)
    #expect(snapshot.plan?.usageStatus == .ready)
    #expect(await ClaudeSetupDetection.upgradeUsage(snapshot, applicationSupport: support) == .skipped)
    // Even called directly, the installer refuses without an install record.
    #expect(ClaudeSetupInstaller().upgradeUsage(try #require(snapshot.plan), roots: roots,
                                                capabilities: claudeCapabilities) == .skipped)
    #expect(try Data(contentsOf: roots.settingsURL) == original)
    #expect(!FileManager.default.fileExists(atPath: roots.stateURL.path))
}

@Test func automaticUsageLeavesSettingsChangedSinceThePlanWasRead() async throws {
    let folder = try folderSetUpWithUsageOff("claude-usage-auto-race",
                                             settings: Data(#"{"statusLine":{"type":"command","command":"cat"}}"#.utf8))
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let snapshot = claudeSnapshot(folder.config, support: folder.support)
    var edited = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.roots.settingsURL)) as? [String: Any])
    edited["model"] = "sonnet"
    let editedData = try JSONSerialization.data(withJSONObject: edited)
    try editedData.write(to: folder.roots.settingsURL)
    #expect(await ClaudeSetupDetection.upgradeUsage(snapshot, applicationSupport: folder.support) == .skipped)
    #expect(try Data(contentsOf: folder.roots.settingsURL) == editedData)
}

@Test func automaticUsageWaitsWhileTheFolderNeedsRepair() async throws {
    let folder = try folderSetUpWithUsageOff("claude-usage-auto-repair",
                                             settings: Data(#"{"statusLine":{"type":"command","command":"cat"}}"#.utf8))
    defer { try? FileManager.default.removeItem(at: folder.root) }
    try FileManager.default.removeItem(at: folder.roots.helperURL)
    let before = try Data(contentsOf: folder.roots.settingsURL)
    let snapshot = claudeSnapshot(folder.config, support: folder.support)
    #expect(snapshot.status == .repairRequired("Herdly's Claude helper is missing; Configure Claude to repair setup."))
    #expect(await ClaudeSetupDetection.upgradeUsage(snapshot, applicationSupport: folder.support) == .skipped)
    #expect(try Data(contentsOf: folder.roots.settingsURL) == before)
}

@Test func automaticUsageLeavesAnIncompatibleStatusLineByteIdentical() async throws {
    let original = Data(#"{"statusLine":{"command":"sleep 2 & exit 0","type":"command"}}"#.utf8)
    let folder = try folderSetUpWithUsageOff("claude-usage-auto-incompatible", settings: original)
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let before = try Data(contentsOf: folder.roots.settingsURL)
    let snapshot = claudeSnapshot(folder.config, support: folder.support)
    #expect(snapshot.plan?.usageStatus == .unavailable(ClaudeUsageSetupStatus.compatibilityFailureMessage))
    #expect(await ClaudeSetupDetection.upgradeUsage(snapshot, applicationSupport: folder.support) == .skipped)
    #expect(try Data(contentsOf: folder.roots.settingsURL) == before)
    #expect(ClaudeSetupPlanner.memberData(before, key: "statusLine") == ClaudeSetupPlanner.memberData(original, key: "statusLine"))
    let row = claudeRow(claudeSnapshot(folder.config, support: folder.support))
    #expect(row.lines.count == 2)   // the restart line and one quiet usage reason
    #expect(row.lines.contains { if case .note = $0 { true } else { false } })
    #expect(!row.lines.contains { if case .problem = $0 { true } else { false } })
}

/// Fails writes to `target`: only the first one when `once`, otherwise every one.
private func failingWrites(to target: URL, once: Bool) -> @Sendable () -> ClaudeSetupInstaller {
    struct Failure: Error {}
    let failures = OSAllocatedUnfairLock(initialState: 0)
    return {
        ClaudeSetupInstaller(beforeWrite: { url in
            guard url == target else { return }
            let count = failures.withLock { count in
                count += 1
                return count
            }
            if !once || count == 1 { throw Failure() }
        })
    }
}

@Test func aFailedUsageUpgradeRestoresSettingsAndShowsOnTheRow() async throws {
    let folder = try folderSetUpWithUsageOff("claude-usage-auto-fail",
                                             settings: Data(#"{"statusLine":{"type":"command","command":"cat"}}"#.utf8))
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let before = try Data(contentsOf: folder.roots.settingsURL)
    let stateBefore = try Data(contentsOf: folder.roots.stateURL)
    let result = await ClaudeSetupDetection.upgradeUsage(
        claudeSnapshot(folder.config, support: folder.support), applicationSupport: folder.support,
        writes: ClaudeSetupWrites(), makeInstaller: failingWrites(to: folder.roots.stateURL, once: true))
    #expect(result == .failed("Usage setup was not completed; the original configuration was restored."))
    #expect(try Data(contentsOf: folder.roots.settingsURL) == before)
    #expect(try Data(contentsOf: folder.roots.stateURL) == stateBefore)
    var after = claudeSnapshot(folder.config, support: folder.support)
    after.usageUpgrade = result
    #expect(!after.usageInstalled)
    let row = claudeRow(after)
    #expect(row.lines.contains(.note("Couldn't add Herdly's usage status line: Usage setup was not completed; the original configuration was restored.")))
    #expect(!row.lines.contains(.note("Usage limits are unavailable until Herdly can add its status line")))
}

@Test func aUsageUpgradeWhoseRollbackFailsNeedsAttention() async throws {
    let folder = try folderSetUpWithUsageOff("claude-usage-auto-rollback",
                                             settings: Data(#"{"statusLine":{"type":"command","command":"cat"}}"#.utf8))
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let result = await ClaudeSetupDetection.upgradeUsage(
        claudeSnapshot(folder.config, support: folder.support), applicationSupport: folder.support,
        writes: ClaudeSetupWrites(), makeInstaller: failingWrites(to: folder.roots.stateURL, once: false))
    guard case .rollbackIncomplete(let message) = result else {
        Issue.record("expected rollbackIncomplete, got \(result)")
        return
    }
    var after = claudeSnapshot(folder.config, support: folder.support)
    after.usageUpgrade = result
    #expect(!after.usageInstalled)
    let row = claudeRow(after)
    #expect(row.badge == .needsAttention)
    #expect(row.lines.contains(.problem(AgentProblem(kind: .usageWriteFailed, label: "Usage limits", value: message),
                                        configures: false)))
}

/// A folder whose automatic usage upgrade failed and could not roll back.
private func folderWithFailedRollback(_ name: String) async throws
    -> (root: URL, config: URL, support: URL, roots: ClaudeSetupRoots, message: String) {
    let folder = try folderSetUpWithUsageOff(name, settings: Data(#"{"statusLine":{"type":"command","command":"cat"}}"#.utf8))
    let result = await ClaudeSetupDetection.upgradeUsage(
        claudeSnapshot(folder.config, support: folder.support), applicationSupport: folder.support,
        writes: ClaudeSetupWrites(), makeInstaller: failingWrites(to: folder.roots.stateURL, once: false))
    guard case .rollbackIncomplete(let message) = result else {
        throw ClaudeSetupError.failed("expected rollbackIncomplete, got \(result)")
    }
    return (folder.root, folder.config, folder.support, folder.roots, message)
}

/// The folder's row as detection builds it: snapshot, then the automatic upgrade, as `startRefresh` does.
private func detectedRow(_ config: URL, support: URL) async -> AgentSettingsRow {
    var snapshot = claudeSnapshot(config, support: support)
    snapshot.usageUpgrade = await ClaudeSetupDetection.upgradeUsage(snapshot, applicationSupport: support,
                                                                    writes: ClaudeSetupWrites())
    return claudeRow(snapshot)
}

@Test func aFailedRollbackStaysOnTheRowAcrossDetectionsAndBlocksTheUpgrade() async throws {
    let folder = try await folderWithFailedRollback("claude-usage-rollback-sticky")
    defer { try? FileManager.default.removeItem(at: folder.root) }
    // Kept in Herdly's own state, never in the user's Claude folder.
    #expect(folder.roots.usageRollbackURL.path.hasPrefix(folder.support.path))
    #expect(ClaudeSetupInstaller().usageRollbackIncomplete(for: folder.roots) == folder.message)
    let before = try Data(contentsOf: folder.roots.settingsURL)
    // A later detection (or Review Again) with a working installer still shows it and writes nothing.
    for _ in 0..<2 {
        let row = await detectedRow(folder.config, support: folder.support)
        #expect(row.badge == .needsAttention)
        #expect(row.lines.contains(.problem(AgentProblem(kind: .usageWriteFailed, label: "Usage limits", value: folder.message),
                                            configures: false)))
    }
    #expect(ClaudeSetupInstaller().upgradeUsage(try #require(claudeSnapshot(folder.config, support: folder.support).plan),
                                                roots: folder.roots, capabilities: claudeCapabilities)
        == .rollbackIncomplete(folder.message))
    #expect(try Data(contentsOf: folder.roots.settingsURL) == before)
    #expect(!claudeSnapshot(folder.config, support: folder.support).usageInstalled)
}

@Test func aSuccessfulConfigureClearsAFailedRollback() async throws {
    let folder = try await folderWithFailedRollback("claude-usage-rollback-configure")
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let plan = try #require(claudeSnapshot(folder.config, support: folder.support).plan)
    _ = try ClaudeSetupInstaller().install(plan, roots: folder.roots, helper: Data("helper".utf8),
                                           capabilities: claudeCapabilities)
    #expect(ClaudeSetupInstaller().usageRollbackIncomplete(for: folder.roots) == nil)
    let row = await detectedRow(folder.config, support: folder.support)
    #expect(row.badge != .needsAttention)
    #expect(!row.lines.contains { if case .problem = $0 { true } else { false } })
}

@Test func aSuccessfulUndoClearsAFailedRollback() async throws {
    let folder = try await folderWithFailedRollback("claude-usage-rollback-undo")
    defer { try? FileManager.default.removeItem(at: folder.root) }
    #expect(try ClaudeSetupInstaller().undo(roots: folder.roots) == .notConfigured)
    #expect(ClaudeSetupInstaller().usageRollbackIncomplete(for: folder.roots) == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.roots.usageRollbackURL.path))
    let row = await detectedRow(folder.config, support: folder.support)
    #expect(row.badge == .off)
}

@Test func aRollbackFailureOutranksReadyOnAConnectedFolder() {
    let row = AgentSettingsRow.claude(claudeCapabilities, status: .connected, statusText: "Connected", installed: true,
                                      setup: ClaudeFolderSetup(planReady: true, plannedUsage: .ready,
                                                               usageUpgrade: .rollbackIncomplete("Check settings.json")),
                                      restartAfterUpdate: false)
    #expect(row.badge == .needsAttention)
    #expect(row.lines == [.problem(AgentProblem(kind: .usageWriteFailed, label: "Usage limits", value: "Check settings.json"),
                                   configures: false)])
}

/// Holds the first write to `target` until `release` is signalled, after yielding to `entered`.
private func gatedWrites(to target: URL, entered: AsyncStream<Void>.Continuation,
                         release: DispatchSemaphore) -> @Sendable () -> ClaudeSetupInstaller {
    let held = OSAllocatedUnfairLock(initialState: false)
    return {
        ClaudeSetupInstaller(beforeWrite: { url in
            guard url == target, held.withLock({ held in
                defer { held = true }
                return !held
            }) else { return }
            entered.yield()
            release.wait()
        })
    }
}

@Test func anUndoIssuedDuringAUsageUpgradeWaitsAndRestoresTheOriginal() async throws {
    let original = Data(#"{"model":"opus","statusLine":{"type":"command","command":"cat"}}"#.utf8)
    let folder = try folderSetUpWithUsageOff("claude-usage-auto-undo-race", settings: original)
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let writes = ClaudeSetupWrites()
    let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
    let release = DispatchSemaphore(value: 0)
    let snapshot = claudeSnapshot(folder.config, support: folder.support)
    let support = folder.support
    let upgrade = Task {
        await ClaudeSetupDetection.upgradeUsage(snapshot, applicationSupport: support, writes: writes,
                                                makeInstaller: gatedWrites(to: folder.roots.settingsURL,
                                                                           entered: enteredContinuation, release: release))
    }
    for await _ in entered { break }
    // The upgrade is mid-write. Undo is issued now and must wait its turn.
    let (issued, issuedContinuation) = AsyncStream.makeStream(of: Void.self)
    let roots = folder.roots
    let undo = Task {
        issuedContinuation.yield()
        return try await writes.run { try ClaudeSetupInstaller().undo(roots: roots) }
    }
    for await _ in issued { break }
    release.signal()
    #expect(await upgrade.value == .applied)
    #expect(try await undo.value == .notConfigured)
    #expect(try Data(contentsOf: folder.roots.settingsURL) == original)
}

@Test func aUsageUpgradeQueuedBehindUndoWritesNothing() async throws {
    let original = Data(#"{"statusLine":{"type":"command","command":"cat"}}"#.utf8)
    let folder = try folderSetUpWithUsageOff("claude-usage-auto-after-undo", settings: original)
    defer { try? FileManager.default.removeItem(at: folder.root) }
    let writes = ClaudeSetupWrites()
    let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
    let release = DispatchSemaphore(value: 0)
    let stale = claudeSnapshot(folder.config, support: folder.support)
    let roots = folder.roots
    let undoInstaller = gatedWrites(to: roots.settingsURL, entered: enteredContinuation, release: release)
    let undo = Task { try await writes.run { try undoInstaller().undo(roots: roots) } }
    for await _ in entered { break }
    let support = folder.support
    let (issued, issuedContinuation) = AsyncStream.makeStream(of: Void.self)
    let upgrade = Task {
        issuedContinuation.yield()
        return await ClaudeSetupDetection.upgradeUsage(stale, applicationSupport: support, writes: writes)
    }
    for await _ in issued { break }
    release.signal()
    #expect(try await undo.value == .notConfigured)
    #expect(await upgrade.value == .skipped)
    #expect(try Data(contentsOf: roots.settingsURL) == original)
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
