import Foundation

public struct CodexCapabilities: Equatable, Sendable {
    public let cli: Bool
    public let desktop: Bool
    public let ghostty: Bool
    public let supported: Bool
    public let cliInstalled: Bool
    public let desktopInstalled: Bool
    public let ghosttyInstalled: Bool
    public let unsupportedReason: String?
    public let cliVersion: String?
    public let desktopVersion: String?
    public let ghosttyVersion: String?

    public init(cli: Bool, desktop: Bool, ghostty: Bool, supported: Bool,
                unsupportedReason: String? = nil, cliVersion: String? = nil,
                desktopVersion: String? = nil, ghosttyVersion: String? = nil,
                cliInstalled: Bool = false, desktopInstalled: Bool = false,
                ghosttyInstalled: Bool = false) {
        self.cli = cli
        self.desktop = desktop
        self.ghostty = ghostty
        self.supported = supported
        self.cliInstalled = cliInstalled
        self.desktopInstalled = desktopInstalled
        self.ghosttyInstalled = ghosttyInstalled
        self.unsupportedReason = unsupportedReason
        self.cliVersion = cliVersion
        self.desktopVersion = desktopVersion
        self.ghosttyVersion = ghosttyVersion
    }
}

public enum CodexSetupRequirements {
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd"]
    public static let helperSource = "steer-hook-v1"
    public static let hookTimeout = Int(ApprovalTiming.helperWaitBound + ApprovalTiming.connectionTimeout + 2)
    /// Timeouts written by earlier Steer builds; setup upgrades them in place instead of adding a handler.
    public static let legacyHookTimeouts = [2, 35]
    public static let minimumCLIVersion = "0.145.0"
    public static let minimumDesktopVersion = "26.901.51231"
    public static let minimumGhosttyVersion = "1.3.1"
    public static let metadataClockSkew: TimeInterval = 300
}

public enum CodexSetupValidator {
    public static func hasSessionTitle(in config: String) -> Bool {
        var section = ""
        for line in config.split(separator: "\n") {
            let trimmed = stripComment(String(line)).trimmingCharacters(in: .whitespaces)
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

    private static func stripComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if character == "\\" && quote == "\"" { escaped.toggle(); continue }
            if (character == "\"" || character == "'") && !escaped {
                quote = quote == character ? nil : (quote == nil ? character : quote)
            }
            if character == "#" && quote == nil { return String(value[..<index]) }
            escaped = false
        }
        return value
    }

    public static func hasRequiredHooks(_ data: Data, command: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any] else { return false }
        return CodexSetupRequirements.hookEvents.allSatisfy { event in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { entry in
                (entry["hooks"] as? [[String: Any]])?.contains {
                    $0["type"] as? String == "command" &&
                    $0["command"] as? String == command &&
                    ($0["timeout"] as? NSNumber)?.intValue == CodexSetupRequirements.hookTimeout
                } == true
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
    case notConfigured
    case repairRequired(String)
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
    public let installationID: String
    let originalConfig: String
    let originalHooks: Data
    let configAdded: Bool
    let configTableAdded: Bool

    public init(status: CodexSetupStatus, configChange: String, hooksChange: Data,
                helperCommand: String, requiresConfigure: Bool,
                originalConfig: String, originalHooks: Data, configAdded: Bool, configTableAdded: Bool = false,
                installationID: String = "") {
        self.status = status
        self.configChange = configChange
        self.hooksChange = hooksChange
        self.helperCommand = helperCommand
        self.requiresConfigure = requiresConfigure
        self.installationID = installationID
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
        guard isSafeTOML(config) else {
            return empty(.malformed("Codex config.toml is not valid enough to edit safely."), config: config, hooks: hooks)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: hooks) as? [String: Any] else {
            return empty(.malformed("Codex hooks.json is not valid JSON and was not changed."), config: config, hooks: hooks)
        }
        let prefix = "\(shellQuote(helperPath.path)) --events-dir \(shellQuote(eventsPath.path)) --installation-id "
        let discoveredInstallations = installationIDs(in: parsed, prefix: prefix)
        guard discoveredInstallations.count <= 1 else {
            return empty(.conflict("Multiple Steer hook installations were found; review hooks.json before reconnecting."), config: config, hooks: hooks)
        }
        let installationID = discoveredInstallations.first ?? UUID().uuidString
        let command = prefix + shellQuote(installationID)
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
                              configTableAdded: configResult.tableAdded, installationID: installationID)
    }

    private static func empty(_ status: CodexSetupStatus, config: String, hooks: Data) -> CodexSetupPlan {
        CodexSetupPlan(status: status, configChange: config, hooksChange: hooks, helperCommand: "",
                       requiresConfigure: false, originalConfig: config, originalHooks: hooks, configAdded: false,
                       configTableAdded: false, installationID: "")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(helperPath: URL, eventsPath: URL, installationID: String) -> String {
        "\(shellQuote(helperPath.path)) --events-dir \(shellQuote(eventsPath.path)) --installation-id \(shellQuote(installationID))"
    }

    static func isSafeTOML(_ value: String) -> Bool {
        // This is deliberately a small, conservative validator for the fields we
        // edit. Unknown TOML constructs are refused instead of being rewritten.
        var section = ""
        var seenSections = Set<String>()
        var seenKeysBySection = [String: Set<String>]()
        var pending = ""
        for rawLine in value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = pending.isEmpty ? rawLine : pending + rawLine.trimmingCharacters(in: .whitespaces)
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if !pending.isEmpty || trimmed.contains("=") {
                guard let equals = findUnquoted(trimmed, character: "=") else { return false }
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, validKey(key) else { return false }
                let valueStart = trimmed.index(after: equals)
                let rawValue = stripComment(String(trimmed[valueStart...])).trimmingCharacters(in: .whitespaces)
                guard !rawValue.isEmpty else { return false }
                if !valueIsComplete(rawValue) {
                    pending = line
                    continue
                }
                guard validValue(rawValue) else { return false }
                var keys = seenKeysBySection[section, default: []]
                guard keys.insert(key).inserted else { return false }
                seenKeysBySection[section] = keys
                pending = ""
                continue
            }
            guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]"),
                  !trimmed.hasPrefix("[[") && !trimmed.hasSuffix("]]"),
                  trimmed.count > 2 else { return false }
            let header = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            guard !header.isEmpty, validHeader(header), seenSections.insert(header).inserted else { return false }
            section = header
        }
        return pending.isEmpty
    }

    private static func findUnquoted(_ value: String, character: Character) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let characterAtIndex = value[index]
            if characterAtIndex == "\\" && quote == "\"" { escaped.toggle(); continue }
            if (characterAtIndex == "\"" || characterAtIndex == "'") && !escaped {
                quote = quote == characterAtIndex ? nil : (quote == nil ? characterAtIndex : quote)
            }
            if characterAtIndex == character && quote == nil { return index }
            escaped = false
        }
        return nil
    }

    private static func stripComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if character == "\\" && quote == "\"" { escaped.toggle(); continue }
            if (character == "\"" || character == "'") && !escaped {
                quote = quote == character ? nil : (quote == nil ? character : quote)
            }
            if character == "#" && quote == nil { return String(value[..<index]) }
            escaped = false
        }
        return value
    }

    private static func validKey(_ key: String) -> Bool {
        var segments: [String] = []
        var segment = ""
        var activeQuote: Character?
        var escaped = false
        for character in key {
            if activeQuote != nil {
                segment.append(character)
                if character == "\\" && activeQuote == "\"" { escaped.toggle(); continue }
                if character == activeQuote && !escaped { activeQuote = nil }
                escaped = false
            } else if character == "\"" || character == "'" {
                guard segment.isEmpty else { return false }
                activeQuote = character
                segment.append(character)
            } else if character == "." {
                guard validKeySegment(segment) else { return false }
                segments.append(segment)
                segment = ""
            } else {
                segment.append(character)
            }
        }
        guard activeQuote == nil, validKeySegment(segment) else { return false }
        segments.append(segment)
        return !segments.isEmpty
    }

    private static func validKeySegment(_ segment: String) -> Bool {
        guard let first = segment.first else { return false }
        if first == "\"" || first == "'" {
            return validQuotedString(segment)
        }
        return segment.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLetter || $0 == "_" || $0 == "-") }
    }

    private static func validQuotedString(_ value: String) -> Bool {
        guard let quote = value.first, (quote == "\"" || quote == "'"), value.last == quote, value.count >= 2 else { return false }
        let contents = Array(value.dropFirst().dropLast())
        var index = contents.startIndex
        while index < contents.endIndex {
            let character = contents[index]
            if character == quote || character.asciiValue.map({ ($0 < 0x20 && $0 != 0x09) || $0 == 0x7f }) == true { return false }
            if quote == "\"" && character == "\\" {
                index = contents.index(after: index)
                guard index < contents.endIndex else { return false }
                let escaped = contents[index]
                if escaped == "u" {
                    for _ in 0..<4 {
                        index = contents.index(after: index)
                        guard index < contents.endIndex,
                              String(contents[index]).rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdefABCDEF")) != nil else { return false }
                    }
                } else {
                    guard "bfnrt\\\"".contains(escaped) else { return false }
                }
            }
            index = contents.index(after: index)
        }
        return true
    }

    private static func validHeader(_ header: String) -> Bool {
        validKey(header)
    }

    private static func valueIsComplete(_ value: String) -> Bool {
        var quote: Character?
        var escaped = false
        var depth = 0
        for character in value {
            if character == "\\" && quote == "\"" { escaped.toggle(); continue }
            if (character == "\"" || character == "'") && !escaped {
                quote = quote == character ? nil : (quote == nil ? character : quote)
            }
            if quote == nil {
                if character == "[" { depth += 1 }
                if character == "]" { depth -= 1 }
                if depth < 0 { return false }
            }
            escaped = false
        }
        return quote == nil && depth == 0
    }

    private static func validValue(_ value: String) -> Bool {
        guard valueIsComplete(value) else { return false }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return validQuotedString(value)
        }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            let body = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if body.isEmpty { return true }
            return splitArray(body).allSatisfy(validValue)
        }
        if value == "true" || value == "false" { return true }
        return value.range(of: #"^[+-]?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$"#, options: .regularExpression) != nil
    }

    private static func splitArray(_ body: String) -> [String] {
        var result: [String] = [], start = body.startIndex, depth = 0, quote: Character?, escaped = false
        for index in body.indices {
            let character = body[index]
            if character == "\\" && quote == "\"" { escaped.toggle(); continue }
            if (character == "\"" || character == "'") && !escaped { quote = quote == character ? nil : (quote == nil ? character : quote) }
            if quote == nil {
                if character == "[" { depth += 1 }
                if character == "]" { depth -= 1 }
                if character == "," && depth == 0 {
                    result.append(String(body[start..<index]).trimmingCharacters(in: .whitespaces)); start = body.index(after: index)
                }
            }
            escaped = false
        }
        result.append(String(body[start...]).trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func configWithSessionTitle(_ config: String) -> (value: String, added: Bool, tableAdded: Bool)? {
        let lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var section = ""
        for line in lines {
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespaces)
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
        guard let tui = lines.firstIndex(where: { stripComment($0).trimmingCharacters(in: .whitespaces) == "[tui]" }) else {
            var next = config
            if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }
            next += (next.isEmpty ? "[tui]\n" : "\n[tui]\n") + "terminal_title = [\"session-id\"]\n"
            return (next, true, true)
        }
        var nextTable = lines[(tui + 1)...].firstIndex { line in
            let value = stripComment(line).trimmingCharacters(in: .whitespaces)
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
            var found = false
            var normalized: [[String: Any]] = []
            for var entry in entries {
                guard let nested = entry["hooks"] as? [[String: Any]] else { return nil }
                var kept: [[String: Any]] = []
                for var hook in nested {
                    if hook["type"] as? String == "command", hook["command"] as? String == command {
                        guard !found else { continue }
                        hook["timeout"] = CodexSetupRequirements.hookTimeout
                        found = true
                    }
                    kept.append(hook)
                }
                if !kept.isEmpty { entry["hooks"] = kept; normalized.append(entry) }
            }
            entries = normalized
            if !found { entries.append(["hooks": [["type": "command", "command": command, "timeout": CodexSetupRequirements.hookTimeout]]]) }
            hooks[event] = entries
        }
        result["hooks"] = hooks
        return result
    }

    private static func installationIDs(in source: [String: Any], prefix: String) -> Set<String> {
        guard let hooks = source["hooks"] as? [String: Any] else { return [] }
        var candidates: [(command: String, id: String)] = []
        for event in CodexSetupRequirements.hookEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            candidates += entries.flatMap { entry -> [(String, String)] in
                guard let nested = entry["hooks"] as? [[String: Any]] else { return [] }
                return nested.compactMap { hook -> (String, String)? in
                    guard hook["type"] as? String == "command",
                          ([CodexSetupRequirements.hookTimeout] + CodexSetupRequirements.legacyHookTimeouts)
                              .contains((hook["timeout"] as? NSNumber)?.intValue ?? 0),
                          let command = hook["command"] as? String,
                          command.hasPrefix(prefix),
                          let id = installationID(in: command, prefix: prefix), UUID(uuidString: id) != nil else { return nil }
                    return (command, id)
                }
            }
        }
        return Set(candidates.map(\.id))
    }

    private static func installationID(in command: String, prefix: String) -> String? {
        let suffix = command.dropFirst(prefix.count)
        guard suffix.first == "'", suffix.last == "'" else { return nil }
        return String(suffix.dropFirst().dropLast())
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
    private let beforeCleanup: ((URL) throws -> Void)?

    public init(fileManager: FileManager = .default, beforeWrite: ((URL) throws -> Void)? = nil,
                beforeCleanup: ((URL) throws -> Void)? = nil) {
        self.fileManager = fileManager
        self.beforeWrite = beforeWrite
        self.beforeCleanup = beforeCleanup
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
           (try? readableData(at: roots.helperURL)) == helper,
           let state = try? readState(roots), state.command == plan.helperCommand,
           state.installedConfig == currentConfig, state.installedHooks == currentHooks {
            return status(roots: roots, capabilities: capabilities)
        }
        let existingState = try? readState(roots)
        let repairing = existingState.flatMap { state in
            currentConfig == state.installedConfig && currentHooks == state.installedHooks &&
            state.command == plan.helperCommand && state.installationID == plan.installationID &&
            !fileManager.fileExists(atPath: roots.helperURL.path) ? state : nil
        }
        if existingState != nil && repairing == nil {
            throw CodexSetupError.conflict("Existing Steer setup changed after setup; review setup before reconfiguring.")
        }
        guard repairing != nil || (currentConfig == plan.originalConfig && currentHooks == plan.originalHooks) else {
            throw CodexSetupError.conflict("Codex configuration changed after the preview. Review setup again.")
        }
        if let existing = try? readableData(at: roots.helperURL) {
            guard let state = try? readState(roots), state.helper == existing.base64EncodedString() else {
                throw CodexSetupError.conflict("A different file already exists at Steer's helper path.")
            }
        }
        if fileManager.fileExists(atPath: roots.helperURL.path) {
            var directory = ObjCBool(false)
            guard fileManager.fileExists(atPath: roots.helperURL.path, isDirectory: &directory), !directory.boolValue,
                  (try? readableData(at: roots.helperURL)) != nil else {
                throw CodexSetupError.conflict("Steer's helper path is a directory or unreadable; it was not changed.")
            }
        }
        let backupDirectory = roots.helperDirectory.appendingPathComponent("backups").appendingPathComponent(UUID().uuidString)
        let originalConfig = try readableData(at: roots.configURL)
        let originalHooks = try readableData(at: roots.hooksURL)
        let originalHelper = try? readableData(at: roots.helperURL)
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
                                     installationID: plan.installationID,
                                     backupDirectory: repairing?.backupDirectory ??
                                        (fileManager.fileExists(atPath: backupDirectory.path) ? backupDirectory.lastPathComponent : nil),
                                     installedConfig: plan.configChange, installedHooks: plan.hooksChange,
                                     originalConfig: repairing?.originalConfig ?? plan.originalConfig,
                                     originalHooks: repairing?.originalHooks ?? plan.originalHooks,
                                     originalConfigExisted: repairing?.originalConfigExisted ?? (originalConfig != nil),
                                     originalHooksExisted: repairing?.originalHooksExisted ?? (originalHooks != nil),
                                     originalHelperExisted: repairing?.originalHelperExisted ?? (originalHelper != nil),
                                     configAdded: repairing?.configAdded ?? plan.configAdded,
                                     configTableAdded: repairing?.configTableAdded ?? plan.configTableAdded,
                                     installedAt: Date().timeIntervalSince1970)
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
        guard fileManager.fileExists(atPath: roots.stateURL.path) else { return .notConfigured }
        guard let state = try? readState(roots) else { return .conflict("Steer setup state is unreadable; review setup before changing Codex files.") }
        guard UUID(uuidString: state.installationID) != nil,
              state.command == CodexSetupPlanner.command(helperPath: roots.helperURL, eventsPath: roots.eventsDirectory,
                                                         installationID: state.installationID) else {
            return .conflict("Steer setup state has an invalid installation identity; review setup before changing Codex files.")
        }
        guard let configData = try? readableData(at: roots.configURL),
              let config = String(data: configData, encoding: .utf8),
              let hooks = try? readableData(at: roots.hooksURL) else { return .malformed("Steer setup files are missing or unreadable.") }
        guard CodexSetupPlanner.isSafeTOML(config) else {
            return .malformed("Codex config.toml is not valid enough to verify safely.")
        }
        guard fileManager.fileExists(atPath: roots.helperURL.path) else {
            if config == state.installedConfig, hooks == state.installedHooks {
                return .repairRequired("Steer's helper is missing; Configure Codex to repair setup.")
            }
            return .conflict("Steer's helper is missing and Codex setup also changed; review setup before repair.")
        }
        var helperDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: roots.helperURL.path, isDirectory: &helperDirectory), !helperDirectory.boolValue,
              let helper = try? readableData(at: roots.helperURL) else {
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
        guard files.contains(where: { validMetadataEvent($0, installedAt: state.installedAt, installationID: state.installationID) }) else {
            return .configuredAwaitingRestart("Configured; restart a Codex session and complete Codex's hook-trust review to verify delivery.")
        }
        return .connected
    }

    public func undo(roots: CodexSetupRoots) throws -> CodexConnectionStatus {
        let state = try readState(roots)
        guard let currentConfigData = try readableData(at: roots.configURL),
              let currentConfig = String(data: currentConfigData, encoding: .utf8),
              let currentHooks = try readableData(at: roots.hooksURL),
              let currentHelper = try readableData(at: roots.helperURL) else {
            throw CodexSetupError.conflict("Codex or Steer's setup files are missing or unreadable; undo made no changes.")
        }
        guard currentConfig == state.installedConfig, currentHooks == state.installedHooks,
              currentHelper == Data(base64Encoded: state.helper) else {
            throw CodexSetupError.conflict("Codex or Steer's setup files changed after setup; undo made no changes.")
        }
        let originalConfig = state.originalConfigExisted ? Data(state.originalConfig.utf8) : nil
        let originalHooks = state.originalHooksExisted ? state.originalHooks : nil
        let originalHelper = Data(base64Encoded: state.helper)
        guard let originalState = try readableData(at: roots.stateURL) else {
            throw CodexSetupError.conflict("Steer setup state is missing or unreadable; undo made no changes.")
        }
        let ownedEvents = try ownedEventArtifacts(in: roots.eventsDirectory, installationID: state.installationID)
        let ownedBackups = try ownedBackupArtifacts(in: roots.helperDirectory.appendingPathComponent("backups", isDirectory: true), state: state)
        do {
            try restore(originalConfig, to: roots.configURL)
            try restore(originalHooks, to: roots.hooksURL)
            try fileManager.removeItem(at: roots.helperURL)
            try fileManager.removeItem(at: roots.stateURL)
            try removeOwnedEvents(in: roots.eventsDirectory, installationID: state.installationID)
            try removeOwnedBackups(in: roots.helperDirectory.appendingPathComponent("backups", isDirectory: true), state: state)
            try removeDirectoryIfEmpty(roots.helperDirectory)
        } catch let error {
            do {
                try restoreArtifacts(ownedEvents)
                try restoreArtifacts(ownedBackups?.files ?? [])
                try restore(Data(currentConfig.utf8), to: roots.configURL)
                try restore(currentHooks, to: roots.hooksURL)
                try restore(originalHelper, to: roots.helperURL)
                try atomicWrite(originalState, to: roots.stateURL)
            } catch let rollbackError {
                throw CodexSetupError.rollbackIncomplete("Undo failed (\(error)); rollback also failed (\(rollbackError)). Check the affected files before retrying.")
            }
            throw CodexSetupError.failed("Undo was not completed; the installed configuration was restored.")
        }
        return .notConfigured
    }

    private func readState(_ roots: CodexSetupRoots) throws -> InstallState {
        guard let data = try readableData(at: roots.stateURL) else { throw CodexSetupError.failed("Steer setup is not installed.") }
        return try JSONDecoder().decode(InstallState.self, from: data)
    }

    private func readableData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard isRegularFile(at: url) else {
            throw CodexSetupError.conflict("\(url.lastPathComponent) is a directory; it was not changed.")
        }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else {
            throw CodexSetupError.conflict("Codex configuration could not be read; it was not changed.")
        }
        try? handle.close()
        return data
    }

    private func validMetadataEvent(_ url: URL, installedAt: TimeInterval, installationID: String) -> Bool {
        guard url.pathExtension == "json", let data = boundedData(at: url, maximum: 65536),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["hook_event_name"] as? String, !event.isEmpty,
              let session = object["session_id"] as? String, UUID(uuidString: session) != nil,
              let received = object["received_at"] as? String, !received.isEmpty,
              object["source"] as? String == CodexSetupRequirements.helperSource,
              object["installation_id"] as? String == installationID,
              let captured = object["captured_at"] as? NSNumber else { return false }
        let now = Date().timeIntervalSince1970
        return captured.doubleValue.isFinite && captured.doubleValue >= installedAt &&
            captured.doubleValue <= now + CodexSetupRequirements.metadataClockSkew
    }

    private func boundedData(at url: URL, maximum: Int) -> Data? {
        guard isRegularFile(at: url), let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: maximum + 1) else { return nil }
        try? handle.close()
        return data.count <= maximum ? data : nil
    }

    private func isRegularFile(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        return true
    }

    private func isDirectory(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        return true
    }

    private func ensureDirectory(_ url: URL) throws { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }

    private func removeDirectoryIfEmpty(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard isDirectory(at: url) else { throw CodexSetupError.conflict("Steer cleanup path is not a directory; no cleanup was completed.") }
        guard try fileManager.contentsOfDirectory(atPath: url.path).isEmpty else { return }
        try fileManager.removeItem(at: url)
    }

    private func removeOwnedEvents(in directory: URL, installationID: String) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard isDirectory(at: directory) else { throw CodexSetupError.conflict("Steer's events path is not a directory; no cleanup was completed.") }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var owned: [(URL, Data)] = []
        for url in files where url.pathExtension == "json" {
            guard let data = boundedData(at: url, maximum: 65536),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["hook_event_name"] as? String != nil,
                  let session = object["session_id"] as? String, UUID(uuidString: session) != nil,
                  object["source"] as? String == CodexSetupRequirements.helperSource,
                  object["installation_id"] as? String == installationID,
                  object["captured_at"] as? NSNumber != nil else { continue }
            owned.append((url, data))
        }
        var removed: [(URL, Data)] = []
        do {
            for (url, data) in owned {
                try fileManager.removeItem(at: url)
                removed.append((url, data))
            }
        } catch {
            do {
                for (url, data) in removed { try atomicWrite(data, to: url) }
            } catch let restoreError {
                throw CodexSetupError.rollbackIncomplete("Undo cleanup failed (\(error)); restoring removed event artifacts also failed (\(restoreError)).")
            }
            throw error
        }
        try removeDirectoryIfEmpty(directory)
    }

    private func removeOwnedBackups(in directory: URL, state: InstallState) throws {
        guard let name = state.backupDirectory else { return }
        guard name != ".", name != "..", !name.contains("/") else { throw CodexSetupError.conflict("Steer setup backup identity is invalid; no cleanup was completed.") }
        let backup = directory.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: backup.path) else { return }
        guard isDirectory(at: backup) else { throw CodexSetupError.conflict("Steer setup backup is not a directory; no cleanup was completed.") }
        let expected: [String: Data] = [
            "config.toml": state.originalConfigExisted ? Data(state.originalConfig.utf8) : nil,
            "hooks.json": state.originalHooksExisted ? state.originalHooks : nil,
            "SteerHook": state.originalHelperExisted ? Data(base64Encoded: state.helper) : nil
        ].compactMapValues { $0 }
        let files = try fileManager.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
        guard files.count == expected.count,
              files.allSatisfy({ expected[$0.lastPathComponent] == boundedData(at: $0, maximum: 1_048_576) }) else { return }
        try beforeCleanup?(backup)
        try fileManager.removeItem(at: backup)
        try removeDirectoryIfEmpty(directory)
    }

    private func ownedEventArtifacts(in directory: URL, installationID: String) throws -> [OwnedArtifact] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        guard isDirectory(at: directory) else { throw CodexSetupError.conflict("Steer's events path is not a directory; no cleanup was completed.") }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = boundedData(at: url, maximum: 65536),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["hook_event_name"] as? String != nil,
                  let session = object["session_id"] as? String, UUID(uuidString: session) != nil,
                  object["source"] as? String == CodexSetupRequirements.helperSource,
                  object["installation_id"] as? String == installationID,
                  object["captured_at"] as? NSNumber != nil else { return nil }
            return OwnedArtifact(url: url, data: data)
        }
    }

    private func ownedBackupArtifacts(in directory: URL, state: InstallState) throws -> BackupSnapshot? {
        guard let name = state.backupDirectory else { return nil }
        guard name != ".", name != "..", !name.contains("/") else { throw CodexSetupError.conflict("Steer setup backup identity is invalid; no cleanup was completed.") }
        let backup = directory.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: backup.path) else { return nil }
        guard isDirectory(at: backup) else { throw CodexSetupError.conflict("Steer setup backup is not a directory; no cleanup was completed.") }
        let expected: [String: Data] = [
            "config.toml": state.originalConfigExisted ? Data(state.originalConfig.utf8) : nil,
            "hooks.json": state.originalHooksExisted ? state.originalHooks : nil,
            "SteerHook": state.originalHelperExisted ? Data(base64Encoded: state.helper) : nil
        ].compactMapValues { $0 }
        let files = try fileManager.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
        let artifacts = files.compactMap { url -> OwnedArtifact? in
            guard let expectedData = expected[url.lastPathComponent], let data = boundedData(at: url, maximum: 1_048_576), data == expectedData else { return nil }
            return OwnedArtifact(url: url, data: data)
        }
        guard files.count == expected.count, artifacts.count == expected.count else { return nil }
        return BackupSnapshot(files: artifacts)
    }

    private func restoreArtifacts(_ artifacts: [OwnedArtifact]) throws {
        for artifact in artifacts { try atomicWrite(artifact.data, to: artifact.url) }
    }

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

private struct OwnedArtifact {
    let url: URL
    let data: Data
}

private struct BackupSnapshot {
    let files: [OwnedArtifact]
}

private struct InstallState: Codable {
    let helper: String
    let command: String
    let installationID: String
    let backupDirectory: String?
    let installedConfig: String
    let installedHooks: Data
    let originalConfig: String
    let originalHooks: Data
    let originalConfigExisted: Bool
    let originalHooksExisted: Bool
    let originalHelperExisted: Bool
    let configAdded: Bool
    let configTableAdded: Bool
    let installedAt: TimeInterval
}
