import Foundation

public struct CodexCapabilities: Equatable, Sendable {
    public let cli: Bool
    public let desktop: Bool
    public let ghostty: Bool
    public let supported: Bool
    public let unsupportedReason: String?
    public let cliVersion: String?
    public let desktopVersion: String?
    public let ghosttyVersion: String?

    public init(cli: Bool, desktop: Bool, ghostty: Bool, supported: Bool,
                unsupportedReason: String? = nil, cliVersion: String? = nil,
                desktopVersion: String? = nil, ghosttyVersion: String? = nil) {
        self.cli = cli
        self.desktop = desktop
        self.ghostty = ghostty
        self.supported = supported
        self.unsupportedReason = unsupportedReason
        self.cliVersion = cliVersion
        self.desktopVersion = desktopVersion
        self.ghosttyVersion = ghosttyVersion
    }
}

public enum CodexSetupRequirements {
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd"]
    public static let minimumCLIVersion = "0.145.0"
    public static let minimumDesktopVersion = "26.901.51231"
    public static let minimumGhosttyVersion = "1.3.1"
}

public enum CodexSetupValidator {
    public static func hasSessionTitle(in config: String) -> Bool {
        var section = ""
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast())
                continue
            }
            let key = trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            guard key == "tui.terminal_title" || (key == "terminal_title" && section == "tui") else { continue }
            let value = trimmed.split(separator: "=", maxSplits: 1).dropFirst().first?
                .split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            return value == "[\"session-id\"]"
        }
        return false
    }

    public static func hasRequiredHooks(_ data: Data, command: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any] else { return false }
        return CodexSetupRequirements.hookEvents.allSatisfy { event in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { $0["type"] as? String == "command" && $0["command"] as? String == command } == true
            }
        }
    }
}

public enum CodexSetupStatus: Equatable, Sendable {
    case ready
    case unavailable(String)
    case unsupported(String)
    case malformed(String)
    case conflict(String)
}

public enum CodexConnectionStatus: Equatable, Sendable {
    case unavailable(String)
    case unsupported(String)
    case installed
    case connected
    case permissionRequired(String)
    case configuredAwaitingRestart(String)
    case malformed(String)
    case conflict(String)
}

public struct CodexSetupRoots: Equatable, Sendable {
    public let configDirectory: URL
    public let helperDirectory: URL
    public let eventsDirectory: URL

    public init(configDirectory: URL, helperDirectory: URL, eventsDirectory: URL) {
        self.configDirectory = configDirectory
        self.helperDirectory = helperDirectory
        self.eventsDirectory = eventsDirectory
    }

    public var configURL: URL { configDirectory.appendingPathComponent("config.toml") }
    public var hooksURL: URL { configDirectory.appendingPathComponent("hooks.json") }
    public var helperURL: URL { helperDirectory.appendingPathComponent("SteerHook") }
    public var stateURL: URL { helperDirectory.appendingPathComponent("install.json") }
}

public struct CodexSetupPlan: Sendable {
    public let status: CodexSetupStatus
    public let configChange: String
    public let hooksChange: Data
    public let helperCommand: String
    public let requiresConfigure: Bool
    let originalConfig: String
    let originalHooks: Data
    let configAdded: Bool
    let configTableAdded: Bool

    public init(status: CodexSetupStatus, configChange: String, hooksChange: Data,
                helperCommand: String, requiresConfigure: Bool,
                originalConfig: String, originalHooks: Data, configAdded: Bool, configTableAdded: Bool = false) {
        self.status = status
        self.configChange = configChange
        self.hooksChange = hooksChange
        self.helperCommand = helperCommand
        self.requiresConfigure = requiresConfigure
        self.originalConfig = originalConfig
        self.originalHooks = originalHooks
        self.configAdded = configAdded
        self.configTableAdded = configTableAdded
    }
}

public enum CodexSetupPlanner {
    public static func plan(capabilities: CodexCapabilities, config: String, hooks: Data,
                            helperPath: URL, eventsPath: URL) -> CodexSetupPlan {
        guard capabilities.supported, capabilities.cli || capabilities.desktop else {
            return empty(.unsupported(capabilities.unsupportedReason ?? "No supported Codex runtime was detected."), config: config, hooks: hooks)
        }
        guard validTOMLShape(config) else {
            return empty(.malformed("Codex config.toml is not valid enough to edit safely."), config: config, hooks: hooks)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: hooks) as? [String: Any] else {
            return empty(.malformed("Codex hooks.json is not valid JSON and was not changed."), config: config, hooks: hooks)
        }
        let command = "\(shellQuote(helperPath.path)) --events-dir \(shellQuote(eventsPath.path))"
        guard let merged = mergeHooks(parsed, command: command) else {
            return empty(.malformed("Codex hooks.json has an unsupported hooks shape and was not changed."), config: config, hooks: hooks)
        }
        guard let configResult = configWithSessionTitle(config) else {
            return empty(.conflict("Codex already has a different tui.terminal_title setting."), config: config, hooks: hooks)
        }
        let output = (try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])) ?? hooks
        let needsConfig = configResult.value != config
        let needsHooks = output != hooks
        return CodexSetupPlan(status: .ready, configChange: configResult.value, hooksChange: output,
                              helperCommand: command, requiresConfigure: needsConfig || needsHooks,
                              originalConfig: config, originalHooks: hooks, configAdded: configResult.added,
                              configTableAdded: configResult.tableAdded)
    }

    private static func empty(_ status: CodexSetupStatus, config: String, hooks: Data) -> CodexSetupPlan {
        CodexSetupPlan(status: status, configChange: config, hooksChange: hooks, helperCommand: "",
                       requiresConfigure: false, originalConfig: config, originalHooks: hooks, configAdded: false,
                       configTableAdded: false)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validTOMLShape(_ value: String) -> Bool {
        var quote = false
        var escaped = false
        var brackets = 0
        for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("[") {
                guard trimmed.hasSuffix("]") else { return false }
            } else if !trimmed.contains("=") && brackets == 0 {
                return false
            }
            for character in trimmed {
                if character == "\\" && quote { escaped.toggle(); continue }
                if character == "\"" && !escaped { quote.toggle() }
                escaped = false
                if !quote && character == "[" { brackets += 1 }
                if !quote && character == "]" {
                    brackets -= 1
                    if brackets < 0 { return false }
                }
            }
        }
        // ponytail: delimiter-only TOML validation; use a full parser if setup edits broaden.
        return !quote && brackets == 0
    }

    private static func configWithSessionTitle(_ config: String) -> (value: String, added: Bool, tableAdded: Bool)? {
        let lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var section = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { section = String(trimmed.dropFirst().dropLast()); continue }
            let key = trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            let qualified = key == "tui.terminal_title"
            let local = key == "terminal_title" && section == "tui"
            guard qualified || local else { continue }
            let value = trimmed.split(separator: "=", maxSplits: 1).dropFirst().first?
                .split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if value == "[\"session-id\"]" { return (config, false, false) }
            return nil
        }
        guard let tui = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[tui]" }) else {
            var next = config
            if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }
            next += (next.isEmpty ? "[tui]\n" : "\n[tui]\n") + "terminal_title = [\"session-id\"]\n"
            return (next, true, true)
        }
        var nextTable = lines[(tui + 1)...].firstIndex { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("[") && value.hasSuffix("]")
        } ?? lines.count
        while nextTable > tui + 1 && lines[nextTable - 1].trimmingCharacters(in: .whitespaces).isEmpty { nextTable -= 1 }
        var updated = lines
        updated.insert("terminal_title = [\"session-id\"]", at: nextTable)
        let value = updated.joined(separator: "\n")
        return (value.hasSuffix("\n") ? value : value + "\n", true, false)
    }

    private static func mergeHooks(_ source: [String: Any], command: String) -> [String: Any]? {
        var result = source
        var hooks = (source["hooks"] as? [String: Any]) ?? [:]
        if source["hooks"] != nil && source["hooks"] as? [String: Any] == nil { return nil }
        for event in CodexSetupRequirements.hookEvents {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            if hooks[event] != nil && hooks[event] as? [[String: Any]] == nil { return nil }
            let owned = entries.contains { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { $0["type"] as? String == "command" && $0["command"] as? String == command } == true
            }
            if !owned { entries.append(["hooks": [["type": "command", "command": command]]]) }
            hooks[event] = entries
        }
        result["hooks"] = hooks
        return result
    }
}

public enum CodexSetupError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case conflict(String)
    case failed(String)
    case rollbackIncomplete(String)

    public var description: String {
        switch self {
        case .conflict(let value), .failed(let value), .rollbackIncomplete(let value): return value
        }
    }

    public var errorDescription: String? { description }
}

public struct CodexSetupInstaller {
    private let fileManager: FileManager
    private let beforeWrite: ((URL) throws -> Void)?

    public init(fileManager: FileManager = .default, beforeWrite: ((URL) throws -> Void)? = nil) {
        self.fileManager = fileManager
        self.beforeWrite = beforeWrite
    }

    public func install(_ plan: CodexSetupPlan, roots: CodexSetupRoots, helper: Data,
                        capabilities: CodexCapabilities) throws -> CodexConnectionStatus {
        guard case .ready = plan.status else { throw CodexSetupError.failed("Setup preview is not ready.") }
        guard !helper.isEmpty else { throw CodexSetupError.failed("The bundled Steer helper is unavailable.") }
        try ensureDirectory(roots.configDirectory)
        try ensureDirectory(roots.helperDirectory)
        try ensureDirectory(roots.eventsDirectory)
        let configData = try readableData(at: roots.configURL)
        let currentConfig: String
        if let configData {
            guard let decoded = String(data: configData, encoding: .utf8) else {
                throw CodexSetupError.conflict("Codex config.toml is unreadable or not UTF-8; it was not changed.")
            }
            currentConfig = decoded
        } else { currentConfig = "" }
        let currentHooks = try readableData(at: roots.hooksURL) ?? Data("{}".utf8)
        if currentConfig == plan.configChange, currentHooks == plan.hooksChange,
           (try? Data(contentsOf: roots.helperURL)) == helper,
           let state = try? readState(roots), state.command == plan.helperCommand {
            return status(roots: roots, capabilities: capabilities)
        }
        guard currentConfig == plan.originalConfig, currentHooks == plan.originalHooks else {
            throw CodexSetupError.conflict("Codex configuration changed after the preview. Review setup again.")
        }
        if let existing = try? Data(contentsOf: roots.helperURL), existing != helper {
            guard let state = try? readState(roots), state.helper == existing.base64EncodedString() else {
                throw CodexSetupError.conflict("A different file already exists at Steer's helper path.")
            }
        }
        if fileManager.fileExists(atPath: roots.helperURL.path) {
            var directory = ObjCBool(false)
            guard fileManager.fileExists(atPath: roots.helperURL.path, isDirectory: &directory), !directory.boolValue,
                  (try? Data(contentsOf: roots.helperURL)) != nil else {
                throw CodexSetupError.conflict("Steer's helper path is a directory or unreadable; it was not changed.")
            }
        }
        let backupDirectory = roots.helperDirectory.appendingPathComponent("backups").appendingPathComponent(UUID().uuidString)
        let originalConfig = try readableData(at: roots.configURL)
        let originalHooks = try readableData(at: roots.hooksURL)
        let originalHelper = try? Data(contentsOf: roots.helperURL)
        do {
            if plan.configChange != plan.originalConfig { try backup(originalConfig, named: "config.toml", in: backupDirectory) }
            if plan.hooksChange != plan.originalHooks { try backup(originalHooks, named: "hooks.json", in: backupDirectory) }
            if originalHelper != helper { try backup(originalHelper, named: "SteerHook", in: backupDirectory) }
            if originalHelper != helper {
                try atomicWrite(helper, to: roots.helperURL)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roots.helperURL.path)
            }
            if plan.configChange != plan.originalConfig { try atomicWrite(Data(plan.configChange.utf8), to: roots.configURL) }
            if plan.hooksChange != plan.originalHooks { try atomicWrite(plan.hooksChange, to: roots.hooksURL) }
            let state = InstallState(helper: helper.base64EncodedString(), command: plan.helperCommand,
                                     installedConfig: plan.configChange, installedHooks: plan.hooksChange,
                                     originalConfig: plan.originalConfig, originalHooks: plan.originalHooks,
                                     originalConfigExisted: originalConfig != nil, originalHooksExisted: originalHooks != nil,
                                     configAdded: plan.configAdded, configTableAdded: plan.configTableAdded)
            try atomicWrite(try JSONEncoder().encode(state), to: roots.stateURL)
        } catch let error {
            do {
                try restore(originalConfig, to: roots.configURL)
                try restore(originalHooks, to: roots.hooksURL)
                try restore(originalHelper, to: roots.helperURL)
            } catch let rollbackError {
                throw CodexSetupError.rollbackIncomplete("Setup failed (\(error)); rollback also failed (\(rollbackError)). Check the affected files before retrying.")
            }
            throw CodexSetupError.failed("Setup was not completed; the original configuration was restored.")
        }
        return status(roots: roots, capabilities: capabilities)
    }

    public func status(roots: CodexSetupRoots, capabilities: CodexCapabilities) -> CodexConnectionStatus {
        guard capabilities.supported, capabilities.cli || capabilities.desktop else {
            return .unsupported(capabilities.unsupportedReason ?? "No supported Codex runtime was detected.")
        }
        guard fileManager.fileExists(atPath: roots.stateURL.path) else { return .installed }
        guard let state = try? readState(roots) else { return .conflict("Steer setup state is unreadable; review setup before changing Codex files.") }
        guard let configData = try? Data(contentsOf: roots.configURL), let config = String(data: configData, encoding: .utf8),
              let hooks = try? Data(contentsOf: roots.hooksURL) else { return .malformed("Steer setup files are missing or unreadable.") }
        guard fileManager.fileExists(atPath: roots.helperURL.path) else { return .installed }
        var helperDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: roots.helperURL.path, isDirectory: &helperDirectory), !helperDirectory.boolValue,
              let helper = try? Data(contentsOf: roots.helperURL) else {
            return .conflict("Steer's helper path is a directory or unreadable.")
        }
        guard (try? JSONSerialization.jsonObject(with: hooks) as? [String: Any]) != nil else {
            return .malformed("Codex hooks.json is not valid JSON.")
        }
        guard CodexSetupValidator.hasSessionTitle(in: config),
              CodexSetupValidator.hasRequiredHooks(hooks, command: state.command),
              helper == Data(base64Encoded: state.helper),
              let permissions = (try? fileManager.attributesOfItem(atPath: roots.helperURL.path)[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o111 != 0 else {
            return .conflict("Steer setup is present but differs from its installed values.")
        }
        guard fileManager.fileExists(atPath: roots.eventsDirectory.path) else {
            return .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery.")
        }
        guard let files = try? fileManager.contentsOfDirectory(at: roots.eventsDirectory, includingPropertiesForKeys: nil) else {
            return .permissionRequired("Steer's events directory is not readable. Grant access or choose Configure Codex again.")
        }
        guard files.contains(where: validMetadataEvent) else {
            return .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery.")
        }
        return .connected
    }

    public func undo(roots: CodexSetupRoots) throws -> CodexConnectionStatus {
        let state = try readState(roots)
        let currentConfig = try String(contentsOf: roots.configURL)
        let currentHooks = try Data(contentsOf: roots.hooksURL)
        let currentHelper = try Data(contentsOf: roots.helperURL)
        guard currentConfig == state.installedConfig, currentHooks == state.installedHooks,
              currentHelper == Data(base64Encoded: state.helper) else {
            throw CodexSetupError.conflict("Codex or Steer's setup files changed after setup; undo made no changes.")
        }
        let originalConfig = state.originalConfigExisted ? Data(state.originalConfig.utf8) : nil
        let originalHooks = state.originalHooksExisted ? state.originalHooks : nil
        let originalHelper = Data(base64Encoded: state.helper)
        let originalState = try Data(contentsOf: roots.stateURL)
        do {
            try restore(originalConfig, to: roots.configURL)
            try restore(originalHooks, to: roots.hooksURL)
            try fileManager.removeItem(at: roots.helperURL)
            try fileManager.removeItem(at: roots.stateURL)
        } catch let error {
            do {
                try restore(Data(currentConfig.utf8), to: roots.configURL)
                try restore(currentHooks, to: roots.hooksURL)
                try restore(originalHelper, to: roots.helperURL)
                try atomicWrite(originalState, to: roots.stateURL)
            } catch let rollbackError {
                throw CodexSetupError.rollbackIncomplete("Undo failed (\(error)); rollback also failed (\(rollbackError)). Check the affected files before retrying.")
            }
            throw CodexSetupError.failed("Undo was not completed; the installed configuration was restored.")
        }
        return .installed
    }

    private func readState(_ roots: CodexSetupRoots) throws -> InstallState {
        guard let data = try? Data(contentsOf: roots.stateURL) else { throw CodexSetupError.failed("Steer setup is not installed.") }
        return try JSONDecoder().decode(InstallState.self, from: data)
    }

    private func readableData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            throw CodexSetupError.conflict("Codex configuration could not be read; it was not changed.")
        }
        return data
    }

    private func validMetadataEvent(_ url: URL) -> Bool {
        guard url.pathExtension == "json", let data = try? Data(contentsOf: url), data.count <= 65536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["hook_event_name"] as? String, !event.isEmpty,
              let session = object["session_id"] as? String, UUID(uuidString: session) != nil,
              let received = object["received_at"] as? String, !received.isEmpty else { return false }
        return true
    }

    private func ensureDirectory(_ url: URL) throws { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }

    private func backup(_ data: Data?, named: String, in directory: URL) throws {
        guard let data else { return }
        try ensureDirectory(directory)
        try data.write(to: directory.appendingPathComponent(named), options: .atomic)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try beforeWrite?(url)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".steer-" + UUID().uuidString)
        do {
            try data.write(to: temp, options: .atomic)
            if fileManager.fileExists(atPath: url.path) { _ = try fileManager.replaceItemAt(url, withItemAt: temp) }
            else { try fileManager.moveItem(at: temp, to: url) }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    private func restore(_ data: Data?, to url: URL) throws {
        if let data { try atomicWrite(data, to: url) }
        else if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }
}

private struct InstallState: Codable {
    let helper: String
    let command: String
    let installedConfig: String
    let installedHooks: Data
    let originalConfig: String
    let originalHooks: Data
    let originalConfigExisted: Bool
    let originalHooksExisted: Bool
    let configAdded: Bool
    let configTableAdded: Bool
}
