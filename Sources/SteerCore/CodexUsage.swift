import Foundation

/// Codex's weekly usage limit as Codex last reported it: how much of the window is used and when
/// the window resets, read from the newest session rollout.
///
/// Every turn, Codex appends a `token_count` event to the session's rollout under
/// `~/.codex/sessions/YYYY/MM/DD/rollout-…jsonl`:
/// `{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":7.0,
/// "window_minutes":10080,"resets_at":1789831495},"secondary":null,…}}}`.
/// The weekly window is whichever of `primary` and `secondary` spans 10080 minutes; some plans
/// report it as `primary` with no secondary, others as `secondary` behind a five-hour `primary`.
///
/// This is a private, build-specific format (observed with CLI 0.153.4). The reader fails soft: a
/// line it cannot read is skipped, and no readable window means no reading, so the strip shows a
/// dash instead of a wrong number. See docs/codex-usage.md.
public struct CodexWeeklyLimit: Equatable, Sendable {
    public static let windowMinutes = 10080

    /// Share of the weekly window used, 0 to 100, as Codex reported it.
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
    public var percentText: String { "\(Int(min(100, max(0, usedPercent)).rounded()))%" }

    /// Once the window has reset, the reading no longer describes the current week.
    public func isCurrent(now: Double) -> Bool { resetsAt > now }
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

    /// The latest weekly reading across the newest rollouts under `root`, or nil when none of them
    /// carries one. Files are tried newest-modified first, so a session that has just started and
    /// has no `token_count` yet falls through to the one before it.
    public static func latest(root: URL) -> CodexWeeklyLimit? {
        for entry in newestRollouts(root: root) {
            if let bytes = tail(entry.url), let limit = parse(bytes) { return limit }
        }
        return nil
    }

    /// Rollouts from the newest day directories, newest modification first, at most `limit`.
    static func newestRollouts(root: URL, limit: Int = maximumFiles) -> [(url: URL, modified: Date)] {
        var days: [URL] = []
        for year in subdirectories(root).prefix(3) {
            for month in subdirectories(year).prefix(3) {
                for day in subdirectories(month) {
                    days.append(day)
                    if days.count == maximumDays { break }
                }
                if days.count == maximumDays { break }
            }
            if days.count == maximumDays { break }
        }
        var files: [(URL, Date)] = []
        for day in days {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: day, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                              options: [.skipsHiddenFiles]) else { continue }
            for url in entries where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((url, modified))
            }
        }
        return files.sorted { $0.1 == $1.1 ? $0.0.path > $1.0.path : $0.1 > $1.1 }.prefix(limit).map { (url: $0.0, modified: $0.1) }
    }

    /// Child directories with numeric names, newest (largest) first.
    private static func subdirectories(_ url: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                          options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { Int($0.lastPathComponent) != nil && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
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

    /// The weekly window from the last `token_count` line that carries one. Lines that are not a
    /// JSON object of that shape, including a partial line mid-append, are skipped.
    public static func parse(_ bytes: Data) -> CodexWeeklyLimit? {
        for line in bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any],
                      (window["window_minutes"] as? NSNumber)?.intValue == CodexWeeklyLimit.windowMinutes,
                      let used = (window["used_percent"] as? NSNumber)?.doubleValue, used.isFinite,
                      let resets = (window["resets_at"] as? NSNumber)?.doubleValue, resets.isFinite else { continue }
                return CodexWeeklyLimit(usedPercent: used, resetsAt: resets, observedAt: object["timestamp"] as? String)
            }
        }
        return nil
    }
}
