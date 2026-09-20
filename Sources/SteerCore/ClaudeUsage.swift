import Darwin
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
}

/// Decode and read Steer's sanitized status-line records. The directory itself supplies the root
/// scope; the payload cannot make one root look like another.
public enum ClaudeUsageReader {
    public static let source = "steer-claude-usage-v1"
    public static let maximumRecordBytes = 64 * 1024
    public static let maximumFiles = 4096

    public static func parse(_ data: Data, sourceScope: String, now: Double? = nil) -> ClaudeUsageReading? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["source"] as? String == source,
              let observedAt = (object["observed_at"] as? NSNumber)?.doubleValue,
              observedAt.isFinite else { return nil }
        let sessionID = (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let sessionID else { return nil }
        let limits = object["rate_limits"] as? [String: Any]
        return ClaudeUsageReading(sourceScope: sourceScope, sessionID: sessionID,
                                  fiveHour: window(limits?["five_hour"]),
                                  sevenDay: window(limits?["seven_day"]), observedAt: observedAt)
            .current(now: now ?? -.infinity) ?? ClaudeUsageReading(sourceScope: sourceScope, sessionID: sessionID,
                                                                    fiveHour: nil, sevenDay: nil, observedAt: observedAt)
    }

    public static func latest(root: URL, sourceScope: String? = nil, now: Double = Date().timeIntervalSince1970) -> ClaudeUsageReading? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root,
                                                                           includingPropertiesForKeys: [.contentModificationDateKey],
                                                                           options: [.skipsHiddenFiles]) else { return nil }
        let files = entries.compactMap { url -> (URL, Date)? in
            guard url.pathExtension == "json",
                  regularFile(url),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }.prefix(maximumFiles)
        for (url, _) in files {
            guard let data = try? Data(contentsOf: url), data.count <= maximumRecordBytes else { return nil }
            // The newest bridge record is authoritative for that root. A malformed or missing
            // window report must not resurrect an older session's reading.
            return parse(data, sourceScope: sourceScope ?? root.path, now: now)
        }
        return nil
    }

    /// Keep only the two subscription windows. A valid payload with no windows still produces an
    /// empty record so a newly missing window cannot leave an older value looking current.
    public static func sanitizedRecord(_ payload: Data, observedAt: Double = Date().timeIntervalSince1970) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
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
        if let sessionID = object["session_id"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 256 {
            record["session_id"] = sessionID
        }
        guard JSONSerialization.isValidJSONObject(record) else { return nil }
        return try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    public static func record(_ payload: Data, to directory: URL, observedAt: Double = Date().timeIntervalSince1970) -> Bool {
        guard let data = sanitizedRecord(payload, observedAt: observedAt) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".steer-" + UUID().uuidString)
            let destination = directory.appendingPathComponent(UUID().uuidString + ".json")
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return true
        } catch {
            return false
        }
    }

    private static func window(_ value: Any?) -> ClaudeUsageWindow? {
        guard let value = value as? [String: Any],
              let used = (value["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (value["resets_at"] as? NSNumber)?.doubleValue,
              used.isFinite, resets.isFinite, used >= 0, used <= 100 else { return nil }
        return ClaudeUsageWindow(usedPercentage: used, resetsAt: resets)
    }

    private static func regularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        return true
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
    case off
    case ready
    case unavailable(String)
    case conflict(String)
}

/// Bounded setup probe for an existing status-line command. A status line must finish promptly;
/// otherwise Claude's refresh cancellation can leave a descendant alive during session exit.
public enum ClaudeStatusLineCompatibility {
    public static let failureMessage = "Claude usage unavailable: the existing status line did not pass Steer's cancellation compatibility probe."

    public static func probe(command: String, timeout: TimeInterval = 0.75) -> Bool {
        let input = Data("{\"session_id\":\"probe\",\"rate_limits\":null}\n\u{1b}[32mprobe\u{1b}[0m\n".utf8)
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        // Process launches in its own group on the supported macOS runtime. Keep the check
        // explicit so a future launch implementation cannot accidentally signal Steer's group.
        let processGroupOwned = getpgid(process.processIdentifier) == process.processIdentifier
        stdin.fileHandleForWriting.write(input)
        stdin.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else {
            terminate(process: process, groupOwned: processGroupOwned)
            let cancellationDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < cancellationDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if processGroupOwned {
                _ = kill(-process.processIdentifier, SIGKILL)
            } else {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                for pid in descendants(of: process.processIdentifier) { _ = kill(pid, SIGKILL) }
            }
            process.waitUntilExit()
            return false
        }
        process.waitUntilExit()
        if processGroupOwned, kill(-process.processIdentifier, 0) == 0 {
            _ = kill(-process.processIdentifier, SIGTERM)
            Thread.sleep(forTimeInterval: 0.05)
            _ = kill(-process.processIdentifier, SIGKILL)
            return false
        }
        let remaining = descendants(of: process.processIdentifier)
        guard remaining.isEmpty else {
            for pid in remaining { _ = kill(pid, SIGTERM) }
            Thread.sleep(forTimeInterval: 0.05)
            for pid in remaining { _ = kill(pid, SIGKILL) }
            return false
        }
        var descriptor = pollfd(fd: stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLHUP), revents: 0)
        guard poll(&descriptor, 1, 200) > 0, descriptor.revents & Int16(POLLHUP) != 0 else { return false }
        return true
    }

    private static func terminate(process: Process, groupOwned: Bool) {
        if groupOwned {
            _ = kill(-process.processIdentifier, SIGTERM)
            return
        }
        for pid in descendants(of: process.processIdentifier) { _ = kill(pid, SIGTERM) }
        process.terminate()
    }

    private static func descendants(of root: pid_t) -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        guard let string = String(data: data, encoding: .utf8) else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for line in string.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
            children[parent, default: []].append(pid)
        }
        var pending = children[root] ?? []
        var result: [pid_t] = []
        while let pid = pending.popLast() {
            result.append(pid)
            pending.append(contentsOf: children[pid] ?? [])
        }
        return result
    }
}
