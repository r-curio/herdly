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
    ///
    /// Several readers list the same directories every scan, and a busy Claude directory holds
    /// thousands of records, each needing its own creation-date lookup (#301). An unchanged
    /// directory stamp reuses the last listing outright. Otherwise only names are read, and a
    /// creation date is looked up only for an entry not seen before under the same inode: a file's
    /// creation date never changes, and a name replaced by another file has a new inode. The stamp is
    /// taken before listing, so a change during the listing shows up as a new stamp next call.
    public static func entries(in directory: URL, limit: Int = maximumEntries) -> [URL]? {
        listing(in: directory, limit: limit)?.entries
    }

    /// `entries(in:)` with its `newestRecords`, worked out once per directory change rather than by
    /// every reader on every scan (#302).
    public static func listing(in directory: URL, limit: Int = maximumEntries) -> (entries: [URL], records: ArraySlice<URL>)? {
        detailedListing(in: directory, limit: limit).map { ($0.entries, $0.records) }
    }

    /// `listing(in:)` with the inode the directory itself gives for each of `records`, in the same
    /// order. A name replaced by another file has a new inode, so a reader can tell a record it has
    /// already read from a replacement without looking at the file.
    static func detailedListing(in directory: URL, limit: Int = maximumEntries)
        -> (entries: [URL], records: ArraySlice<URL>, recordInodes: [UInt64])? {
        let stamp = FileStamp(directory, followingLinks: true)
        let key = directory.standardizedFileURL.path
        let previous = listings.entry(key)
        if let stamp, let previous, previous.stamp == stamp {
            return previous.urls.count <= limit ? (previous.urls, previous.records, previous.recordInodes) : nil
        }
        guard let names = names(in: directory), names.count <= limit else { return nil }
        var dates: [String: Dated] = [:]
        dates.reserveCapacity(names.count)
        var added: [Dated] = []
        for name in names {
            if let known = previous?.dates[name.name], known.inode == name.inode {
                dates[name.name] = known
            } else {
                let url = directory.appendingPathComponent(name.name, isDirectory: name.isDirectory)
                let entry = Dated(name: name.name, url: url, inode: name.inode, created: Self.created(url))
                dates[name.name] = entry
                added.append(entry)
            }
        }
        // The usual change: records were removed, or added after the newest one. The kept entries
        // are still in order, so only the new ones are sorted.
        let kept = previous?.order.filter { name in
            guard let entry = dates[name] else { return false }
            return previous?.dates[name]?.inode == entry.inode
        } ?? []
        let order: [String]
        if let newest = kept.last.flatMap({ dates[$0]?.created }), added.allSatisfy({ $0.created > newest }) {
            order = kept + added.sorted(by: Dated.older).map(\.name)
        } else {
            order = dates.values.sorted(by: Dated.older).map(\.name)
        }
        let ordered = order.compactMap { dates[$0]?.url }
        let newest = order.filter(isRecordName).compactMap { dates[$0] }.suffix(maximumRecords)
        let records = ArraySlice(newest.map(\.url)), recordInodes = newest.map(\.inode)
        if let stamp {
            listings.store(ListingCache.Entry(stamp: stamp, urls: ordered, records: records, recordInodes: recordInodes,
                                              order: order, dates: dates), for: key)
        }
        return (ordered, records, recordInodes)
    }

    /// A `.json` record by name alone: `pathExtension` parses each URL, and listings hold thousands.
    private static func isRecordName(_ name: String) -> Bool {
        name.hasSuffix(".json") && name != ".json"
    }

    /// One listed entry with the inode its creation date was read under.
    private struct Dated {
        let name: String
        let url: URL
        let inode: UInt64
        let created: Date

        static func older(_ left: Dated, _ right: Dated) -> Bool {
            left.created == right.created ? left.name < right.name : left.created < right.created
        }
    }

    /// Top-level names with their inodes, `.` and `..` excluded; nil when the directory cannot be opened.
    private static func names(in directory: URL) -> [(name: String, inode: UInt64, isDirectory: Bool)]? {
        let handle = directory.withUnsafeFileSystemRepresentation { path in path.flatMap { opendir($0) } }
        guard let handle else { return nil }
        defer { closedir(handle) }
        var result: [(name: String, inode: UInt64, isDirectory: Bool)] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            result.append((name, UInt64(entry.pointee.d_ino), Int32(entry.pointee.d_type) == DT_DIR))
        }
        return result
    }

    private static let listings = ListingCache()

    /// The last successful listing per directory, the stamp it was taken under, and each entry's
    /// inode and creation date. Unreadable and oversized results are never kept.
    private final class ListingCache: @unchecked Sendable {
        struct Entry {
            let stamp: FileStamp
            let urls: [URL]
            let records: ArraySlice<URL>
            /// Each of `records`' inodes as the directory listed it, in the same order.
            let recordInodes: [UInt64]
            /// `urls`' names, in the same order.
            let order: [String]
            let dates: [String: Dated]
        }

        // Invariant for `@unchecked Sendable`: `entries` is only touched while holding `lock`.
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func entry(_ key: String) -> Entry? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ entry: Entry, for key: String) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = entry
        }
    }

    /// The newest `.json` hook records among `entries`, still oldest first.
    public static func newestRecords(_ entries: [URL]) -> ArraySlice<URL> {
        entries.filter { isRecordName($0.lastPathComponent) }.suffix(maximumRecords)
    }

    static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}

/// Deletes expired hook records from one of Herdly's event directories. Tool records only label the
/// current tool and subagent records only list a session's running subagents, so both expire after
/// `toolRecordAge`; every other record after `recordAge`.
///
/// What is kept regardless of age: tool calls with no completion, turn end or session end (a
/// waiting question lives in one), the start of a subagent with no stop of its own, no later
/// `Stop`/`StopFailure` in its session and no later session end (it is still listed), lifecycle records of sessions that still have an approval
/// unresolved request file (a handed-back reminder resolves from their session end), and anything Herdly
/// cannot identify as its own record: request, receipt and decision files, malformed or foreign
/// JSON, symlinks and directories. Age is the file's creation date.
public enum HookEventRetention {
    public static let toolRecordAge: TimeInterval = 60 * 60
    public static let recordAge: TimeInterval = 7 * 24 * 60 * 60
    public static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch"]
    /// Claude writes one pair per subagent, often the bulk of a busy directory. Kept a week, they
    /// crowded session and turn records out of the readers' `maximumRecords` window.
    public static let subagentEvents: Set<String> = ["SubagentStart", "SubagentStop"]
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
        /// Claude's `agent_id` for subagent records, when the reader would accept it.
        let agent: String?
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
            if name.hasPrefix(".herdly-") {
                // A helper's write is renamed within milliseconds; an old one was abandoned.
                if age >= recordAge { expired.append(url) }
            } else if url.pathExtension == "approval", let session = unresolvedRequestSession(url, in: directory) {
                protectedSessions.insert(session)
            } else if url.pathExtension == "json", let record = record(url, age: age) {
                records.append(record)
            }
        }

        var closedTools = Set<String>()
        var stoppedAgents = Set<String>()
        var subagentsEndedAt: [String: Double] = [:]
        for record in records where ClaudeObservationReader.subagentsEndingEvents.contains(record.event) {
            subagentsEndedAt[record.session] = max(subagentsEndedAt[record.session] ?? -.infinity, record.capturedAt)
        }
        var endedTurns: [String: Double] = [:]
        var endedSessions: [String: Double] = [:]
        for record in records {
            switch record.event {
            case let event where toolEvents.contains(event) && event != "PreToolUse":
                closedTools.formUnion(record.closes.map { toolKey(record.session, $0) })
            case "SubagentStop":
                if let agent = record.agent { stoppedAgents.insert(agentKey(record.session, agent)) }
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
        // The reader lists a subagent from its start until its own stop or a later
        // `ClaudeObservationReader.subagentsEndingEvents` record in its session.
        func isRunning(_ record: Record) -> Bool {
            guard record.event == "SubagentStart", let agent = record.agent,
                  !stoppedAgents.contains(agentKey(record.session, agent)) else { return false }
            if let ended = subagentsEndedAt[record.session], ended >= record.capturedAt { return false }
            return true
        }

        var keptToolStarts = Set<String>()
        var completions: [Record] = []
        for record in records {
            let isTool = toolEvents.contains(record.event)
            let isSubagent = subagentEvents.contains(record.event)
            if record.age >= recordAge {
                if isTool || isSubagent || !protectedSessions.contains(record.session) { expired.append(record.url) }
            } else if isSubagent, record.age >= toolRecordAge {
                if !isRunning(record) { expired.append(record.url) }
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
                      tool: tool, agent: ClaudeObservationReader.subagentID(in: object), closes: event == "PostToolBatch" ? batch : tool.map { [$0] } ?? [],
                      capturedAt: (object["captured_at"] as? NSNumber)?.doubleValue
                        ?? (object["received_at"] as? String).flatMap(RolloutTimestamp.parse) ?? -.infinity)
    }

    /// Codex writes UUIDs in either case; Claude session ids are compared as written.
    private static func sessionKey(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString ?? value
    }

    private static func toolKey(_ session: String, _ tool: String) -> String { session + "\u{0}" + tool }
    private static func turnKey(_ session: String, _ turn: String) -> String { session + "\u{0}" + turn }
    private static func agentKey(_ session: String, _ agent: String) -> String { session + "\u{0}" + agent }

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

    /// Adds the environment's validated pane ID to a hook event record, together with the validated
    /// `HERDR_SOCKET_PATH` when present. Pane IDs are unique only within one herdr server, so a
    /// socket path is never recorded without a valid pane ID. Leaves the record unchanged when the
    /// pane ID is absent or invalid.
    public static func record(from environment: [String: String], into record: inout [String: Any]) {
        guard let paneID = value(in: environment) else { return }
        record[recordKey] = paneID
        if let socketPath = HerdrSocketPath.value(in: environment) { record[HerdrSocketPath.recordKey] = socketPath }
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

/// The herdr server socket a hook event's pane belongs to, from the `HERDR_SOCKET_PATH` herdr
/// injects alongside `HERDR_PANE_ID` (ADR 0008, ADR 0009). Recorded under `recordKey` only with a
/// valid pane ID; whether it is herdr's default socket is decided by readers, not here.
///
/// A missing, empty, relative, oversized or control-character value is absent, never normalized
/// or guessed. Records written before this field decode as absent.
public enum HerdrSocketPath {
    public static let environmentKey = "HERDR_SOCKET_PATH"
    public static let recordKey = "herdr_socket_path"
    public static let maximumLength = 1024

    /// `value` when it is an absolute path of at most `maximumLength` UTF-8 bytes with no NUL or
    /// other control characters.
    public static func validated(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), value.utf8.count <= maximumLength,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return value
    }

    /// The validated socket path from a hook helper's environment.
    public static func value(in environment: [String: String]) -> String? {
        validated(environment[environmentKey])
    }

    /// The socket path recorded in a decoded hook event record: `nil` for records without the
    /// field, for an invalid stored value, and for a record without a valid pane ID.
    public static func recorded(in record: [String: Any]) -> String? {
        guard HerdrPaneID.recorded(in: record) != nil else { return nil }
        return validated(record[recordKey] as? String)
    }
}

/// A Zellij pane named by a Claude Code hook event: `ZELLIJ_PANE_ID` within `ZELLIJ_SESSION_NAME`.
public struct ZellijHookPane: Equatable, Hashable, Sendable {
    public let paneID: String
    public let sessionName: String

    public init(paneID: String, sessionName: String) {
        self.paneID = paneID
        self.sessionName = sessionName
    }
}

/// Terminal and multiplexer identifiers from a hook helper's environment (ADR 0013, ADR 0014).
///
/// `ITERM_SESSION_ID`, `TERM_SESSION_ID` and `WEZTERM_PANE` are recorded for diagnostics only: they
/// neither bind nor veto, because a terminal launched from another agent's session inherits that
/// session's values. `ZELLIJ_PANE_ID` with `ZELLIJ_SESSION_NAME` is the one exception, a Claude
/// Code binding input checked against the session process's ancestry. Both hook writers record
/// every key, but `zellijPane(in:)` reads the Zellij pane only from Claude Code records: Codex
/// hooks run in a shared daemon whose environment names another pane (ADR 0012).
///
/// A missing, empty, oversized or malformed value is absent, never trimmed or repaired.
public enum TerminalHookIdentifiers {
    /// Environment key → hook record key, snake case like the record's other keys.
    static let keys: [(environment: String, record: String)] = [
        ("ITERM_SESSION_ID", "iterm_session_id"),
        ("TERM_SESSION_ID", "term_session_id"),
        ("WEZTERM_PANE", "wezterm_pane"),
        (zellijPaneEnvironmentKey, zellijPaneRecordKey),
        (zellijSessionEnvironmentKey, zellijSessionRecordKey),
    ]
    static let zellijPaneEnvironmentKey = "ZELLIJ_PANE_ID"
    static let zellijPaneRecordKey = "zellij_pane_id"
    static let zellijSessionEnvironmentKey = "ZELLIJ_SESSION_NAME"
    static let zellijSessionRecordKey = "zellij_session_name"
    /// iTerm2's and Terminal.app's `w0t0p0:` plus a GUID is 42 bytes.
    public static let maximumLength = 128

    /// `value` when it is 1...`maximumLength` ASCII letters, digits, `:`, `_`, `-` or `.`.
    public static func validated(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximumLength,
              value.utf8.allSatisfy(isAllowed) else { return nil }
        return value
    }

    /// Adds every valid identifier in `environment` to a hook event record.
    public static func record(from environment: [String: String], into record: inout [String: Any]) {
        for key in keys {
            if let value = validated(environment[key.environment]) { record[key.record] = value }
        }
    }

    /// Every valid identifier recorded in a decoded hook event record, by record key. For
    /// diagnostics only.
    public static func diagnostics(in record: [String: Any]) -> [String: String] {
        keys.reduce(into: [:]) { result, key in
            if let value = validated(record[key.record] as? String) { result[key.record] = value }
        }
    }

    /// The Zellij pane a Claude Code hook event recorded, or nil for any other record, including
    /// every Codex record and a pane recorded without its session.
    public static func zellijPane(in record: [String: Any]) -> ZellijHookPane? {
        guard record["source"] as? String == ClaudeSetupRequirements.helperSource,
              let paneID = validated(record[zellijPaneRecordKey] as? String),
              paneID.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let session = validated(record[zellijSessionRecordKey] as? String) else { return nil }
        return ZellijHookPane(paneID: paneID, sessionName: session)
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

/// The bytes of hook record files read by earlier scans, reused while a file's `FileStamp` is
/// unchanged. Helpers write each record once, atomically, so normally only new records are opened.
/// Each scan carries forward only the files it read; readers apply their own size limits to the
/// cached bytes, which hold at most `maximumBytes + 1`.
public struct HookFileCache: Sendable {
    /// The largest limit any reader of this cache applies (`DesktopEventReader.maximumRecordSize`).
    static let maximumBytes = 128 * 1024

    struct Entry: Sendable {
        let stamp: FileStamp
        let bytes: Data?
    }

    var entries: [String: Entry] = [:]

    public init() {}

    /// Number of files held, for tests.
    var count: Int { entries.count }

    /// The files either cache read; `other`'s entry wins for a file both hold.
    public func merging(_ other: HookFileCache) -> HookFileCache {
        var merged = self
        merged.entries.merge(other.entries) { _, latest in latest }
        return merged
    }

    /// The file's bytes when it holds at most `limit` (≤ `maximumBytes`); nil when it is larger or
    /// unreadable. Reused from this cache while the file's stamp is unchanged; the read is recorded
    /// in `next` either way. A file that cannot be stat'ed is read uncached.
    func bytes(_ url: URL, limit: Int, next: inout HookFileCache) -> Data? {
        precondition(limit <= Self.maximumBytes)
        let stamp = FileStamp(url, followingLinks: true)
        let bytes: Data?
        if let stamp, let entry = entries[url.path] ?? next.entries[url.path], entry.stamp == stamp {
            next.entries[url.path] = entry
            bytes = entry.bytes
        } else {
            bytes = Self.read(url)
            if let stamp { next.entries[url.path] = Entry(stamp: stamp, bytes: bytes) }
        }
        guard let bytes, bytes.count <= limit else { return nil }
        return bytes
    }

    private static func read(_ url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        return try? file.read(upToCount: maximumBytes + 1)
    }
}
