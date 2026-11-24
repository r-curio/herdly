import Foundation

// Claude Desktop Code sessions (#471, docs/evidence/claude-desktop-sessions.md). Claude Desktop runs
// Claude Code itself with the user's hooks, so its sessions reach Herdly like any Claude session but
// with no terminal. Open returns to one through Claude Desktop's own link,
// `claude://code/continue?session=local_<id>`, whose id comes only from Claude Desktop's per-session
// file that names the hook session as `cliSessionId`. Both the files and the link are Claude Desktop
// internals, not a documented interface, so every reading fails closed: anything unexpected leaves
// the session without an exact target, and Open then only raises Claude Desktop. Nothing here
// acknowledges a result (agreed 2026-11-24: only Dismiss does for a desktop session).

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

    public init(localIDs: [String: String] = [:]) {
        self.localIDs = localIDs
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
        var found: [String: Set<String>] = [:]
        for data in files {
            guard data.count <= maximumFileSize,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let local = object["sessionId"] as? String, isLocalID(local),
                  let hook = ClaudeInventoryDecoder.canonicalSessionID(object["cliSessionId"]) else { continue }
            found[hook, default: []].insert(local)
        }
        return ClaudeDesktopSessionIndex(localIDs: found.compactMapValues { $0.count == 1 ? $0.first : nil })
    }

    /// Reads the index under Claude Desktop's Application Support folder, nil when the session folder
    /// is missing or cannot be listed, or holds more files than the bound. Folders and files are
    /// opened without following symlinks.
    public static func read(applicationSupport: URL) -> ClaudeDesktopSessionIndex? {
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
        return decode(files.compactMap { SafeFile.read($0, limit: maximumFileSize) })
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
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["lastFocusedAt"] as? NSNumber,
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
    /// jump as unverified.
    public static let verificationTimeout: TimeInterval = 2

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
    public static func verified(lastFocusedAt: Double?, clickedAt: Double) -> Bool {
        guard let lastFocusedAt else { return false }
        return lastFocusedAt >= clickedAt - 0.05
    }
}
