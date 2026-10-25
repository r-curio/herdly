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

    static func setupSnapshot(root: URL, applicationSupport: URL, capabilities: ClaudeCapabilities,
                              usageEnabled: Bool = false,
                              inventoryStatus: ActiveSessionStatus? = nil) -> Snapshot {
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
        let setupPolicy = policy(for: root)
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
            status = ClaudeSetupInstaller().status(roots: roots, capabilities: capabilities)
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
            status = ClaudeSetupInstaller().status(roots: roots, capabilities: capabilities)
        }
        let usageStatus = installer.usageStatus(for: roots, requested: usageEnabled,
                                                planned: plannerPlan?.usageStatus)
        let usageInstalled = installer.usageStatus(for: roots, requested: true) == .ready
        return Snapshot(root: root, capabilities: capabilities, plan: plan, status: status,
                        helperPath: roots.helperURL.path, eventsPath: roots.eventsDirectory.path,
                        settingsPath: roots.settingsURL.path, statePath: roots.stateURL.path,
                        backupsPath: roots.backupsURL.path, usagePath: roots.usageDirectory.path,
                        usage: usageEnabled ? ClaudeUsageReader.latest(root: roots.usageDirectory,
                                                                        sourceScope: root.standardizedFileURL.path) : nil,
                        usageStatus: usageStatus,
                        usageInstalled: usageInstalled,
                        activeSessionStatus: activeSessionStatus)
    }

    private static func statusLineCompatibility(settings: Data, usageEnabled: Bool) -> Bool? {
        guard usageEnabled,
              let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
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
        return .available(restartCount: restartCount(in: inventory, installedAt: installedAt,
                                                     deliveredSessionIDs: deliveredSessionIDs))
    }

    static func activeSessionInventory(root: URL, capabilities: ClaudeCapabilities,
                                       observedAt: TimeInterval = Date().timeIntervalSince1970) -> ClaudeInventoryScan {
        guard capabilities.supported else {
            return .unavailable(sourceScope: root.path, observedAt: observedAt,
                                reason: "Unavailable: Claude Code is below Herdly's tested inventory baseline.")
        }
        // Claude Code 2.1.292 removed `claude agents --json`; its session registry is read first.
        // The CLI remains the fallback for a version without a usable registry. When both fail, the
        // registry's own failure (and any ambiguous session IDs) is reported, not the CLI's.
        let registry = ClaudeSessionRegistry.read(root: root, observedAt: observedAt)
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
        return .available(restartCount: restartCount(in: inventory, installedAt: installedAt,
                                                     deliveredSessionIDs: deliveredSessionIDs))
    }

    private static func restartCount(in inventory: ClaudeInventoryScan, installedAt: TimeInterval?,
                                     deliveredSessionIDs: Set<String>) -> Int {
        var count = 0
        for session in inventory.sessions where session.lifecycle.needsRestart {
            let needsRestart: Bool
            if let installedAt {
                needsRestart = session.startedAt < installedAt && !deliveredSessionIDs.contains(session.sessionID)
            } else {
                needsRestart = true
            }
            if needsRestart { count += 1 }
        }
        return count
    }

    static func policy(for root: URL, projectDirectory: URL? = nil) -> ClaudeSetupPolicy {
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
            if object["allowManagedHooksOnly"] as? Bool == true { return ClaudeSetupPolicy(managedHooksOnly: true) }
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
                        return ClaudeSetupPolicy(shadowedBy: "project settings at \(url.path) disables all hooks")
                    }
                    if let environment = object["env"] as? [String: Any],
                       let value = environment[ClaudeSetupRequirements.titleDisableEnvironmentKey] as? String,
                       value != ClaudeSetupRequirements.titleDisableEnvironmentValue {
                        return ClaudeSetupPolicy(shadowedBy: "project settings at \(url.path) overrides \(ClaudeSetupRequirements.titleDisableEnvironmentKey)")
                    }
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return ClaudeSetupPolicy()
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
        let activeSessionStatus: ClaudeSetupDetection.ActiveSessionStatus
        var id: String { url.standardizedFileURL.path }
        var displayPath: String { url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
    }

    @Published private(set) var roots: [Root] = []
    /// False until the first detection pass lands; until then `roots` holds a placeholder.
    @Published private(set) var checked = false
    @Published var message = ""
    private let applicationSupport: URL
    private let defaultRoot: URL
    private var alternatePaths: [String]
    private var usageOptInPaths: Set<String>
    private var refreshToken = 0
    /// When a root awaiting restart may next be re-checked; nil while a re-check is running (#364).
    private var nextRestartRecheck: Date? = .distantPast
    /// A waiting root's check decodes every listed hook record, so scans re-run it at most this often.
    private static let restartRecheckInterval: TimeInterval = 5

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        defaultRoot = home.appendingPathComponent(".claude", isDirectory: true)
        applicationSupport = home.appendingPathComponent("Library/Application Support/Herdly", isDirectory: true)
        alternatePaths = UserDefaults.standard.stringArray(forKey: "claudeConfigRoots") ?? []
        usageOptInPaths = Set(UserDefaults.standard.stringArray(forKey: "claudeUsageRoots") ?? [])
        roots = [Root(url: defaultRoot,
                      capabilities: ClaudeCapabilities(installed: false, supported: false),
                      plan: nil, status: .unavailable("Checking Claude Code setup…"),
                      helperPath: "", eventsPath: "",
                      settingsPath: "", statePath: "", backupsPath: "", usagePath: "", usage: nil, usageStatus: .off,
                      usageInstalled: false,
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
        let usagePaths = usageOptInPaths
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
                    return ClaudeSetupDetection.setupSnapshot(root: root, applicationSupport: support, capabilities: caps,
                                                              usageEnabled: usagePaths.contains(root.standardizedFileURL.path))
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
                     activeSessionStatus: snapshot.activeSessionStatus)
            }
            // Unchanged roots are not written back: the notch observes this model (#306).
            if next != roots { roots = next }
            checked = true
        }
    }

    /// Re-checks only the roots waiting for a new Claude session, which nothing else would notice
    /// landing (#364). A root that stopped waiting gets a full refresh; connected roots cost nothing.
    func recheckAwaitingRestart(now: Date = Date()) {
        let waiting = roots.filter { $0.status.isAwaitingRestart }
        guard !waiting.isEmpty, let due = nextRestartRecheck, now >= due else { return }
        nextRestartRecheck = nil
        let support = applicationSupport
        Task { @MainActor in
            let settled = await Task.detached(priority: .utility) {
                waiting.contains { root in
                    !ClaudeSetupInstaller().status(
                        roots: ClaudeSetupDetection.setupRoots(configDirectory: root.url, applicationSupport: support),
                        capabilities: root.capabilities).isAwaitingRestart
                }
            }.value
            nextRestartRecheck = Date().addingTimeInterval(Self.restartRecheckInterval)
            if settled { refresh() }
        }
    }

    func refreshUsage() {
        let current = roots
        let enabled = usageOptInPaths
        Task { @MainActor in
            let readings = await Task.detached {
                Dictionary(uniqueKeysWithValues: current.compactMap { root -> (String, ClaudeUsageReading?)? in
                    guard enabled.contains(root.url.standardizedFileURL.path), !root.usagePath.isEmpty else { return nil }
                    return (root.id, ClaudeUsageReader.latest(root: URL(fileURLWithPath: root.usagePath, isDirectory: true),
                                                              sourceScope: root.url.standardizedFileURL.path))
                })
            }.value
            let next = roots.map { root in
                guard enabled.contains(root.url.standardizedFileURL.path) else { return root }
                return Root(url: root.url, capabilities: root.capabilities, plan: root.plan, status: root.status,
                            helperPath: root.helperPath, eventsPath: root.eventsPath, settingsPath: root.settingsPath,
                            statePath: root.statePath, backupsPath: root.backupsPath, usagePath: root.usagePath,
                            usage: readings[root.id] ?? nil, usageStatus: root.usageStatus,
                            usageInstalled: root.usageInstalled,
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

    func usageEnabled(for root: Root) -> Bool { usageOptInPaths.contains(root.url.standardizedFileURL.path) }

    func setUsageEnabled(_ enabled: Bool, for root: Root) {
        let path = root.url.standardizedFileURL.path
        if enabled { usageOptInPaths.insert(path) } else { usageOptInPaths.remove(path) }
        UserDefaults.standard.set(Array(usageOptInPaths), forKey: "claudeUsageRoots")
        refresh()
    }

    /// The opt-in lives as a marker file beside the hook's events, so the hook reads the same
    /// switch the toggle shows without Claude's settings changing.
    func sessionTitlesEnabled(for root: Root) -> Bool {
        ClaudeSessionTitles.isEnabled(eventsDirectory: eventsDirectory(for: root))
    }

    func setSessionTitlesEnabled(_ enabled: Bool, for root: Root) {
        objectWillChange.send()
        if !ClaudeSessionTitles.setEnabled(enabled, eventsDirectory: eventsDirectory(for: root)) {
            message = "Herdly could not \(enabled ? "turn on" : "turn off") session titles for \(root.displayPath)."
        }
    }

    private func eventsDirectory(for root: Root) -> URL {
        ClaudeSetupDetection.setupRoots(configDirectory: root.url, applicationSupport: applicationSupport).eventsDirectory
    }

    func configure(_ root: Root) {
        guard let plan = root.plan, case .ready = plan.status else {
            message = "Claude setup preview is not ready for \(root.displayPath)."
            return
        }
        let roots = ClaudeSetupDetection.setupRoots(configDirectory: root.url, applicationSupport: applicationSupport)
        let bundleHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HerdlyHook")
        let capabilities = root.capabilities
        Task { @MainActor in
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
            case .success(let status):
                message = Self.statusText(status)
                refresh()
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    func undo(_ root: Root) {
        let roots = ClaudeSetupDetection.setupRoots(configDirectory: root.url, applicationSupport: applicationSupport)
        Task { @MainActor in
            let result = await Task.detached {
                Result { try ClaudeSetupInstaller().undo(roots: roots) }
            }.value
            switch result {
            case .success:
                message = "Claude setup removed from \(root.displayPath)."
                refresh()
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    static func statusText(_ status: ClaudeConnectionStatus) -> String {
        switch status {
        case .connected: "Connected"
        case .configuredAwaitingRestart(let value): value
        case .notConfigured: "Not configured"
        case .unsupported(let value), .unavailable(let value), .repairRequired(let value),
             .blockedByPolicy(let value), .shadowed(let value), .malformed(let value), .conflict(let value): value
        }
    }
}
