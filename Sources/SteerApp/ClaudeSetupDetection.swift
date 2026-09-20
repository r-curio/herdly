import AppKit
import Foundation
import SteerCore

enum ClaudeSetupDetection {
    static let activeSessionInventoryUnavailable = "Unavailable: Claude exposes no bounded root-scoped active-session inventory."

    struct Snapshot: Sendable {
        let root: URL
        let capabilities: ClaudeCapabilities
        let plan: ClaudeSetupPlan?
        let status: ClaudeConnectionStatus
        let helperPath: String
        let eventsPath: String
        let activeSessionStatus: String
    }

    static func capabilities() -> ClaudeCapabilities {
        let executable = executable(named: "claude")
        let version = executable.flatMap(version(of:))
        let installed = executable != nil
        return ClaudeCapabilities(installed: installed, supported: installed && atLeast(version, ClaudeSetupRequirements.minimumCLIVersion),
                                  version: version)
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
                              usageEnabled: Bool = false) -> Snapshot {
        let roots = setupRoots(configDirectory: root, applicationSupport: applicationSupport)
        let manager = FileManager.default
        let settingsExists = manager.fileExists(atPath: roots.settingsURL.path)
        let installRecordExists = manager.fileExists(atPath: roots.stateURL.path)
        let installRecordPresent = ClaudeSetupInstaller().isInstallRecordValid(for: roots)
        let settings = boundedRegularData(at: roots.settingsURL) ?? Data("{}".utf8)
        let setupPolicy = policy(for: root)
        let plan: ClaudeSetupPlan?
        if settingsExists && boundedRegularData(at: roots.settingsURL) == nil {
            plan = nil
        } else if installRecordExists && !installRecordPresent {
            plan = nil
        } else {
            plan = ClaudeSetupPlanner.plan(capabilities: capabilities, settings: settings,
                                           helperPath: roots.helperURL, eventsPath: roots.eventsDirectory,
                                           policy: setupPolicy,
                                           usageEnabled: usageEnabled, settingsExisted: settingsExists,
                                           installRecordPresent: installRecordPresent)
        }
        let status: ClaudeConnectionStatus
        if settingsExists && boundedRegularData(at: roots.settingsURL) == nil {
            status = .malformed("Claude settings.json is unreadable or too large; Steer will not change it.")
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
        } else {
            status = ClaudeSetupInstaller().status(roots: roots, capabilities: capabilities)
        }
        return Snapshot(root: root, capabilities: capabilities, plan: plan, status: status,
                        helperPath: roots.helperURL.path, eventsPath: roots.eventsDirectory.path,
                        activeSessionStatus: activeSessionInventoryUnavailable)
    }

    private static func policy(for root: URL) -> ClaudeSetupPolicy {
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

    private static func runBounded(_ url: URL, arguments: [String], timeout: TimeInterval = 2) -> (status: Int32, output: Data)? {
        let process = Process(), output = Pipe()
        process.executableURL = url
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else { process.terminate(); return nil }
        return (process.terminationStatus, (try? output.fileHandleForReading.read(upToCount: 64 * 1024)) ?? Data())
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
    struct Root: Identifiable, Sendable {
        let url: URL
        let capabilities: ClaudeCapabilities
        let plan: ClaudeSetupPlan?
        let status: ClaudeConnectionStatus
        let helperPath: String
        let eventsPath: String
        let activeSessionStatus: String
        var id: String { url.standardizedFileURL.path }
        var displayPath: String { url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
    }

    @Published private(set) var roots: [Root] = []
    @Published var message = ""
    private let applicationSupport: URL
    private let defaultRoot: URL
    private var alternatePaths: [String]
    private var usageOptInPaths: Set<String>
    private var refreshToken = 0

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        defaultRoot = home.appendingPathComponent(".claude", isDirectory: true)
        applicationSupport = home.appendingPathComponent("Library/Application Support/Steer", isDirectory: true)
        alternatePaths = UserDefaults.standard.stringArray(forKey: "claudeConfigRoots") ?? []
        usageOptInPaths = Set(UserDefaults.standard.stringArray(forKey: "claudeUsageRoots") ?? [])
        roots = [Root(url: defaultRoot,
                      capabilities: ClaudeCapabilities(installed: false, supported: false),
                      plan: nil, status: .unavailable("Checking Claude Code setup…"),
                      helperPath: "", eventsPath: "",
                      activeSessionStatus: ClaudeSetupDetection.activeSessionInventoryUnavailable)]
        refresh()
    }

    func refresh() {
        let paths = [defaultRoot.path] + alternatePaths.filter { $0 != defaultRoot.path }
        refreshToken += 1
        let token = refreshToken
        let support = applicationSupport
        let usagePaths = usageOptInPaths
        Task { @MainActor in
            let snapshots = await Task.detached(priority: .utility) {
                let caps = ClaudeSetupDetection.capabilities()
                return paths.map { path in
                    let root = URL(fileURLWithPath: path, isDirectory: true)
                    return ClaudeSetupDetection.setupSnapshot(root: root, applicationSupport: support, capabilities: caps,
                                                              usageEnabled: usagePaths.contains(root.standardizedFileURL.path))
                }
            }.value
            guard token == refreshToken else { return }
            roots = snapshots.map { snapshot in
                Root(url: snapshot.root, capabilities: snapshot.capabilities, plan: snapshot.plan, status: snapshot.status,
                     helperPath: snapshot.helperPath, eventsPath: snapshot.eventsPath,
                     activeSessionStatus: snapshot.activeSessionStatus)
            }
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

    func configure(_ root: Root) {
        guard let plan = root.plan, case .ready = plan.status else {
            message = "Claude setup preview is not ready for \(root.displayPath)."
            return
        }
        let roots = ClaudeSetupDetection.setupRoots(configDirectory: root.url, applicationSupport: applicationSupport)
        let bundleHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SteerHook")
        let capabilities = root.capabilities
        Task { @MainActor in
            let preparation = await Task.detached {
                (ClaudeSetupDetection.boundedRegularData(at: bundleHelper), CodexSetupDetection.validateHelper(bundleHelper))
            }.value
            guard let helper = preparation.0, preparation.1 else {
                message = "The bundled Steer helper is unavailable or failed its self-test. Reinstall Steer and try again."
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
