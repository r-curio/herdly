import Foundation

// tmux (#241, ADR 0014): a session in a tmux pane has two layers, the pane running it and the terminal
// tab running the session's one client. Everything here is a pure function of `list-panes -a` and
// `list-clients` output in Steer's own format strings, decoded within fixed bounds, and of the
// observations SteerApp passes in. SteerApp resolves the binary from fixed locations, checks the
// default socket, runs every command with a bounded wait and owns scheduling (TmuxClient.swift,
// Companion+Tmux.swift). The live proof is docs/evidence/tmux-live.md.

/// The `-F` formats Steer lists with. Fields are separated by `|`, which never occurs in an id, a tty
/// or a number; the pane title is last, so a title containing `|` is kept whole. A printable separator
/// is used because tmux replaces a tab in `-F` output with `_` when its locale is not UTF-8.
public enum TmuxListing {
    public static let paneFormat = "#{pane_id}|#{pane_tty}|#{window_id}|#{window_panes}|#{session_id}|#{session_attached}|#{session_grouped}|#{pane_in_mode}|#{pane_dead}|#{pane_input_off}|#{pane_title}"
    public static let clientFormat = "#{client_tty}|#{client_pid}|#{session_id}|#{pane_id}|#{client_control_mode}"
    /// Bytes accepted from one listing; a larger listing is unreadable rather than truncated.
    public static let maximumOutput = 4 * 1024 * 1024
}

// MARK: - Default socket, trust and binary

/// The only server Steer reads: `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default` (ADR 0014). Sockets chosen
/// with `-L` or `-S` are never scanned, so their sessions stay unbound.
public enum TmuxDefaultSocket {
    /// The default socket's path as tmux resolves it: the first of `TMUX_TMPDIR` and `/tmp` whose real
    /// path `resolve` finds. `TMPDIR` is ignored, as tmux has since 2.2. Nil when neither resolves.
    public static func path(uid: UInt32, environment: [String: String], resolve: (String) -> String?) -> String? {
        let candidates = [environment["TMUX_TMPDIR"], "/tmp"].compactMap { $0 }.filter { !$0.isEmpty }
        guard let base = candidates.lazy.compactMap(resolve).first else { return nil }
        return "\(base)/tmux-\(uid)/default"
    }
}

/// What `lstat` says about one path, for the trust check. The app reads it; a symlink is `.other`.
public struct TmuxFileFacts: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case directory, socket, other }

    public let kind: Kind
    public let owner: UInt32
    public let mode: UInt16

    public init(kind: Kind, owner: UInt32, mode: UInt16) {
        self.kind = kind
        self.owner = owner
        self.mode = mode
    }
}

/// ADR 0014's socket rule: a Unix socket owned by the current user in the per-user directory tmux itself
/// accepts (owned by the user, no permission bit for others). tmux binds the default socket `0660`, so
/// group bits are allowed as tmux allows them. That the server runs as this user is checked by SteerApp
/// after connecting (`getpeereid`), as for herdr.
public enum TmuxSocketTrust {
    public enum Problem: Equatable, Sendable {
        /// No socket: no default server runs, so tmux holds no pane.
        case notRunning
        /// The directory or socket could have been placed, or reached, by another user.
        case untrusted
    }

    public static func problem(directory: TmuxFileFacts?, socket: TmuxFileFacts?, me: UInt32) -> Problem? {
        guard let socket else { return .notRunning }
        guard let directory, directory.kind == .directory, directory.owner == me, directory.mode & 0o007 == 0,
              socket.kind == .socket, socket.owner == me, socket.mode & 0o007 == 0 else { return .untrusted }
        return nil
    }
}

/// `tmux` resolves only from fixed locations, as `herdr` does (ADR 0009, ADR 0014), never from `PATH`.
public enum TmuxBinary {
    public static let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    public static func resolve(isExecutable: (String) -> Bool) -> String? {
        candidates.first(where: isExecutable)
    }
}

/// One running tmux server, so a send never reaches a restarted server that reuses pane ids.
public struct TmuxServerIdentity: Equatable, Hashable, Sendable {
    public static let format = "#{pid}|#{start_time}"

    public let pid: Int32
    public let startTime: Int

    public init(pid: Int32, startTime: Int) {
        self.pid = pid
        self.startTime = startTime
    }

    /// `display-message -p` output in `format`; nil for anything else.
    public static func parse(_ output: String) -> TmuxServerIdentity? {
        let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 2, let pid = Int32(fields[0]), pid > 0, let start = Int(fields[1]), start > 0 else { return nil }
        return TmuxServerIdentity(pid: pid, startTime: start)
    }

    /// A send goes only to the server the fresh check read, re-read immediately before the send.
    public static func allowsSend(expected: TmuxServerIdentity?, current: TmuxServerIdentity?) -> Bool {
        guard let expected, let current else { return false }
        return expected == current
    }
}

/// One read of the default server, from SteerApp's side.
public enum TmuxRead: Equatable, Sendable {
    /// No default socket, or nothing accepts connections on it: no pane exists.
    case notRunning
    /// A socket exists but no `tmux` is installed at the fixed locations.
    case binaryNotFound
    /// The socket or its directory fails the trust check, or the server runs as another user.
    case untrustedSocket
    /// A command failed, timed out or printed a malformed listing.
    case unreadable
    case snapshot(TmuxSnapshot)

    /// ADR 0013's inventory: a server that may be running but cannot be read holds every session it
    /// could hold unavailable.
    public var inventory: TerminalHostInventory {
        switch self {
        case .notRunning: .notRunning
        case .binaryNotFound, .untrustedSocket, .unreadable: .unreadable
        case .snapshot(let snapshot): snapshot.inventory
        }
    }

    public var snapshot: TmuxSnapshot? {
        if case .snapshot(let value) = self { return value }
        return nil
    }
}

/// One pane as `list-panes -a` lists it. A pane in a window linked into several sessions, or in a
/// grouped session, is listed once per session with the same `paneID`.
public struct TmuxPane: Equatable, Hashable, Sendable {
    /// `%N`, unique for the pane's life in this server.
    public let paneID: String
    /// `/dev/ttysNNN`.
    public let tty: String
    /// `@N`.
    public let windowID: String
    public let windowPanes: Int
    /// `$N`.
    public let sessionID: String
    public let sessionAttached: Int
    public let sessionGrouped: Bool
    /// Copy mode or another mode: keys become mode commands (tmux-live.md, "Copy mode").
    public let inMode: Bool
    public let dead: Bool
    /// `select-pane -d`: keys are dropped silently.
    public let inputOff: Bool
    public let title: String

    public init(paneID: String, tty: String, windowID: String, windowPanes: Int, sessionID: String,
                sessionAttached: Int, sessionGrouped: Bool, inMode: Bool, dead: Bool, inputOff: Bool, title: String) {
        self.paneID = paneID
        self.tty = tty
        self.windowID = windowID
        self.windowPanes = windowPanes
        self.sessionID = sessionID
        self.sessionAttached = sessionAttached
        self.sessionGrouped = sessionGrouped
        self.inMode = inMode
        self.dead = dead
        self.inputOff = inputOff
        self.title = title
    }
}

/// One attached client as `list-clients` lists it: its own tty (the host tab's), its session, and
/// the pane it shows (its session's current window's active pane).
public struct TmuxClient: Equatable, Hashable, Sendable {
    public let tty: String
    public let pid: Int32
    public let sessionID: String
    public let paneID: String
    /// `tmux -C`/`-CC` (iTerm2's integration): attached, and counted, but never a host tab.
    public let controlMode: Bool

    public init(tty: String, pid: Int32, sessionID: String, paneID: String, controlMode: Bool) {
        self.tty = tty
        self.pid = pid
        self.sessionID = sessionID
        self.paneID = paneID
        self.controlMode = controlMode
    }
}

/// One read of the default server: every pane and every attached client.
public struct TmuxSnapshot: Equatable, Sendable {
    public static let maximumPanes = 1024
    public static let maximumClients = 256
    public static let maximumTitleLength = 1024

    public let panes: [TmuxPane]
    public let clients: [TmuxClient]
    /// Each client process's ancestry from itself up, by executable name, as read from the kernel when
    /// this listing was taken; a client missing here could not be read. herdr and Zellij list no pane
    /// tty, so only this shows a client running inside their panes (ADR 0014, "Nesting").
    public private(set) var clientAncestries: [Int32: [String]] = [:]
    /// The server this listing came from (`display-message -p '#{pid}|#{start_time}'`), nil when unread.
    public private(set) var server: TmuxServerIdentity?

    public init(panes: [TmuxPane], clients: [TmuxClient]) {
        self.panes = panes
        self.clients = clients
    }

    public func withClientAncestries(_ ancestries: [Int32: [String]]) -> TmuxSnapshot {
        var copy = self
        copy.clientAncestries = ancestries
        return copy
    }

    public func withServer(_ server: TmuxServerIdentity?) -> TmuxSnapshot {
        var copy = self
        copy.server = server
        return copy
    }

    /// Both listings, or nil when either is not complete and well formed: unreadable, never repaired.
    public static func parse(panes: String, clients: String) -> TmuxSnapshot? {
        guard panes.utf8.count <= TmuxListing.maximumOutput, clients.utf8.count <= TmuxListing.maximumOutput else {
            return nil
        }
        var parsedPanes: [TmuxPane] = []
        for line in panes.split(separator: "\n", omittingEmptySubsequences: true) {
            guard parsedPanes.count < maximumPanes, let pane = pane(line) else { return nil }
            parsedPanes.append(pane)
        }
        var parsedClients: [TmuxClient] = []
        for line in clients.split(separator: "\n", omittingEmptySubsequences: true) {
            guard parsedClients.count < maximumClients, let client = client(line) else { return nil }
            parsedClients.append(client)
        }
        return TmuxSnapshot(panes: parsedPanes, clients: parsedClients)
    }

    /// ADR 0013's inventory with the pane in place of the tab (ADR 0014): one entry per pane id, its
    /// window's pane count as `paneCount`, so a split is visible. Whether the pane is listed in several
    /// sessions is the layout check's (`TmuxLayout`), not the inventory's.
    public var inventory: TerminalHostInventory {
        var seen: Set<String> = []
        return .tabs(panes.compactMap { pane in
            guard seen.insert(pane.paneID).inserted else { return nil }
            return TerminalTab(tabID: pane.paneID, tty: pane.tty, title: pane.title, paneCount: pane.windowPanes)
        })
    }

    /// The ttys of every attached client that is not in control mode: the host tabs ADR 0014 leaves
    /// out of the Codex title count, because their titles can mirror the focused pane's.
    public var clientTTYs: Set<String> {
        Set(clients.filter { !$0.controlMode }.map(\.tty))
    }

    /// Every listing of `paneID`, one per session showing its window.
    public func listings(of paneID: String) -> [TmuxPane] {
        panes.filter { $0.paneID == paneID }
    }

    /// The ttys whose `ps -t` read ADR 0013 needs: panes titled with a shortened Codex identifier and
    /// panes on one of `claudeTTYs`. Other panes are never read.
    public func ttysToRead(claudeTTYs: Set<String>) -> Set<String> {
        Set(panes.filter { claudeTTYs.contains($0.tty) || HerdrBindingRules.isShortenedCodexSessionTitle($0.title) }
            .map(\.tty))
    }

    private static func pane(_ line: Substring) -> TmuxPane? {
        let fields = line.split(separator: "|", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11, let paneID = id(fields[0], prefix: "%"),
              let tty = GhosttyTTYMatch.normalizedTTY(String(fields[1])),
              let windowID = id(fields[2], prefix: "@"), let windowPanes = count(fields[3]), windowPanes > 0,
              let sessionID = id(fields[4], prefix: "$"), let attached = count(fields[5]),
              let grouped = flag(fields[6]), let inMode = flag(fields[7]), let dead = flag(fields[8]),
              let inputOff = flag(fields[9]), fields[10].count <= maximumTitleLength else { return nil }
        return TmuxPane(paneID: paneID, tty: tty, windowID: windowID, windowPanes: windowPanes, sessionID: sessionID,
                        sessionAttached: attached, sessionGrouped: grouped, inMode: inMode, dead: dead,
                        inputOff: inputOff, title: String(fields[10]))
    }

    private static func client(_ line: Substring) -> TmuxClient? {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5, let tty = GhosttyTTYMatch.normalizedTTY(String(fields[0])),
              let pid = Int32(fields[1]), pid > 0, let sessionID = id(fields[2], prefix: "$"),
              let paneID = id(fields[3], prefix: "%"), let controlMode = flag(fields[4]) else { return nil }
        return TmuxClient(tty: tty, pid: pid, sessionID: sessionID, paneID: paneID, controlMode: controlMode)
    }

    /// `prefix` followed by 1 to 9 ASCII digits.
    private static func id(_ field: Substring, prefix: Character) -> String? {
        guard field.first == prefix else { return nil }
        let digits = field.dropFirst()
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(field)
    }

    private static func count(_ field: Substring) -> Int? {
        guard !field.isEmpty, field.count <= 9, field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(field)
    }

    private static func flag(_ field: Substring) -> Bool? {
        switch field {
        case "0": false
        case "1": true
        default: nil
        }
    }
}
