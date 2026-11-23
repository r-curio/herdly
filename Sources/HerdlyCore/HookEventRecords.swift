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
    ///
    /// A directory that changes often is not read in full each time when something watches it and
    /// reports the changed names to `changes`: the listing is then brought up to date from those
    /// names alone, and read in full only when they do not account for the directory's entry count.
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
    ///
    /// `now` is the wall clock, compared with the directory's modification time (`settleTime`).
    static func detailedListing(in directory: URL, limit: Int = maximumEntries, now: Double = Date().timeIntervalSince1970)
        -> (entries: [URL], records: ArraySlice<URL>, recordInodes: [UInt64])? {
        current(in: directory, limit: limit, now: now).map { ($0.urls, $0.records, $0.recordInodes) }
    }

    /// `listing(in:)`'s `records` with a number naming that listing: two calls that give the same
    /// number gave the same records, so a reader can reuse what it made of them without comparing
    /// thousands of URLs. Nil for a listing that was not kept (its directory could not be stamped),
    /// which is never the same as another. `now` is the wall clock, as for `detailedListing`.
    static func numberedRecords(in directory: URL, now: Double = Date().timeIntervalSince1970)
        -> (records: ArraySlice<URL>, number: UInt64?)? {
        current(in: directory, limit: maximumEntries, now: now).map { ($0.records, $0.number) }
    }

    private static func current(in directory: URL, limit: Int, now: Double) -> ListingCache.Entry? {
        let stamp = FileStamp(directory, followingLinks: true)
        let key = directory.standardizedFileURL.path
        let previous = listings.entry(key)
        // What a watcher saw change since the last call; nil when nothing watches this directory.
        // The directory changed: first have the watcher hand over everything it has not reported
        // yet, so the names cover every change made before the stamp was taken.
        if stamp == nil || previous?.stamp != stamp { changes.flush(key) }
        let reported = changes.take(key)
        if let stamp, let previous, previous.stamp == stamp, reported ?? .names([]) == .names([]) {
            return previous.urls.count <= limit ? previous : nil
        }
        if let stamp, let previous, case .names(let names)? = reported, !names.isEmpty,
           HookDirectoryChangeLog.settled(modifiedAt: stamp.modifiedAt, now: now),
           let entry = updated(previous, with: names, in: directory, stamp: stamp), entry.urls.count <= limit {
            return listings.store(entry, for: key)
        }
        listings.countFullRead(key)
        guard let entry = relisted(directory, previous: previous, stamp: stamp, limit: limit) else { return nil }
        return stamp != nil ? listings.store(entry, for: key) : entry
    }

    /// How many times this directory was read in full, for tests.
    static func fullReadCount(in directory: URL) -> Int {
        listings.fullReads(directory.standardizedFileURL.path)
    }

    /// The listing read from the directory itself, with nothing reused: what every other route to a
    /// listing must equal. Tests only.
    static func fullListing(in directory: URL) -> (entries: [URL], records: ArraySlice<URL>, recordInodes: [UInt64])? {
        relisted(directory, previous: nil, stamp: nil, limit: maximumEntries).map { ($0.urls, $0.records, $0.recordInodes) }
    }

    /// Reads every name in `directory`, reusing `previous` only for the creation dates of entries
    /// still listed under the same inode. Nil when it is unreadable or holds more than `limit` entries.
    private static func relisted(_ directory: URL, previous: ListingCache.Entry?, stamp: FileStamp?,
                                 limit: Int) -> ListingCache.Entry? {
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
        return entry(stamp: stamp, kept: kept, added: added, dates: dates)
    }

    /// `previous` brought up to date from the `names` a watcher reported, without reading the
    /// directory: each name is looked at once, and is an addition, a replacement (another inode), a
    /// removal (no longer there) or unchanged. Nil, for a full read instead, when a name cannot be
    /// looked at or the result does not hold exactly as many entries as the directory says it has:
    /// a change the watcher has not reported yet. `stamp` must have been taken before this call.
    private static func updated(_ previous: ListingCache.Entry, with names: Set<String>, in directory: URL,
                                stamp: FileStamp) -> ListingCache.Entry? {
        guard let count = entryCount(directory) else { return nil }
        var dates = previous.dates
        var added: [Dated] = []
        var removedAny = false
        for name in names {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
            var info = stat()
            let status = directory.appendingPathComponent(name).withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return lstat(path, &info) == 0 ? 0 : (errno == ENOENT ? 1 : -1)
            }
            switch status {
            case 0:
                let inode = UInt64(info.st_ino)
                if let known = previous.dates[name] {
                    if known.inode == inode { continue }
                    removedAny = true
                }
                let url = directory.appendingPathComponent(name, isDirectory: info.st_mode & S_IFMT == S_IFDIR)
                let entry = Dated(name: name, url: url, inode: inode, created: Self.created(url))
                dates[name] = entry
                added.append(entry)
            case 1:
                if dates.removeValue(forKey: name) != nil { removedAny = true }
            default:
                return nil
            }
        }
        guard dates.count == count else { return nil }
        if added.isEmpty, !removedAny {
            return ListingCache.Entry(stamp: stamp, urls: previous.urls, records: previous.records,
                                      recordInodes: previous.recordInodes, order: previous.order, dates: previous.dates)
        }
        guard removedAny else {
            // Only additions. When all are newer than the newest entry, the listing just grows at its end.
            let sorted = added.sorted(by: Dated.older)
            if let newest = previous.order.last.flatMap({ dates[$0]?.created }), sorted.allSatisfy({ $0.created > newest }) {
                let newRecords = sorted.filter { isRecordName($0.name) }
                return ListingCache.Entry(
                    stamp: stamp, urls: previous.urls + sorted.map(\.url),
                    records: ArraySlice(Array((previous.records + newRecords.map(\.url)).suffix(maximumRecords))),
                    recordInodes: Array((previous.recordInodes + newRecords.map(\.inode)).suffix(maximumRecords)),
                    order: previous.order + sorted.map(\.name), dates: dates)
            }
            return entry(stamp: stamp, kept: previous.order, added: added, dates: dates)
        }
        let kept = previous.order.filter { name in
            guard let entry = dates[name] else { return false }
            return previous.dates[name]?.inode == entry.inode
        }
        return entry(stamp: stamp, kept: kept, added: added, dates: dates)
    }

    /// The listing of `dates`: `kept` are the entries still in their earlier order, `added` the rest.
    private static func entry(stamp: FileStamp?, kept: [String], added: [Dated],
                              dates: [String: Dated]) -> ListingCache.Entry {
        let order: [String]
        if let newest = kept.last.flatMap({ dates[$0]?.created }), added.allSatisfy({ $0.created > newest }) {
            order = kept + added.sorted(by: Dated.older).map(\.name)
        } else {
            order = dates.values.sorted(by: Dated.older).map(\.name)
        }
        let ordered = order.compactMap { dates[$0]?.url }
        let newest = order.filter(isRecordName).compactMap { dates[$0] }.suffix(maximumRecords)
        return ListingCache.Entry(stamp: stamp, urls: ordered, records: ArraySlice(newest.map(\.url)),
                                  recordInodes: newest.map(\.inode), order: order, dates: dates)
    }

    /// How many entries the directory says it holds. APFS counts each entry as a link beside the
    /// directory's own two; on a file system that counts otherwise the number never matches a
    /// listing, and every change is simply read in full.
    private static func entryCount(_ directory: URL) -> Int? {
        var info = stat()
        let status = directory.withUnsafeFileSystemRepresentation { path in path.map { stat($0, &info) } ?? -1 }
        guard status == 0, info.st_nlink >= 2 else { return nil }
        return Int(info.st_nlink) - 2
    }

    /// What watchers report about the directories they watch (`HookDirectoryChangeLog`).
    public static let changes = HookDirectoryChangeLog()

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
            /// The directory's stamp, taken before it was listed; nil when it could not be stamped,
            /// and such a listing is never kept.
            let stamp: FileStamp?
            let urls: [URL]
            let records: ArraySlice<URL>
            /// Each of `records`' inodes as the directory listed it, in the same order.
            let recordInodes: [UInt64]
            /// `urls`' names, in the same order.
            let order: [String]
            let dates: [String: Dated]
            /// Set when the listing is kept: a number no other kept listing has. Nil until then.
            var number: UInt64?
        }

        // Invariant for `@unchecked Sendable`: `entries` is only touched while holding `lock`.
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func entry(_ key: String) -> Entry? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        /// Keeps `entry` and returns it numbered.
        @discardableResult
        func store(_ entry: Entry, for key: String) -> Entry {
            lock.lock(); defer { lock.unlock() }
            stored += 1
            var entry = entry
            entry.number = stored
            entries[key] = entry
            return entry
        }

        private var stored: UInt64 = 0
        private var reads: [String: Int] = [:]

        func countFullRead(_ key: String) {
            lock.lock(); defer { lock.unlock() }
            reads[key, default: 0] += 1
        }

        func fullReads(_ key: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return reads[key] ?? 0
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

/// Deletes expired hook records from one of Herdly's event directories. Tool records label the current
/// tool, and subagent records list a session's running subagents and end their calls, so both expire
/// after `toolRecordAge`; every other record after `recordAge`.
///
/// What is kept regardless of age:
/// - a tool call with no completion, turn end or session end (a waiting question or a request lives in
///   one); a call inside a subagent instead stays exactly while the subagent's run that holds it is open
///   (`ClaudeSubagentLifetimes`, the reader's rule), and keeps the general rule when no run holds it;
/// - the start of a subagent the Claude reader still lists, and a subagent's start and stop while one
///   of its calls is kept, so the reader never sees the call without what ended it;
/// - lifecycle records of sessions that still have an unresolved approval request file (a handed-back
///   reminder resolves from their session end);
/// - anything Herdly cannot identify as its own record: request, receipt and decision files, malformed
///   or foreign JSON, symlinks and directories.
///
/// Age is the file's creation date.
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
        /// Claude's raw `prompt_id`; `ClaudeSubagentLifetimes` bounds it as the reader does.
        let prompt: String?
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
        // When each subagent runs, as the Claude reader decides it.
        var lifetimes = ClaudeSubagentLifetimes()
        for record in records {
            lifetimes.note(event: record.event, session: record.session, agent: record.agent, prompt: record.prompt,
                           at: record.capturedAt)
        }
        let nowSeconds = now.timeIntervalSince1970
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
            // A subagent's call ends with the run that holds it, and only then, as the reader ends it. A call
            // no run holds keeps the rules below.
            if let agent = record.agent {
                switch lifetimes.call(session: record.session, agent: agent, at: record.capturedAt, now: nowSeconds) {
                case .ended: return false
                case .running: return true
                case .unknown: break
                }
            }
            if let turn = record.turn, let ended = endedTurns[turnKey(record.session, turn)], ended >= record.capturedAt {
                return false
            }
            if let ended = endedSessions[record.session], ended >= record.capturedAt { return false }
            return true
        }
        // The reader lists a subagent while its run is open (`ClaudeSubagentLifetimes`).
        func isRunning(_ record: Record) -> Bool {
            guard record.event == "SubagentStart", let agent = record.agent else { return false }
            return lifetimes.call(session: record.session, agent: agent, at: record.capturedAt, now: nowSeconds) == .running
        }

        var keptToolStarts = Set<String>()
        var keptAgentCalls = Set<String>()
        func keep(call record: Record) {
            if let tool = record.tool { keptToolStarts.insert(toolKey(record.session, tool)) }
            if let agent = record.agent { keptAgentCalls.insert(agentKey(record.session, agent)) }
        }
        var completions: [Record] = []
        var oldSubagentRecords: [Record] = []
        for record in records {
            let isTool = toolEvents.contains(record.event)
            let isSubagent = subagentEvents.contains(record.event)
            if record.age >= recordAge {
                if isTool || isSubagent || !protectedSessions.contains(record.session) { expired.append(record.url) }
            } else if isSubagent, record.age >= toolRecordAge {
                oldSubagentRecords.append(record)
            } else if isTool, record.age >= toolRecordAge {
                if record.event == "PreToolUse" {
                    if isOpen(record) { keep(call: record) } else { expired.append(record.url) }
                } else {
                    completions.append(record)
                }
            } else if record.event == "PreToolUse" {
                keep(call: record)
            }
        }
        // A subagent's start and stop stay while it runs or while one of its calls is still on disk.
        for record in oldSubagentRecords where !isRunning(record) {
            if let agent = record.agent, keptAgentCalls.contains(agentKey(record.session, agent)) { continue }
            expired.append(record.url)
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
                      tool: tool, agent: ClaudeObservationReader.subagentID(in: object),
                      prompt: object["prompt_id"] as? String, closes: event == "PostToolBatch" ? batch : tool.map { [$0] } ?? [],
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
/// `ITERM_SESSION_ID`, `TERM_SESSION_ID`, `WEZTERM_PANE` and `REX_BLOCK` are recorded for diagnostics only: they
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
        ("REX_BLOCK", "rex_block"),
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

/// What a watcher saw change in a directory since `HookEventListing` last asked.
public enum HookDirectoryChanges: Equatable, Sendable {
    /// These top-level names were added, replaced, rewritten or removed; possibly none.
    case names(Set<String>)
    /// Something changed that the watcher cannot name: the directory must be read in full.
    case unknown
}

/// What one batch of a watcher's events says about its directory, for `HookDirectoryChangeLog`.
public enum HookWatchReport: Equatable, Sendable {
    /// These top-level names changed; none when every change lay below the top level.
    case names(Set<String>)
    /// Events were lost or name something else: read the directory in full. `watchLost` when the
    /// directory itself moved or its volume changed, so the watcher may be following nothing.
    case unknown(watchLost: Bool)

    /// - Parameters:
    ///   - prefix: the directory's real path with a trailing slash, as events name it.
    ///   - droppedFlags: event flags meaning names were lost.
    ///   - lostFlags: event flags meaning the directory moved or its volume changed.
    public static func from(paths: [String], flags: [UInt32], prefix: String,
                            droppedFlags: UInt32, lostFlags: UInt32) -> HookWatchReport {
        var names = Set<String>()
        for (path, flag) in zip(paths, flags) {
            guard flag & (droppedFlags | lostFlags) == 0, path.hasPrefix(prefix) else {
                return .unknown(watchLost: flags.contains { $0 & lostFlags != 0 })
            }
            let name = path.dropFirst(prefix.count)
            // The listing is top-level only; what changes inside a subdirectory does not change it.
            if !name.isEmpty, !name.contains("/") { names.insert(String(name)) }
        }
        return .names(names)
    }
}

/// Changed names reported by whatever watches a hook event directory (HerdlyApp, through macOS
/// file-system events), held until `HookEventListing` next lists that directory.
///
/// A report is a hint about where to look, never a fact about the directory: the listing looks at
/// every reported name itself and checks the directory's own entry count, so a wrong or missing
/// report costs a full read and cannot invent a record.
///
/// macOS reports a change some milliseconds after it happens, and nothing makes it report sooner
/// (measured: 4 to 10 ms; a flush only hands over what has already reached the event service). So
/// names are relied on only once the directory's last change is `settleTime` old, after asking the
/// watcher for what it holds; a younger change is read in full. What remains is a change later than
/// that whose report is later still, in a directory whose entry count happens to match: an addition
/// and a removal together. Its report arrives within moments, is never dropped, and corrects the
/// listing on the next call. Reports for a directory
/// nobody watches are dropped. Watching starts as `unknown`, so the first listing is a full read
/// taken after the watcher was already running.
public final class HookDirectoryChangeLog: @unchecked Sendable {
    /// Past this many pending names a full read is cheaper than looking at each.
    public static let maximumNames = 512
    /// How old a directory's last change must be before reported names are relied on for it.
    public static let settleTime: Double = 0.1

    /// Whether a directory last changed at `modifiedAt` (wall clock) has settled by `now`. A change
    /// dated in the future, or a clock that is not a number, has not.
    public static func settled(modifiedAt: Double, now: Double) -> Bool {
        now.isFinite && modifiedAt.isFinite && now - modifiedAt >= settleTime
    }

    // Invariant for `@unchecked Sendable`: `pending` is only touched while holding `lock`.
    private let lock = NSLock()
    private var pending: [String: HookDirectoryChanges] = [:]
    private var flushes: [String: @Sendable () -> Void] = [:]
    /// Watched directories with a report since `takeScanEvidence` last asked (#306). Kept apart from
    /// `pending`, which the listing empties from the scan's own thread.
    private var touched: Set<String> = []
    /// Watched directories whose watch said it may no longer follow them, until watching starts again.
    private var lost: Set<String> = []

    public init() {}

    /// - Parameter flush: makes the watcher report, before it returns, every change that had
    ///   already happened when it was called (macOS delivers file-system events a moment late).
    ///   It may call `report` and `reportUnknown`; it is called from whichever thread lists.
    public func startWatching(_ directory: URL, flush: @escaping @Sendable () -> Void = {}) {
        lock.lock(); defer { lock.unlock() }
        pending[Self.key(directory)] = .unknown
        flushes[Self.key(directory)] = flush
        // A new watch knows nothing of what changed before it started.
        touched.insert(Self.key(directory))
        lost.remove(Self.key(directory))
    }

    public func stopWatching(_ directory: URL) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: Self.key(directory))
        flushes.removeValue(forKey: Self.key(directory))
        touched.remove(Self.key(directory))
        lost.remove(Self.key(directory))
    }

    /// Asks the directory's watcher, if any, to report what it has not reported yet.
    func flush(_ key: String) {
        lock.lock()
        let flush = flushes[key]
        lock.unlock()
        flush?()
    }

    /// `names` may be empty: something changed under the directory that is not a top-level name.
    public func report(_ names: Set<String>, in directory: URL) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(directory)
        if pending[key] != nil { touched.insert(key) }
        guard case .names(let known)? = pending[key] else { return }
        let all = known.union(names)
        pending[key] = all.count > Self.maximumNames ? .unknown : .names(all)
    }

    /// - Parameter watchLost: the watcher may no longer follow the directory (it moved, or its volume
    ///   went away). The directory then counts as unwatched for `takeScanEvidence` until
    ///   `startWatching` is called for it again.
    public func reportUnknown(in directory: URL, watchLost: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(directory)
        guard pending[key] != nil else { return }
        pending[key] = .unknown
        touched.insert(key)
        if watchLost { lost.insert(key) }
    }

    /// Whether the watcher gave up on this directory (`reportUnknown(in:watchLost:)`).
    public func isWatchLost(_ directory: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lost.contains(Self.key(directory))
    }

    /// What the watchers say about the directories a scan would list, for `HookScanSchedule` (#306).
    /// `changed`: any watched directory had a report since the last call, which then starts again
    /// from nothing. `trusted`: every one of `directories` is watched by a watcher that has not given
    /// up; with none to watch there is nothing to distrust. A caller that does not scan loses nothing:
    /// it passes `changed` on (`HookScanSchedule.noteChange`), where it stays until a scan starts.
    public func takeScanEvidence(for directories: [URL]) -> (changed: Bool, trusted: Bool) {
        lock.lock(); defer { lock.unlock() }
        let changed = !touched.isEmpty
        touched = []
        let trusted = directories.allSatisfy { pending[Self.key($0)] != nil && !lost.contains(Self.key($0)) }
        return (changed, trusted)
    }

    /// What was reported for the directory with this listing key since the last call, which then
    /// starts again from nothing; nil when the directory is not watched.
    func take(_ key: String) -> HookDirectoryChanges? {
        lock.lock(); defer { lock.unlock() }
        guard let value = pending[key] else { return nil }
        pending[key] = .names([])
        return value
    }

    private static func key(_ directory: URL) -> String { directory.standardizedFileURL.path }
}
