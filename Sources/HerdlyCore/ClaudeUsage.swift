import Foundation

/// One subscription window reported by Claude's status-line payload.
public struct ClaudeUsageWindow: Equatable, Sendable {
    public let usedPercentage: Double
    public let resetsAt: Double

    public init(usedPercentage: Double, resetsAt: Double) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    public var percentText: String {
        "\(Int(min(100, max(0, usedPercentage)).rounded()))%"
    }

    public func isCurrent(now: Double) -> Bool {
        usedPercentage.isFinite && resetsAt.isFinite && usedPercentage >= 0 && usedPercentage <= 100 && resetsAt > now
    }
}

/// Claude usage from one configuration root and one session. Roots are never merged.
public struct ClaudeUsageReading: Equatable, Sendable {
    public let sourceScope: String
    public let sessionID: String?
    public let fiveHour: ClaudeUsageWindow?
    public let sevenDay: ClaudeUsageWindow?
    public let observedAt: Double

    public init(sourceScope: String, sessionID: String?, fiveHour: ClaudeUsageWindow?, sevenDay: ClaudeUsageWindow?, observedAt: Double) {
        self.sourceScope = sourceScope
        self.sessionID = sessionID
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.observedAt = observedAt
    }

    public func current(now: Double) -> ClaudeUsageReading? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        let current = ClaudeUsageReading(sourceScope: sourceScope, sessionID: sessionID,
                                         fiveHour: fiveHour?.isCurrent(now: now) == true ? fiveHour : nil,
                                         sevenDay: sevenDay?.isCurrent(now: now) == true ? sevenDay : nil,
                                         observedAt: observedAt)
        return current.fiveHour == nil && current.sevenDay == nil ? nil : current
    }

    /// The one reading the strip shows when several roots report: the most recently observed
    /// reading with a window still current. Equal observation times go to the lexicographically
    /// smallest root path, so the choice does not depend on dictionary order.
    public static func newest(_ readings: some Collection<ClaudeUsageReading>, now: Double) -> ClaudeUsageReading? {
        readings.compactMap { $0.current(now: now) }.max { lhs, rhs in
            lhs.observedAt != rhs.observedAt ? lhs.observedAt < rhs.observedAt : lhs.sourceScope > rhs.sourceScope
        }
    }
}

/// Decode and read Herdly's sanitized status-line records. The directory itself supplies the root
/// scope; the payload cannot make one root look like another.
public enum ClaudeUsageReader {
    public static let source = "herdly-claude-usage-v1"
    public static let maximumRecordBytes = 64 * 1024
    public static let maximumFiles = 4096
    public static let latestRecordName = "herdly-latest.json"

    public static func parse(_ data: Data, sourceScope: String, now: Double? = nil) -> ClaudeUsageReading? {
        guard data.count <= maximumRecordBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["source"] as? String == source,
              let observedAt = (object["observed_at"] as? NSNumber)?.doubleValue,
              observedAt.isFinite else { return nil }
        let sessionID = canonicalSessionID(object["session_id"])
        guard let sessionID else { return nil }
        let limits = object["rate_limits"] as? [String: Any]
        return ClaudeUsageReading(sourceScope: sourceScope, sessionID: sessionID,
                                  fiveHour: window(limits?["five_hour"]),
                                  sevenDay: window(limits?["seven_day"]), observedAt: observedAt)
            .current(now: now ?? -.infinity) ?? ClaudeUsageReading(sourceScope: sourceScope, sessionID: sessionID,
                                                                    fiveHour: nil, sevenDay: nil, observedAt: observedAt)
    }

    private static let memo = StampedFileMemo<Data?>()

    public static func latest(root: URL, sourceScope: String? = nil, now: Double = Date().timeIntervalSince1970) -> ClaudeUsageReading? {
        // The bridge owns one fixed snapshot. Reading that path directly keeps lookup bounded
        // even when a user places unrelated files or directories beside it.
        let record = root.appendingPathComponent(latestRecordName)
        // The bridge replaces the snapshot when it reports, so an unchanged stamp is not opened again.
        guard let data = memo.value(of: record, read: { SafeFile.read($0, limit: maximumRecordBytes) }) else { return nil }
        // The newest bridge record is authoritative for that root. A malformed or missing
        // window report must not resurrect an older session's reading.
        return parse(data, sourceScope: sourceScope ?? root.path, now: now)
    }

    /// Keep only the two subscription windows. A valid payload with no windows still produces an
    /// empty record so a newly missing window cannot leave an older value looking current.
    public static func sanitizedRecord(_ payload: Data, observedAt: Double = Date().timeIntervalSince1970) -> Data? {
        guard payload.count <= maximumRecordBytes,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              observedAt.isFinite else { return nil }
        var windows: [String: Any] = [:]
        if let limits = object["rate_limits"] as? [String: Any] {
            for name in ["five_hour", "seven_day"] {
                guard let value = limits[name] as? [String: Any],
                      let used = (value["used_percentage"] as? NSNumber)?.doubleValue,
                      let resets = (value["resets_at"] as? NSNumber)?.doubleValue,
                      used.isFinite, resets.isFinite, used >= 0, used <= 100 else { continue }
                windows[name] = ["used_percentage": used, "resets_at": resets]
            }
        }
        var record: [String: Any] = ["source": source, "observed_at": observedAt, "rate_limits": windows]
        if let sessionID = canonicalSessionID(object["session_id"]) {
            record["session_id"] = sessionID
        }
        guard JSONSerialization.isValidJSONObject(record) else { return nil }
        return try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    public static func record(_ payload: Data, to directory: URL, observedAt: Double = Date().timeIntervalSince1970) -> Bool {
        guard let data = sanitizedRecord(payload, observedAt: observedAt) else { return false }
        let destination = directory.appendingPathComponent(latestRecordName)
        let temporary = directory.appendingPathComponent(".herdly-usage-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard isOwnedRecord(at: destination) else {
                    removeTemporaryIfOwned(temporary, matching: data)
                    return false
                }
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            return true
        } catch {
            removeTemporaryIfOwned(temporary, matching: data)
            return false
        }
    }

    public static func isOwnedRecord(at url: URL) -> Bool {
        guard url.lastPathComponent == latestRecordName,
              let data = SafeFile.read(url, limit: maximumRecordBytes),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard object["source"] as? String == source,
              let observedAt = (object["observed_at"] as? NSNumber)?.doubleValue,
              observedAt.isFinite,
              object["rate_limits"] as? [String: Any] != nil else { return false }
        return true
    }

    private static func window(_ value: Any?) -> ClaudeUsageWindow? {
        guard let value = value as? [String: Any],
              let used = (value["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (value["resets_at"] as? NSNumber)?.doubleValue,
              used.isFinite, resets.isFinite, used >= 0, used <= 100 else { return nil }
        return ClaudeUsageWindow(usedPercentage: used, resetsAt: resets)
    }

    private static func canonicalSessionID(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count == 36,
              let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func removeTemporaryIfOwned(_ url: URL, matching data: Data) {
        let prefix = ".herdly-usage-"
        guard url.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))) != nil,
              SafeFile.read(url, limit: maximumRecordBytes) == data else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// The status-line bridge's small, stable command contract. The existing command is one shell
/// string because Claude itself invokes status-line commands through a shell.
public enum ClaudeStatusLineBridge {
    public static let marker = "--claude-status-line"

    public static func command(helperPath: URL, usagePath: URL, existingCommand: String?) -> String {
        let existing = existingCommand ?? ":"
        return "\(shellQuote(helperPath.path)) \(marker) --usage-dir \(shellQuote(usagePath.path)) --existing-command \(shellQuote(existing))"
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func statusLineCommand(_ statusLine: Any?) -> String? {
        guard let object = statusLine as? [String: Any],
              object["type"] as? String == "command",
              let command = object["command"] as? String,
              !command.isEmpty else { return nil }
        return command
    }

    public static func bridgeStatusLine(_ statusLine: Any?, helperPath: URL, usagePath: URL) -> [String: Any]? {
        let existing = statusLineCommand(statusLine)
        if statusLine != nil, existing == nil { return nil }
        var object = (statusLine as? [String: Any]) ?? [String: Any](minimumCapacity: 2)
        object["type"] = "command"
        object["command"] = command(helperPath: helperPath, usagePath: usagePath, existingCommand: existing)
        return object
    }

    public static func isBridgeCommand(_ command: String) -> Bool {
        command.contains(" \(marker) ") || command.hasSuffix(" \(marker)")
    }
}

public enum ClaudeUsageSetupStatus: Equatable, Sendable {
    public static let compatibilityFailureMessage = "Claude usage unavailable: the existing status line did not pass Herdly's cancellation compatibility probe."

    case off
    case ready
    case unavailable(String)
    case conflict(String)
}
