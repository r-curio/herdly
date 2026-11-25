import AppKit
import Darwin
import Foundation
import HerdlyCore

enum ClaudeSetupDetection {
    static let activeSessionInventoryUnavailable = "Unavailable: Claude's root-scoped agents inventory could not be read."

    enum ActiveSessionStatus: Equatable, Sendable {
        case available(restartCount: Int)
        case unavailable(String)

        var displayText: String {
            switch self {
            case .available(0): return "No active sessions need restart."
            case let .available(count):
                return "\(count) active session\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") restart after setup."
            case let .unavailable(message): return message
            }
        }

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    struct Snapshot: Sendable {
        let root: URL
        let capabilities: ClaudeCapabilities
        let plan: ClaudeSetupPlan?
        let status: ClaudeConnectionStatus
        let helperPath: String
        let eventsPath: String
        let settingsPath: String
        let statePath: String
        let backupsPath: String
        let usagePath: String
        let usage: ClaudeUsageReading?
        let usageStatus: ClaudeUsageSetupStatus
        let usageInstalled: Bool
        /// Whether Herdly's install record for this folder exists: the files Undo Setup removes (#481, A3).
        let installed: Bool
        let activeSessionStatus: ActiveSessionStatus
    }

    static func capabilities() -> ClaudeCapabilities {
        let executable = executable(named: "claude")
        let version = executable.flatMap(version(of:))
        let installed = executable != nil
        return ClaudeCapabilities(installed: installed, supported: installed && atLeast(version, ClaudeSetupRequirements.minimumCLIVersion),
                                  version: version, executablePath: executable?.path)
    }

    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    static func setupRoots(configDirectory: URL, applicationSupport: URL) -> ClaudeSetupRoots {
        ClaudeSetupRoots(configDirectory: configDirectory,
                         helperDirectory: applicationSupport.appendingPathComponent("claude/\(storageKey(configDirectory))", isDirectory: true),
                         eventsDirectory: applicationSupport.appendingPathComponent("claude-events/\(storageKey(configDirectory))", isDirectory: true))
    }

    /// Usage limits are always on for every folder (#481, A4): the plan wraps an existing status line
    /// when the compatibility probe passes and otherwise leaves it byte-identical, reading usage unavailable.
    static func setupSnapshot(root: URL, applicationSupport: URL, capabilities: ClaudeCapabilities,
                              inventoryStatus: ActiveSessionStatus? = nil,
                              titleSettingRequired titleRequired: Bool = ClaudeSetupDetection.titleSettingRequired()) -> Snapshot {
        let usageEnabled = true
        let roots = setupRoots(configDirectory: root, applicationSupport: applicationSupport)
        let manager = FileManager.default
        let settingsExists = manager.fileExists(atPath: roots.settingsURL.path)
        let installRecordExists = manager.fileExists(atPath: roots.stateURL.path)
        let installer = ClaudeSetupInstaller()
        let installRecordPresent = installer.isInstallRecordValid(for: roots)
        let activeSessionStatus = inventoryStatus ?? activeSessionsStatus(root: root, capabilities: capabilities,
                                                                          installedAt: installer.installedAt(for: roots),
                                                                          deliveredSessionIDs: installer.deliveredSessionIDs(for: roots))
        let inventoryUnavailable = activeSessionStatus.isUnavailable
        let settings = boundedRegularData(at: roots.settingsURL) ?? Data("{}".utf8)
        let setupPolicy = policy(for: root, titleSettingRequired: titleRequired)
        let plannerPlan: ClaudeSetupPlan?
        if settingsExists && boundedRegularData(at: roots.settingsURL) == nil {
            plannerPlan = nil
        } else if installRecordExists && !installRecordPresent {
            plannerPlan = nil
        } else {
            let statusLineCompatible = statusLineCompatibility(settings: settings, usageEnabled: usageEnabled)
            plannerPlan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: settings,
                                                  helperPath: roots.helperURL, eventsPath: roots.eventsDirectory,
                                                  sourceScope: root,
                                                  policy: setupPolicy,
                                                  usageEnabled: usageEnabled, settingsExisted: settingsExists,
                                                  installRecordPresent: installRecordPresent,
                                                  statusLineCompatible: statusLineCompatible)
        }
        let plan: ClaudeSetupPlan?
        if capabilities.supported && !installRecordPresent && inventoryUnavailable,
           let plannerPlan, case .ready = plannerPlan.status {
            plan = nil
        } else {
            plan = plannerPlan
        }
        let status: ClaudeConnectionStatus
        if settingsExists && boundedRegularData(at: roots.settingsURL) == nil {
            status = .malformed("Claude settings.json is unreadable or too large; Herdly will not change it.")
        } else if installRecordExists && !installRecordPresent {
            status = ClaudeSetupInstaller().status(roots: roots, capabilities: capabilities,
                                                   titleSettingRequired: titleRequired)
        } else if let plan, case let .unsupported(message) = plan.status {
            status = .unsupported(message)
        } else if let plan, case let .malformed(message) = plan.status {
            status = .malformed(message)
        } else if let plan, case let .conflict(message) = plan.status {
            status = .conflict(message)
        } else if let plan, case let .shadowed(message) = plan.status {
            status = .shadowed(message)
        } else if let plan, case let .blockedByPolicy(message) = plan.status {
            status = .blockedByPolicy(message)
        } else if capabilities.supported && !installRecordPresent && inventoryUnavailable {
            status = .unavailable("Claude setup is blocked until the selected root's agents inventory is available.")
        } else {
            status = ClaudeSetupInstaller().status(roots: roots, capabilities: capabilities,
                                                   titleSettingRequired: titleRequired)
        }
        let usageStatus = installer.usageStatus(for: roots, requested: usageEnabled,
                                                planned: plannerPlan?.usageStatus)
        let usageInstalled = installer.usageStatus(for: roots, requested: true) == .ready
        return Snapshot(root: root, capabilities: capabilities, plan: plan, status: status,
                        helperPath: roots.helperURL.path, eventsPath: roots.eventsDirectory.path,
                        settingsPath: roots.settingsURL.path, statePath: roots.stateURL.path,
                        backupsPath: roots.backupsURL.path, usagePath: roots.usageDirectory.path,
                        usage: ClaudeUsageReader.latest(root: roots.usageDirectory, sourceScope: root.standardizedFileURL.path),
                        usageStatus: usageStatus,
                        usageInstalled: usageInstalled,
                        installed: installRecordExists,
                        activeSessionStatus: activeSessionStatus)
    }

    private static func statusLineCompatibility(settings: Data, usageEnabled: Bool) -> Bool? {
        guard usageEnabled, let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let command = ClaudeStatusLineBridge.statusLineCommand(object["statusLine"]),
              !ClaudeStatusLineBridge.isBridgeCommand(command) else { return nil }
        return ClaudeStatusLineCompatibility.probe(command: command)
    }

    static func activeSessionsStatus(root: URL, capabilities: ClaudeCapabilities,
                                     installedAt: TimeInterval? = nil,
                                     deliveredSessionIDs: Set<String> = []) -> ActiveSessionStatus {
        let inventory = activeSessionInventory(root: root, capabilities: capabilities)
        guard inventory.available else {
            return .unavailable(inventory.failure ?? activeSessionInventoryUnavailable)
        }
        return .available(restartCount: inventory.restartCount(installedAt: installedAt,
                                                               deliveredSessionIDs: deliveredSessionIDs))
    }

    /// Registry entries kept between scheduled scans (`ClaudeSessionRegistry.read`'s `memo`).
    private static let scheduledRegistryEntries = StampedFileMemo<Data>()

    /// `scheduled` is true only for the hook scans (`HookScanSchedule`), which may skip registry entries whose files
    /// are unchanged. Every read that chooses a target or answers a click leaves it false and reads all.
    static func activeSessionInventory(root: URL, capabilities: ClaudeCapabilities,
                                       observedAt: TimeInterval = Date().timeIntervalSince1970,
                                       scheduled: Bool = false) -> ClaudeInventoryScan {
        guard capabilities.supported else {
            return .unavailable(sourceScope: root.path, observedAt: observedAt,
                                reason: "Unavailable: Claude Code is below Herdly's tested inventory baseline.")
        }
        // Claude Code 2.1.292 removed `claude agents --json`; its session registry is read first.
        // The CLI remains the fallback for a version without a usable registry. When both fail, the
        // registry's own failure (and any ambiguous session IDs) is reported, not the CLI's.
        let registry = ClaudeSessionRegistry.read(root: root, observedAt: observedAt,
                                                  memo: scheduled ? scheduledRegistryEntries : nil)
        if let registry, registry.available { return registry }
        guard let executable = executable(named: "claude") else {
            return registry ?? .unavailable(sourceScope: root.path, observedAt: observedAt,
                                            reason: "Unavailable: the Claude executable was not found.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = root.standardizedFileURL.path
        guard let result = runBounded(executable, arguments: ["agents", "--json"], environment: environment, timeout: 5),
              result.status == 0 else {
            return registry ?? .unavailable(sourceScope: root.path, observedAt: observedAt,
                                            reason: activeSessionInventoryUnavailable)
        }
        let cli = ClaudeInventoryDecoder.decode(result.output, sourceScope: root.path, observedAt: observedAt)
        return cli.available ? cli : registry ?? cli
    }

    static func activeSessionSummary(_ data: Data, installedAt: TimeInterval? = nil,
                                     deliveredSessionIDs: Set<String> = []) -> ActiveSessionStatus {
        let inventory = ClaudeInventoryDecoder.decode(data, sourceScope: "/", observedAt: 0)
        guard inventory.available else {
            return .unavailable(inventory.failure ?? "Unavailable: Claude returned an invalid agents inventory.")
        }
        return .available(restartCount: inventory.restartCount(installedAt: installedAt,
                                                               deliveredSessionIDs: deliveredSessionIDs))
    }

    /// Whether this Mac's Ghostty binds Claude by title (ADR 0013), read from its scripting dictionary.
    static func titleSettingRequired() -> Bool {
        let bundle = GhosttyScriptingSupport.bundleURL()
        return ClaudeSetupRequirements.titleSettingRequired(ghosttyInstalled: bundle != nil,
                                                            ttySupport: GhosttyScriptingSupport.ttySupport(bundle: bundle))
    }

    static func policy(for root: URL, projectDirectory: URL? = nil, titleSettingRequired: Bool = true) -> ClaudeSetupPolicy {
        if let configuredRoot = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configuredRoot.isEmpty,
           URL(fileURLWithPath: configuredRoot).standardizedFileURL.path != root.standardizedFileURL.path {
            return ClaudeSetupPolicy(shadowedBy: "CLAUDE_CONFIG_DIR=\(configuredRoot)")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"),
            home.appendingPathComponent("Library/Application Support/ClaudeCode/managed-settings.json")
        ]
        for url in candidates {
            guard let data = boundedRegularData(at: url, maximum: 1024 * 1024),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["allowManagedHooksOnly"] as? Bool == true {
                return ClaudeSetupPolicy(managedHooksOnly: true, titleSettingRequired: titleSettingRequired)
            }
        }
        // Claude's effective-settings resolver is not exposed by the supported CLI. Project
        // settings are inspected only when a caller supplies an exact project directory from
        // trusted session context; the setup snapshot has no such context and stays unknown.
        if let projectDirectory {
            var directory = projectDirectory.standardizedFileURL
            for _ in 0..<32 {
                for filename in ["settings.json", "settings.local.json"] {
                    let url = directory.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent(filename)
                    guard let data = boundedRegularData(at: url, maximum: 1024 * 1024),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if object["disableAllHooks"] as? Bool == true {
                        return ClaudeSetupPolicy(shadowedBy: "project settings at \(url.path) disables all hooks",
                                                 titleSettingRequired: titleSettingRequired)
                    }
                    if titleSettingRequired, let environment = object["env"] as? [String: Any],
                       let value = environment[ClaudeSetupRequirements.titleDisableEnvironmentKey] as? String,
                       value != ClaudeSetupRequirements.titleDisableEnvironmentValue {
                        return ClaudeSetupPolicy(shadowedBy: "project settings at \(url.path) overrides \(ClaudeSetupRequirements.titleDisableEnvironmentKey)",
                                                 titleSettingRequired: titleSettingRequired)
                    }
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return ClaudeSetupPolicy(titleSettingRequired: titleSettingRequired)
    }

    static func boundedRegularData(at url: URL, maximum: Int = 20 * 1024 * 1024) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: maximum + 1) else { return nil }
        try? handle.close()
        return data.count <= maximum ? data : nil
    }

    private static func storageKey(_ root: URL) -> String {
        Data(root.standardizedFileURL.path.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func executable(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [home.appendingPathComponent(".local/bin/\(name)").path,
                     "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths += path.split(separator: ":").map { String($0) + "/\(name)" }
        }
        return paths.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func version(of url: URL) -> String? {
        guard let result = runBounded(url, arguments: ["--version"]), result.status == 0,
              let text = String(data: result.output, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: { !$0.isNumber && $0 != "." })
            .first(where: { $0.first?.isNumber == true && $0.contains(".") })
            .map(String.init)
    }

    /// Reads at most one bounded chunk and returns whether the pipe reached EOF.
    private static func drain(_ descriptor: Int32, into buffer: inout Data) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        var drained = 0
        while drained < 64 * 1024 {
            let count = bytes.withUnsafeMutableBytes { storage in
                read(descriptor, storage.baseAddress, storage.count)
            }
            if count > 0 {
                let remaining = 64 * 1024 + 1 - buffer.count
                if remaining > 0 {
                    buffer.append(contentsOf: bytes.prefix(min(Int(count), remaining)))
                }
                drained += Int(count)
            } else if count == 0 {
                return true
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return false
            } else {
                return false
            }
        }
        return false
    }

    static func runBounded(_ url: URL, arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval = 2) -> (status: Int32, output: Data)? {
        let process = Process(), output = Pipe()
        var buffer = Data()
        process.executableURL = url
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        do { try process.run() } catch {
            return nil
        }
        output.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            _ = drain(descriptor, into: &buffer)
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < terminationDeadline {
                _ = drain(descriptor, into: &buffer)
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            _ = drain(descriptor, into: &buffer)
            return nil
        }
        process.waitUntilExit()
        let drainDeadline = Date().addingTimeInterval(0.02)
        while Date() < drainDeadline {
            if drain(descriptor, into: &buffer) { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return (process.terminationStatus, buffer)
    }

    private static func atLeast(_ value: String?, _ minimum: String) -> Bool {
        guard let value else { return false }
        func parts(_ input: String) -> [Int] {
            var result = input.split(separator: ".").map { Int($0) ?? 0 }
            while result.count < 3 { result.append(0) }
            return Array(result.prefix(3))
        }
        return !parts(value).lexicographicallyPrecedes(parts(minimum))
    }
}

@MainActor
final class ClaudeSetupModel: ObservableObject {
    struct Root: Identifiable, Equatable, Sendable {
        let url: URL
        let capabilities: ClaudeCapabilities
        let plan: ClaudeSetupPlan?
        let status: ClaudeConnectionStatus
        let helperPath: String
        let eventsPath: String
        let settingsPath: String
        let statePath: String
        let backupsPath: String
        let usagePath: String
        let usage: ClaudeUsageReading?
        let usageStatus: ClaudeUsageSetupStatus
        let usageInstalled: Bool
        /// Whether Herdly's install record for this folder exists; the row's switch shows it.
        let installed: Bool
        let activeSessionStatus: ClaudeSetupDetection.ActiveSessionStatus
        var id: String { url.standardizedFileURL.path }
        /// The root's hook event directory when Herdly reads records from it: connected, with an events
        /// path and an installation ID. The one rule for what the hook scan reads and watches (#306).
        var hookSource: (scope: String, events: URL, installationID: String)? {
            guard status == .connected, !eventsPath.isEmpty,
                  let installationID = plan?.installationID, !installationID.isEmpty else { return nil }
            return (url.standardizedFileURL.path, URL(fileURLWithPath: eventsPath, isDirectory: true), installationID)
        }
        var displayPath: String { url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
    }

    @Published private(set) var roots: [Root] = []
    /// False until the first detection pass lands; until then `roots` holds a placeholder.
    @Published private(set) var checked = false
    @Published var message = ""
    private let applicationSupport: URL
    private let defaultRoot: URL
    private var alternatePaths: [String]
    private var refreshToken = 0
    private var restartRecheck = RestartRecheckGate()

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        defaultRoot = home.appendingPathComponent(".claude", isDirectory: true)
        applicationSupport = home.appendingPathComponent("Library/Application Support/Herdly", isDirectory: true)
        alternatePaths = UserDefaults.standard.stringArray(forKey: "claudeConfigRoots") ?? []
        // Usage limits were an opt-in before #481; they are always on now, so the old choice is dropped.
        UserDefaults.standard.removeObject(forKey: "claudeUsageRoots")
        roots = [Root(url: defaultRoot,
                      capabilities: ClaudeCapabilities(installed: false, supported: false),
                      plan: nil, status: .unavailable("Checking Claude Code setup…"),
                      helperPath: "", eventsPath: "",
                      settingsPath: "", statePath: "", backupsPath: "", usagePath: "", usage: nil, usageStatus: .off,
                      usageInstalled: false, installed: false,
                      activeSessionStatus: .unavailable(ClaudeSetupDetection.activeSessionInventoryUnavailable))]
        refresh()
    }

    func refresh() { startRefresh() }

    /// Starts a detection pass; awaiting the task waits until its result has landed (or been
    /// superseded by a newer pass).
    @discardableResult
    func startRefresh() -> Task<Void, Never> {
        let paths = [defaultRoot.path] + alternatePaths.filter { $0 != defaultRoot.path }
        refreshToken += 1
        let token = refreshToken
        let support = applicationSupport
        return Task { @MainActor in
            let (snapshots, updatedHelpers) = await Task.detached(priority: .utility) {
                let caps = ClaudeSetupDetection.capabilities()
                var updated = 0
                let snapshots = paths.map { path in
                    let root = URL(fileURLWithPath: path, isDirectory: true)
                    // Only Herdly's own unchanged helper is replaced; settings.json is never touched here.
                    if let helper = BundledHelper.validated,
                       (try? ClaudeSetupInstaller().refreshHelper(
                           roots: ClaudeSetupDetection.setupRoots(configDirectory: root, applicationSupport: support),
                           helper: helper)) == .updated {
                        updated += 1
                    }
                    return ClaudeSetupDetection.setupSnapshot(root: root, applicationSupport: support, capabilities: caps)
                }
                return (snapshots, updated)
            }.value
            guard token == refreshToken else { return }
            if updatedHelpers > 0 { message = "Updated Herdly's Claude helper to match this version of Herdly." }
            let next = snapshots.map { snapshot in
                Root(url: snapshot.root, capabilities: snapshot.capabilities, plan: snapshot.plan, status: snapshot.status,
                     helperPath: snapshot.helperPath, eventsPath: snapshot.eventsPath,
                     settingsPath: snapshot.settingsPath, statePath: snapshot.statePath,
                     backupsPath: snapshot.backupsPath, usagePath: snapshot.usagePath, usage: snapshot.usage,
                     usageStatus: snapshot.usageStatus, usageInstalled: snapshot.usageInstalled,
                     installed: snapshot.installed, activeSessionStatus: snapshot.activeSessionStatus)
            }
            // Unchanged roots are not written back: the notch observes this model (#306).
            if next != roots { roots = next }
            checked = true
        }
    }

    /// Re-checks only the roots waiting for a new Claude session, which nothing else would notice
    /// landing (#364). A root that stopped waiting gets a full refresh; connected roots cost nothing.
    func recheckAwaitingRestart() {
        let waiting = roots.filter { $0.status.isAwaitingRestart }
        guard restartRecheck.start(now: ProcessInfo.processInfo.systemUptime, anyWaiting: !waiting.isEmpty) else { return }
        let support = applicationSupport
        Task { @MainActor in
            let anyStoppedWaiting = await Task.detached(priority: .utility) {
                let titleRequired = ClaudeSetupDetection.titleSettingRequired()
                return waiting.contains { root in
                    !ClaudeSetupInstaller().status(
                        roots: ClaudeSetupDetection.setupRoots(configDirectory: root.url, applicationSupport: support),
                        capabilities: root.capabilities, titleSettingRequired: titleRequired).isAwaitingRestart
                }
            }.value
            restartRecheck.finish(now: ProcessInfo.processInfo.systemUptime)
            if anyStoppedWaiting { refresh() }
        }
    }

    func refreshUsage() {
        let current = roots
        Task { @MainActor in
            let readings = await Task.detached {
                Dictionary(uniqueKeysWithValues: current.compactMap { root -> (String, ClaudeUsageReading?)? in
                    guard root.usageInstalled, !root.usagePath.isEmpty else { return nil }
                    return (root.id, ClaudeUsageReader.latest(root: URL(fileURLWithPath: root.usagePath, isDirectory: true),
                                                              sourceScope: root.url.standardizedFileURL.path))
                })
            }.value
            let next = roots.map { root in
                guard root.usageInstalled else { return root }
                return Root(url: root.url, capabilities: root.capabilities, plan: root.plan, status: root.status,
                            helperPath: root.helperPath, eventsPath: root.eventsPath, settingsPath: root.settingsPath,
                            statePath: root.statePath, backupsPath: root.backupsPath, usagePath: root.usagePath,
                            usage: readings[root.id] ?? nil, usageStatus: root.usageStatus,
                            usageInstalled: root.usageInstalled, installed: root.installed,
                            activeSessionStatus: root.activeSessionStatus)
            }
            if next != roots { roots = next }
        }
    }

    func addAlternateRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Claude root"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        guard path != defaultRoot.path, !alternatePaths.contains(path) else { return }
        alternatePaths.append(path)
        UserDefaults.standard.set(alternatePaths, forKey: "claudeConfigRoots")
        refresh()
    }

    func removeAlternateRoot(_ root: Root) {
        guard root.url.standardizedFileURL.path != defaultRoot.path else { return }
        alternatePaths.removeAll { $0 == root.url.standardizedFileURL.path }
        UserDefaults.standard.set(alternatePaths, forKey: "claudeConfigRoots")
        refresh()
    }

    /// Runs the folder's setup; the task ends once the result, and the detection after it, has landed.
    @discardableResult
    func configure(_ root: Root) -> Task<Void, Never>? {
        guard let plan = root.plan, case .ready = plan.status else {
            message = "Claude setup preview is not ready for \(root.displayPath)."
            return nil
        }
        let roots = ClaudeSetupDetection.setupRoots(configDirectory: root.url, applicationSupport: applicationSupport)
        let bundleHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HerdlyHook")
        let capabilities = root.capabilities
        return Task { @MainActor in
            let preparation = await Task.detached {
                (ClaudeSetupDetection.boundedRegularData(at: bundleHelper), CodexSetupDetection.validateHelper(bundleHelper))
            }.value
            guard let helper = preparation.0, preparation.1 else {
                message = "The bundled Herdly helper is unavailable or failed its self-test. Reinstall Herdly and try again."
                return
            }
            let result = await Task.detached {
                Result { try ClaudeSetupInstaller().install(plan, roots: roots, helper: helper, capabilities: capabilities) }
            }.value
            switch result {
            case .success:
                // The row's badge and restart line say what happens next (#481, A5).
                message = ""
                await startRefresh().value
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    /// Undo Setup for the folder; the task ends once the result, and the detection after it, has landed.
    @discardableResult
    func undo(_ root: Root) -> Task<Void, Never> {
        let roots = ClaudeSetupDetection.setupRoots(configDirectory: root.url, applicationSupport: applicationSupport)
        return Task { @MainActor in
            let result = await Task.detached {
                Result { try ClaudeSetupInstaller().undo(roots: roots) }
            }.value
            switch result {
            case .success:
                // The row reads Off with its switch off.
                message = ""
                await startRefresh().value
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    nonisolated static func statusText(_ status: ClaudeConnectionStatus) -> String {
        switch status {
        case .connected: "Connected"
        case .configuredAwaitingRestart(let value): value
        case .notConfigured: "Not configured"
        case .unsupported(let value), .unavailable(let value), .repairRequired(let value),
             .blockedByPolicy(let value), .shadowed(let value), .malformed(let value), .conflict(let value): value
        }
    }
}
