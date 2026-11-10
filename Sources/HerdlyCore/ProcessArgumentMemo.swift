import Foundation

/// The argument vectors the scheduled process listing read recently, so the 2-second scan does not ask
/// the kernel for every process's vector each time (`KERN_PROCARGS2` is one call per process).
///
/// A vector is reused only for the same process: same pid, same start time and same short name. A new
/// process is always read at once. A process that replaces its own image keeps its pid and start time,
/// and usually changes its short name; for the case where it does not, a kept vector is read again once
/// it is `maximumAge` old. A vector the kernel would not give is never kept.
///
/// Only the scheduled listing may use this. A read made to choose a target reads the kernel directly.
public struct ProcessArgumentMemo: Sendable {
    public static let maximumAge: Double = 10

    /// What tells one process from a later one that reuses its pid.
    public struct Identity: Hashable, Sendable {
        public let pid: Int32
        public let startedSeconds: Int
        public let startedMicroseconds: Int
        public let shortName: String

        public init(pid: Int32, startedSeconds: Int, startedMicroseconds: Int, shortName: String) {
            self.pid = pid
            self.startedSeconds = startedSeconds
            self.startedMicroseconds = startedMicroseconds
            self.shortName = shortName
        }
    }

    private struct Entry: Sendable {
        let identity: Identity
        let arguments: [String]
        let readAt: Double
    }

    private var entries: [Int32: Entry] = [:]

    public init() {}

    /// Number of vectors held, for tests.
    var count: Int { entries.count }

    /// `process`'s vector at the monotonic `now`: the kept one while it is the same process and younger
    /// than `maximumAge`, otherwise what `read` returns.
    public mutating func arguments(of process: Identity, now: Double, read: () -> [String]?) -> [String]? {
        if let entry = entries[process.pid], entry.identity == process,
           now.isFinite, now >= entry.readAt, now - entry.readAt < Self.maximumAge {
            return entry.arguments
        }
        guard let arguments = read() else {
            entries.removeValue(forKey: process.pid)
            return nil
        }
        if now.isFinite { entries[process.pid] = Entry(identity: process, arguments: arguments, readAt: now) }
        return arguments
    }

    /// Drops every process not in `pids`: the ones the latest table no longer lists.
    public mutating func keep(_ pids: Set<Int32>) {
        entries = entries.filter { pids.contains($0.key) }
    }
}
