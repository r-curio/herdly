import Foundation
import CryptoKit

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

/// Largest file Herdly will read or verify during setup: Codex config, hooks, the bundled helper, and
/// its own install record (which embeds the helper). Anything larger is treated as unreadable.
public enum CodexSetupLimits {
    public static let maximumFileSize = 20 * 1024 * 1024
}

/// Outcome of keeping Herdly's own installed helper in step with the running app's bundled helper.
/// `skipped` carries why nothing changed; setup status reports any conflict separately.
public enum HelperRefreshResult: Equatable, Sendable {
    case current
    case updated
    case skipped(String)
}

public enum CodexSetupRequirements {
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "SessionEnd"]
    public static let helperSource = "herdly-hook-v1"
    public static let hookTimeout = Int(ApprovalTiming.helperWaitBound + ApprovalTiming.connectionTimeout + 2)
    /// Timeouts written by earlier Herdly builds; setup upgrades them in place instead of adding a handler.
    public static let legacyHookTimeouts = [2, 35]
    public static let minimumCLIVersion = "0.145.0"
    public static let minimumDesktopVersion = "26.901.51231"
    public static let minimumGhosttyVersion = "1.3.1"
    public static let metadataClockSkew: TimeInterval = 300
}

public enum CodexSetupValidator {
    public static func hasSessionTitle(in config: String) -> Bool {
        configValue(in: config, table: "tui", key: "terminal_title") == "[\"session-id\"]"
    }

    /// Codex runs hooks only when `features.hooks` is enabled; without it every Herdly hook is ignored.
    public static func hasHooksEnabled(in config: String) -> Bool {
        configValue(in: config, table: "features", key: "hooks") == "true"
    }

    /// The first value written for `table.key`, either as `key` inside `[table]` or as the dotted
    /// `table.key` at the top level; nil when the config does not set it.
    static func configValue(in config: String, table: String, key: String) -> String? {
        var section = ""
        for line in config.split(separator: "\n") {
            let trimmed = stripComment(String(line)).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast())
                continue
            }
            let name = trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            guard name == "\(table).\(key)" || (name == key && section == table) else { continue }
            return trimmed.split(separator: "=", maxSplits: 1).dropFirst().first?
                .split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
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

/// Codex runs a non-managed hook only after its exact definition is trusted. Trust is recorded in
/// config.toml as `[hooks.state."<hooks.json path>:<event>:<group>:<handler>"] trusted_hash = "sha256:…"`,
/// where the hash covers the normalized handler. This mirrors codex-rs (hooks/src/engine/discovery.rs
/// `hook_hash` and config/src/fingerprint.rs `version_for_toml`, identical in CLI 0.145.0 and 0.153.4):
/// SHA-256 of the canonical, key-sorted, compact JSON of the identity. Herdly records trust only for
/// the handlers it installs, which the user approved in the configuration preview.
public enum CodexHookTrust {
    public struct Entry: Equatable, Codable, Sendable {
        public let table: String
        public let hash: String
        public init(table: String, hash: String) { self.table = table; self.hash = hash }
    }

    static let eventLabels = ["SessionStart": "session_start", "UserPromptSubmit": "user_prompt_submit",
                              "PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use",
                              "PermissionRequest": "permission_request", "Stop": "stop", "SessionEnd": "session_end"]

    public static func hash(event: String, command: String, timeout: Int) -> String? {
        guard let label = eventLabels[event] else { return nil }
        // Codex normalizes before hashing: SessionEnd is clamped to 1…3 s, everything else to ≥ 1 s.
        let normalizedTimeout = event == "SessionEnd" ? min(max(timeout, 1), 3) : max(timeout, 1)
        let handler: [String: Any] = ["type": "command", "command": command, "timeout": normalizedTimeout, "async": false]
        let identity: [String: Any] = ["event_name": label, "hooks": [handler]]
        guard let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Config table name for one handler, escaped as a TOML basic string.
    public static func table(hooksPath: String, event: String, group: Int, handler: Int) -> String? {
        guard let label = eventLabels[event] else { return nil }
        let key = "\(hooksPath):\(label):\(group):\(handler)"
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "hooks.state.\"\(escaped)\""
    }

    /// One entry per Herdly handler present in `hooks`, keyed by its position the way Codex keys it.
    public static func entries(hooksPath: String, hooks: Data, command: String) -> [Entry] {
        guard let object = try? JSONSerialization.jsonObject(with: hooks) as? [String: Any],
              let events = object["hooks"] as? [String: Any] else { return [] }
        var result: [Entry] = []
        for event in CodexSetupRequirements.hookEvents {
            guard let groups = events[event] as? [[String: Any]] else { continue }
            for (groupIndex, group) in groups.enumerated() {
                guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
                for (handlerIndex, handler) in handlers.enumerated()
                where handler["type"] as? String == "command" && handler["command"] as? String == command {
                    let timeout = (handler["timeout"] as? NSNumber)?.intValue ?? 600
                    guard let table = table(hooksPath: hooksPath, event: event, group: groupIndex, handler: handlerIndex),
                          let hash = hash(event: event, command: command, timeout: timeout) else { continue }
                    result.append(Entry(table: table, hash: hash))
                }
            }
        }
        return result
    }
}

/// What Herdly wrote for one trust entry, so undo can put back exactly what was there before.
public struct TrustRecord: Equatable, Codable, Sendable {
    public let table: String
    public let hash: String
    /// A value that already sat under this key before Herdly wrote its own; restored on undo.
    public let previous: String?
    public init(table: String, hash: String, previous: String?) {
        self.table = table; self.hash = hash; self.previous = previous
    }
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
    public var helperURL: URL { helperDirectory.appendingPathComponent("HerdlyHook") }
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
    /// What this plan adds to config.toml, per line, so undo can remove exactly that and nothing else.
    let titleAdded: Bool
    let titleTableAdded: Bool
    let hooksFlagAdded: Bool
    let hooksTableAdded: Bool
    let trustRecords: [TrustRecord]

    public init(status: CodexSetupStatus, configChange: String, hooksChange: Data,
                helperCommand: String, requiresConfigure: Bool,
                originalConfig: String, originalHooks: Data, configAdded: Bool, configTableAdded: Bool = false,
                installationID: String = "", titleAdded: Bool? = nil, titleTableAdded: Bool? = nil,
                hooksFlagAdded: Bool = false, hooksTableAdded: Bool = false, trustRecords: [TrustRecord] = []) {
        self.trustRecords = trustRecords
        self.titleAdded = titleAdded ?? configAdded
        self.titleTableAdded = titleTableAdded ?? configTableAdded
        self.hooksFlagAdded = hooksFlagAdded
        self.hooksTableAdded = hooksTableAdded
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
                            helperPath: URL, eventsPath: URL, hooksPath: URL? = nil) -> CodexSetupPlan {
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
            return empty(.conflict("Multiple Herdly hook installations were found; review hooks.json before reconnecting."), config: config, hooks: hooks)
        }
        let installationID = discoveredInstallations.first ?? UUID().uuidString
        let command = prefix + shellQuote(installationID)
        guard let merged = mergeHooks(parsed, command: command) else {
            return empty(.malformed("Codex hooks.json has an unsupported hooks shape and was not changed."), config: config, hooks: hooks)
        }
        guard let titled = configWithSessionTitle(config) else {
            return empty(.conflict("Codex already has a different tui.terminal_title setting."), config: config, hooks: hooks)
        }
        guard let hooked = configWithHooksEnabled(titled.value) else {
            return empty(.conflict("Codex has hooks disabled (features.hooks = false); enable them in config.toml before connecting Herdly."), config: config, hooks: hooks)
        }
        let output = (try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])) ?? hooks
        // Record Codex's trust for exactly the handlers this plan installs; the preview shows every line.
        var trusted = hooked.value
        var trustRecords: [TrustRecord] = []
        if let hooksPath {
            for entry in CodexHookTrust.entries(hooksPath: hooksPath.path, hooks: output, command: command) {
                let written = configSetting(trusted, table: entry.table, key: "trusted_hash", value: "\"\(entry.hash)\"")
                trusted = written.value
                trustRecords.append(TrustRecord(table: entry.table, hash: entry.hash, previous: written.previous))
            }
        }
        let configResult = (value: trusted, added: titled.added || hooked.added, tableAdded: titled.tableAdded || hooked.tableAdded)
        let needsConfig = configResult.value != config
        let needsHooks = output != hooks
        return CodexSetupPlan(status: .ready, configChange: configResult.value, hooksChange: output,
                              helperCommand: command, requiresConfigure: needsConfig || needsHooks,
                              originalConfig: config, originalHooks: hooks, configAdded: configResult.added,
                              configTableAdded: configResult.tableAdded, installationID: installationID,
                              titleAdded: titled.added, titleTableAdded: titled.tableAdded,
                              hooksFlagAdded: hooked.added, hooksTableAdded: hooked.tableAdded, trustRecords: trustRecords)
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
        var seenArrayTables = Set<String>()
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
            if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") && trimmed.count > 4 {
                // Arrays of tables (such as Codex's `[[skills.config]]`) repeat, so each element starts
                // with fresh keys. Herdly never edits them, but one rooted where Herdly writes would make
                // its appended `[tui]`, `[features]`, or `[hooks.state.…]` tables ambiguous, so refuse it.
                let header = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                guard !header.isEmpty, validHeader(header), !seenSections.contains(header),
                      !herdlyOwnedRoots.contains(unquotedFirstSegment(header)) else { return false }
                seenArrayTables.insert(header)
                section = "[[\(header)]]"
                seenKeysBySection[section] = []
                continue
            }
            guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]"),
                  !trimmed.hasPrefix("[[") && !trimmed.hasSuffix("]]"),
                  trimmed.count > 2 else { return false }
            let header = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            guard !header.isEmpty, validHeader(header), !seenArrayTables.contains(header),
                  seenSections.insert(header).inserted else { return false }
            section = header
        }
        return pending.isEmpty
    }

    /// Top-level tables Herdly writes into; see `configWithSessionTitle`, `configWithHooksEnabled`, and `CodexHookTrust`.
    private static let herdlyOwnedRoots: Set<String> = ["tui", "features", "hooks"]

    /// The first segment of an already validated key, without the quotes a quoted segment carries.
    private static func unquotedFirstSegment(_ key: String) -> String {
        guard let quote = key.first, quote == "\"" || quote == "'" else {
            return String(key.prefix { $0 != "." })
        }
        var escaped = false
        for index in key.indices.dropFirst() {
            let character = key[index]
            if character == "\\" && quote == "\"" { escaped.toggle(); continue }
            if character == quote && !escaped { return String(key[key.index(after: key.startIndex)..<index]) }
            escaped = false
        }
        return key
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

    /// Like `configEnsuring`, but a different existing value is replaced rather than refused; the
    /// replaced value is returned so undo can restore it. Used only for Herdly's own trust entries.
    static func configSetting(_ config: String, table: String, key: String, value: String) -> (value: String, previous: String?) {
        if let existing = CodexSetupValidator.configValue(in: config, table: table, key: key) {
            if existing == value { return (config, nil) }
            let removed = configRemoving(config, table: table, key: key, value: existing, removeTable: false)
            return (configEnsuring(removed, table: table, key: key, value: value)?.value ?? config, existing)
        }
        return (configEnsuring(config, table: table, key: key, value: value)?.value ?? config, nil)
    }

    /// Removes `key = value` from `[table]` when it still holds exactly that value, leaving every
    /// other line as it is. With `removeTable`, a table left with nothing but blank lines and
    /// comments loses its header too. A line the user already changed or removed is left alone.
    static func configRemoving(_ config: String, table: String, key: String, value: String, removeTable: Bool) -> String {
        guard CodexSetupValidator.configValue(in: config, table: table, key: key) == value else { return config }
        var lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var section = ""
        var headerIndex: Int?
        var removed = false
        for (index, line) in lines.enumerated() {
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast())
                if section == table { headerIndex = index }
                continue
            }
            let name = trimmed.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            guard name == "\(table).\(key)" || (name == key && section == table) else { continue }
            lines.remove(at: index)
            removed = true
            break
        }
        guard removed else { return config }
        if removeTable, let header = headerIndex {
            var end = header + 1
            while end < lines.count {
                let trimmed = stripComment(lines[end]).trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { break }
                end += 1
            }
            let body = lines[(header + 1)..<end]
            if body.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
                lines.removeSubrange(header..<end)
                while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1,
                      lines[lines.count - 2].trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            }
        }
        let joined = lines.joined(separator: "\n")
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        return joined.hasSuffix("\n") ? joined : joined + "\n"
    }

    /// Removes every hook entry whose command is Herdly's, keeping all other hooks in place.
    static func removingHooks(_ source: [String: Any], command: String) -> [String: Any] {
        var result = source
        guard var hooks = source["hooks"] as? [String: Any] else { return source }
        for event in CodexSetupRequirements.hookEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var entry in entries {
                guard let nested = entry["hooks"] as? [[String: Any]] else { kept.append(entry); continue }
                let remaining = nested.filter { !($0["type"] as? String == "command" && $0["command"] as? String == command) }
                if remaining.count == nested.count { kept.append(entry); continue }
                if !remaining.isEmpty { entry["hooks"] = remaining; kept.append(entry) }
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }

    private static func configWithSessionTitle(_ config: String) -> (value: String, added: Bool, tableAdded: Bool)? {
        configEnsuring(config, table: "tui", key: "terminal_title", value: "[\"session-id\"]")
    }

    private static func configWithHooksEnabled(_ config: String) -> (value: String, added: Bool, tableAdded: Bool)? {
        configEnsuring(config, table: "features", key: "hooks", value: "true")
    }

    /// Returns the config with `key = value` present in `[table]`: unchanged when it already holds
    /// that value, nil when it holds a different one (the user's setting is never overwritten),
    /// otherwise with the line inserted at the end of the existing table or in a new table appended
    /// at the end of the file.
    private static func configEnsuring(_ config: String, table: String, key: String, value: String) -> (value: String, added: Bool, tableAdded: Bool)? {
        if let existing = CodexSetupValidator.configValue(in: config, table: table, key: key) {
            return existing == value ? (config, false, false) : nil
        }
        let lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.firstIndex(where: { stripComment($0).trimmingCharacters(in: .whitespaces) == "[\(table)]" }) else {
            var next = config
            if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }
            next += (next.isEmpty ? "[\(table)]\n" : "\n[\(table)]\n") + "\(key) = \(value)\n"
            return (next, true, true)
        }
        var nextTable = lines[(header + 1)...].firstIndex { line in
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        } ?? lines.count
        while nextTable > header + 1 && lines[nextTable - 1].trimmingCharacters(in: .whitespaces).isEmpty { nextTable -= 1 }
        var updated = lines
        updated.insert("\(key) = \(value)", at: nextTable)
        let joined = updated.joined(separator: "\n")
        return (joined.hasSuffix("\n") ? joined : joined + "\n", true, false)
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
        guard !helper.isEmpty else { throw CodexSetupError.failed("The bundled Herdly helper is unavailable.") }
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
           let state = try? readState(roots), state.command == plan.helperCommand {
            return status(roots: roots, capabilities: capabilities)
        }
        // The preview must describe the files as they are now; anything else is a race.
        guard currentConfig == plan.originalConfig, currentHooks == plan.originalHooks else {
            throw CodexSetupError.conflict("Codex configuration changed after the preview. Review setup again.")
        }
        // An existing install is re-baselined on the current files. Codex rewrites config.toml on
        // its own (settings, hook trust), so the files are never required to equal what Herdly last
        // wrote; what is kept from the earlier record is the user's original files and which lines
        // Herdly added, so undo still removes only Herdly's own contribution.
        let repairing = (try? readState(roots)).flatMap { state in
            state.command == plan.helperCommand && state.installationID == plan.installationID ? state : nil
        }
        if let existing = try? readableData(at: roots.helperURL) {
            guard let state = try? readState(roots), state.helper == existing.base64EncodedString() else {
                throw CodexSetupError.conflict("A different file already exists at Herdly's helper path.")
            }
        }
        if fileManager.fileExists(atPath: roots.helperURL.path) {
            var directory = ObjCBool(false)
            guard fileManager.fileExists(atPath: roots.helperURL.path, isDirectory: &directory), !directory.boolValue,
                  (try? readableData(at: roots.helperURL)) != nil else {
                throw CodexSetupError.conflict("Herdly's helper path is a directory or unreadable; it was not changed.")
            }
        }
        let backupDirectory = roots.helperDirectory.appendingPathComponent("backups").appendingPathComponent(UUID().uuidString)
        let originalConfig = try readableData(at: roots.configURL)
        let originalHooks = try readableData(at: roots.hooksURL)
        let originalHelper = try? readableData(at: roots.helperURL)
        do {
            if plan.configChange != plan.originalConfig { try backup(originalConfig, named: "config.toml", in: backupDirectory) }
            if plan.hooksChange != plan.originalHooks { try backup(originalHooks, named: "hooks.json", in: backupDirectory) }
            if originalHelper != helper { try backup(originalHelper, named: "HerdlyHook", in: backupDirectory) }
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
                                     configAdded: (repairing?.configAdded ?? false) || plan.configAdded,
                                     configTableAdded: (repairing?.configTableAdded ?? false) || plan.configTableAdded,
                                     installedAt: Date().timeIntervalSince1970,
                                     titleAdded: (repairing?.titleAdded ?? repairing?.configAdded ?? false) || plan.titleAdded,
                                     titleTableAdded: (repairing?.titleTableAdded ?? repairing?.configTableAdded ?? false) || plan.titleTableAdded,
                                     hooksFlagAdded: (repairing?.hooksFlagAdded ?? false) || plan.hooksFlagAdded,
                                     hooksTableAdded: (repairing?.hooksTableAdded ?? false) || plan.hooksTableAdded,
                                     trustRecords: plan.trustRecords.map { record in
                                         // A value Herdly itself wrote earlier is never "previous"; keep the first record's.
                                         if let earlier = repairing?.trustRecords?.first(where: { $0.table == record.table }) {
                                             return TrustRecord(table: record.table, hash: record.hash, previous: earlier.previous)
                                         }
                                         return record
                                     })
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

    /// Replaces Herdly's installed helper with `helper` only while the installed file is exactly the
    /// one Herdly recorded, and records the replacement so status and undo still recognize it. It never
    /// reads or writes config.toml or hooks.json. A missing or inconsistent record, or a helper that
    /// differs from the record, changes nothing. A failed write restores the previous helper and record.
    public func refreshHelper(roots: CodexSetupRoots, helper: Data) throws -> HelperRefreshResult {
        guard !helper.isEmpty else { return .skipped("The bundled Herdly helper is unavailable.") }
        guard fileManager.fileExists(atPath: roots.stateURL.path) else { return .skipped("Codex setup is not installed.") }
        guard let originalState = try? readableData(at: roots.stateURL),
              var state = try? JSONDecoder().decode(InstallState.self, from: originalState),
              UUID(uuidString: state.installationID) != nil,
              let recorded = Data(base64Encoded: state.helper) else {
            return .skipped("Herdly setup state is unreadable or inconsistent.")
        }
        guard let installed = try? readableData(at: roots.helperURL) else { return .skipped("Herdly's helper is missing or unreadable.") }
        guard installed == recorded else { return .skipped("Herdly's helper differs from the one it installed.") }
        guard installed != helper else { return .current }
        state.helper = helper.base64EncodedString()
        let updatedState = try JSONEncoder().encode(state)
        do {
            try atomicWriteExecutable(helper, to: roots.helperURL)
            try atomicWrite(updatedState, to: roots.stateURL)
        } catch let error {
            do {
                try atomicWriteExecutable(installed, to: roots.helperURL)
                try atomicWrite(originalState, to: roots.stateURL)
            } catch let rollbackError {
                throw CodexSetupError.rollbackIncomplete("Helper update failed (\(error)); rollback also failed (\(rollbackError)). Check Herdly's helper before retrying.")
            }
            throw CodexSetupError.failed("The helper update was not completed; the previous helper was restored.")
        }
        return .updated
    }

    public func status(roots: CodexSetupRoots, capabilities: CodexCapabilities) -> CodexConnectionStatus {
        guard capabilities.supported, capabilities.cli || capabilities.desktop else {
            return .unsupported(capabilities.unsupportedReason ?? "No supported Codex runtime was detected.")
        }
        guard fileManager.fileExists(atPath: roots.stateURL.path) else { return .notConfigured }
        guard let state = try? readState(roots) else { return .conflict("Herdly setup state is unreadable; review setup before changing Codex files.") }
        guard UUID(uuidString: state.installationID) != nil,
              state.command == CodexSetupPlanner.command(helperPath: roots.helperURL, eventsPath: roots.eventsDirectory,
                                                         installationID: state.installationID) else {
            return .conflict("Herdly setup state has an invalid installation identity; review setup before changing Codex files.")
        }
        guard let configData = try? readableData(at: roots.configURL),
              let config = String(data: configData, encoding: .utf8),
              let hooks = try? readableData(at: roots.hooksURL) else { return .malformed("Herdly setup files are missing or unreadable.") }
        guard CodexSetupPlanner.isSafeTOML(config) else {
            return .malformed("Codex config.toml is not valid enough to verify safely.")
        }
        guard fileManager.fileExists(atPath: roots.helperURL.path) else {
            if CodexSetupValidator.hasRequiredHooks(hooks, command: state.command) {
                return .repairRequired("Herdly's helper is missing; Configure Codex to repair setup.")
            }
            return .conflict("Herdly's helper is missing and its Codex hooks are gone; review setup before repair.")
        }
        var helperDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: roots.helperURL.path, isDirectory: &helperDirectory), !helperDirectory.boolValue,
              let helper = try? readableData(at: roots.helperURL) else {
            return .conflict("Herdly's helper path is a directory or unreadable.")
        }
        guard (try? JSONSerialization.jsonObject(with: hooks) as? [String: Any]) != nil else {
            return .malformed("Codex hooks.json is not valid JSON.")
        }
        guard helper == Data(base64Encoded: state.helper),
              let permissions = (try? fileManager.attributesOfItem(atPath: roots.helperURL.path)[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o111 != 0 else {
            return .conflict("Herdly's helper differs from the one it installed; review setup before repair.")
        }
        // Herdly owns only its lines and hook entries; the rest of Codex's files may change freely.
        guard CodexSetupValidator.hasRequiredHooks(hooks, command: state.command) else {
            return .repairRequired("Herdly's Codex hook entries are missing; Configure Codex to repair setup.")
        }
        guard CodexSetupValidator.hasSessionTitle(in: config) else {
            return .repairRequired("Codex's session-ID terminal title is missing; Configure Codex to repair setup.")
        }
        guard CodexSetupValidator.hasHooksEnabled(in: config) else {
            return .repairRequired("Codex hooks are not enabled in config.toml; Configure Codex to repair setup.")
        }
        let trustEntries = CodexHookTrust.entries(hooksPath: roots.hooksURL.path, hooks: hooks, command: state.command)
        guard trustEntries.allSatisfy({ CodexSetupValidator.configValue(in: config, table: $0.table, key: "trusted_hash") == "\"\($0.hash)\"" }) else {
            return .repairRequired("Codex has not recorded trust for Herdly's hooks; Configure Codex to repair setup.")
        }
        guard fileManager.fileExists(atPath: roots.eventsDirectory.path) else {
            return .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Herdly's hooks.")
        }
        guard let files = try? fileManager.contentsOfDirectory(at: roots.eventsDirectory, includingPropertiesForKeys: nil) else {
            return .permissionRequired("Herdly's events directory is not readable. Grant access or choose Configure Codex again.")
        }
        guard files.contains(where: { validMetadataEvent($0, installedAt: state.installedAt, installationID: state.installationID) }) else {
            return .configuredAwaitingRestart("Configured; start a new Codex session to verify delivery. Existing sessions keep running without Herdly's hooks.")
        }
        return .connected
    }

    public func undo(roots: CodexSetupRoots) throws -> CodexConnectionStatus {
        let state = try readState(roots)
        guard let currentConfigData = try readableData(at: roots.configURL),
              let currentConfig = String(data: currentConfigData, encoding: .utf8),
              let currentHooks = try readableData(at: roots.hooksURL) else {
            throw CodexSetupError.conflict("Codex's configuration files are missing or unreadable; undo made no changes.")
        }
        let currentHelper = try readableData(at: roots.helperURL)
        guard currentHelper == nil || currentHelper == Data(base64Encoded: state.helper) else {
            throw CodexSetupError.conflict("A different file sits at Herdly's helper path; undo made no changes.")
        }
        // Files still exactly as installed go back to the user's originals byte for byte. Files
        // Codex or the user changed since lose only the lines and hook entries Herdly added.
        let originalConfig: Data?
        if currentConfig == state.installedConfig {
            originalConfig = state.originalConfigExisted ? Data(state.originalConfig.utf8) : nil
        } else {
            var reduced = currentConfig
            if state.titleAdded ?? state.configAdded {
                reduced = CodexSetupPlanner.configRemoving(reduced, table: "tui", key: "terminal_title", value: "[\"session-id\"]",
                                                           removeTable: state.titleTableAdded ?? state.configTableAdded)
            }
            if state.hooksFlagAdded ?? false {
                reduced = CodexSetupPlanner.configRemoving(reduced, table: "features", key: "hooks", value: "true",
                                                           removeTable: state.hooksTableAdded ?? false)
            }
            for record in state.trustRecords ?? [] {
                if let previous = record.previous {
                    reduced = CodexSetupPlanner.configSetting(reduced, table: record.table, key: "trusted_hash", value: previous).value
                } else {
                    reduced = CodexSetupPlanner.configRemoving(reduced, table: record.table, key: "trusted_hash",
                                                               value: "\"\(record.hash)\"", removeTable: true)
                }
            }
            originalConfig = Data(reduced.utf8)
        }
        let originalHooks: Data?
        if currentHooks == state.installedHooks {
            originalHooks = state.originalHooksExisted ? state.originalHooks : nil
        } else {
            guard let parsed = try? JSONSerialization.jsonObject(with: currentHooks) as? [String: Any] else {
                throw CodexSetupError.conflict("Codex hooks.json is not valid JSON; undo made no changes.")
            }
            let reduced = CodexSetupPlanner.removingHooks(parsed, command: state.command)
            originalHooks = try JSONSerialization.data(withJSONObject: reduced, options: [.prettyPrinted, .sortedKeys])
        }
        let originalHelper = Data(base64Encoded: state.helper)
        guard let originalState = try readableData(at: roots.stateURL) else {
            throw CodexSetupError.conflict("Herdly setup state is missing or unreadable; undo made no changes.")
        }
        let ownedEvents = try ownedEventArtifacts(in: roots.eventsDirectory, installationID: state.installationID)
        let ownedBackups = try ownedBackupArtifacts(in: roots.helperDirectory.appendingPathComponent("backups", isDirectory: true), state: state)
        do {
            try restore(originalConfig, to: roots.configURL)
            try restore(originalHooks, to: roots.hooksURL)
            if fileManager.fileExists(atPath: roots.helperURL.path) { try fileManager.removeItem(at: roots.helperURL) }
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
        guard let data = try readableData(at: roots.stateURL) else { throw CodexSetupError.failed("Herdly setup is not installed.") }
        return try JSONDecoder().decode(InstallState.self, from: data)
    }

    private func readableData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard isRegularFile(at: url) else {
            throw CodexSetupError.conflict("\(url.lastPathComponent) is a directory; it was not changed.")
        }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: CodexSetupLimits.maximumFileSize + 1), data.count <= CodexSetupLimits.maximumFileSize else {
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
        guard isDirectory(at: url) else { throw CodexSetupError.conflict("Herdly cleanup path is not a directory; no cleanup was completed.") }
        guard try fileManager.contentsOfDirectory(atPath: url.path).isEmpty else { return }
        try fileManager.removeItem(at: url)
    }

    private func removeOwnedEvents(in directory: URL, installationID: String) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard isDirectory(at: directory) else { throw CodexSetupError.conflict("Herdly's events path is not a directory; no cleanup was completed.") }
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
        guard name != ".", name != "..", !name.contains("/") else { throw CodexSetupError.conflict("Herdly setup backup identity is invalid; no cleanup was completed.") }
        let backup = directory.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: backup.path) else { return }
        guard isDirectory(at: backup) else { throw CodexSetupError.conflict("Herdly setup backup is not a directory; no cleanup was completed.") }
        let expected: [String: Data] = [
            "config.toml": state.originalConfigExisted ? Data(state.originalConfig.utf8) : nil,
            "hooks.json": state.originalHooksExisted ? state.originalHooks : nil,
            "HerdlyHook": state.originalHelperExisted ? Data(base64Encoded: state.helper) : nil
        ].compactMapValues { $0 }
        let files = try fileManager.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
        guard files.count == expected.count,
              files.allSatisfy({ expected[$0.lastPathComponent] == boundedData(at: $0, maximum: CodexSetupLimits.maximumFileSize) }) else { return }
        try beforeCleanup?(backup)
        try fileManager.removeItem(at: backup)
        try removeDirectoryIfEmpty(directory)
    }

    private func ownedEventArtifacts(in directory: URL, installationID: String) throws -> [OwnedArtifact] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        guard isDirectory(at: directory) else { throw CodexSetupError.conflict("Herdly's events path is not a directory; no cleanup was completed.") }
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
        guard name != ".", name != "..", !name.contains("/") else { throw CodexSetupError.conflict("Herdly setup backup identity is invalid; no cleanup was completed.") }
        let backup = directory.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: backup.path) else { return nil }
        guard isDirectory(at: backup) else { throw CodexSetupError.conflict("Herdly setup backup is not a directory; no cleanup was completed.") }
        let expected: [String: Data] = [
            "config.toml": state.originalConfigExisted ? Data(state.originalConfig.utf8) : nil,
            "hooks.json": state.originalHooksExisted ? state.originalHooks : nil,
            "HerdlyHook": state.originalHelperExisted ? Data(base64Encoded: state.helper) : nil
        ].compactMapValues { $0 }
        let files = try fileManager.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
        let artifacts = files.compactMap { url -> OwnedArtifact? in
            guard let expectedData = expected[url.lastPathComponent], let data = boundedData(at: url, maximum: CodexSetupLimits.maximumFileSize), data == expectedData else { return nil }
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
        let temp = url.deletingLastPathComponent().appendingPathComponent(".herdly-" + UUID().uuidString)
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

    /// Writes an executable beside `url` and renames it into place, so a hook starting meanwhile
    /// runs either the old helper or the new one, never a partial or non-executable file.
    private func atomicWriteExecutable(_ data: Data, to url: URL) throws {
        try beforeWrite?(url)
        try SetupFileWriter.replaceExecutable(data, at: url, fileManager: fileManager)
    }
}

/// Shared executable replacement for the Codex and Claude installers.
enum SetupFileWriter {
    static func replaceExecutable(_ data: Data, at url: URL, fileManager: FileManager) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".herdly-" + UUID().uuidString)
        do {
            try data.write(to: temp)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
            guard rename(temp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
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
    var helper: String
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
    var titleAdded: Bool?
    var titleTableAdded: Bool?
    var hooksFlagAdded: Bool?
    var hooksTableAdded: Bool?
    var trustRecords: [TrustRecord]?
}
