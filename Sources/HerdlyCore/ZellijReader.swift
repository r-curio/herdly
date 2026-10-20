import Foundation

// The order of every Zellij read and send (#242, ADR 0014), over effects HerdlyApp supplies: a fresh
// listing of the default socket directory and a connection to each socket come first, and no `zellij`
// command runs unless every socket there accepts. An isolated Zellij 0.45.1 run showed that any
// `zellij --session <name> action …`, like `zellij list-sessions`, deletes a socket in the directory that
// refuses connections; ADR 0014 keeps Herdly from changing the user's Zellij state just to read it, so a
// refusing (stale) socket makes Zellij unreadable instead. Whether to amend that is an open product
// question.

/// What connecting to one session socket showed.
public enum ZellijSocketPeer: Equatable, Sendable {
    /// Nothing accepts: a stale socket, which any `zellij` command would delete.
    case refused
    /// A server accepted, running as another user.
    case otherUser
    case currentUser
}

/// One fresh `lstat` listing of the default socket directory: `zellij-<uid>`, its contract directory, and
/// each socket entry in it by name (entries of other kinds are never addressed and are not listed).
public struct ZellijDirectoryListing: Equatable, Sendable {
    public let base: TmuxFileFacts?
    public let directory: TmuxFileFacts?
    public let sockets: [String: TmuxFileFacts]

    public init(base: TmuxFileFacts?, directory: TmuxFileFacts?, sockets: [String: TmuxFileFacts]) {
        self.base = base
        self.directory = directory
        self.sockets = sockets
    }
}

/// HerdlyApp's side of a read: each closure is blocking and bounded (ZellijRunner.swift).
public struct ZellijEffects: Sendable {
    /// `<user temporary directory>/zellij-<uid>/contract_version_1`; nil when it cannot be resolved.
    public let socketDirectory: String?
    public let me: UInt32
    /// nil when the directory exists but cannot be listed, or holds too many entries.
    public let listing: @Sendable () -> ZellijDirectoryListing?
    /// Connects to one socket path and reads the peer's user; writes nothing.
    public let probe: @Sendable (String) -> ZellijSocketPeer
    /// A `zellij` is at the fixed locations.
    public let binaryPresent: @Sendable () -> Bool
    /// Runs one `zellij` command.
    public let run: @Sendable ([String]) -> ZellijCommandOutcome
    public let processTable: @Sendable () -> ZellijProcessTable?

    public init(socketDirectory: String?, me: UInt32, listing: @escaping @Sendable () -> ZellijDirectoryListing?,
                probe: @escaping @Sendable (String) -> ZellijSocketPeer, binaryPresent: @escaping @Sendable () -> Bool,
                run: @escaping @Sendable ([String]) -> ZellijCommandOutcome,
                processTable: @escaping @Sendable () -> ZellijProcessTable?) {
        self.socketDirectory = socketDirectory
        self.me = me
        self.listing = listing
        self.probe = probe
        self.binaryPresent = binaryPresent
        self.run = run
        self.processTable = processTable
    }
}

public enum ZellijReader {
    /// Where the directory check leaves a read: finished with an outcome, or the live sessions to address.
    enum Gate: Equatable {
        case finished(ZellijRead)
        case live(directory: String, sessions: [String])
    }

    /// The fresh directory check every read and send starts with. Sockets are probed by Herdly's own
    /// connection; any refusing socket stops everything before a `zellij` command runs. With no binary,
    /// nothing accepting is not running (a leftover socket file blocks nothing), and a live session is
    /// unreadable.
    static func gate(_ effects: ZellijEffects) -> Gate {
        guard let directory = effects.socketDirectory, let listing = effects.listing() else {
            return .finished(.unreadable(.directoryUnlistable))
        }
        switch ZellijSocketTrust.problem(base: listing.base, directory: listing.directory, sockets: listing.sockets,
                                         me: effects.me) {
        case .untrusted?: return .finished(.untrustedSocket)
        case .notRunning?: return effects.binaryPresent() ? .live(directory: directory, sessions: []) : .finished(.notRunning)
        case nil: break
        }
        var live: [String] = []
        var stale = false
        for name in listing.sockets.keys.sorted() {
            switch effects.probe("\(directory)/\(name)") {
            case .refused: stale = true
            case .otherUser: return .finished(.untrustedSocket)
            case .currentUser: live.append(name)
            }
        }
        guard effects.binaryPresent() else { return .finished(live.isEmpty ? .notRunning : .binaryNotFound) }
        if stale { return .finished(.unreadable(.staleSocket)) }
        return .live(directory: directory, sessions: live)
    }

    /// One read: the directory check, the version, the process table, then each live session's panes,
    /// tabs and clients.
    public static func read(_ effects: ZellijEffects) -> ZellijRead {
        let directory: String, live: [String]
        switch gate(effects) {
        case .finished(let read): return read
        case .live(let value, let sessions): (directory, live) = (value, sessions)
        }
        // `--version` addresses no session and touches no socket.
        guard case .succeeded(let output) = effects.run(["--version"]), let version = ZellijVersion.parse(output) else {
            return live.isEmpty ? .notRunning : .unreadable(.versionUnreadable)
        }
        guard version.isSupported else {
            return .unsupportedVersion(version, running: effects.processTable().map { !$0.zellijPIDs.isEmpty } ?? true)
        }
        guard !live.isEmpty else { return .notRunning }
        guard live.allSatisfy({ ZellijSessionName.validated($0) != nil }) else { return .unreadable(.sessionName) }
        guard let table = effects.processTable() else { return .unreadable(.processTable) }
        var sessions: [ZellijSession] = []
        for name in live {
            guard let session = session(name, effects) else { return .unreadable(.commandFailed) }
            sessions.append(session)
        }
        return .snapshot(ZellijSnapshot(socketDirectory: directory, sessions: sessions, processes: table))
    }

    /// A command that types or moves focus (`write-chars`, `write`, `focus-pane-id`): sent only when a fresh
    /// directory check finds every socket accepting and the target's session live, and a read of that
    /// session and the process table taken just before shows the bound pane still a live, single terminal
    /// pane under the server the fresh check read (`ZellijInput.writeAllowed`). An unknown pane id would
    /// otherwise exit 0 having written nothing. Refused: `.failed`, so nothing counts as written.
    public static func send(_ arguments: [String], to target: ZellijPaneTarget, expecting expected: ZellijServerIdentity?,
                            effects: ZellijEffects) -> ZellijCommandOutcome {
        guard case .live(let directory, let live) = gate(effects), live.contains(target.session),
              ZellijSessionName.validated(target.session) != nil, let session = session(target.session, effects),
              let table = effects.processTable(),
              ZellijInput.writeAllowed(target, expected: expected,
                                       current: ZellijSnapshot(socketDirectory: directory, sessions: [session], processes: table)) else {
            return .failed(stderr: "")
        }
        return effects.run(arguments)
    }

    private static func session(_ name: String, _ effects: ZellijEffects) -> ZellijSession? {
        guard case .succeeded(let panes) = effects.run(["--session", name, "action", "list-panes", "--json", "--all"]),
              case .succeeded(let tabs) = effects.run(["--session", name, "action", "list-tabs", "--json"]),
              case .succeeded(let clients) = effects.run(["--session", name, "action", "list-clients"]) else { return nil }
        return ZellijSession.parse(name: name, panes: panes, tabs: tabs, clients: clients)
    }
}
