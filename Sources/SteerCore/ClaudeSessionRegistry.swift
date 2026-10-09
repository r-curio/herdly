import Darwin
import Foundation

/// Reads Claude Code's per-process session registry (`<CLAUDE_CONFIG_DIR>/sessions/<pid>.json`) as
/// an inventory. Claude Code 2.1.292 no longer accepts `claude agents --json`, but each live Claude
/// process keeps one registry entry with the identity and lifecycle fields that command returned.
///
/// The registry is raw process state, not the CLI's normalized inventory:
/// - Claude rewrites an entry in place (no rename), so a read can see an empty or partial file.
///   A torn entry is re-read a bounded number of times; one still torn from a live process makes the
///   scan unavailable, and one from a process that is gone is ignored.
/// - Entries outlive their process. An entry counts only while its PID runs and, when Claude
///   recorded `procStart`, that process started at the recorded UTC time, so a reused PID never
///   revives a session.
/// - Only `interactive` entries (or entries with no `kind`, which Claude treats as interactive)
///   become inventory rows. Other holders of a session are not duplicates: a `bg` entry only marks
///   its session as background, and `daemon`, `daemon-worker`, and parked-job entries are skipped.
///   An unknown kind makes the scan unavailable. Claude writes the `shell` status when the prompt is
///   idle while a background Bash task (a dev server, say) is still running, so it is reported as
///   `idle`: the turn has ended.
///
/// Remaining rows are validated by `ClaudeInventoryDecoder`, so an unknown status, a malformed
/// identity, or two live interactive entries for one session make the scan unavailable rather than
/// silently shrinking it.
public enum ClaudeSessionRegistry {
    public static let directoryName = "sessions"
    public static let maximumEntries = 256
    public static let maximumEntrySize = 64 * 1024
    public static let tornReadAttempts = 3

    /// A registry entry's process identity: its PID and Claude's recorded start time, if any.
    public struct Process: Equatable, Sendable {
        public let pid: Int32
        public let procStart: String?

        public init(pid: Int32, procStart: String?) {
            self.pid = pid
            self.procStart = procStart
        }
    }

    /// One registry file: the PID its name carries and the bytes read, nil when it vanished.
    public struct Entry: Sendable {
        public let pid: Int32
        public let data: Data?

        public init(pid: Int32, data: Data?) {
            self.pid = pid
            self.data = data
        }
    }

    /// The registry under `root` as an inventory, or nil when `root` has no registry directory (a
    /// Claude version without one). Entries are opened without following symlinks; a non-regular
    /// or unreadable entry makes the scan unavailable.
    public static func read(root: URL, observedAt: Double, isRunning: (Process) -> Bool = isRunning,
                            retryDelay: TimeInterval = 0.02) -> ClaudeInventoryScan? {
        let directory = root.standardizedFileURL.appendingPathComponent(directoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let unavailable = ClaudeInventoryScan.unavailable(sourceScope: root.path, observedAt: observedAt,
                                                          reason: ClaudeInventoryDecoder.invalidMessage)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return unavailable }
        let files = names.compactMap { name -> (String, Int32)? in
            guard name.hasSuffix(".json"), let pid = Int32(name.dropLast(5)), pid > 0 else { return nil }
            return (name, pid)
        }
        guard files.count <= maximumEntries else { return unavailable }
        var entries: [Entry] = []
        for (name, pid) in files {
            let path = directory.appendingPathComponent(name).path
            var data: Data?
            for attempt in 0..<tornReadAttempts {
                guard case let .read(value) = readEntry(path) else { return unavailable }
                data = value
                if value == nil || parse(value!) != nil || attempt == tornReadAttempts - 1 { break }
                // Claude may be mid-rewrite; a dead process's torn file never settles, so don't wait on it.
                guard isRunning(Process(pid: pid, procStart: nil)) else { break }
                Thread.sleep(forTimeInterval: retryDelay)
            }
            entries.append(Entry(pid: pid, data: data))
        }
        return decode(entries, sourceScope: root.path, observedAt: observedAt, isRunning: isRunning)
    }

    /// - Parameters:
    ///   - entries: each registry file's name PID and contents, any order.
    ///   - isRunning: whether the entry's process is still the one Claude registered.
    public static func decode(_ entries: [Entry], sourceScope: String, observedAt: Double,
                              isRunning: (Process) -> Bool) -> ClaudeInventoryScan {
        func unavailable(_ reason: String) -> ClaudeInventoryScan {
            .unavailable(sourceScope: sourceScope, observedAt: observedAt, reason: reason)
        }
        guard entries.count <= maximumEntries else { return unavailable(ClaudeInventoryDecoder.incompleteMessage) }
        var rows: [[String: Any]] = []
        var pids: [String: Int32] = [:]
        var background: Set<String> = []
        for entry in entries {
            // A vanished entry's session ended, and any entry, torn or malformed, is harmless once
            // the process its name carries is gone.
            guard let data = entry.data, isRunning(Process(pid: entry.pid, procStart: nil)) else { continue }
            guard let row = parse(data), let process = process(row), process.pid == entry.pid else {
                return unavailable(ClaudeInventoryDecoder.invalidMessage)
            }
            // The PID now belongs to a different process than the one Claude registered.
            guard isRunning(process) else { continue }
            guard row["parkedJobId"] == nil else { continue }
            switch row["kind"] {
            case nil, "interactive" as String:
                // Claude treats a missing kind as interactive.
                var normalized = row
                normalized["kind"] = "interactive"
                if row["status"] as? String == "shell" { normalized["status"] = "idle" }
                rows.append(normalized)
                // A duplicate session ID makes the decoder reject the scan, so this pid is never misattributed.
                if let sessionID = (row["sessionId"] as? String).flatMap(UUID.init(uuidString:)) {
                    pids[sessionID.uuidString.lowercased()] = process.pid
                }
            case "bg" as String:
                // A background holder has no `state`; it only marks the session as background.
                guard let sessionID = (row["sessionId"] as? String).flatMap(UUID.init(uuidString:)) else {
                    return unavailable(ClaudeInventoryDecoder.incompleteMessage)
                }
                background.insert(sessionID.uuidString.lowercased())
            case "daemon" as String, "daemon-worker" as String:
                continue
            default:
                return unavailable(ClaudeInventoryDecoder.unsupportedKindMessage)
            }
        }
        let scan = ClaudeInventoryDecoder.decode(rows: rows, sourceScope: sourceScope, observedAt: observedAt)
        guard scan.available else { return scan }
        let sessions = scan.sessions.map {
            ClaudeInventorySession(sessionID: $0.sessionID, name: $0.name, kind: $0.kind, startedAt: $0.startedAt,
                                   lifecycle: $0.lifecycle, pid: pids[$0.sessionID], directory: $0.directory)
        }
        return ClaudeInventoryScan(sourceScope: sourceScope, observedAt: observedAt, sessions: sessions,
                                   backgroundSessionIDs: background)
    }

    /// Whether `process` is alive (not a zombie) and, when Claude recorded `procStart`, started at
    /// that time. Claude writes `procStart` as the process start in UTC in `ctime` layout.
    public static func isRunning(_ process: Process) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process.pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == process.pid, info.kp_proc.p_stat != SZOMB else { return false }
        guard let recorded = process.procStart else { return true }
        var seconds = info.kp_proc.p_starttime.tv_sec
        var utc = tm()
        guard gmtime_r(&seconds, &utc) != nil else { return false }
        return procStart(weekday: Int(utc.tm_wday), month: Int(utc.tm_mon), day: Int(utc.tm_mday),
                         hour: Int(utc.tm_hour), minute: Int(utc.tm_min), second: Int(utc.tm_sec),
                         year: Int(utc.tm_year) + 1900) == recorded
    }

    /// Claude's `procStart` text for a UTC start time: `ctime` layout with English names, independent
    /// of the current locale. `weekday` counts from Sunday = 0 and `month` from January = 0.
    public static func procStart(weekday: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int,
                                 year: Int) -> String? {
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard weekdays.indices.contains(weekday), months.indices.contains(month), (1...31).contains(day) else { return nil }
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        let paddedDay = day < 10 ? " \(day)" : "\(day)"
        return "\(weekdays[weekday]) \(months[month]) \(paddedDay) \(two(hour)):\(two(minute)):\(two(second)) \(year)"
    }

    private enum EntryRead {
        case read(Data?)
        case failed
    }

    /// Reads one entry: `.read(nil)` when it no longer exists, `.failed` for a symlink, non-regular
    /// file, or read error. At most `maximumEntrySize + 1` bytes are read.
    private static func readEntry(_ path: String) -> EntryRead {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 { return errno == ENOENT ? .read(nil) : .failed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .failed }
        // `read(upToCount:)` returns nil at end of file, so an empty entry is empty data, not a failure.
        do { return .read(try handle.read(upToCount: maximumEntrySize + 1) ?? Data()) } catch { return .failed }
    }

    private static func parse(_ data: Data) -> [String: Any]? {
        guard data.count <= maximumEntrySize else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func process(_ row: [String: Any]) -> Process? {
        guard let number = row["pid"] as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID(),
              let pid = Int32(exactly: number.doubleValue), pid > 0 else { return nil }
        let procStart: String?
        if let raw = row["procStart"] {
            guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 64 else { return nil }
            procStart = value
        } else {
            procStart = nil
        }
        return Process(pid: pid, procStart: procStart)
    }
}

/// The process Claude's inventories name for one session, as ADR 0008's foreground rule requires it
/// in a herdr pane. Kept separate from "no inventory" so an ambiguous session never falls back to
/// the weaker name rule.
public enum ClaudeSessionProcess: Equatable, Hashable, Sendable {
    /// No inventory names the session's process: none lists it as interactive, or the one that
    /// does came from `claude agents --json`, which carries no PID. The foreground rule falls back
    /// to a process named `claude`.
    case unidentified
    /// Exactly one available inventory lists the session as interactive, and its registry names
    /// this live process.
    case identified(pid: Int32)
    /// Several available inventories list the session as interactive, or an inventory reports it
    /// held by two interactive processes, whether from a registry or `claude agents --json`. No one
    /// process can be required, so the binding fails closed.
    case ambiguous

    /// Selects the session's process from every configured root's latest inventory.
    ///
    /// - Parameters:
    ///   - sessionID: compared exactly, as `HerdrSessionKey` keeps Claude session IDs. herdr's pane
    ///     binding carries no root, so every root is searched rather than one.
    ///   - inventories: the latest scan of each root, available or not. Only available scans list
    ///     sessions; an unavailable one counts only through its `ambiguousSessionIDs`.
    public init(sessionID: String, inventories: [ClaudeInventoryScan]) {
        if inventories.contains(where: { $0.ambiguousSessionIDs.contains(sessionID) }) {
            self = .ambiguous
            return
        }
        let holders = inventories.filter(\.available).flatMap(\.sessions)
            .filter { $0.kind == .interactive && $0.sessionID == sessionID }
        switch holders.count {
        case 0: self = .unidentified
        case 1: self = holders[0].pid.map { .identified(pid: $0) } ?? .unidentified
        default: self = .ambiguous
        }
    }
}
