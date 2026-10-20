import Foundation

/// Optional Haiku-written titles for Claude sessions that still carry Claude's derived placeholder
/// name (`landbase-22`). The hook never delays a prompt for a title: the first eligible prompt
/// starts a detached generator, and a later prompt hands the finished title to Claude through
/// `hookSpecificOutput.sessionTitle`, which Claude records in its session registry with
/// `nameSource: "hook"`. A title is offered only while that registry entry still shows the derived
/// name, so a `/rename`, `--name`, or Claude's own AI title always wins, and an unreadable registry
/// offers nothing. Titles are presentation only; they never identify a session or a target.
public enum ClaudeSessionTitles {
    public static let directoryName = "session-titles"
    public static let enabledMarkerName = "enabled"
    /// The leading part of a prompt sent to the model; longer prompts are cut here.
    public static let maximumSourceLength = 2_000
    public static let maximumTitleLength = 48
    /// The model call's bound. A generator past it is stopped and records a failure.
    public static let generationTimeout: TimeInterval = 30
    /// A generator that has not reported by then is presumed dead, so a later prompt may retry.
    public static let pendingLifetime: TimeInterval = 120
    public static let maximumAttempts = 2
    public static let recordAge: TimeInterval = 7 * 24 * 60 * 60
    static let maximumRecordSize = 4 * 1024
    public static let maximumRegistryEntrySize = 64 * 1024

    public struct RegisteredName: Equatable, Sendable {
        public let name: String
        public let source: String?

        public init(name: String, source: String?) {
            self.name = name
            self.source = source
        }

        /// Claude's folder-based placeholder, the only name a hook title replaces.
        public var isDerived: Bool { source == "derived" }
    }

    public struct Record: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            case pending
            case ready
            case failed
            case applied
        }

        public let status: Status
        public let title: String?
        public let attempts: Int
        public let updatedAt: Double

        public init(status: Status, title: String? = nil, attempts: Int, updatedAt: Double) {
            self.status = status
            self.title = title
            self.attempts = attempts
            self.updatedAt = updatedAt
        }
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Start a generator for this prompt text and record the attempt as pending.
        case generate(source: String)
        /// Return this title to Claude and record it as applied.
        case apply(title: String)
    }

    // MARK: - Locations and opt-in

    public static func directory(in eventsDirectory: URL) -> URL {
        eventsDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func isEnabled(eventsDirectory: URL) -> Bool {
        let marker = directory(in: eventsDirectory).appendingPathComponent(enabledMarkerName)
        return SafeFile.read(marker, limit: 64) != nil
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool, eventsDirectory: URL) -> Bool {
        let marker = directory(in: eventsDirectory).appendingPathComponent(enabledMarkerName)
        if enabled { return write(Data("on\n".utf8), to: marker) }
        do {
            try FileManager.default.removeItem(at: marker)
            return true
        } catch {
            return !FileManager.default.fileExists(atPath: marker.path)
        }
    }

    /// Claude's registry entry for the process that ran the hook (`CLAUDE_PID`).
    public static func registryEntryURL(configDirectory: URL, pid: Int32) -> URL {
        configDirectory.appendingPathComponent(ClaudeSessionRegistry.directoryName, isDirectory: true)
            .appendingPathComponent("\(pid).json")
    }

    // MARK: - Decisions

    /// The registry entry's current name, or nil when the entry is malformed, unnamed, or belongs
    /// to another session (a reused PID, or a `/clear` that moved the process to a new session).
    public static func registeredName(_ data: Data, sessionID: String) -> RegisteredName? {
        guard data.count <= maximumRegistryEntrySize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["sessionId"] as? String == sessionID,
              let name = object["name"] as? String, !name.isEmpty else { return nil }
        return RegisteredName(name: name, source: object["nameSource"] as? String)
    }

    /// The prompt text worth titling, or nil for one that says nothing about the work: empty
    /// prompts, Claude's tagged messages (`<task-notification>`, `<command-message>`), and bare
    /// slash commands such as `/clear`. A slash command with arguments keeps them as the subject.
    public static func titleSource(_ prompt: String?) -> String? {
        guard let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.hasPrefix("<") else { return nil }
        if text.hasPrefix("/") {
            let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        }
        return String(text.prefix(maximumSourceLength))
    }

    /// What the hook does for one prompt. Nothing happens unless the registry shows Claude's
    /// derived placeholder for this exact session. A finished title is applied once; a failed or
    /// abandoned generation is retried on a later eligible prompt up to `maximumAttempts`.
    public static func action(prompt: String?, registered: RegisteredName?, record: Record?, now: Double) -> Action {
        guard registered?.isDerived == true else { return .none }
        let generate: (Int) -> Action = { attempts in
            guard attempts < maximumAttempts, let source = titleSource(prompt) else { return .none }
            return .generate(source: source)
        }
        guard let record else { return generate(0) }
        switch record.status {
        case .ready:
            guard let title = record.title.flatMap(sanitizedTitle) else { return generate(record.attempts) }
            return .apply(title: title)
        case .applied:
            return .none
        case .pending:
            return now - record.updatedAt < pendingLifetime ? .none : generate(record.attempts)
        case .failed:
            return generate(record.attempts)
        }
    }

    // MARK: - Generation

    /// The instruction sent to the model on stdin, so the prompt never appears in a process list.
    public static func generationInput(source: String) -> String {
        """
        Write a short title for a coding session that begins with the request below. Use 2 to 5 \
        lowercase words joined by hyphens, like fix-login-redirect. Output only the title.

        <request>
        \(source.prefix(maximumSourceLength))
        </request>
        """
    }

    /// A one-shot Haiku call with no tools, hooks, MCP servers, user or project settings, slash
    /// commands, or saved transcript. Skipping hooks keeps the call from re-entering Herdly's own.
    public static let generationArguments = [
        "-p", "--model", "haiku", "--no-session-persistence", "--tools", "",
        "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#,
        "--disable-slash-commands", "--strict-mcp-config"
    ]

    /// The hook's environment without the variables that tie a process to the parent session, so
    /// the model call is not taken for part of it. Claude's child-session marker stays.
    public static func generationEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !["CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ID",
              "CLAUDE_PID", "CLAUDE_PROJECT_DIR"].contains(key)
        }
    }

    /// The model's reply as a kebab-case title, or nil when nothing usable remains: the first
    /// non-empty line, lowercased, with every run of other characters folded to one hyphen, and cut
    /// at a word boundary to `maximumTitleLength`.
    public static func sanitizedTitle(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        var words: [String] = []
        var current = ""
        for scalar in line.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        var title = ""
        for word in words {
            let next = title.isEmpty ? word : title + "-" + word
            guard next.count <= maximumTitleLength else { break }
            title = next
        }
        guard title.contains(where: \.isLetter) else { return nil }
        return title
    }

    /// The `UserPromptSubmit` output that sets the session title.
    public static func hookOutput(title: String) -> Data? {
        let object: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "sessionTitle": title]
        ]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Records

    public static func load(sessionID: String, in eventsDirectory: URL) -> Record? {
        guard let url = recordURL(sessionID: sessionID, in: eventsDirectory),
              let data = SafeFile.read(url, limit: maximumRecordSize) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    @discardableResult
    public static func save(_ record: Record, sessionID: String, in eventsDirectory: URL) -> Bool {
        guard let url = recordURL(sessionID: sessionID, in: eventsDirectory),
              let data = try? JSONEncoder().encode(record) else { return false }
        return write(data, to: url)
    }

    /// Removes records untouched for `recordAge` and abandoned temporary files. Bounded by the
    /// directory listing; the opt-in marker is never removed.
    public static func prune(in eventsDirectory: URL, now: Date = Date()) {
        let folder = directory(in: eventsDirectory)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        for url in urls.prefix(4_096) where url.lastPathComponent != enabledMarkerName {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= recordAge else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func recordURL(sessionID: String, in eventsDirectory: URL) -> URL? {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 256,
              sessionID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return directory(in: eventsDirectory).appendingPathComponent(sessionID + ".json")
    }

    private static func write(_ data: Data, to destination: URL) -> Bool {
        let folder = destination.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
        let temporary = folder.appendingPathComponent(".herdly-" + UUID().uuidString)
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }
}
