import Foundation

/// A turn a session rollout shows as started and not yet ended: the candidate for a session that
/// was already running when the companion launched, before any hook event of its own arrives.
public struct DiscoveredTurn: Equatable, Sendable {
    public let session: UUID
    public let source: AttentionSource
    public let turn: UUID
    /// The rollout timestamp of the `task_started` event, or of the earliest line seen for the
    /// turn when its start lies beyond the bytes read.
    public let startedAt: String

    public init(session: UUID, source: AttentionSource, turn: UUID, startedAt: String) {
        self.session = session
        self.source = source
        self.turn = turn
        self.startedAt = startedAt
    }
}

/// What the app knows about which sessions can still be alive, gathered outside the rollouts.
public struct SessionLiveness: Equatable, Sendable {
    /// The Codex desktop app is running (`NSWorkspace`).
    public var desktopRunning: Bool
    /// At least one Codex CLI process is running on this Mac (`CodexCLIProcesses`).
    public var cliProcessRunning: Bool
    /// CLI sessions whose session-ID title is on a Ghostty tab right now, when Ghostty controls are on.
    public var cliSessionsInGhostty: Set<UUID>
    /// Latest SessionEnd hook time per session, from the events directory.
    public var sessionEnds: [UUID: Double]

    public init(desktopRunning: Bool, cliProcessRunning: Bool, cliSessionsInGhostty: Set<UUID>, sessionEnds: [UUID: Double]) {
        self.desktopRunning = desktopRunning
        self.cliProcessRunning = cliProcessRunning
        self.cliSessionsInGhostty = cliSessionsInGhostty
        self.sessionEnds = sessionEnds
    }
}

/// Recognizes Codex CLI processes in a `ps -axo args=` listing.
public enum CodexCLIProcesses {
    /// True when any process runs an executable named `codex…` (the npm launcher is `codex.js`, the
    /// Homebrew binary `codex-aarch64-apple-darwin`) other than an app-server, which is the
    /// desktop app's own backend and never a terminal session.
    public static func isRunning(processList: String) -> Bool {
        processList.split(separator: "\n").contains { line in
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            // The executable, or the script an interpreter runs, is one of the first two words.
            return words.prefix(2).contains { isCodexExecutable($0.split(separator: "/").last ?? "") }
                && !words.contains("app-server")
        }
    }

    static func isCodexExecutable(_ name: Substring) -> Bool {
        name == "codex" || name == "codex.js" || name.hasPrefix("codex-")
    }
}

/// One process in a Codex TUI's ancestry, from the TUI itself up: its executable's file name (from
/// the kernel, so a path with spaces is whole) and, for an app's main executable, the app's bundle
/// identifier.
public struct ProcessAncestor: Equatable, Sendable {
    public let command: String
    public let bundleIdentifier: String?

    public init(command: String, bundleIdentifier: String?) {
        self.command = command
        self.bundleIdentifier = bundleIdentifier
    }
}

extension CodexCLIProcesses {
    /// The processes in `ps -axo pid=,args=` output whose command line names Codex and is not the
    /// app-server: the ones whose ancestry may be walked. Loose on purpose, since an executable path
    /// may contain spaces; `hostReached` confirms each by its kernel-reported executable name.
    public static func candidatePIDs(processList: String) -> [Int32] {
        // One pass over the bytes with `memchr`/`memmem`: the list holds every process's full
        // arguments and is read every scan, and splitting it into substrings and searching each one
        // cost more than everything else in the scan (#306). The rules are unchanged: leading spaces
        // skipped, the pid is the text before the first space, and the rest must contain `codex` and
        // not `app-server`.
        var text = processList
        return text.withUTF8 { bytes -> [Int32] in
            guard let base = bytes.baseAddress else { return [] }
            let raw = UnsafeRawPointer(base)
            var pids: [Int32] = []
            var start = 0
            while start < bytes.count {
                let end = memchr(raw + start, 0x0A, bytes.count - start).map { UnsafeRawPointer($0) - raw } ?? bytes.count
                defer { start = end + 1 }
                var first = start
                while first < end, bytes[first] == 0x20 { first += 1 }
                guard let space = memchr(raw + first, 0x20, end - first).map({ UnsafeRawPointer($0) - raw }),
                      contains("codex", in: raw, from: space, to: end),
                      !contains("app-server", in: raw, from: space, to: end),
                      let pid = Int32(String(decoding: UnsafeBufferPointer(rebasing: bytes[first..<space]), as: UTF8.self))
                else { continue }
                pids.append(pid)
            }
            return pids
        }
    }

    private static func contains(_ needle: StaticString, in raw: UnsafeRawPointer, from: Int, to: Int) -> Bool {
        to - from >= needle.utf8CodeUnitCount
            && memmem(raw + from, to - from, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    /// `ps -axo pid=,args=` output without its pid column, for `isRunning`.
    public static func arguments(processList: String) -> String {
        processList.split(separator: "\n").map { line in
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), Int32(trimmed[..<space]) != nil else { return String(trimmed) }
            return String(trimmed[space...].drop { $0 == " " })
        }.joined(separator: "\n")
    }

    /// The host a Codex TUI runs in, from its ancestry: nil when the process is not a Codex
    /// executable. Otherwise the nearest multiplexer server (tmux, Zellij, herdr), whose own parent
    /// is not the terminal, or else the nearest app when it is a supported terminal. Nil when the
    /// walk reaches neither.
    public static func hostReached(by ancestry: [ProcessAncestor]) -> TerminalHost? {
        guard let first = ancestry.first, isCodexExecutable(Substring(first.command)) else { return nil }
        let multiplexers: [String: TerminalHost] = ["tmux": .tmux, "zellij": .zellij, "herdr": .herdr]
        for ancestor in ancestry.dropFirst() {
            if let host = multiplexers[ancestor.command] { return host }
            if let identifier = ancestor.bundleIdentifier { return TerminalHost(bundleIdentifier: identifier) }
        }
        return nil
    }

    /// How many Codex TUIs in `ancestries` reach each host.
    public static func hostsReached(by ancestries: [[ProcessAncestor]]) -> [TerminalHost: Int] {
        ancestries.compactMap(hostReached(by:)).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}

/// Finds sessions that are working right now from their rollouts alone.
///
/// Codex opens every rollout with a `session_meta` line whose `source` names the surface (`"cli"`
/// for the terminal, `"vscode"` for the desktop app) and appends `task_started` when a turn begins
/// and `task_complete` or `turn_aborted` when it ends. A rollout whose last turn has started and
/// not ended is a candidate; whether it is shown as working is decided by `running`, which needs
/// liveness evidence beyond the file. See docs/session-discovery.md.
public enum SessionDiscovery {
    static let sources: [String: AttentionSource] = ["cli": .cli, "vscode": .desktop]
    /// A rollout untouched for this long is not a running session, whatever its last turn says:
    /// a turn that died with the process leaves `task_started` dangling forever, while a live
    /// turn keeps appending (a parent thread waiting on subagents was seen writing every minute).
    public static let maximumAge: Double = 3600
    /// The first line carries the session identity; the tail carries its latest turn events.
    public static let headBytes = 64 * 1024
    public static let tailBytes = CodexUsageReader.tailBytes
    /// Newest rollouts inspected per scan; each two-second scan rereads them.
    public static let maximumFiles = 24

    /// Open turns in the newest rollouts under `root` that were written within `maximumAge` of
    /// `now`, newest first. Symlinks and irregular files are never read.
    public static func candidates(root: URL, now: Double) -> [DiscoveredTurn] {
        var found: [DiscoveredTurn] = []
        for entry in CodexUsageReader.newestRollouts(root: root, limit: maximumFiles) {
            guard now - entry.modified.timeIntervalSince1970 <= maximumAge, let open = openTurn(at: entry.url) else { continue }
            found.append(open)
        }
        return found
    }

    /// What the last successful read of each rollout found. A rollout only grows, which changes its
    /// stamp, so an unchanged one is not opened or parsed again. A read that failed is never kept.
    private static let memo = StampedFileMemo<Read>()

    private struct Read: Sendable {
        let open: DiscoveredTurn?
    }

    /// The open turn in the rollout at `url`, from its first line and its bounded tail.
    static func openTurn(at url: URL) -> DiscoveredTurn? {
        // The stamp is taken before the read, so an append during it shows as a new stamp next time.
        let kept = memo.kept(url)
        if let value = kept.value { return value.open }
        guard let (head, tail) = read(url) else { return nil }
        var found: DiscoveredTurn?
        if let first = firstLine(head) {
            let lines = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)[...]
            found = Self.open(meta: Data(first), lines: lines)
        }
        if let stamp = kept.stamp { memo.keep(Read(open: found), for: url, stamp: stamp) }
        return found
    }

    /// The first line that is not empty, without splitting the rest: the head holds up to
    /// `headBytes` of lines and only this one is used.
    static func firstLine(_ bytes: Data) -> Data.SubSequence? {
        let newline = UInt8(ascii: "\n")
        let start = bytes.drop { $0 == newline }
        return start.isEmpty ? nil : start.prefix { $0 != newline }
    }

    /// The candidates that may be shown as working. A rollout alone never proves a session is
    /// alive: a desktop turn needs the desktop app running; a CLI turn needs its tab on screen or,
    /// failing that, any Codex CLI process; and a SessionEnd hook recorded after the turn started
    /// rules the session out whatever else is running. Nothing here becomes a completion, request,
    /// or question: those still need their own evidence.
    public static func running(_ candidates: [DiscoveredTurn], liveness: SessionLiveness) -> [AttentionRunning] {
        candidates.compactMap { candidate in
            guard let startedAt = RolloutTimestamp.parse(candidate.startedAt) else { return nil }
            if let ended = liveness.sessionEnds[candidate.session], ended >= startedAt { return nil }
            switch candidate.source {
            case .desktop:
                guard liveness.desktopRunning else { return nil }
            case .cli:
                guard liveness.cliSessionsInGhostty.contains(candidate.session) || liveness.cliProcessRunning else { return nil }
            }
            return AttentionRunning(source: candidate.source, session: candidate.session, turn: candidate.turn, arrivedAt: startedAt)
        }
    }

    /// The bounded head and tail of a regular file. A file shorter than both is read once.
    static func read(_ url: URL) -> (head: Data, tail: Data)? {
        read(url, header: { $0 }).map { (head: $0.header, tail: $0.tail) }
    }

    /// `read(_:)`, where `header` decodes the head bytes first: nil from it skips the file without
    /// reading its tail (`CodexSubagentReader` reads tails of subagent rollouts only).
    static func read<Header>(_ url: URL, header: (Data) -> Header?) -> (header: Header, tail: Data)? {
        guard let (file, size) = CodexUsageReader.regularFile(url) else { return nil }
        defer { try? file.close() }
        guard let head = try? file.read(upToCount: min(size, headBytes)), let decoded = header(head) else { return nil }
        if size <= headBytes { return (decoded, head.dropFirst(head.firstIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? head.count)) }
        try? file.seek(toOffset: UInt64(max(size - tailBytes, 0)))
        guard let tail = try? file.read(upToCount: tailBytes) else { return nil }
        return (decoded, tail)
    }

    /// The open turn in one rollout, or nil when its last turn ended, it is not a user session, or
    /// it cannot be read.
    public static func parse(_ bytes: Data) -> DiscoveredTurn? {
        var lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)[...]
        guard let first = lines.popFirst() else { return nil }
        return open(meta: first, lines: lines)
    }

    /// Only the CLI and desktop surfaces qualify: subagent threads carry an object as their source
    /// and `exec` runs have no tab or thread to return to.
    ///
    /// The open turn is the last turn any line names that no later `task_complete` or
    /// `turn_aborted` ended. Every item Codex records during a turn names the turn, either as the
    /// event's `turn_id` or in a response item's passthrough metadata, so a turn whose
    /// `task_started` line lies beyond the tail read (a long turn writes megabytes) is still found;
    /// its `startedAt` is then the earliest line seen for it, a lower bound on how long it has run.
    /// A line that names no turn is skipped, including a partial line mid-append or the cut first
    /// line of a tail read.
    static func open(meta first: Data, lines: ArraySlice<Data>) -> DiscoveredTurn? {
        guard let event = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
              event["type"] as? String == "session_meta",
              let meta = event["payload"] as? [String: Any],
              let session = (meta["id"] as? String).flatMap(UUID.init(uuidString:)),
              let source = (meta["source"] as? String).flatMap({ sources[$0] }) else { return nil }
        let events = lines.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return openTurn(in: events).map { DiscoveredTurn(session: session, source: source, turn: $0.turn, startedAt: $0.startedAt) }
    }

    /// The open turn among decoded rollout lines, by the rule `open(meta:lines:)` documents; shared
    /// with `CodexSubagentReader`, so a subagent counts as running exactly when a session would.
    static func openTurn(in events: [[String: Any]]) -> (turn: UUID, startedAt: String)? {
        var current: (turn: UUID, startedAt: String)?
        var ended: Set<UUID> = []
        for event in events {
            guard let payload = event["payload"] as? [String: Any],
                  let turn = turnID(in: payload) else { continue }
            let kind = event["type"] as? String == "event_msg" ? payload["type"] as? String : nil
            if kind == "task_complete" || kind == "turn_aborted" {
                ended.insert(turn)
                if current?.turn == turn { current = nil }
                continue
            }
            // A line written after an end seen here (a trailing token count) does not reopen the turn.
            guard let at = event["timestamp"] as? String, !ended.contains(turn) else { continue }
            if current?.turn != turn || kind == "task_started" {
                current = (turn, at)
            }
        }
        return current
    }

    static func turnID(in payload: [String: Any]) -> UUID? {
        let direct = payload["turn_id"] as? String
        let passthrough = (payload["internal_chat_message_metadata_passthrough"] as? [String: Any])?["turn_id"] as? String
        return (direct ?? passthrough).flatMap(UUID.init(uuidString:))
    }
}
