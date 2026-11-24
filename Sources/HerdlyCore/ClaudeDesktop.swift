import Foundation

// Claude Desktop Code sessions (#471, docs/evidence/claude-desktop-sessions.md). Claude Desktop runs
// Claude Code itself with the user's hooks, so its sessions reach Herdly like any Claude session but
// with no terminal. Open returns to one through Claude Desktop's own link,
// `claude://code/continue?session=local_<id>`, whose id comes only from Claude Desktop's per-session
// file that names the hook session as `cliSessionId`. Both the files and the link are Claude Desktop
// internals, not a documented interface, so every reading fails closed: anything unexpected leaves
// the session without an exact target, and Open then only raises Claude Desktop. Results acknowledge
// by ADR 0016's verified Open, visit and dwell rules, with "visible" read from the session files'
// `lastFocusedAt` and macOS's frontmost app (agreed 2026-11-24, #474).

/// How a Claude Desktop session reads in the notch (agreed 2026-11-24, #471).
public enum ClaudeDesktopPresentation {
    /// The row's place, in place of "project @ branch".
    public static let place = "Claude Desktop"
}

/// The exact Claude Desktop id of each hook session, from Claude Desktop's session files.
public struct ClaudeDesktopSessionIndex: Equatable, Sendable {
    /// Claude Desktop's own bundle identifier.
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    /// The folder under Claude Desktop's Application Support that holds one file per Code session,
    /// two levels down (account, then organization).
    public static let directoryName = "claude-code-sessions"
    /// Files read per scan and bytes per file. A session file lists every enabled MCP tool, so it is
    /// larger than its few identity fields; Claude Desktop 5.11492.5 wrote about 75 KB.
    public static let maximumFiles = 4096
    public static let maximumFileSize = 1024 * 1024

    /// Hook session id (lowercased) to Claude Desktop id. A hook session two files name with different
    /// Claude Desktop ids is left out, so it has no exact target.
    public let localIDs: [String: String]
    /// The Claude Desktop id with the strictly latest `lastFocusedAt`: the session Claude Desktop last
    /// brought to the front. Nil when no file records a focus or two share the latest one.
    public let frontLocalID: String?

    public init(localIDs: [String: String] = [:], frontLocalID: String? = nil) {
        self.localIDs = localIDs
        self.frontLocalID = frontLocalID
    }

    /// The Claude Desktop id for `hookSession`, compared case-insensitively as hook ids are UUIDs.
    public func localID(for hookSession: String) -> String? {
        localIDs[hookSession.lowercased()]
    }

    /// A Claude Desktop id the continue link accepts: `local_` and 1–64 letters, digits or hyphens,
    /// the same rule Claude Desktop applies before opening one.
    public static func isLocalID(_ value: String) -> Bool {
        guard value.hasPrefix("local_") else { return false }
        let rest = value.dropFirst("local_".count)
        return (1...64).contains(rest.count)
            && rest.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" }
    }

    /// The index from session files' contents. A file that does not parse, or lacks a valid
    /// `sessionId` or `cliSessionId`, is skipped: it names no session.
    public static func decode(_ files: [Data]) -> ClaudeDesktopSessionIndex {
        combine(files.compactMap(entry))
    }

    /// One session file's identity and focus, nil when it names no exact session.
    static func entry(_ data: Data) -> ClaudeDesktopSessionFileCache.Entry? {
        guard data.count <= maximumFileSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let local = object["sessionId"] as? String, isLocalID(local),
              let hook = ClaudeInventoryDecoder.canonicalSessionID(object["cliSessionId"]) else { return nil }
        return .init(localID: local, hookSession: hook, focusedAt: lastFocusedAt(object))
    }

    static func combine(_ entries: [ClaudeDesktopSessionFileCache.Entry]) -> ClaudeDesktopSessionIndex {
        var found: [String: Set<String>] = [:]
        var latest: (focusedAt: Double, localIDs: Set<String>)?
        for entry in entries {
            let local = entry.localID
            found[entry.hookSession, default: []].insert(local)
            if let focusedAt = entry.focusedAt {
                if latest == nil || focusedAt > latest!.focusedAt {
                    latest = (focusedAt, [local])
                } else if focusedAt == latest!.focusedAt {
                    latest!.localIDs.insert(local)
                }
            }
        }
        return ClaudeDesktopSessionIndex(localIDs: found.compactMapValues { $0.count == 1 ? $0.first : nil },
                                         frontLocalID: latest.flatMap { $0.localIDs.count == 1 ? $0.localIDs.first : nil })
    }

    /// Reads the index under Claude Desktop's Application Support folder, nil when the session folder
    /// is missing or cannot be listed, or holds more files than the bound. Folders and files are
    /// opened without following symlinks.
    public static func read(applicationSupport: URL) -> ClaudeDesktopSessionIndex? {
        var cache = ClaudeDesktopSessionFileCache()
        return read(applicationSupport: applicationSupport, cache: &cache)
    }

    /// The same read, reusing `cache`'s parse of each file whose modification date and size are
    /// unchanged. Claude Desktop rewrites a session file whenever its focus or activity changes, so the
    /// visit check, which reads every two seconds while Claude Desktop is frontmost, parses only what
    /// changed. Files that are gone leave the cache.
    public static func read(applicationSupport: URL, cache: inout ClaudeDesktopSessionFileCache) -> ClaudeDesktopSessionIndex? {
        let root = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
        guard let accounts = directories(in: root) else { return nil }
        var files: [URL] = []
        for account in accounts {
            for organization in directories(in: account) ?? [] {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: organization.path)) ?? []
                for name in names where name.hasPrefix("local_") && name.hasSuffix(".json") {
                    files.append(organization.appendingPathComponent(name))
                    if files.count > maximumFiles { return nil }
                }
            }
        }
        var entries: [ClaudeDesktopSessionFileCache.Entry] = []
        var kept: [String: ClaudeDesktopSessionFileCache.Stamped] = [:]
        for url in files {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
            let stamp = values.flatMap { v -> ClaudeDesktopSessionFileCache.Stamp? in
                guard v.isSymbolicLink != true, let modified = v.contentModificationDate, let size = v.fileSize else { return nil }
                return .init(modified: modified, size: size)
            }
            if let stamp, let cached = cache.files[url.path], cached.stamp == stamp {
                kept[url.path] = cached
                if let entry = cached.entry { entries.append(entry) }
                continue
            }
            let entry = SafeFile.read(url, limit: maximumFileSize).flatMap(entry)
            if let entry { entries.append(entry) }
            // A file whose stamp could not be read is parsed every time rather than trusted.
            if let stamp { kept[url.path] = .init(stamp: stamp, entry: entry) }
        }
        cache.files = kept
        return combine(entries)
    }

    /// Claude Desktop's Application Support folder for the current user.
    public static var defaultApplicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    /// The `lastFocusedAt` Claude Desktop recorded for `localID`, in seconds, nil when unreadable.
    /// Open's verification compares it with the click (`ClaudeDesktopOpen.verified`).
    public static func lastFocusedAt(localID: String, applicationSupport: URL) -> Double? {
        guard isLocalID(localID) else { return nil }
        let root = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
        for account in directories(in: root) ?? [] {
            for organization in directories(in: account) ?? [] {
                let url = organization.appendingPathComponent(localID + ".json")
                guard let data = SafeFile.read(url, limit: maximumFileSize) else { continue }
                return lastFocusedAt(data)
            }
        }
        return nil
    }

    /// `lastFocusedAt` from one session file's contents, Claude Desktop's milliseconds as seconds.
    public static func lastFocusedAt(_ data: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return lastFocusedAt(object)
    }

    private static func lastFocusedAt(_ object: [String: Any]) -> Double? {
        guard let number = object["lastFocusedAt"] as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue / 1000
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Real subdirectories of `url` (no symlinks), nil when it is not one or cannot be listed.
    private static func directories(in url: URL) -> [URL]? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        return names.sorted().compactMap { name in
            let child = url.appendingPathComponent(name, isDirectory: true)
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return child
        }
    }
}

/// What one Open of a Claude Desktop session does, decided from fresh readings. Pure: opening the
/// link, raising the app and reading the files belong to HerdlyApp.
public enum ClaudeDesktopOpen {
    /// How long Open waits for Claude Desktop to record the session's focus before it counts the
    /// jump as unverified. Claude Desktop writes the session file about 1.0–1.4 s after the jump when
    /// idle; 2 s proved too short live (2026-11-24), so a reached session showed the fallback note.
    public static let verificationTimeout: TimeInterval = 5

    public enum Plan: Equatable, Sendable {
        /// Open this link, then verify the session took focus.
        case exact(URL)
        /// No exact target: raise Claude Desktop only.
        case raise
        case unavailable(OpenUnavailableReason)
    }

    public enum Result: Equatable, Sendable {
        /// Claude Desktop recorded the session's focus after the click.
        case opened
        /// Claude Desktop was brought forward without a verified jump to the session.
        case raised
        case unavailable(OpenUnavailableReason)

        /// Reached the session or raised its app, so an actionable request is handed back with no
        /// decision (ADR 0015, #411). An unavailable Open hands nothing back.
        public var handsBackRequest: Bool {
            if case .unavailable = self { return false }
            return true
        }

        /// The card's line after this Open: the fallback note, the unavailable reason, or none.
        public var cardLine: OpenUnavailableReason? {
            switch self {
            case .opened: nil
            case .raised: .claudeDesktopSessionNotFound
            case .unavailable(let reason): reason
            }
        }
    }

    /// The plan for a session at click time, from fresh readings.
    /// - Parameters:
    ///   - complete: every configured Claude root's registry was read and is available.
    ///   - holders: how many interactive entries across those reads hold the session.
    ///   - desktopHolder: the session's own root lists it as interactive in Claude Desktop.
    ///   - listedAnywhere: any read lists the session at all, background included.
    ///   - localID: the session's Claude Desktop id from a fresh index, nil when it has none.
    ///   - claudeRunning: Claude Desktop is running now. Herdly never launches it.
    public static func plan(complete: Bool, holders: Int, desktopHolder: Bool, listedAnywhere: Bool,
                            localID: String?, claudeRunning: Bool) -> Plan {
        guard complete else { return .unavailable(.appNotIdentified) }
        if holders == 0 { return .unavailable(listedAnywhere ? .appNotIdentified : .sessionEnded) }
        guard holders == 1, desktopHolder else { return .unavailable(.appNotIdentified) }
        guard claudeRunning else { return .unavailable(.claudeDesktopNotRunning) }
        guard let localID, let url = continueURL(localID: localID) else { return .raise }
        return .exact(url)
    }

    /// Claude Desktop's link to one Code session, nil for an id it would refuse.
    public static func continueURL(localID: String) -> URL? {
        guard ClaudeDesktopSessionIndex.isLocalID(localID) else { return nil }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: localID)]
        return components.url
    }

    /// Whether Claude Desktop recorded focusing the session at or after the click. Its clock is the
    /// same machine's, in milliseconds, so a small tolerance covers rounding only.
    /// Whether Claude Desktop already showed the session when Open was clicked: macOS reported Claude
    /// Desktop frontmost, and the session has the strictly latest `lastFocusedAt`. Claude Desktop writes
    /// no new focus for a link to the session it already shows (live, 2026-11-24), so `verified` would
    /// never pass; the link still names the exact session, so the Open counts as reached.
    public static func alreadyShowing(localID: String, claudeFrontmost: Bool, index: ClaudeDesktopSessionIndex?) -> Bool {
        claudeFrontmost && index?.frontLocalID == localID
    }

    public static func verified(lastFocusedAt: Double?, clickedAt: Double) -> Bool {
        guard let lastFocusedAt else { return false }
        return lastFocusedAt >= clickedAt - 0.05
    }
}

/// ADR 0016's visible test for Claude Desktop sessions (#474), over Claude Desktop ids. Claude Desktop
/// writes a session's `lastFocusedAt` when it selects the session or comes to the front with it
/// selected, about a second later, and writes nothing while it stays in front or when it loses focus
/// (probe of 2026-11-24 on Claude.app 5.11492.5). So the front session is the one with the latest
/// focus, and only while macOS reports Claude Desktop frontmost. A switch between sessions reads the
/// previous session for up to that second.
public enum ClaudeDesktopVisibility {
    /// - Parameters:
    ///   - frontmost: macOS reports Claude Desktop as the frontmost app as the scan starts.
    ///   - index: a fresh read of the session files, nil when they could not be read.
    public static func reading(frontmost: Bool, index: ClaudeDesktopSessionIndex?) -> TerminalVisibilityReading<String> {
        guard frontmost else { return .nothing }
        guard let front = index?.frontLocalID else { return .unknown }
        return .visible(front)
    }

    /// A verified Open (`ClaudeDesktopOpen.Result.opened`) acknowledges the session's completions that
    /// arrived strictly before the click. A raise or an unavailable Open acknowledges nothing.
    public static func afterOpen<ID>(_ completions: [TerminalCompletionCandidate<ID>], result: ClaudeDesktopOpen.Result,
                                     clickedAt: Double) -> Set<ID> {
        guard result == .opened, clickedAt.isFinite else { return [] }
        return Set(completions.filter { $0.arrivedAt.isFinite && $0.arrivedAt < clickedAt }.map(\.id))
    }
}

/// Parsed Claude Desktop session files by path, each with the modification date and size it was
/// parsed at (`ClaudeDesktopSessionIndex.read(applicationSupport:cache:)`).
public struct ClaudeDesktopSessionFileCache: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        let localID: String
        let hookSession: String
        let focusedAt: Double?
    }

    struct Stamp: Equatable, Sendable {
        let modified: Date
        let size: Int
    }

    struct Stamped: Equatable, Sendable {
        let stamp: Stamp
        /// Nil for a file that names no exact session.
        let entry: Entry?
    }

    var files: [String: Stamped] = [:]

    public init() {}

    /// How many files the cache holds, for tests.
    public var count: Int { files.count }
}
