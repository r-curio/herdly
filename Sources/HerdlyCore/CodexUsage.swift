import Foundation

/// One of Codex's usage windows as Codex last reported it: how much of the window is used and
/// when the window resets, read from the newest session rollout.
///
/// Every turn, Codex appends a `token_count` event to the session's rollout under
/// `~/.codex/sessions/YYYY/MM/DD/rollout-…jsonl`:
/// `{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":7.0,
/// "window_minutes":10080,"resets_at":1789831495},"secondary":null,…}}}`.
/// The weekly window is whichever of `primary` and `secondary` spans 10080 minutes and the
/// five-hour window whichever spans 300; some plans report the weekly window as `primary` with no
/// secondary, others a five-hour `primary` with the weekly window as `secondary`.
///
/// This is a private, build-specific format (observed with CLI 0.153.4). The reader fails soft: a
/// line it cannot read is skipped, and no readable window means no reading, so the strip shows a
/// dash instead of a wrong number. See docs/codex-usage.md.
public struct CodexUsageWindow: Equatable, Sendable {
    public static let weeklyMinutes = 10080
    public static let fiveHourMinutes = 300

    /// Share of the window used, 0 to 100, as Codex reported it.
    public let usedPercent: Double
    /// Unix time at which the window resets.
    public let resetsAt: Double
    /// The rollout event's own timestamp, when it had one.
    public let observedAt: String?

    public init(usedPercent: Double, resetsAt: Double, observedAt: String? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    /// Whole percent for the strip: never above 100, never negative.
    public var percentText: String { UsageShare(usedPercent: usedPercent).percentText }

    /// Once the window has reset, the reading no longer describes the current period.
    public func isCurrent(now: Double) -> Bool { resetsAt > now }

    /// The window itself while it has not reset; nil after.
    public func ifCurrent(now: Double) -> CodexUsageWindow? { isCurrent(now: now) ? self : nil }
}

/// Codex's weekly and five-hour windows from one `token_count` event; either may be absent.
public struct CodexUsageReading: Equatable, Sendable {
    public let weekly: CodexUsageWindow?
    public let fiveHour: CodexUsageWindow?

    public init(weekly: CodexUsageWindow?, fiveHour: CodexUsageWindow?) {
        self.weekly = weekly
        self.fiveHour = fiveHour
    }

    /// The windows that have not yet reset; nil once neither describes the present, so the strip
    /// shows nothing stale.
    public func current(now: Double) -> CodexUsageReading? {
        let reading = CodexUsageReading(weekly: weekly?.ifCurrent(now: now), fiveHour: fiveHour?.ifCurrent(now: now))
        return reading.weekly == nil && reading.fiveHour == nil ? nil : reading
    }
}

public enum CodexUsageReader {
    /// Only the end of a rollout is read; the last `token_count` line is what matters.
    public static let tailBytes = 512 * 1024
    /// Newest rollouts inspected before giving up, and day directories walked to find them.
    public static let maximumFiles = 8
    public static let maximumDays = 14

    public static func defaultRoot(codexHome: URL) -> URL {
        codexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    /// The latest usage reading across the newest rollouts under `root`, or nil when none of them
    /// carries the weekly window. Files are tried newest-modified first, so a session that has just started
    /// and has no `token_count` yet falls through to the one before it.
    public static func latest(root: URL) -> CodexUsageReading? {
        for entry in newestRollouts(root: root) {
            // A rollout only grows, which changes its stamp: an unchanged one is not opened again.
            if let reading = memo.value(of: entry.url, read: { tail($0).flatMap(parse) }) { return reading }
        }
        return nil
    }

    private static let memo = StampedFileMemo<CodexUsageReading?>()

    /// Rollouts from the newest day directories, newest modification first, at most `limit`
    /// (`RolloutDays`, which lists a directory again only when it changed).
    static func newestRollouts(root: URL, limit: Int = maximumFiles) -> [(url: URL, modified: Date)] {
        RolloutDays.newest(root: root, limit: limit)
    }

    /// An open handle and the size of a regular, non-symlinked file; nil for anything else.
    static func regularFile(_ url: URL) -> (handle: FileHandle, size: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        return (file, size)
    }

    /// The last `tailBytes` of a regular, non-symlinked file. A cut first line is skipped by `parse`.
    static func tail(_ url: URL) -> Data? {
        guard let (file, size) = regularFile(url) else { return nil }
        defer { try? file.close() }
        if size > tailBytes { try? file.seek(toOffset: UInt64(size - tailBytes)) }
        return try? file.read(upToCount: tailBytes)
    }

    /// The plan's own limit. Rollouts also carry per-model limits (`codex_bengalfox`, the Spark
    /// model) whose windows are not the plan's; those lines are skipped, and a line naming no limit
    /// at all is read as older rollouts may not carry the id.
    public static let planLimitID = "codex"

    /// The windows from the last `token_count` line that carries the plan's weekly window; the
    /// five-hour window comes from that same line when it has one. Lines that are not a JSON object
    /// of that shape, including a partial line mid-append, are skipped.
    public static func parse(_ bytes: Data) -> CodexUsageReading? {
        for line in bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any],
                  (limits["limit_id"] as? String ?? planLimitID) == planLimitID else { continue }
            let observed = object["timestamp"] as? String
            var weekly: CodexUsageWindow?
            var fiveHour: CodexUsageWindow?
            for key in ["primary", "secondary"] {
                guard let entry = limits[key] as? [String: Any],
                      let minutes = (entry["window_minutes"] as? NSNumber)?.intValue,
                      let used = (entry["used_percent"] as? NSNumber)?.doubleValue, used.isFinite,
                      let resets = (entry["resets_at"] as? NSNumber)?.doubleValue, resets.isFinite else { continue }
                let window = CodexUsageWindow(usedPercent: used, resetsAt: resets, observedAt: observed)
                if minutes == CodexUsageWindow.weeklyMinutes { weekly = weekly ?? window }
                else if minutes == CodexUsageWindow.fiveHourMinutes { fiveHour = fiveHour ?? window }
            }
            if weekly != nil { return CodexUsageReading(weekly: weekly, fiveHour: fiveHour) }
        }
        return nil
    }
}
