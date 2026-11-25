import Foundation

public struct ClaudeCapabilities: Equatable, Sendable {
    public let installed: Bool
    public let supported: Bool
    public let version: String?
    /// The detected `claude` executable, which runs `claude update`.
    public let executablePath: String?

    public init(installed: Bool, supported: Bool, version: String? = nil, executablePath: String? = nil) {
        self.installed = installed
        self.supported = supported
        self.version = version
        self.executablePath = executablePath
    }
}

public struct ClaudeSetupPolicy: Equatable, Sendable {
    public let managedHooksOnly: Bool
    public let shadowedBy: String?
    /// Whether setup needs `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`. Only Ghostty without `tty` binds Claude
    /// by its "Herdly Claude <id>" title (ADR 0013); every other host binds by tty. Claude also reads the
    /// setting as "send no OSC 7501 program status", which hides its sessions from hosts that list agents
    /// by that status (the Herdr app), so setup asks for it only when the title is the binding.
    public let titleSettingRequired: Bool

    public init(managedHooksOnly: Bool = false, shadowedBy: String? = nil, titleSettingRequired: Bool = true) {
        self.managedHooksOnly = managedHooksOnly
        self.shadowedBy = shadowedBy
        self.titleSettingRequired = titleSettingRequired
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
    public static let helperSource = "herdly-claude-hook-v1"
    /// Timeouts written by earlier Herdly builds; setup upgrades them in place.
    public static let previousHookTimeouts = [10, 38]
    /// Covers the companion connection wait, one decision window with its longest hover hold
    /// (ADR 0020), and a small bound.
    public static let hookTimeout = Int(ApprovalTiming.helperWaitBound + ApprovalTiming.connectionTimeout + 2)
    public static let titlePrefix = "Herdly Claude "
    public static let titleDisableEnvironmentKey = "CLAUDE_CODE_DISABLE_TERMINAL_TITLE"
    public static let titleDisableEnvironmentValue = "1"

    /// True only when an installed Ghostty cannot report terminal ttys, so Claude tabs there bind by title.
    /// No Ghostty, or one that reports ttys, binds Claude by tty and needs no title setting.
    public static func titleSettingRequired(ghosttyInstalled: Bool, ttySupport: GhosttyTTYSupport) -> Bool {
        ghosttyInstalled && ttySupport == .unsupported
    }
    public static let metadataClockSkew: TimeInterval = 300

    /// The events needed by the observer and the Bash, file, and web decision slices. Other permission
    /// families stay in Claude's native flow. Each later family has its own `PermissionRequest` entry so
    /// an existing install's exact earlier entries stay unchanged.
    public static let hookDefinitions = [
        ClaudeHookDefinition(event: "SessionStart", terminalTitle: true),
        ClaudeHookDefinition(event: "UserPromptSubmit"),
        ClaudeHookDefinition(event: "PreToolUse"),
        ClaudeHookDefinition(event: "PreToolUse", matcher: "AskUserQuestion", questionHelper: true),
        ClaudeHookDefinition(event: "PostToolUse"),
        ClaudeHookDefinition(event: "PostToolUseFailure"),
        ClaudeHookDefinition(event: "PostToolBatch"),
        ClaudeHookDefinition(event: "PermissionRequest", matcher: "Bash"),
        ClaudeHookDefinition(event: "PermissionRequest", matcher: ClaudeDirectApproval.fileMatcher),
        ClaudeHookDefinition(event: "PermissionRequest", matcher: ClaudeDirectApproval.webMatcher),
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

extension ClaudeConnectionStatus {
    public var isAwaitingRestart: Bool {
        if case .configuredAwaitingRestart = self { return true }
        return false
    }

    /// Whether Configure Claude would change anything. A root awaiting restart is already installed and
    /// needs only a new session, so it offers Configure only when the plan has settings to write or the
    /// usage choice differs from what is installed.
    public func offersConfigure(requiresConfigure: Bool, usageMatches: Bool) -> Bool {
        if requiresConfigure || !usageMatches { return true }
        return self != .connected && !isAwaitingRestart
    }

    /// Whether Undo Setup is offered: only once the root's setup preview is ready and Herdly's setup
    /// is present in some form.
    public func offersUndo(planReady: Bool) -> Bool {
        planReady && self != .notConfigured
    }
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
    public var helperURL: URL { helperDirectory.appendingPathComponent("HerdlyHook") }
    public var stateURL: URL { helperDirectory.appendingPathComponent("install.json") }
    public var backupsURL: URL { helperDirectory.appendingPathComponent("backups", isDirectory: true) }
    public var usageDirectory: URL { helperDirectory.appendingPathComponent("usage", isDirectory: true) }
    /// Herdly's own record that an automatic usage upgrade failed and could not roll back, kept beside
    /// the install record (never in the user's Claude folder) until Configure or Undo Setup succeeds.
    public var usageRollbackURL: URL { helperDirectory.appendingPathComponent("usage-rollback-incomplete") }
}

public struct ClaudeSetupPlan: Equatable, Sendable {
    public let status: ClaudeSetupStatus
    public let settingsChange: Data
    public let ownedHooks: [ClaudeOwnedHook]
    public let ownedEnvironment: [String: String]
    public let helperCommand: String
    public let requiresConfigure: Bool
    /// True when Configure would change settings other than the usage status line, which detection
    /// adds on its own to an installed folder (`ClaudeSetupInstaller.upgradeUsage`).
    public let changesBeyondUsage: Bool
    /// True when Configure would add a Herdly hook entry the settings do not have yet, such as a newer
    /// release's file-approval hook on an already connected root.
    public let addsHooks: Bool
    public let installationID: String
    public let usageEnabled: Bool
    public let usageStatus: ClaudeUsageSetupStatus
    /// The policy's `titleSettingRequired`, carried so install checks the same requirement the preview used.
    public let titleSettingRequired: Bool

    let originalSettings: Data
    let originalSettingsExisted: Bool

    init(status: ClaudeSetupStatus, settingsChange: Data, ownedHooks: [ClaudeOwnedHook],
         ownedEnvironment: [String: String],
         helperCommand: String, requiresConfigure: Bool, changesBeyondUsage: Bool? = nil, addsHooks: Bool = false,
         installationID: String,
         usageEnabled: Bool, usageStatus: ClaudeUsageSetupStatus, titleSettingRequired: Bool = true,
         originalSettings: Data, originalSettingsExisted: Bool) {
        self.status = status
        self.settingsChange = settingsChange
        self.ownedHooks = ownedHooks
        self.ownedEnvironment = ownedEnvironment
        self.helperCommand = helperCommand
        self.requiresConfigure = requiresConfigure
        self.changesBeyondUsage = changesBeyondUsage ?? requiresConfigure
        self.addsHooks = addsHooks
        self.installationID = installationID
        self.usageEnabled = usageEnabled
        self.usageStatus = usageStatus
        self.titleSettingRequired = titleSettingRequired
        self.originalSettings = originalSettings
        self.originalSettingsExisted = originalSettingsExisted
    }
}

public enum ClaudeSetupPlanner {
    public static func plan(capabilities: ClaudeCapabilities, settings: Data,
                            helperPath: URL, eventsPath: URL,
                            sourceScope: URL? = nil,
                            policy: ClaudeSetupPolicy = ClaudeSetupPolicy(), usageEnabled: Bool = false,
                            settingsExisted: Bool = true, installRecordPresent: Bool = true,
                            statusLineCompatible: Bool? = nil) -> ClaudeSetupPlan {
        guard capabilities.supported else {
            return empty(.unsupported("Claude Code \(capabilities.version ?? "version unknown") is older than the tested minimum \(ClaudeSetupRequirements.minimumCLIVersion)."), settings: settings, settingsExisted: settingsExisted)
        }
        guard let source = try? jsonObject(settings) else {
            return empty(.malformed("Claude settings.json is not valid JSON and was not changed."), settings: settings, settingsExisted: settingsExisted)
        }
        if policy.managedHooksOnly || (source["allowManagedHooksOnly"] as? Bool == true) {
            return empty(.blockedByPolicy("Claude managed policy allows only managed hooks; Herdly did not change settings."), settings: settings, settingsExisted: settingsExisted)
        }
        if let shadowedBy = policy.shadowedBy {
            return empty(.shadowed("Claude settings are shadowed by \(shadowedBy); Herdly did not change settings."), settings: settings, settingsExisted: settingsExisted)
        }
        if source["disableAllHooks"] as? Bool == true {
            return empty(.blockedByPolicy("Claude hooks are disabled by settings.json; Herdly did not change settings."), settings: settings, settingsExisted: settingsExisted)
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
        if policy.titleSettingRequired,
           let existing = (source["env"] as? [String: Any])?[ClaudeSetupRequirements.titleDisableEnvironmentKey],
           (existing as? String) != ClaudeSetupRequirements.titleDisableEnvironmentValue {
            return empty(.conflict("Claude's automatic terminal title setting is owned by another value; review settings.json before reconnecting."), settings: settings, settingsExisted: settingsExisted)
        }

        let marker = ownershipMarker(helperPath: helperPath, eventsPath: eventsPath)
        let installationIDs = existingInstallationIDs(source, marker: marker)
        guard installationIDs.count <= 1 else {
            return empty(.conflict("Multiple Herdly Claude installations were found in this root; review settings.json before reconnecting."), settings: settings, settingsExisted: settingsExisted)
        }
        guard installRecordPresent || installationIDs.isEmpty else {
            return empty(.conflict("Herdly Claude setup state is missing; review this root's settings.json before reconnecting."), settings: settings, settingsExisted: settingsExisted)
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
            return empty(.conflict("A Herdly-owned Claude hook was changed; review setup before repair."), settings: settings, settingsExisted: settingsExisted)
        }
        var merged = source
        var hooks = (source["hooks"] as? [String: Any]) ?? [:]
        var addsHooks = false
        for (definition, owned) in zip(definitions, expectedHooks) {
            var groups = (hooks[definition.event] as? [[String: Any]]) ?? []
            let exact = groups.filter { group in
                groupMatcher(group) == definition.matcher &&
                (group["hooks"] as? [[String: Any]])?.contains(where: { handlerMatches($0, command: owned.command) }) == true
            }
            if exact.count > 1 {
                return empty(.conflict("Duplicate Herdly-owned Claude hooks were found; review settings.json before reconnecting."), settings: settings, settingsExisted: settingsExisted)
            }
            if exact.isEmpty {
                // Several definitions share one command under different matchers (PermissionRequest),
                // so an upgrade must match the matcher too or those siblings read as duplicates.
                let legacy = groups.enumerated().filter { _, group in
                    groupMatcher(group) == definition.matcher &&
                    (group["hooks"] as? [[String: Any]])?.contains(where: { handlerIsLegacy($0, command: owned.command) }) == true
                }
                if legacy.count > 1 {
                    return empty(.conflict("Duplicate Herdly-owned Claude hooks were found; review settings.json before reconnecting."), settings: settings, settingsExisted: settingsExisted)
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
                addsHooks = true
            }
            hooks[definition.event] = groups
        }
        merged["hooks"] = hooks
        var environment = (source["env"] as? [String: Any]) ?? [:]
        // Not required: whatever settings.json holds for the key stays as it is, and Herdly owns nothing new.
        let titleEnvironmentAlreadyPresent = !policy.titleSettingRequired
            || environment[ClaudeSetupRequirements.titleDisableEnvironmentKey] as? String
                == ClaudeSetupRequirements.titleDisableEnvironmentValue
        if policy.titleSettingRequired {
            environment[ClaudeSetupRequirements.titleDisableEnvironmentKey] = ClaudeSetupRequirements.titleDisableEnvironmentValue
            merged["env"] = environment
        }
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
              let changedBase = policy.titleSettingRequired
                  ? try? jsonDataPreservingEnvironment(hooksChanged, original: source["env"], value: environment)
                  : hooksChanged else {
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
                : (statusLineCompatible == true
                    ? .ready : .unavailable(ClaudeUsageSetupStatus.compatibilityFailureMessage))
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
                               changesBeyondUsage: changedBase != settings, addsHooks: addsHooks,
                               installationID: installationID, usageEnabled: usageEnabled, usageStatus: usage,
                               titleSettingRequired: policy.titleSettingRequired,
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
            && ClaudeSetupRequirements.previousHookTimeouts.contains((handler["timeout"] as? NSNumber)?.intValue ?? 0)
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
    var helper: Data
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
            // as Herdly-owned. The original snapshot is sufficient to correct that record.
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
    /// Runs before each atomic write, so tests can make a chosen write fail.
    private let beforeWrite: (@Sendable (URL) throws -> Void)?

    public init(fileManager: FileManager = .default, beforeWrite: (@Sendable (URL) throws -> Void)? = nil) {
        self.fileManager = fileManager
        self.beforeWrite = beforeWrite
    }

    /// Configure. Success also clears a stuck usage-rollback record, since the folder's settings are
    /// then exactly what setup wrote.
    public func install(_ plan: ClaudeSetupPlan, roots: ClaudeSetupRoots, helper: Data,
                        capabilities: ClaudeCapabilities) throws -> ClaudeConnectionStatus {
        let status = try performInstall(plan, roots: roots, helper: helper, capabilities: capabilities)
        clearUsageRollback(roots)
        return status
    }

    private func performInstall(_ plan: ClaudeSetupPlan, roots: ClaudeSetupRoots, helper: Data,
                                capabilities: ClaudeCapabilities) throws -> ClaudeConnectionStatus {
        guard case .ready = plan.status else { throw ClaudeSetupError.failed("Setup preview is not ready.") }
        guard !helper.isEmpty else { throw ClaudeSetupError.failed("The bundled Herdly helper is unavailable.") }
        let currentSettings = try readableData(at: roots.settingsURL)
        let current = currentSettings ?? Data("{}" .utf8)
        var settingsChange = plan.settingsChange
        let existingState: ClaudeInstallState?
        if fileManager.fileExists(atPath: roots.stateURL.path) {
            guard let state = try? readState(roots) else {
                throw ClaudeSetupError.conflict("Herdly Claude setup state is missing or inconsistent; review setup before changing this root.")
            }
            guard state.rootPath == roots.configDirectory.path,
                  UUID(uuidString: state.installationID) != nil else {
                throw ClaudeSetupError.conflict("Herdly Claude setup belongs to a different configuration root; review setup before changing this root.")
            }
            existingState = state
        } else {
            existingState = nil
        }
        if !plan.usageEnabled, let state = existingState,
           state.installedStatusLine != state.originalStatusLine {
            guard let restored = try removingStatusLine(settingsChange, original: state.originalStatusLine) else {
                throw ClaudeSetupError.conflict("Claude settings.json could not remove Herdly's usage status line.")
            }
            settingsChange = restored
        }
        if let state = existingState, current != state.installedSettings,
           let object = try? ClaudeSetupPlanner.jsonObject(current) {
            if case .changed = ownedHookState(object, expected: state.ownedHooks) {
                throw ClaudeSetupError.conflict("A Herdly-owned Claude hook was changed; review setup before repair.")
            }
            if plan.titleSettingRequired, case .changed = ownedEnvironmentState(object, expected: state.ownedEnvironment) {
                throw ClaudeSetupError.conflict("Herdly's terminal title setting was changed; review setup before repair.")
            }
            if let installed = state.installedStatusLine {
                guard let currentStatusLine = ClaudeSetupPlanner.memberData(current, key: "statusLine"),
                      currentStatusLine == installed else {
                    throw ClaudeSetupError.conflict("Herdly's Claude usage status line was changed; review setup before repair.")
                }
            }
        }
        if current == settingsChange,
           (try? readableData(at: roots.helperURL)) == helper,
           let state = existingState, state.rootPath == roots.configDirectory.path,
           state.installationID == plan.installationID {
            return status(roots: roots, capabilities: capabilities, titleSettingRequired: plan.titleSettingRequired)
        }
        guard current == plan.originalSettings else {
            throw ClaudeSetupError.conflict("Claude settings changed after the preview. Review setup again.")
        }
        // A helper Herdly installed earlier, still unchanged, may be replaced by this app's helper.
        if let existingHelper = try readableData(at: roots.helperURL), existingHelper != helper,
           existingHelper != existingState?.helper {
            throw ClaudeSetupError.conflict("A different file already exists at Herdly's Claude helper path.")
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
            if oldHelper != helper { try backup(oldHelper, named: "HerdlyHook", in: backupDirectory) }
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
        return status(roots: roots, capabilities: capabilities, titleSettingRequired: plan.titleSettingRequired)
    }

    /// Replaces this root's installed helper with `helper` only while the installed file is exactly the
    /// one Herdly recorded, and records the replacement so status and undo still recognize it. It never
    /// reads or writes settings.json. A missing or inconsistent record, or a helper that differs from
    /// the record, changes nothing. A failed write restores the previous helper and record.
    public func refreshHelper(roots: ClaudeSetupRoots, helper: Data) throws -> HelperRefreshResult {
        guard !helper.isEmpty else { return .skipped("The bundled Herdly helper is unavailable.") }
        guard fileManager.fileExists(atPath: roots.stateURL.path) else { return .skipped("Claude setup is not installed.") }
        guard let originalState = try? readableData(at: roots.stateURL),
              var state = try? JSONDecoder().decode(ClaudeInstallState.self, from: originalState),
              state.rootPath == roots.configDirectory.path,
              UUID(uuidString: state.installationID) != nil else {
            return .skipped("Herdly Claude setup state is missing or inconsistent.")
        }
        guard let installed = try? readableData(at: roots.helperURL) else {
            return .skipped("Herdly's Claude helper is missing or unreadable.")
        }
        guard installed == state.helper else { return .skipped("Herdly's Claude helper differs from the one it installed.") }
        guard installed != helper else { return .current }
        state.helper = helper
        let updatedState = try JSONEncoder().encode(state)
        do {
            try SetupFileWriter.replaceExecutable(helper, at: roots.helperURL, fileManager: fileManager)
            try atomicWrite(updatedState, to: roots.stateURL)
        } catch let error {
            do {
                try SetupFileWriter.replaceExecutable(installed, at: roots.helperURL, fileManager: fileManager)
                try atomicWrite(originalState, to: roots.stateURL)
            } catch let rollbackError {
                throw ClaudeSetupError.rollbackIncomplete("Helper update failed (\(error)); rollback also failed (\(rollbackError)). Check Herdly's Claude helper before retrying.")
            }
            throw ClaudeSetupError.failed("The helper update was not completed; the previous helper was restored.")
        }
        return .updated
    }

    /// `titleSettingRequired` false (no Ghostty that binds Claude by title) reads a missing or different
    /// `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` as fine, so removing it to let Claude report status is not a repair.
    public func status(roots: ClaudeSetupRoots, capabilities: ClaudeCapabilities,
                       titleSettingRequired: Bool = true) -> ClaudeConnectionStatus {
        guard capabilities.supported else {
            return .unsupported("Claude Code \(capabilities.version ?? "version unknown") is older than the tested minimum \(ClaudeSetupRequirements.minimumCLIVersion).")
        }
        guard fileManager.fileExists(atPath: roots.stateURL.path) else {
            if let settings = try? readableData(at: roots.settingsURL),
               let object = try? ClaudeSetupPlanner.jsonObject(settings),
               !ClaudeSetupPlanner.existingInstallationIDs(object, marker: ClaudeSetupPlanner.ownershipMarker(helperPath: roots.helperURL, eventsPath: roots.eventsDirectory)).isEmpty {
                return .conflict("Herdly Claude setup state is missing; review this root's settings.json before reconnecting.")
            }
            return .notConfigured
        }
        guard let state = try? readState(roots), state.rootPath == roots.configDirectory.path,
              UUID(uuidString: state.installationID) != nil else {
            return .conflict("Herdly Claude setup state is missing or inconsistent; review setup before changing this root.")
        }
        guard let settings = try? readableData(at: roots.settingsURL),
              let object = try? ClaudeSetupPlanner.jsonObject(settings) else {
            return .malformed("Claude settings.json is missing or unreadable.")
        }
        if object["allowManagedHooksOnly"] as? Bool == true {
            return .blockedByPolicy("Claude managed policy allows only managed hooks; Herdly cannot verify user hooks.")
        }
        guard let helper = try? readableData(at: roots.helperURL) else {
            return .repairRequired("Herdly's Claude helper is missing; Configure Claude to repair setup.")
        }
        guard helper == state.helper else {
            return .conflict("Herdly's Claude helper differs from the one it installed; review setup before repair.")
        }
        if titleSettingRequired {
            switch titleEnvironmentState(object) {
            case .changed: return .conflict("Claude's automatic terminal title setting was changed; review setup before repair.")
            case .missing: return .repairRequired("Herdly's terminal title setting is missing; Configure Claude to repair setup.")
            case .intact: break
            }
            switch ownedEnvironmentState(object, expected: state.ownedEnvironment) {
            case .changed: return .conflict("Herdly's terminal title setting was changed; review setup before repair.")
            case .missing: return .repairRequired("Herdly's terminal title setting is missing; Configure Claude to repair setup.")
            case .intact: break
            }
        }
        if let installed = state.installedStatusLine {
            guard let currentStatusLine = ClaudeSetupPlanner.memberData(settings, key: "statusLine") else {
                return .repairRequired("Herdly's Claude usage status line is missing; Configure Claude to repair setup.")
            }
            guard currentStatusLine == installed else {
                return .conflict("Herdly's Claude usage status line was changed; review setup before repair.")
            }
        }
        switch ownedHookState(object, expected: state.ownedHooks) {
        case .changed: return .conflict("A Herdly-owned Claude hook was changed; review setup before repair.")
        case .missing: return .repairRequired("Herdly's Claude hook entries are missing; Configure Claude to repair setup.")
        case .intact: break
        }
        guard fileManager.fileExists(atPath: roots.eventsDirectory.path) else {
            return .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Sessions already running may still report activity; restart them so Herdly can match their terminal tabs.")
        }
        let files: [URL]
        // The same listing bound as every other hook reader (`HookEventListing`): busy sessions keep
        // more than 4,096 tool records inside their one-hour retention, and the smaller bound flipped a
        // connected root to unavailable whenever they did. This scan stops at its first proof; with
        // none it decodes every listed entry, off the main actor.
        do { files = try boundedContents(of: roots.eventsDirectory, limit: HookEventListing.maximumEntries) }
        catch {
            return .unavailable("Herdly's Claude events directory is not readable.")
        }
        let now = Date().timeIntervalSince1970
        // Oldest first: startup records outlive the hourly tool-record retention, so the first valid
        // one is usually near the front and the scan stops there.
        return files.map { (url: $0, created: HookEventListing.created($0)) }
            .sorted { $0.created < $1.created }.map(\.url)
            .contains(where: { validEvent($0, installationID: state.installationID, installedAt: state.installedAt, now: now) })
            ? .connected
            : .configuredAwaitingRestart("Configured; start a new Claude session in this root to verify delivery. Sessions already running may still report activity; restart them so Herdly can match their terminal tabs.")
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
            return .conflict("Claude usage unavailable: Herdly's status line is missing; review setup before repair.")
        }
        guard current == installed else {
            return .conflict("Claude usage unavailable: Herdly's status line was changed; review setup before repair.")
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

    /// Undo Setup. Success also clears a stuck usage-rollback record and, with it gone, Herdly's
    /// now-empty folder for this root.
    public func undo(roots: ClaudeSetupRoots) throws -> ClaudeConnectionStatus {
        let status = try performUndo(roots: roots)
        clearUsageRollback(roots)
        try? removeDirectoryIfEmpty(roots.helperDirectory)
        return status
    }

    /// The reason a usage upgrade's rollback failed for this folder, kept until Configure or Undo
    /// Setup succeeds; nil when there is none.
    public func usageRollbackIncomplete(for roots: ClaudeSetupRoots) -> String? {
        guard let data = boundedData(at: roots.usageRollbackURL, maximum: 16 * 1024) else { return nil }
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Herdly couldn't finish or undo adding its usage status line. Check settings.json." : message
    }

    private func clearUsageRollback(_ roots: ClaudeSetupRoots) {
        try? fileManager.removeItem(at: roots.usageRollbackURL)
    }

    private func performUndo(roots: ClaudeSetupRoots) throws -> ClaudeConnectionStatus {
        let state = try readState(roots)
        guard state.rootPath == roots.configDirectory.path else {
            throw ClaudeSetupError.conflict("Herdly Claude setup belongs to a different configuration root; undo made no changes.")
        }
        guard let current = try readableData(at: roots.settingsURL),
              let object = try? ClaudeSetupPlanner.jsonObject(current) else {
            throw ClaudeSetupError.conflict("Claude settings.json is missing or unreadable; undo made no changes.")
        }
        if let helper = try readableData(at: roots.helperURL), helper != state.helper {
            throw ClaudeSetupError.conflict("A different file sits at Herdly's Claude helper path; undo made no changes.")
        }
        switch ownedEnvironmentState(object, expected: state.ownedEnvironment) {
        case .changed: throw ClaudeSetupError.conflict("Herdly's terminal title setting was changed; undo made no changes.")
        case .intact, .missing: break
        }
        if let installed = state.installedStatusLine {
            guard let currentStatusLine = ClaudeSetupPlanner.memberData(current, key: "statusLine"),
                  currentStatusLine == installed else {
                throw ClaudeSetupError.conflict("Herdly's Claude usage status line was changed; undo made no changes.")
            }
        }
        switch ownedHookState(object, expected: state.ownedHooks) {
        case .changed: throw ClaudeSetupError.conflict("A Herdly-owned Claude hook was changed; undo made no changes.")
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
        let usageRecord = roots.usageDirectory.appendingPathComponent(ClaudeUsageReader.latestRecordName)
        let backup = try validatedBackupURL(for: state, roots: roots)
        if fileManager.fileExists(atPath: roots.helperURL.path), !isRegularFile(at: roots.helperURL) {
            throw ClaudeSetupError.conflict("Herdly's Claude helper path is not a regular file; undo made no changes.")
        }
        do {
            try restore(restored, to: roots.settingsURL)
            if fileManager.fileExists(atPath: roots.helperURL.path) {
                try fileManager.removeItem(at: roots.helperURL)
            }
            try fileManager.removeItem(at: roots.stateURL)
            for event in ownedEvents { try fileManager.removeItem(at: event) }
            if ClaudeUsageReader.isOwnedRecord(at: usageRecord) { try fileManager.removeItem(at: usageRecord) }
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
        guard let data = try readableData(at: roots.stateURL) else { throw ClaudeSetupError.failed("Herdly Claude setup is not installed.") }
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

    /// - Parameter limit: entries past which the directory is not inspected. Readers that decode every
    ///   entry keep the original 4,096; the connection check, which stops at its first proof, uses
    ///   `HookEventListing.maximumEntries` (see `status(roots:capabilities:)`).
    private func boundedContents(of url: URL, limit: Int = 4096) throws -> [URL] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        guard isDirectory(at: url) else { throw ClaudeSetupError.conflict("\(url.lastPathComponent) is not a directory.") }
        let files = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.creationDateKey])
        guard files.count <= limit else { throw ClaudeSetupError.conflict("\(url.lastPathComponent) contains too many entries to inspect safely.") }
        return files
    }

    private func validatedBackupURL(for state: ClaudeInstallState, roots: ClaudeSetupRoots) throws -> URL? {
        guard let name = state.backupDirectory else { return nil }
        guard name != ".", name != "..", !name.contains("/") else {
            throw ClaudeSetupError.conflict("Herdly Claude setup backup identity is invalid; undo made no changes.")
        }
        let url = roots.backupsURL.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard isDirectory(at: url) else {
            throw ClaudeSetupError.conflict("Herdly Claude setup backup is not a directory; undo made no changes.")
        }
        let files = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        let expected: [String: Data] = state.originalSettings.map { ["settings.json": $0] } ?? [:]
        guard files.count == expected.count,
              files.allSatisfy({ expected[$0.lastPathComponent] == boundedData(at: $0, maximum: 20 * 1024 * 1024) }) else {
            throw ClaudeSetupError.conflict("Herdly Claude setup backup changed; undo made no changes.")
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
        try beforeWrite?(url)
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

/// What `ClaudeSetupInstaller.upgradeUsage` did: added Herdly's usage status line, changed nothing,
/// failed with the original settings restored, or failed and could not restore them, so the
/// folder's files may be half-written and need the user's attention.
public enum ClaudeUsageUpgrade: Equatable, Sendable {
    case applied
    case skipped
    case failed(String)
    case rollbackIncomplete(String)
}

extension ClaudeSetupInstaller {
    /// Usage limits are always on (#481, owner decision 2026-11-25): a folder Herdly set up while usage
    /// was an opt-in gets the usage status line on its own, without a Configure click. Only the
    /// `statusLine` member changes, exactly as Configure would write it, and only when every guard
    /// holds; otherwise nothing is written and the folder reads usage unavailable.
    ///
    /// Guards: the folder has Herdly's install record and a connected or awaiting-restart setup; the
    /// bridge isn't already in place; `plan` was read from the current `settings.json` (unchanged
    /// since) and found the status line wrappable, which for an existing command means the
    /// compatibility probe passed; and the status line is still the one Herdly recorded at install.
    /// The settings are backed up as Configure backs them up, written atomically, and the install
    /// record keeps the user's original status line, so Undo Setup restores it byte for byte.
    public func upgradeUsage(_ plan: ClaudeSetupPlan, roots: ClaudeSetupRoots,
                             capabilities: ClaudeCapabilities) -> ClaudeUsageUpgrade {
        // While a failed rollback is on record the settings may be half-written: never write again.
        if let message = usageRollbackIncomplete(for: roots) { return .rollbackIncomplete(message) }
        do {
            return try applyUsageUpgrade(plan, roots: roots, capabilities: capabilities)
        } catch ClaudeSetupError.rollbackIncomplete(let message) {
            // Kept beside the install record so the next detection still shows it; written directly,
            // since this is Herdly's own state, not the user's settings.
            try? fileManager.createDirectory(at: roots.helperDirectory, withIntermediateDirectories: true)
            try? Data(message.utf8).write(to: roots.usageRollbackURL, options: .atomic)
            return .rollbackIncomplete(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func applyUsageUpgrade(_ plan: ClaudeSetupPlan, roots: ClaudeSetupRoots,
                                   capabilities: ClaudeCapabilities) throws -> ClaudeUsageUpgrade {
        guard case .ready = plan.status, plan.usageEnabled, plan.usageStatus == .ready,
              let state = try? readState(roots), state.rootPath == roots.configDirectory.path,
              UUID(uuidString: state.installationID) != nil, state.installationID == plan.installationID,
              usageStatus(for: roots, requested: true) != .ready else { return .skipped }
        let status = status(roots: roots, capabilities: capabilities, titleSettingRequired: plan.titleSettingRequired)
        guard status == .connected || status.isAwaitingRestart,
              let current = try readableData(at: roots.settingsURL), current == plan.originalSettings,
              ClaudeSetupPlanner.memberData(current, key: "statusLine") == state.installedStatusLine,
              let object = try? ClaudeSetupPlanner.jsonObject(current) else { return .skipped }
        if let command = ClaudeStatusLineBridge.statusLineCommand(object["statusLine"]),
           ClaudeStatusLineBridge.isBridgeCommand(command) { return .skipped }
        guard let bridged = ClaudeStatusLineBridge.bridgeStatusLine(object["statusLine"], helperPath: roots.helperURL,
                                                                    usagePath: roots.usageDirectory),
              let upgraded = try? ClaudeSetupPlanner.jsonDataPreservingMember(current, key: "statusLine", value: bridged),
              upgraded != current else { return .skipped }
        let originalState = try readableData(at: roots.stateURL)
        let next = ClaudeInstallState(rootPath: state.rootPath, helper: state.helper, installationID: state.installationID,
                                      ownedHooks: state.ownedHooks, ownedEnvironment: state.ownedEnvironment,
                                      installedSettings: upgraded, originalSettings: state.originalSettings,
                                      installedAt: state.installedAt, backupDirectory: state.backupDirectory,
                                      usageEnabled: true, originalStatusLine: state.originalStatusLine,
                                      installedStatusLine: ClaudeSetupPlanner.memberData(upgraded, key: "statusLine"),
                                      environmentOwnershipRecorded: state.environmentOwnershipRecorded)
        let encoded = try JSONEncoder().encode(next)
        let backupDirectory = roots.backupsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Read again right before writing: a change since the plan was read means leave it alone.
        guard try readableData(at: roots.settingsURL) == current else { return .skipped }
        do {
            try fileManager.createDirectory(at: roots.usageDirectory, withIntermediateDirectories: true)
            try backup(current, named: "settings.json", in: backupDirectory)
            try atomicWrite(upgraded, to: roots.settingsURL)
            try atomicWrite(encoded, to: roots.stateURL)
        } catch let error {
            do {
                try restore(current, to: roots.settingsURL)
                try restore(originalState, to: roots.stateURL)
            } catch let rollbackError {
                throw ClaudeSetupError.rollbackIncomplete("Usage setup failed (\(error)); rollback also failed (\(rollbackError)). Check the affected files before retrying.")
            }
            throw ClaudeSetupError.failed("Usage setup was not completed; the original configuration was restored.")
        }
        return .applied
    }
}
