import Foundation

/// The bounded view of one hook event directory that every reader shares. Listing names and
/// creation dates is cheap; decoding records is not, so readers decode only the newest window.
public enum HookEventListing {
    /// Past this many entries the directory is unavailable rather than read partially. Retention
    /// keeps normal use far below it.
    public static let maximumEntries = 65_536
    /// The newest hook records a reader decodes per scan.
    public static let maximumRecords = 4096

    /// Every top-level entry, oldest first by creation date and then name. `nil` when the directory
    /// is unreadable or holds more than `maximumEntries` entries.
    public static func entries(in directory: URL, limit: Int = maximumEntries) -> [URL]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]),
              urls.count <= limit else { return nil }
        let dated: [(url: URL, created: Date)] = urls.map { ($0, created($0)) }
        return dated.sorted { left, right in
            left.created == right.created ? left.url.lastPathComponent < right.url.lastPathComponent
                : left.created < right.created
        }.map(\.url)
    }

    /// The newest `.json` hook records among `entries`, still oldest first.
    public static func newestRecords(_ entries: [URL]) -> ArraySlice<URL> {
        entries.filter { $0.pathExtension == "json" }.suffix(maximumRecords)
    }

    static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}

/// Deletes expired hook records from one of Steer's event directories. Tool records only label the
/// current tool, so they expire after `toolRecordAge`; every other record after `recordAge`.
///
/// What is kept regardless of age: tool calls with no completion, turn end or session end (a
/// waiting question lives in one), lifecycle records of sessions that still have an approval
/// unresolved request file (a handed-back reminder resolves from their session end), and anything Steer
/// cannot identify as its own record: request, receipt and decision files, malformed or foreign
/// JSON, symlinks and directories. Age is the file's creation date.
public enum HookEventRetention {
    public static let toolRecordAge: TimeInterval = 60 * 60
    public static let recordAge: TimeInterval = 7 * 24 * 60 * 60
    public static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch"]
    static let sources: Set<String> = [CodexSetupRequirements.helperSource, ClaudeSetupRequirements.helperSource]

    public struct Outcome: Equatable, Sendable {
        public let available: Bool
        public let removed: Int

        public init(available: Bool, removed: Int) {
            self.available = available
            self.removed = removed
        }
    }

    private struct Record {
        let url: URL
        let age: TimeInterval
        let event: String
        let session: String
        let turn: String?
        let tool: String?
        let closes: [String]
        let capturedAt: Double
    }

    /// Unbounded listing on purpose: retention is what brings an overgrown directory back under
    /// the readers' bound. Run it off the main actor.
    @discardableResult
    public static func prune(_ directory: URL, now: Date = Date()) -> Outcome {
        guard isDirectory(directory),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
            return Outcome(available: false, removed: 0)
        }
        var records: [Record] = []
        var protectedSessions = Set<String>()
        var expired: [URL] = []
        for url in urls where isRegularFile(url) {
            let age = now.timeIntervalSince(HookEventListing.created(url))
            let name = url.lastPathComponent
            if name.hasPrefix(".steer-") {
                // A helper's write is renamed within milliseconds; an old one was abandoned.
                if age >= recordAge { expired.append(url) }
            } else if url.pathExtension == "approval", let session = unresolvedRequestSession(url, in: directory) {
                protectedSessions.insert(session)
            } else if url.pathExtension == "json", let record = record(url, age: age) {
                records.append(record)
            }
        }

        var closedTools = Set<String>()
        var endedTurns: [String: Double] = [:]
        var endedSessions: [String: Double] = [:]
        for record in records {
            switch record.event {
            case let event where toolEvents.contains(event) && event != "PreToolUse":
                closedTools.formUnion(record.closes.map { toolKey(record.session, $0) })
            case "Stop", "StopFailure":
                if let turn = record.turn {
                    endedTurns[turnKey(record.session, turn)] = max(endedTurns[turnKey(record.session, turn)] ?? -.infinity,
                                                                    record.capturedAt)
                }
            case "SessionEnd":
                endedSessions[record.session] = max(endedSessions[record.session] ?? -.infinity, record.capturedAt)
            default:
                break
            }
        }
        func isOpen(_ record: Record) -> Bool {
            guard record.event == "PreToolUse", let tool = record.tool else { return false }
            if closedTools.contains(toolKey(record.session, tool)) { return false }
            if let turn = record.turn, let ended = endedTurns[turnKey(record.session, turn)], ended >= record.capturedAt {
                return false
            }
            if let ended = endedSessions[record.session], ended >= record.capturedAt { return false }
            return true
        }

        var keptToolStarts = Set<String>()
        var completions: [Record] = []
        for record in records {
            let isTool = toolEvents.contains(record.event)
            if record.age >= recordAge {
                if isTool || !protectedSessions.contains(record.session) { expired.append(record.url) }
            } else if isTool, record.age >= toolRecordAge {
                if record.event == "PreToolUse" {
                    if isOpen(record) {
                        if let tool = record.tool { keptToolStarts.insert(toolKey(record.session, tool)) }
                    } else {
                        expired.append(record.url)
                    }
                } else {
                    completions.append(record)
                }
            } else if record.event == "PreToolUse", let tool = record.tool {
                keptToolStarts.insert(toolKey(record.session, tool))
            }
        }
        // A completion stays while the call it completes is still on disk, so a reader never sees
        // a kept start without its end.
        for record in completions where record.closes.allSatisfy({ !keptToolStarts.contains(toolKey(record.session, $0)) }) {
            expired.append(record.url)
        }

        var removed = 0
        for url in expired where (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        return Outcome(available: true, removed: removed)
    }

    /// The session of a request the reminder reader would still show: the same outcomes and
    /// formats `ReminderReader` accepts, minus requests the user already decided.
    private static func unresolvedRequestSession(_ url: URL, in directory: URL) -> String? {
        guard let bytes = SafeFile.read(url, limit: 65536) else { return nil }
        if let request = try? JSONDecoder().decode(ApprovalRequest.self, from: bytes) {
            guard [.pending, .noDecision].contains(request.outcome) else { return nil }
            if request.outcome == .pending,
               ApprovalDecisions.existing(for: request.id, in: directory)?.decision.isUserDecision == true { return nil }
            return sessionKey(request.sessionID.uuidString)
        }
        if let reminder = try? JSONDecoder().decode(Reminder.self, from: bytes),
           ["pending", "no_decision"].contains(reminder.outcome) {
            return sessionKey(reminder.session_id.uuidString)
        }
        return nil
    }

    private static func record(_ url: URL, age: TimeInterval) -> Record? {
        guard let bytes = SafeFile.read(url, limit: DesktopEventReader.maximumRecordSize),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let source = object["source"] as? String, sources.contains(source),
              let event = object["hook_event_name"] as? String, !event.isEmpty,
              let session = object["session_id"] as? String, !session.isEmpty else { return nil }
        let tool = object["tool_use_id"] as? String
        let input = object["tool_input"] as? [String: Any] ?? [:]
        let batch = input["tool_use_ids"] as? [String]
            ?? (input["tool_uses"] as? [[String: Any]] ?? []).compactMap { $0["tool_use_id"] as? String }
        return Record(url: url, age: age, event: event, session: sessionKey(session),
                      turn: object["turn_id"] as? String ?? object["prompt_id"] as? String,
                      tool: tool, closes: event == "PostToolBatch" ? batch : tool.map { [$0] } ?? [],
                      capturedAt: (object["captured_at"] as? NSNumber)?.doubleValue
                        ?? (object["received_at"] as? String).flatMap(RolloutTimestamp.parse) ?? -.infinity)
    }

    /// Codex writes UUIDs in either case; Claude session ids are compared as written.
    private static func sessionKey(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString ?? value
    }

    private static func toolKey(_ session: String, _ tool: String) -> String { session + "\u{0}" + tool }
    private static func turnKey(_ session: String, _ turn: String) -> String { session + "\u{0}" + turn }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }
}

/// The herdr pane a hook event ran in, from the `HERDR_PANE_ID` herdr injects into every managed
/// pane (ADR 0008, ADR 0009). The helper records it in each Codex CLI and Claude Code hook event
/// record under `recordKey`; nothing else uses it yet.
///
/// herdr documents pane IDs as opaque handles, observed live as `w1:p1` and `w4:p1`. Validation is
/// deliberately narrower than "any string": a missing, empty, oversized or malformed value is
/// absent, never trimmed, repaired or guessed. Records written before this field decode as absent.
public enum HerdrPaneID {
    public static let environmentKey = "HERDR_PANE_ID"
    /// The hook record key, snake case like the record's other keys.
    public static let recordKey = "herdr_pane_id"
    /// Observed IDs are a few bytes; this leaves room for large workspace and pane counts.
    public static let maximumLength = 64

    /// `value` when it is 1...`maximumLength` ASCII letters, digits, `:`, `_`, `-` or `.`.
    public static func validated(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximumLength,
              value.utf8.allSatisfy(isAllowed) else { return nil }
        return value
    }

    /// The validated pane ID from a hook helper's environment.
    public static func value(in environment: [String: String]) -> String? {
        validated(environment[environmentKey])
    }

    /// Adds the environment's validated pane ID to a hook event record; leaves the record unchanged
    /// when the value is absent or invalid.
    public static func record(from environment: [String: String], into record: inout [String: Any]) {
        if let paneID = value(in: environment) { record[recordKey] = paneID }
    }

    /// The pane ID recorded in a decoded hook event record: `nil` for records without the field
    /// and for a stored value that is not a valid pane ID.
    public static func recorded(in record: [String: Any]) -> String? {
        validated(record[recordKey] as? String)
    }

    private static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: ":"), UInt8(ascii: "_"),
             UInt8(ascii: "-"), UInt8(ascii: "."):
            return true
        default:
            return false
        }
    }
}
