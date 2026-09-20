import Foundation

public struct ClaudeCapabilities: Equatable, Sendable {
    public let installed: Bool
    public let supported: Bool
    public let version: String?

    public init(installed: Bool, supported: Bool, version: String? = nil) {
        self.installed = installed
        self.supported = supported
        self.version = version
    }
}

public struct ClaudeSetupPolicy: Equatable, Sendable {
    public let managedHooksOnly: Bool
    public let shadowedBy: String?

    public init(managedHooksOnly: Bool = false, shadowedBy: String? = nil) {
        self.managedHooksOnly = managedHooksOnly
        self.shadowedBy = shadowedBy
    }
}

public struct ClaudeHookDefinition: Equatable, Sendable {
    public let event: String
    public let matcher: String?
    public let terminalTitle: Bool
    public let questionHelper: Bool

    public init(event: String, matcher: String? = nil, terminalTitle: Bool = false, questionHelper: Bool = false) {
        self.event = event
        self.matcher = matcher
        self.terminalTitle = terminalTitle
        self.questionHelper = questionHelper
    }
}

public struct ClaudeOwnedHook: Codable, Equatable, Sendable {
    public let event: String
    public let matcher: String?
    public let command: String
    public let groupIndex: Int?
    public let handlerIndex: Int?
    public let handlerData: Data?

    public init(event: String, matcher: String?, command: String, groupIndex: Int? = nil, handlerIndex: Int? = nil,
                handlerData: Data? = nil) {
        self.event = event
        self.matcher = matcher
        self.command = command
        self.groupIndex = groupIndex
        self.handlerIndex = handlerIndex
        self.handlerData = handlerData
    }
}

public enum ClaudeSetupRequirements {
    public static let minimumCLIVersion = "2.1.273"
    public static let helperSource = "steer-claude-hook-v1"
    public static let previousHookTimeout = 10
    /// Covers the companion connection wait, one 30-second decision window, and a small bound.
    public static let hookTimeout = 38
    public static let titlePrefix = "Steer Claude "
    public static let titleDisableEnvironmentKey = "CLAUDE_CODE_DISABLE_TERMINAL_TITLE"
    public static let titleDisableEnvironmentValue = "1"
    public static let metadataClockSkew: TimeInterval = 300

    /// The events needed by the observer and Bash decision slices. Other permission families stay
    /// in Claude's native flow until separately proven.
    public static let hookDefinitions = [
        ClaudeHookDefinition(event: "SessionStart", terminalTitle: true),
        ClaudeHookDefinition(event: "UserPromptSubmit"),
        ClaudeHookDefinition(event: "PreToolUse"),
        ClaudeHookDefinition(event: "PreToolUse", matcher: "AskUserQuestion", questionHelper: true),
        ClaudeHookDefinition(event: "PostToolUse"),
        ClaudeHookDefinition(event: "PostToolUseFailure"),
        ClaudeHookDefinition(event: "PostToolBatch"),
        ClaudeHookDefinition(event: "PermissionRequest", matcher: "Bash"),
        ClaudeHookDefinition(event: "Stop"),
        ClaudeHookDefinition(event: "StopFailure"),
        ClaudeHookDefinition(event: "SessionEnd", terminalTitle: true),
        ClaudeHookDefinition(event: "SubagentStart"),
        ClaudeHookDefinition(event: "SubagentStop"),
        ClaudeHookDefinition(event: "Notification")
    ]
}

public enum ClaudeSetupStatus: Equatable, Sendable {
    case ready
    case unsupported(String)
    case malformed(String)
    case conflict(String)
    case blockedByPolicy(String)
    case shadowed(String)
}

public enum ClaudeConnectionStatus: Equatable, Sendable {
    case unavailable(String)
    case unsupported(String)
    case notConfigured
    case configuredAwaitingRestart(String)
    case connected
    case repairRequired(String)
    case blockedByPolicy(String)
    case shadowed(String)
    case malformed(String)
    case conflict(String)
}

public enum ClaudeGhosttyStatus: Equatable, Sendable {
    case off
    case permissionRequired
    case ready
    case unavailable(String)
}

public struct ClaudeSetupRoots: Equatable, Sendable {
    public let configDirectory: URL
    public let helperDirectory: URL
    public let eventsDirectory: URL

    public init(configDirectory: URL, helperDirectory: URL, eventsDirectory: URL) {
        self.configDirectory = configDirectory
        self.helperDirectory = helperDirectory
        self.eventsDirectory = eventsDirectory
    }

    public var settingsURL: URL { configDirectory.appendingPathComponent("settings.json") }
    public var helperURL: URL { helperDirectory.appendingPathComponent("SteerHook") }
    public var stateURL: URL { helperDirectory.appendingPathComponent("install.json") }
    public var backupsURL: URL { helperDirectory.appendingPathComponent("backups", isDirectory: true) }
    public var usageDirectory: URL { helperDirectory.appendingPathComponent("usage", isDirectory: true) }
}

public struct ClaudeSetupPlan: Sendable {
    public let status: ClaudeSetupStatus
    public let settingsChange: Data
    public let ownedHooks: [ClaudeOwnedHook]
    public let ownedEnvironment: [String: String]
    public let helperCommand: String
    public let requiresConfigure: Bool
    public let installationID: String
    public let usageEnabled: Bool
    public let usageStatus: ClaudeUsageSetupStatus

    let originalSettings: Data
    let originalSettingsExisted: Bool

    init(status: ClaudeSetupStatus, settingsChange: Data, ownedHooks: [ClaudeOwnedHook],
         ownedEnvironment: [String: String],
         helperCommand: String, requiresConfigure: Bool, installationID: String,
         usageEnabled: Bool, usageStatus: ClaudeUsageSetupStatus,
         originalSettings: Data, originalSettingsExisted: Bool) {
        self.status = status
        self.settingsChange = settingsChange
        self.ownedHooks = ownedHooks
        self.ownedEnvironment = ownedEnvironment
        self.helperCommand = helperCommand
        self.requiresConfigure = requiresConfigure
        self.installationID = installationID
        self.usageEnabled = usageEnabled
        self.usageStatus = usageStatus
        self.originalSettings = originalSettings
        self.originalSettingsExisted = originalSettingsExisted
    }
}

public enum ClaudeSetupPlanner {
    public static func plan(capabilities: ClaudeCapabilities, settings: Data,
                            helperPath: URL, eventsPath: URL,
                            sourceScope: URL? = nil,
                            policy: ClaudeSetupPolicy = ClaudeSetupPolicy(), usageEnabled: Bool = false,
                            settingsExisted: Bool = true, installRecordPresent: Bool = true) -> ClaudeSetupPlan {
        guard capabilities.supported else {
            return empty(.unsupported("Claude Code \(capabilities.version ?? "version unknown") is older than the tested minimum \(ClaudeSetupRequirements.minimumCLIVersion)."), settings: settings, settingsExisted: settingsExisted)
        }
        guard let source = try? jsonObject(settings) else {
            return empty(.malformed("Claude settings.json is not valid JSON and was not changed."), settings: settings, settingsExisted: settingsExisted)
        }
        if policy.managedHooksOnly || (source["allowManagedHooksOnly"] as? Bool == true) {
            return empty(.blockedByPolicy("Claude managed policy allows only managed hooks; Steer did not change settings."), settings: settings, settingsExisted: settingsExisted)
        }
        if let shadowedBy = policy.shadowedBy {
            return empty(.shadowed("Claude settings are shadowed by \(shadowedBy); Steer did not change settings."), settings: settings, settingsExisted: settingsExisted)
        }
        if source["disableAllHooks"] as? Bool == true {
            return empty(.blockedByPolicy("Claude hooks are disabled by settings.json; Steer did not change settings."), settings: settings, settingsExisted: settingsExisted)
        }
        if let hooks = source["hooks"], !(hooks is [String: Any]) {
            return empty(.malformed("Claude settings.json has an unsupported hooks shape and was not changed."), settings: settings, settingsExisted: settingsExisted)
        }
        if let hooks = source["hooks"] as? [String: Any], !hooksShapeIsValid(hooks) {
            return empty(.malformed("Claude settings.json has an unsupported hooks shape and was not changed."), settings: settings, settingsExisted: settingsExisted)
        }
        if let environment = source["env"], !(environment is [String: Any]) {
            return empty(.malformed("Claude settings.json has an unsupported env shape and was not changed."), settings: settings, settingsExisted: settingsExisted)
        }
        if let existing = (source["env"] as? [String: Any])?[ClaudeSetupRequirements.titleDisableEnvironmentKey],
           (existing as? String) != ClaudeSetupRequirements.titleDisableEnvironmentValue {
            return empty(.conflict("Claude's automatic terminal title setting is owned by another value; review settings.json before reconnecting."), settings: settings, settingsExisted: settingsExisted)
        }

        let marker = ownershipMarker(helperPath: helperPath, eventsPath: eventsPath)
        let installationIDs = existingInstallationIDs(source, marker: marker)
        guard installationIDs.count <= 1 else {
            return empty(.conflict("Multiple Steer Claude installations were found in this root; review settings.json before reconnecting."), settings: settings, settingsExisted: settingsExisted)
        }
        guard installRecordPresent || installationIDs.isEmpty else {
            return empty(.conflict("Steer Claude setup state is missing; review this root's settings.json before reconnecting."), settings: settings, settingsExisted: settingsExisted)
        }
        let installationID = installationIDs.first ?? UUID().uuidString
        let definitions = ClaudeSetupRequirements.hookDefinitions
        let expectedHooks = definitions.map { definition in
            ClaudeOwnedHook(event: definition.event, matcher: definition.matcher,
                            command: command(helperPath: helperPath, eventsPath: eventsPath,
                                             installationID: installationID, terminalTitle: definition.terminalTitle,
                                             questionHelper: definition.questionHelper,
                                             sourceScope: definition.questionHelper ? sourceScope : nil))
        }
        if hasChangedOwnedHook(source, expected: expectedHooks, marker: marker) {
            return empty(.conflict("A Steer-owned Claude hook was changed; review setup before repair."), settings: settings, settingsExisted: settingsExisted)
        }
        var merged = source
        var hooks = (source["hooks"] as? [String: Any]) ?? [:]
        for (definition, owned) in zip(definitions, expectedHooks) {
            var groups = (hooks[definition.event] as? [[String: Any]]) ?? []
            let exact = groups.filter { group in
                groupMatcher(group) == definition.matcher &&
                (group["hooks"] as? [[String: Any]])?.contains(where: { handlerMatches($0, command: owned.command) }) == true
            }
            if exact.count > 1 {
                return empty(.conflict("Duplicate Steer-owned Claude hooks were found; review settings.json before reconnecting."), settings: settings, settingsExisted: settingsExisted)
            }
            if exact.isEmpty {
                let legacy = groups.enumerated().filter { _, group in
                    (group["hooks"] as? [[String: Any]])?.contains(where: { handlerIsLegacy($0, command: owned.command) }) == true
                }
                if legacy.count > 1 {
                    return empty(.conflict("Duplicate Steer-owned Claude hooks were found; review settings.json before reconnecting."), settings: settings, settingsExisted: settingsExisted)
                }
                if let (groupIndex, _) = legacy.first,
                   var handlers = groups[groupIndex]["hooks"] as? [[String: Any]],
                   let handlerIndex = handlers.firstIndex(where: { handlerIsLegacy($0, command: owned.command) }) {
                    handlers[handlerIndex]["timeout"] = ClaudeSetupRequirements.hookTimeout
                    groups[groupIndex]["hooks"] = handlers
                    hooks[definition.event] = groups
                    continue
                }
                var group: [String: Any] = ["hooks": [["type": "command", "command": owned.command, "timeout": ClaudeSetupRequirements.hookTimeout]]]
                if let matcher = definition.matcher { group["matcher"] = matcher }
                groups.append(group)
            }
            hooks[definition.event] = groups
        }
        merged["hooks"] = hooks
        var environment = (source["env"] as? [String: Any]) ?? [:]
        let titleEnvironmentAlreadyPresent = environment[ClaudeSetupRequirements.titleDisableEnvironmentKey] as? String
            == ClaudeSetupRequirements.titleDisableEnvironmentValue
        environment[ClaudeSetupRequirements.titleDisableEnvironmentKey] = ClaudeSetupRequirements.titleDisableEnvironmentValue
        merged["env"] = environment
        let ownedHooks = expectedHooks.map { owned in
            let groups = (hooks[owned.event] as? [[String: Any]]) ?? []
            var position: (Int, Int)?
            for (groupIndex, group) in groups.enumerated() {
                guard groupMatcher(group) == owned.matcher,
                      let handlers = group["hooks"] as? [[String: Any]],
                      let handlerIndex = handlers.firstIndex(where: { handlerMatches($0, command: owned.command) }) else { continue }
                position = (groupIndex, handlerIndex)
                break
            }
            return ClaudeOwnedHook(event: owned.event, matcher: owned.matcher, command: owned.command,
                                   groupIndex: position?.0, handlerIndex: position?.1,
                                   handlerData: position.flatMap { groupIndex, handlerIndex in
                                       guard let groups = hooks[owned.event] as? [[String: Any]],
                                             groupIndex < groups.count,
                                             let handlers = groups[groupIndex]["hooks"] as? [[String: Any]],
                                             handlerIndex < handlers.count else { return nil }
                                       let handler = handlers[handlerIndex]
                                       return try? JSONSerialization.data(withJSONObject: handler, options: [.sortedKeys])
                                   })
        }
        guard let mergedHooks = merged["hooks"] as? [String: Any],
              let hooksChanged = try? jsonDataPreservingOtherBytes(
                  settings,
                  hooks: jsonEquivalent(source["hooks"], mergedHooks) ? source["hooks"] as? [String: Any] : mergedHooks
              ),
              let changedBase = try? jsonDataPreservingEnvironment(hooksChanged, original: source["env"], value: environment) else {
            return empty(.malformed("Claude settings.json could not be encoded safely and was not changed."), settings: settings, settingsExisted: settingsExisted)
        }
        let usage: ClaudeUsageSetupStatus
        if !usageEnabled {
            usage = .off
        } else if source["statusLine"] == nil {
            usage = .ready
        } else if let existingCommand = ClaudeStatusLineBridge.statusLineCommand(source["statusLine"]) {
            usage = ClaudeStatusLineBridge.isBridgeCommand(existingCommand)
                ? .ready
                : (ClaudeStatusLineCompatibility.probe(command: existingCommand)
                    ? .ready : .unavailable(ClaudeStatusLineCompatibility.failureMessage))
        } else {
            usage = .unavailable("Claude usage unavailable: the existing status line is incompatible.")
        }
        var changed = changedBase
        if usage == .ready, usageEnabled,
           !(ClaudeStatusLineBridge.statusLineCommand(source["statusLine"]).map { ClaudeStatusLineBridge.isBridgeCommand($0) } ?? false),
           let bridged = ClaudeStatusLineBridge.bridgeStatusLine(source["statusLine"], helperPath: helperPath,
                                                                 usagePath: helperPath.deletingLastPathComponent().appendingPathComponent("usage", isDirectory: true)),
           let statusLineChanged = try? jsonDataPreservingMember(changed, key: "statusLine", value: bridged) {
            changed = statusLineChanged
        }
        return ClaudeSetupPlan(status: .ready, settingsChange: changed, ownedHooks: ownedHooks,
                               ownedEnvironment: titleEnvironmentAlreadyPresent ? [:] : [ClaudeSetupRequirements.titleDisableEnvironmentKey: ClaudeSetupRequirements.titleDisableEnvironmentValue],
                               helperCommand: ownedHooks.first?.command ?? "", requiresConfigure: changed != settings,
                               installationID: installationID, usageEnabled: usageEnabled, usageStatus: usage,
                               originalSettings: settings, originalSettingsExisted: settingsExisted)
    }

    public static func command(helperPath: URL, eventsPath: URL, installationID: String,
                               terminalTitle: Bool = false, questionHelper: Bool = false,
                               sourceScope: URL? = nil) -> String {
        var value = ownershipMarker(helperPath: helperPath, eventsPath: eventsPath) + shellQuote(installationID)
        if terminalTitle { value += " --terminal-title" }
        if questionHelper { value += " --question-helper" }
        if questionHelper, let sourceScope {
            value += " --source-scope \(shellQuote(sourceScope.standardizedFileURL.path))"
        }
        return value
    }

    static func ownershipMarker(helperPath: URL, eventsPath: URL) -> String {
        "\(shellQuote(helperPath.path)) --agent claude --events-dir \(shellQuote(eventsPath.path)) --installation-id "
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeSetupError.conflict("not an object") }
        return object
    }

    static func jsonEquivalent(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs,
              let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else { return false }
        return left == right
    }

    static func memberData(_ settings: Data, key: String) -> Data? {
        guard let source = try? jsonObject(settings), let value = source[key],
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return data
    }

    static func restoreMemberBytes(_ changed: Data, from original: Data, key: String) -> Data? {
        guard let changedObject = rawObject(changed), let originalObject = rawObject(original),
              let changedMember = changedObject.members.first(where: { $0.key == key }),
              let originalMember = originalObject.members.first(where: { $0.key == key }) else { return nil }
        return changed.subdata(in: 0..<changedMember.valueStart)
            + original.subdata(in: originalMember.valueStart..<originalMember.valueEnd)
            + changed.subdata(in: changedMember.valueEnd..<changed.count)
    }

    /// Replace only the top-level hooks value. The rest of settings.json remains byte-for-byte
    /// intact, so unrelated formatting, ordering, and values are not rewritten by setup or undo.
    static func jsonDataPreservingOtherBytes(_ original: Data, hooks: [String: Any]?) throws -> Data {
        try jsonDataPreservingMember(original, key: "hooks", value: hooks)
    }

    private static func jsonDataPreservingEnvironment(_ data: Data, original: Any?, value: [String: Any]) throws -> Data {
        guard !jsonEquivalent(original, value) else { return data }
        if original != nil {
            return try jsonDataPreservingNestedMember(data, parentKey: "env",
                                                      key: ClaudeSetupRequirements.titleDisableEnvironmentKey,
                                                      value: ClaudeSetupRequirements.titleDisableEnvironmentValue)
        }
        return try jsonDataPreservingMember(data, key: "env", value: value)
    }

    /// Replace one key inside a top-level object member while preserving the bytes around
    /// that nested key. This keeps unrelated environment variables and formatting intact.
    static func jsonDataPreservingNestedMember(_ original: Data, parentKey: String, key: String, value: Any?) throws -> Data {
        guard let raw = rawObject(original), raw.members.filter({ $0.key == parentKey }).count == 1,
              let parent = raw.members.first(where: { $0.key == parentKey }) else {
            throw ClaudeSetupError.conflict("Claude settings.json has an invalid \(parentKey) object.")
        }
        let nested = original.subdata(in: parent.valueStart..<parent.valueEnd)
        let changed = try jsonDataPreservingMember(nested, key: key, value: value)
        return original.subdata(in: 0..<parent.valueStart) + changed + original.subdata(in: parent.valueEnd..<original.count)
    }

    static func jsonDataPreservingMember(_ original: Data, key: String, value: Any?) throws -> Data {
        guard let raw = rawObject(original), raw.members.filter({ $0.key == key }).count <= 1 else {
            throw ClaudeSetupError.conflict("Claude settings.json has duplicate top-level \(key) keys.")
        }
        let replacement: Data
        if let value { replacement = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) }
        else { replacement = Data() }
        if let member = raw.members.first(where: { $0.key == key }) {
            if value == nil {
                let bytes = [UInt8](original)
                var start = member.keyStart
                var after = member.valueEnd
                var cursor = skipWhitespace(bytes, from: after)
                if cursor < bytes.count, bytes[cursor] == 44 {
                    after = cursor + 1
                } else {
                    cursor = skipWhitespace(bytes, backwardsFrom: start - 1)
                    if cursor >= 0, bytes[cursor] == 44 { start = cursor }
                }
                return original.subdata(in: 0..<start) + original.subdata(in: after..<original.count)
            }
            return original.subdata(in: 0..<member.valueStart) + replacement + original.subdata(in: member.valueEnd..<original.count)
        }
        guard value != nil else { return original }
        let insertion = Data((raw.members.isEmpty ? "\"\(key)\":" : ",\"\(key)\":").utf8) + replacement
        return original.subdata(in: 0..<raw.close) + insertion + original.subdata(in: raw.close..<original.count)
    }

    private struct RawMember {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
    }

    private struct RawObject {
        let members: [RawMember]
        let close: Int
    }

    private static func rawObject(_ data: Data) -> RawObject? {
        let bytes = [UInt8](data)
        var cursor = skipWhitespace(bytes, from: 0)
        guard cursor < bytes.count, bytes[cursor] == 123 else { return nil }
        cursor += 1
        var members: [RawMember] = []
        while true {
            cursor = skipWhitespace(bytes, from: cursor)
            if cursor >= bytes.count { return nil }
            if bytes[cursor] == 125 { return RawObject(members: members, close: cursor) }
            let keyStart = cursor
            guard let keyEnd = stringEnd(bytes, from: cursor),
                  let key = try? JSONSerialization.jsonObject(with: data.subdata(in: keyStart..<keyEnd), options: [.fragmentsAllowed]) as? String else { return nil }
            cursor = skipWhitespace(bytes, from: keyEnd)
            guard cursor < bytes.count, bytes[cursor] == 58 else { return nil }
            cursor = skipWhitespace(bytes, from: cursor + 1)
            let valueStart = cursor
            guard let valueEnd = valueEnd(bytes, from: cursor) else { return nil }
            members.append(RawMember(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd))
            cursor = skipWhitespace(bytes, from: valueEnd)
            guard cursor < bytes.count else { return nil }
            if bytes[cursor] == 44 { cursor += 1; continue }
            if bytes[cursor] == 125 { return RawObject(members: members, close: cursor) }
            return nil
        }
    }

    private static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count, bytes[start] == 34 else { return nil }
        var cursor = start + 1
        while cursor < bytes.count {
            if bytes[cursor] == 92 { cursor += 2; continue }
            if bytes[cursor] == 34 { return cursor + 1 }
            cursor += 1
        }
        return nil
    }

    private static func valueEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        if bytes[start] == 34 { return stringEnd(bytes, from: start) }
        if bytes[start] == 123 || bytes[start] == 91 {
            var stack: [UInt8] = [bytes[start] == 123 ? 125 : 93]
            var cursor = start + 1
            while cursor < bytes.count {
                if bytes[cursor] == 34 {
                    guard let end = stringEnd(bytes, from: cursor) else { return nil }
                    cursor = end
                    continue
                }
                if bytes[cursor] == 123 { stack.append(125) }
                else if bytes[cursor] == 91 { stack.append(93) }
                else if bytes[cursor] == stack.last {
                    stack.removeLast()
                    if stack.isEmpty { return cursor + 1 }
                } else if bytes[cursor] == 125 || bytes[cursor] == 93 { return nil }
                cursor += 1
            }
            return nil
        }
        var cursor = start
        while cursor < bytes.count, bytes[cursor] != 44, bytes[cursor] != 125 { cursor += 1 }
        var end = cursor
        while end > start, bytes[end - 1] == 32 || bytes[end - 1] == 9 || bytes[end - 1] == 10 || bytes[end - 1] == 13 { end -= 1 }
        return end == start ? nil : end
    }

    private static func skipWhitespace(_ bytes: [UInt8], from start: Int) -> Int {
        var cursor = max(0, start)
        while cursor < bytes.count && (bytes[cursor] == 32 || bytes[cursor] == 9 || bytes[cursor] == 10 || bytes[cursor] == 13) { cursor += 1 }
        return cursor
    }

    private static func skipWhitespace(_ bytes: [UInt8], backwardsFrom start: Int) -> Int {
        var cursor = start
        while cursor >= 0 && (bytes[cursor] == 32 || bytes[cursor] == 9 || bytes[cursor] == 10 || bytes[cursor] == 13) { cursor -= 1 }
        return cursor
    }

    static func groupMatcher(_ group: [String: Any]) -> String? { group["matcher"] as? String }

    private static func hooksShapeIsValid(_ hooks: [String: Any]) -> Bool {
        hooks.allSatisfy { _, value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.allSatisfy { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                if let matcher = group["matcher"], !(matcher is String) { return false }
                return handlers.allSatisfy { $0["type"] as? String != nil }
            }
        }
    }

    static func handlerMatches(_ handler: [String: Any], command: String) -> Bool {
        handler["type"] as? String == "command" && handler["command"] as? String == command &&
            (handler["timeout"] as? NSNumber)?.intValue == ClaudeSetupRequirements.hookTimeout
    }

    private static func handlerIsCanonical(_ handler: [String: Any], command: String) -> Bool {
        Set(handler.keys) == ["type", "command", "timeout"] && handlerMatches(handler, command: command)
    }

    static func existingInstallationIDs(_ source: [String: Any], marker: String) -> Set<String> {
        allHandlers(source).compactMap { handler -> String? in
            guard let command = handler.command, command.hasPrefix(marker) else { return nil }
            let suffix = command.dropFirst(marker.count)
            guard suffix.first == "'" else { return nil }
            let value = String(suffix.dropFirst().prefix { $0 != "'" })
            return UUID(uuidString: value) == nil ? nil : value
        }.reduce(into: Set<String>()) { $0.insert($1) }
    }

    static func allHandlers(_ source: [String: Any]) -> [(event: String, matcher: String?, command: String?)] {
        guard let hooks = source["hooks"] as? [String: Any] else { return [] }
        return hooks.flatMap { event, value in
            (value as? [[String: Any]] ?? []).flatMap { group in
                (group["hooks"] as? [[String: Any]] ?? []).map {
                    (event: event, matcher: groupMatcher(group), command: $0["command"] as? String)
                }
            }
        }
    }

    static func hasChangedOwnedHook(_ source: [String: Any], expected: [ClaudeOwnedHook], marker: String) -> Bool {
        let handlers = allHandlers(source)
        let commands = Set(expected.map(\.command))
        return handlers.contains { entry in
            guard let command = entry.command, command.hasPrefix(marker) else { return false }
            guard commands.contains(command),
                  let owned = expected.first(where: { $0.command == command && $0.event == entry.event && $0.matcher == entry.matcher }) else {
                return true
            }
            return !handlerIsExact(source, event: owned.event, matcher: owned.matcher, command: owned.command)
                && !handlerIsLegacy(source, event: owned.event, matcher: owned.matcher, command: owned.command)
        }
    }

    private static func handlerIsExact(_ source: [String: Any], event: String, matcher: String?, command: String) -> Bool {
        guard let hooks = source["hooks"] as? [String: Any], let groups = hooks[event] as? [[String: Any]] else { return false }
        return groups.contains { groupMatcher($0) == matcher &&
            ($0["hooks"] as? [[String: Any]])?.contains(where: { handlerIsCanonical($0, command: command) }) == true }
    }

    static func handlerIsLegacy(_ handler: [String: Any], command: String) -> Bool {
        Set(handler.keys) == ["type", "command", "timeout"]
            && handler["type"] as? String == "command"
            && handler["command"] as? String == command
            && (handler["timeout"] as? NSNumber)?.intValue == ClaudeSetupRequirements.previousHookTimeout
    }

    private static func handlerIsLegacy(_ source: [String: Any], event: String, matcher: String?, command: String) -> Bool {
        guard let hooks = source["hooks"] as? [String: Any], let groups = hooks[event] as? [[String: Any]] else { return false }
        return groups.contains { groupMatcher($0) == matcher &&
            ($0["hooks"] as? [[String: Any]])?.contains(where: { handlerIsLegacy($0, command: command) }) == true }
    }

    private static func empty(_ status: ClaudeSetupStatus, settings: Data, settingsExisted: Bool) -> ClaudeSetupPlan {
        ClaudeSetupPlan(status: status, settingsChange: settings, ownedHooks: [], ownedEnvironment: [:], helperCommand: "",
                        requiresConfigure: false, installationID: "", usageEnabled: false, usageStatus: .off,
                        originalSettings: settings, originalSettingsExisted: settingsExisted)
    }
}

public enum ClaudeSetupError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case conflict(String)
    case failed(String)
    case rollbackIncomplete(String)

    public var description: String {
        switch self {
        case .conflict(let value), .failed(let value), .rollbackIncomplete(let value): value
        }
    }

    public var errorDescription: String? { description }
}

private struct ClaudeInstallState: Codable {
    let rootPath: String
    let helper: Data
    let installationID: String
    let ownedHooks: [ClaudeOwnedHook]
    let ownedEnvironment: [String: String]
    let installedSettings: Data
    let originalSettings: Data?
    let installedAt: TimeInterval
    let backupDirectory: String?
    let usageEnabled: Bool
    let environmentOwnershipRecorded: Bool
    let originalStatusLine: Data?
    let installedStatusLine: Data?

    private enum CodingKeys: String, CodingKey {
        case rootPath, helper, installationID, ownedHooks, ownedEnvironment, installedSettings,
             originalSettings, installedAt, backupDirectory, usageEnabled, environmentOwnershipRecorded,
             originalStatusLine, installedStatusLine
    }

    init(rootPath: String, helper: Data, installationID: String, ownedHooks: [ClaudeOwnedHook],
         ownedEnvironment: [String: String], installedSettings: Data, originalSettings: Data?,
         installedAt: TimeInterval, backupDirectory: String?, usageEnabled: Bool,
         originalStatusLine: Data? = nil, installedStatusLine: Data? = nil,
         environmentOwnershipRecorded: Bool = true) {
        self.rootPath = rootPath
        self.helper = helper
        self.installationID = installationID
        self.ownedHooks = ownedHooks
        self.ownedEnvironment = ownedEnvironment
        self.installedSettings = installedSettings
        self.originalSettings = originalSettings
        self.installedAt = installedAt
        self.backupDirectory = backupDirectory
        self.usageEnabled = usageEnabled
        self.environmentOwnershipRecorded = environmentOwnershipRecorded
        self.originalStatusLine = originalStatusLine
        self.installedStatusLine = installedStatusLine
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        helper = try container.decode(Data.self, forKey: .helper)
        installationID = try container.decode(String.self, forKey: .installationID)
        ownedHooks = try container.decode([ClaudeOwnedHook].self, forKey: .ownedHooks)
        installedSettings = try container.decode(Data.self, forKey: .installedSettings)
        originalSettings = try container.decodeIfPresent(Data.self, forKey: .originalSettings)
        let storedOwnedEnvironment = try container.decodeIfPresent([String: String].self, forKey: .ownedEnvironment)
        let ownershipRecorded = try container.decodeIfPresent(Bool.self, forKey: .environmentOwnershipRecorded) ?? false
        if ownershipRecorded, let storedOwnedEnvironment {
            ownedEnvironment = storedOwnedEnvironment
        } else if let storedOwnedEnvironment {
            // Versions before ownership tracking recorded a pre-existing matching env value
            // as Steer-owned. The original snapshot is sufficient to correct that record.
            if let originalSettings,
               let original = try? ClaudeSetupPlanner.jsonObject(originalSettings),
               (original["env"] as? [String: Any])?[ClaudeSetupRequirements.titleDisableEnvironmentKey] as? String
                   == ClaudeSetupRequirements.titleDisableEnvironmentValue {
                ownedEnvironment = [:]
            } else {
                ownedEnvironment = storedOwnedEnvironment
            }
        } else {
            ownedEnvironment = [ClaudeSetupRequirements.titleDisableEnvironmentKey: ClaudeSetupRequirements.titleDisableEnvironmentValue]
        }
        installedAt = try container.decode(TimeInterval.self, forKey: .installedAt)
        backupDirectory = try container.decodeIfPresent(String.self, forKey: .backupDirectory)
        usageEnabled = try container.decodeIfPresent(Bool.self, forKey: .usageEnabled) ?? false
        environmentOwnershipRecorded = ownershipRecorded
        originalStatusLine = try container.decodeIfPresent(Data.self, forKey: .originalStatusLine)
        installedStatusLine = try container.decodeIfPresent(Data.self, forKey: .installedStatusLine)
    }
}

public struct ClaudeSetupInstaller {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func install(_ plan: ClaudeSetupPlan, roots: ClaudeSetupRoots, helper: Data,
                        capabilities: ClaudeCapabilities) throws -> ClaudeConnectionStatus {
        guard case .ready = plan.status else { throw ClaudeSetupError.failed("Setup preview is not ready.") }
        guard !helper.isEmpty else { throw ClaudeSetupError.failed("The bundled Steer helper is unavailable.") }
        let currentSettings = try readableData(at: roots.settingsURL)
        let current = currentSettings ?? Data("{}" .utf8)
        var settingsChange = plan.settingsChange
        let existingState: ClaudeInstallState?
        if fileManager.fileExists(atPath: roots.stateURL.path) {
            guard let state = try? readState(roots) else {
                throw ClaudeSetupError.conflict("Steer Claude setup state is missing or inconsistent; review setup before changing this root.")
            }
            guard state.rootPath == roots.configDirectory.path,
                  UUID(uuidString: state.installationID) != nil else {
                throw ClaudeSetupError.conflict("Steer Claude setup belongs to a different configuration root; review setup before changing this root.")
            }
            existingState = state
        } else {
            existingState = nil
        }
        if !plan.usageEnabled, let state = existingState,
           state.installedStatusLine != state.originalStatusLine {
            guard let restored = try removingStatusLine(settingsChange, original: state.originalStatusLine) else {
                throw ClaudeSetupError.conflict("Claude settings.json could not remove Steer's usage status line.")
            }
            settingsChange = restored
        }
        if plan.usageEnabled, plan.usageStatus == .ready,
           let original = try? ClaudeSetupPlanner.jsonObject(plan.originalSettings),
           let existingCommand = ClaudeStatusLineBridge.statusLineCommand(original["statusLine"]),
           !ClaudeStatusLineBridge.isBridgeCommand(existingCommand),
           !ClaudeStatusLineCompatibility.probe(command: existingCommand),
           original["statusLine"] != nil,
           let restored = ClaudeSetupPlanner.restoreMemberBytes(settingsChange, from: plan.originalSettings, key: "statusLine") {
            settingsChange = restored
        }
        if let state = existingState, current != state.installedSettings,
           let object = try? ClaudeSetupPlanner.jsonObject(current) {
            if case .changed = ownedHookState(object, expected: state.ownedHooks) {
                throw ClaudeSetupError.conflict("A Steer-owned Claude hook was changed; review setup before repair.")
            }
            if case .changed = ownedEnvironmentState(object, expected: state.ownedEnvironment) {
                throw ClaudeSetupError.conflict("Steer's terminal title setting was changed; review setup before repair.")
            }
            if let installed = state.installedStatusLine {
                guard let currentStatusLine = ClaudeSetupPlanner.memberData(current, key: "statusLine"),
                      currentStatusLine == installed else {
                    throw ClaudeSetupError.conflict("Steer's Claude usage status line was changed; review setup before repair.")
                }
            }
        }
        if current == settingsChange,
           (try? readableData(at: roots.helperURL)) == helper,
           let state = existingState, state.rootPath == roots.configDirectory.path,
           state.installationID == plan.installationID {
            return status(roots: roots, capabilities: capabilities)
        }
        guard current == plan.originalSettings else {
            throw ClaudeSetupError.conflict("Claude settings changed after the preview. Review setup again.")
        }
        if let existingHelper = try readableData(at: roots.helperURL), existingHelper != helper {
            throw ClaudeSetupError.conflict("A different file already exists at Steer's Claude helper path.")
        }
        for directory in [roots.configDirectory, roots.helperDirectory, roots.eventsDirectory, roots.usageDirectory]
            where fileManager.fileExists(atPath: directory.path) && !isDirectory(at: directory) {
            throw ClaudeSetupError.conflict("Claude setup path \(directory.path) is not a regular directory; it was not changed.")
        }
        try fileManager.createDirectory(at: roots.configDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: roots.helperDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: roots.eventsDirectory, withIntermediateDirectories: true)
        if plan.usageEnabled, plan.usageStatus == .ready {
            try fileManager.createDirectory(at: roots.usageDirectory, withIntermediateDirectories: true)
        }
        let backupDirectory = roots.backupsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oldSettings = currentSettings
        let oldHelper = try readableData(at: roots.helperURL)
        do {
            if current != settingsChange { try backup(oldSettings, named: "settings.json", in: backupDirectory) }
            if oldHelper != helper { try backup(oldHelper, named: "SteerHook", in: backupDirectory) }
            if oldHelper != helper {
                try atomicWrite(helper, to: roots.helperURL)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roots.helperURL.path)
            }
            if current != settingsChange { try atomicWrite(settingsChange, to: roots.settingsURL) }
            let ownedEnvironment: [String: String]
            if let existingState, !existingState.ownedEnvironment.isEmpty {
                ownedEnvironment = existingState.ownedEnvironment
            } else {
                ownedEnvironment = plan.ownedEnvironment
            }
            let state = ClaudeInstallState(rootPath: roots.configDirectory.path, helper: helper,
                                           installationID: plan.installationID, ownedHooks: plan.ownedHooks,
                                           ownedEnvironment: ownedEnvironment,
                                           installedSettings: settingsChange,
                                           originalSettings: existingState?.originalSettings ?? (plan.originalSettingsExisted ? plan.originalSettings : nil),
                                           installedAt: Date().timeIntervalSince1970,
                                           backupDirectory: existingState?.backupDirectory ?? backupDirectory.lastPathComponent,
                                           usageEnabled: plan.usageEnabled,
                                           originalStatusLine: existingState?.originalStatusLine
                                               ?? ClaudeSetupPlanner.memberData(plan.originalSettings, key: "statusLine"),
                                           installedStatusLine: ClaudeSetupPlanner.memberData(settingsChange, key: "statusLine"))
            try atomicWrite(try JSONEncoder().encode(state), to: roots.stateURL)
        } catch let error {
            do {
                try restore(oldSettings, to: roots.settingsURL)
                try restore(oldHelper, to: roots.helperURL)
            } catch let rollbackError {
                throw ClaudeSetupError.rollbackIncomplete("Setup failed (\(error)); rollback also failed (\(rollbackError)). Check the affected files before retrying.")
            }
            throw ClaudeSetupError.failed("Setup was not completed; the original configuration was restored.")
        }
        return status(roots: roots, capabilities: capabilities)
    }

    public func status(roots: ClaudeSetupRoots, capabilities: ClaudeCapabilities) -> ClaudeConnectionStatus {
        guard capabilities.supported else {
            return .unsupported("Claude Code \(capabilities.version ?? "version unknown") is older than the tested minimum \(ClaudeSetupRequirements.minimumCLIVersion).")
        }
        guard fileManager.fileExists(atPath: roots.stateURL.path) else {
            if let settings = try? readableData(at: roots.settingsURL),
               let object = try? ClaudeSetupPlanner.jsonObject(settings),
               !ClaudeSetupPlanner.existingInstallationIDs(object, marker: ClaudeSetupPlanner.ownershipMarker(helperPath: roots.helperURL, eventsPath: roots.eventsDirectory)).isEmpty {
                return .conflict("Steer Claude setup state is missing; review this root's settings.json before reconnecting.")
            }
            return .notConfigured
        }
        guard let state = try? readState(roots), state.rootPath == roots.configDirectory.path,
              UUID(uuidString: state.installationID) != nil else {
            return .conflict("Steer Claude setup state is missing or inconsistent; review setup before changing this root.")
        }
        guard let settings = try? readableData(at: roots.settingsURL),
              let object = try? ClaudeSetupPlanner.jsonObject(settings) else {
            return .malformed("Claude settings.json is missing or unreadable.")
        }
        if object["allowManagedHooksOnly"] as? Bool == true {
            return .blockedByPolicy("Claude managed policy allows only managed hooks; Steer cannot verify user hooks.")
        }
        guard let helper = try? readableData(at: roots.helperURL) else {
            return .repairRequired("Steer's Claude helper is missing; Configure Claude to repair setup.")
        }
        guard helper == state.helper else {
            return .conflict("Steer's Claude helper differs from the one it installed; review setup before repair.")
        }
        switch titleEnvironmentState(object) {
        case .changed: return .conflict("Claude's automatic terminal title setting was changed; review setup before repair.")
        case .missing: return .repairRequired("Steer's terminal title setting is missing; Configure Claude to repair setup.")
        case .intact: break
        }
        switch ownedEnvironmentState(object, expected: state.ownedEnvironment) {
        case .changed: return .conflict("Steer's terminal title setting was changed; review setup before repair.")
        case .missing: return .repairRequired("Steer's terminal title setting is missing; Configure Claude to repair setup.")
        case .intact: break
        }
        if let installed = state.installedStatusLine {
            guard let currentStatusLine = ClaudeSetupPlanner.memberData(settings, key: "statusLine") else {
                return .repairRequired("Steer's Claude usage status line is missing; Configure Claude to repair setup.")
            }
            guard currentStatusLine == installed else {
                return .conflict("Steer's Claude usage status line was changed; review setup before repair.")
            }
        }
        switch ownedHookState(object, expected: state.ownedHooks) {
        case .changed: return .conflict("A Steer-owned Claude hook was changed; review setup before repair.")
        case .missing: return .repairRequired("Steer's Claude hook entries are missing; Configure Claude to repair setup.")
        case .intact: break
        }
        guard fileManager.fileExists(atPath: roots.eventsDirectory.path) else {
            return .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Existing sessions keep running without Steer's hooks.")
        }
        let files: [URL]
        do { files = try boundedContents(of: roots.eventsDirectory) }
        catch {
            return .unavailable("Steer's Claude events directory is not readable.")
        }
        let now = Date().timeIntervalSince1970
        return files.contains(where: { validEvent($0, installationID: state.installationID, installedAt: state.installedAt, now: now) })
            ? .connected
            : .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Existing sessions keep running without Steer's hooks.")
    }

    public func isInstallRecordValid(for roots: ClaudeSetupRoots) -> Bool {
        guard let state = try? readState(roots), state.rootPath == roots.configDirectory.path,
              UUID(uuidString: state.installationID) != nil else { return false }
        return true
    }

    public func usageStatus(for roots: ClaudeSetupRoots, requested: Bool,
                            planned: ClaudeUsageSetupStatus? = nil) -> ClaudeUsageSetupStatus {
        guard requested else { return .off }
        guard let state = try? readState(roots) else { return planned ?? .unavailable("Claude usage is unavailable until Claude setup is connected.") }
        guard let installed = state.installedStatusLine else {
            return .unavailable("Claude usage unavailable: the status-line compatibility probe did not pass; Claude connection remains active.")
        }
        guard let settings = try? readableData(at: roots.settingsURL),
              let current = ClaudeSetupPlanner.memberData(settings, key: "statusLine") else {
            return .conflict("Claude usage unavailable: Steer's status line is missing; review setup before repair.")
        }
        guard current == installed else {
            return .conflict("Claude usage unavailable: Steer's status line was changed; review setup before repair.")
        }
        if installed == state.originalStatusLine {
            return .unavailable("Claude usage unavailable: the status-line compatibility probe did not pass; Claude connection remains active.")
        }
        return .ready
    }

    public func installedAt(for roots: ClaudeSetupRoots) -> TimeInterval? {
        guard let state = try? readState(roots), state.rootPath == roots.configDirectory.path,
              UUID(uuidString: state.installationID) != nil else { return nil }
        return state.installedAt
    }

    public func deliveredSessionIDs(for roots: ClaudeSetupRoots, now: TimeInterval = Date().timeIntervalSince1970) -> Set<String> {
        guard let state = try? readState(roots), state.rootPath == roots.configDirectory.path,
              UUID(uuidString: state.installationID) != nil,
              let files = try? boundedContents(of: roots.eventsDirectory) else { return [] }
        return Set(files.compactMap { url in
            guard validEvent(url, installationID: state.installationID, installedAt: state.installedAt, now: now),
                  let data = boundedData(at: url, maximum: 64 * 1024),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["session_id"] as? String
        })
    }

    public func undo(roots: ClaudeSetupRoots) throws -> ClaudeConnectionStatus {
        let state = try readState(roots)
        guard state.rootPath == roots.configDirectory.path else {
            throw ClaudeSetupError.conflict("Steer Claude setup belongs to a different configuration root; undo made no changes.")
        }
        guard let current = try readableData(at: roots.settingsURL),
              let object = try? ClaudeSetupPlanner.jsonObject(current) else {
            throw ClaudeSetupError.conflict("Claude settings.json is missing or unreadable; undo made no changes.")
        }
        if let helper = try readableData(at: roots.helperURL), helper != state.helper {
            throw ClaudeSetupError.conflict("A different file sits at Steer's Claude helper path; undo made no changes.")
        }
        switch ownedEnvironmentState(object, expected: state.ownedEnvironment) {
        case .changed: throw ClaudeSetupError.conflict("Steer's terminal title setting was changed; undo made no changes.")
        case .intact, .missing: break
        }
        if let installed = state.installedStatusLine {
            guard let currentStatusLine = ClaudeSetupPlanner.memberData(current, key: "statusLine"),
                  currentStatusLine == installed else {
                throw ClaudeSetupError.conflict("Steer's Claude usage status line was changed; undo made no changes.")
            }
        }
        switch ownedHookState(object, expected: state.ownedHooks) {
        case .changed: throw ClaudeSetupError.conflict("A Steer-owned Claude hook was changed; undo made no changes.")
        case .intact, .missing: break
        }
        var restored: Data?
        if current == state.installedSettings {
            restored = state.originalSettings
        } else {
            let reducedHooks = removingHooks(object, owned: state.ownedHooks)
            let reducedEnvironment = removingEnvironment(reducedHooks, owned: state.ownedEnvironment)
            let withoutHooks = try ClaudeSetupPlanner.jsonDataPreservingOtherBytes(current, hooks: reducedEnvironment["hooks"] as? [String: Any])
            if state.ownedEnvironment.isEmpty {
                restored = withoutHooks
            } else if let environment = reducedEnvironment["env"] as? [String: Any], !environment.isEmpty {
                restored = try ClaudeSetupPlanner.jsonDataPreservingNestedMember(
                    withoutHooks, parentKey: "env",
                    key: ClaudeSetupRequirements.titleDisableEnvironmentKey,
                    value: nil)
            } else {
                restored = try ClaudeSetupPlanner.jsonDataPreservingMember(withoutHooks, key: "env", value: nil)
            }
            if state.installedStatusLine != nil {
                restored = try removingStatusLine(restored, original: state.originalStatusLine)
            }
        }
        let originalState = try readableData(at: roots.stateURL)
        let eventFiles = try boundedContents(of: roots.eventsDirectory)
        let now = Date().timeIntervalSince1970
        let ownedEvents = eventFiles.filter { validEvent($0, installationID: state.installationID, installedAt: state.installedAt, now: now) }
        let usageFiles = (try? boundedContents(of: roots.usageDirectory)) ?? []
        let backup = try validatedBackupURL(for: state, roots: roots)
        if fileManager.fileExists(atPath: roots.helperURL.path), !isRegularFile(at: roots.helperURL) {
            throw ClaudeSetupError.conflict("Steer's Claude helper path is not a regular file; undo made no changes.")
        }
        do {
            try restore(restored, to: roots.settingsURL)
            if fileManager.fileExists(atPath: roots.helperURL.path) {
                try fileManager.removeItem(at: roots.helperURL)
            }
            try fileManager.removeItem(at: roots.stateURL)
            for event in ownedEvents { try fileManager.removeItem(at: event) }
            for usageFile in usageFiles where isRegularFile(at: usageFile) { try fileManager.removeItem(at: usageFile) }
            if let backup { try fileManager.removeItem(at: backup) }
            try removeDirectoryIfEmpty(roots.usageDirectory)
            try removeDirectoryIfEmpty(roots.helperDirectory)
        } catch let error {
            do {
                try restore(current, to: roots.settingsURL)
                try restore(state.helper, to: roots.helperURL)
                if let originalState { try atomicWrite(originalState, to: roots.stateURL) }
            } catch let rollbackError {
                throw ClaudeSetupError.rollbackIncomplete("Undo failed (\(error)); rollback also failed (\(rollbackError)). Check the affected files before retrying.")
            }
            throw ClaudeSetupError.failed("Undo was not completed; the installed configuration was restored.")
        }
        return .notConfigured
    }

    private enum OwnedHookState { case intact, missing, changed }

    private enum OwnedEnvironmentState { case intact, missing, changed }

    private func removingStatusLine(_ settings: Data?, original: Data?) throws -> Data? {
        guard let settings else { return nil }
        let value = original.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return try ClaudeSetupPlanner.jsonDataPreservingMember(settings, key: "statusLine", value: value)
    }

    private func titleEnvironmentState(_ source: [String: Any]) -> OwnedEnvironmentState {
        guard let environment = source["env"] as? [String: Any],
              let value = environment[ClaudeSetupRequirements.titleDisableEnvironmentKey] else { return .missing }
        return (value as? String) == ClaudeSetupRequirements.titleDisableEnvironmentValue ? .intact : .changed
    }

    private func ownedEnvironmentState(_ source: [String: Any], expected: [String: String]) -> OwnedEnvironmentState {
        guard !expected.isEmpty else { return .intact }
        guard let environment = source["env"] as? [String: Any] else { return .missing }
        var missing = false
        for (key, value) in expected {
            guard let actual = environment[key] else { missing = true; continue }
            guard actual as? String == value else { return .changed }
        }
        return missing ? .missing : .intact
    }

    private func ownedHookState(_ source: [String: Any], expected: [ClaudeOwnedHook]) -> OwnedHookState {
        guard let hooks = source["hooks"] as? [String: Any] else { return .missing }
        var missing = false
        for owned in expected {
            let groups = hooks[owned.event] as? [[String: Any]] ?? []
            let exact = groups.filter { group in
                ClaudeSetupPlanner.groupMatcher(group) == owned.matcher &&
                (group["hooks"] as? [[String: Any]])?.contains(where: { handler in
                    ClaudeSetupPlanner.handlerMatches(handler, command: owned.command) && handlerMatchesInstalled(handler, owned: owned)
                }) == true
            }
            if exact.count == 1 { continue }
            if exact.count > 1 { return .changed }
            if let groupIndex = owned.groupIndex, let handlerIndex = owned.handlerIndex,
               groupIndex < groups.count,
               let handlers = groups[groupIndex]["hooks"] as? [[String: Any]], handlerIndex < handlers.count {
                return .changed
            }
            let commandExists = groups.contains { ($0["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == owned.command } == true }
            if commandExists {
                let legacyExists = groups.contains { group in
                    ClaudeSetupPlanner.groupMatcher(group) == owned.matcher
                        && (group["hooks"] as? [[String: Any]])?.contains(where: { ClaudeSetupPlanner.handlerIsLegacy($0, command: owned.command) }) == true
                }
                return legacyExists ? .missing : .changed
            }
            missing = true
        }
        return missing ? .missing : .intact
    }

    private func handlerMatchesInstalled(_ handler: [String: Any], owned: ClaudeOwnedHook) -> Bool {
        guard let expected = owned.handlerData else { return true }
        guard let actual = try? JSONSerialization.data(withJSONObject: handler, options: [.sortedKeys]) else { return false }
        return actual == expected
    }

    private func removingHooks(_ source: [String: Any], owned: [ClaudeOwnedHook]) -> [String: Any] {
        var result = source
        guard var hooks = source["hooks"] as? [String: Any] else { return source }
        for ownedHook in owned {
            guard let groups = hooks[ownedHook.event] as? [[String: Any]] else { continue }
            var keptGroups: [[String: Any]] = []
            for var group in groups {
                guard ClaudeSetupPlanner.groupMatcher(group) == ownedHook.matcher,
                      let nested = group["hooks"] as? [[String: Any]] else { keptGroups.append(group); continue }
                let remaining = nested.filter { !ClaudeSetupPlanner.handlerMatches($0, command: ownedHook.command) }
                if remaining.count == nested.count { keptGroups.append(group) }
                else if !remaining.isEmpty { group["hooks"] = remaining; keptGroups.append(group) }
            }
            if keptGroups.isEmpty { hooks.removeValue(forKey: ownedHook.event) }
            else { hooks[ownedHook.event] = keptGroups }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }

    private func removingEnvironment(_ source: [String: Any], owned: [String: String]) -> [String: Any] {
        guard var environment = source["env"] as? [String: Any] else { return source }
        for (key, value) in owned where environment[key] as? String == value {
            environment.removeValue(forKey: key)
        }
        var result = source
        if environment.isEmpty { result.removeValue(forKey: "env") }
        else { result["env"] = environment }
        return result
    }

    private func readState(_ roots: ClaudeSetupRoots) throws -> ClaudeInstallState {
        guard let data = try readableData(at: roots.stateURL) else { throw ClaudeSetupError.failed("Steer Claude setup is not installed.") }
        return try JSONDecoder().decode(ClaudeInstallState.self, from: data)
    }

    private func validEvent(_ url: URL, installationID: String, installedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard let data = boundedData(at: url, maximum: 64 * 1024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["hook_event_name"] as? String == "SessionStart",
              object["session_start_source"] as? String == "startup",
              object["source"] as? String == ClaudeSetupRequirements.helperSource,
              object["installation_id"] as? String == installationID,
              let session = object["session_id"] as? String, !session.isEmpty,
              let received = object["received_at"] as? String, !received.isEmpty,
              let captured = object["captured_at"] as? NSNumber else { return false }
        return captured.doubleValue.isFinite && captured.doubleValue >= installedAt - 1 &&
            captured.doubleValue <= now + ClaudeSetupRequirements.metadataClockSkew
    }

    private func readableData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard isRegularFile(at: url), let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 20 * 1024 * 1024 + 1), data.count <= 20 * 1024 * 1024 else {
            throw ClaudeSetupError.conflict("\(url.lastPathComponent) is missing, unreadable, or too large; it was not changed.")
        }
        try? handle.close()
        return data
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

    private func boundedContents(of url: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        guard isDirectory(at: url) else { throw ClaudeSetupError.conflict("\(url.lastPathComponent) is not a directory.") }
        let files = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        guard files.count <= 4096 else { throw ClaudeSetupError.conflict("\(url.lastPathComponent) contains too many entries to inspect safely.") }
        return files
    }

    private func validatedBackupURL(for state: ClaudeInstallState, roots: ClaudeSetupRoots) throws -> URL? {
        guard let name = state.backupDirectory else { return nil }
        guard name != ".", name != "..", !name.contains("/") else {
            throw ClaudeSetupError.conflict("Steer Claude setup backup identity is invalid; undo made no changes.")
        }
        let url = roots.backupsURL.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard isDirectory(at: url) else {
            throw ClaudeSetupError.conflict("Steer Claude setup backup is not a directory; undo made no changes.")
        }
        let files = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        let expected: [String: Data] = state.originalSettings.map { ["settings.json": $0] } ?? [:]
        guard files.count == expected.count,
              files.allSatisfy({ expected[$0.lastPathComponent] == boundedData(at: $0, maximum: 20 * 1024 * 1024) }) else {
            throw ClaudeSetupError.conflict("Steer Claude setup backup changed; undo made no changes.")
        }
        return url
    }

    private func backup(_ data: Data?, named: String, in directory: URL) throws {
        guard let data else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try atomicWrite(data, to: directory.appendingPathComponent(named))
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func restore(_ data: Data?, to url: URL) throws {
        if let data { try atomicWrite(data, to: url) }
        else if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func removeDirectoryIfEmpty(_ url: URL) throws {
        guard isDirectory(at: url),
              (try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)).isEmpty else { return }
        try fileManager.removeItem(at: url)
    }
}
