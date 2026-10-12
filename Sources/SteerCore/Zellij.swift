import Foundation

// Zellij (#242, ADR 0014): a session in a Zellij pane has two layers, the pane running it and the
// terminal tab running Zellij's one client. Zellij lists neither a pane's tty nor its pid and gives a
// client no tty, pid or socket tie, so the pane comes from `action list-panes --json --all`, the
// layout from `list-tabs --json`, the session's clients from `list-clients`, and everything about
// processes (each session's `zellij --server`, the `zellij` client processes and their ttys, ancestry)
// from the process table. Everything here is a pure function of that output, decoded within fixed
// bounds, and of the observations SteerApp passes in. SteerApp resolves the binary from fixed
// locations, lists the default socket directory itself (never `zellij list-sessions`), runs every
// command with a bounded wait and owns scheduling (ZellijRunner.swift, Companion+Zellij.swift). The
// live proof is docs/evidence/zellij-live.md.

public enum ZellijListing {
    /// Bytes accepted from one listing; a larger listing is unreadable rather than truncated.
    public static let maximumOutput = 4 * 1024 * 1024
    /// The `list-clients` header line, which Steer requires before any row.
    public static let clientsHeader = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND"
}

// MARK: - Binary, version, socket directory and trust

/// `zellij` resolves only from fixed locations, as `herdr` and `tmux` do (ADR 0009, ADR 0014), never
/// from `PATH`.
public enum ZellijBinary {
    public static let candidates = ["/opt/homebrew/bin/zellij", "/usr/local/bin/zellij"]

    public static func resolve(isExecutable: (String) -> Bool) -> String? {
        candidates.first(where: isExecutable)
    }
}

/// The installed CLI's version from `zellij --version`. ADR 0014's one hard floor is 0.44.1, which is
/// needed for `focus-pane-id` and `--pane-id`.
public struct ZellijVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public static let minimum = ZellijVersion(major: 0, minor: 44, patch: 1)

    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var isSupported: Bool { self >= Self.minimum }
    public var description: String { "\(major).\(minor).\(patch)" }

    /// `zellij <major>.<minor>.<patch>` with an optional pre-release suffix; nil for anything else.
    public static func parse(_ output: String) -> ZellijVersion? {
        let words = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard words.count == 2, words[0] == "zellij" else { return nil }
        let core = words[1].split(separator: "-", maxSplits: 1)[0]
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        return ZellijVersion(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public static func < (lhs: ZellijVersion, rhs: ZellijVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The only directory Steer reads: `<user temporary directory>/zellij-<uid>/contract_version_1`
/// (Zellij 0.44.0 and later on macOS, ADR 0014). A custom `ZELLIJ_SOCKET_DIR` is never scanned.
public enum ZellijSocketDirectory {
    public static let contract = "contract_version_1"

    /// nil for a temporary directory that is empty or not absolute.
    public static func path(temporaryDirectory: String, uid: UInt32) -> String? {
        var base = temporaryDirectory
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        guard base.hasPrefix("/"), base.count > 1 else { return nil }
        return "\(base)/zellij-\(uid)/\(contract)"
    }
}

/// ADR 0014's socket rule for Zellij: the per-user `zellij-<uid>` directory and its contract
/// directory owned by this user and closed to others, and each session socket a socket owned by this
/// user that no one else may use (Zellij binds them `1700`). That an accepting server runs as this user
/// is checked by SteerApp after connecting (`getpeereid`), as for tmux and herdr.
public enum ZellijSocketTrust {
    public enum Problem: Equatable, Sendable {
        /// No contract directory or no socket in it: no session runs.
        case notRunning
        /// A directory or socket could have been placed, or reached, by another user.
        case untrusted
    }

    /// - Parameters:
    ///   - base: `zellij-<uid>`; `directory`: its contract directory; `sockets`: each socket entry in it
    ///     by name (entries of other kinds are never addressed and are not passed).
    public static func problem(base: TmuxFileFacts?, directory: TmuxFileFacts?, sockets: [String: TmuxFileFacts],
                               me: UInt32) -> Problem? {
        guard let directory else { return .notRunning }
        guard let base, base.kind == .directory, base.owner == me, base.mode & 0o022 == 0,
              directory.kind == .directory, directory.owner == me, directory.mode & 0o077 == 0 else { return .untrusted }
        guard !sockets.isEmpty else { return .notRunning }
        for socket in sockets.values {
            guard socket.kind == .socket, socket.owner == me, socket.mode & 0o077 == 0 else { return .untrusted }
        }
        return nil
    }
}

/// A session name as Steer passes it to `--session`: the socket's file name, never one that the
/// command line could read as an option or that carries control characters.
public enum ZellijSessionName {
    public static let maximumLength = 255

    public static func validated(_ name: String) -> String? {
        guard !name.isEmpty, name.utf8.count <= maximumLength, !name.hasPrefix("-"), !name.contains("/"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
}

// MARK: - Panes, tabs and clients

/// One pane as `list-panes --json --all` lists it. Plugin and terminal panes reuse the same numbers,
/// so `isPlugin` is part of a pane's identity.
public struct ZellijPane: Equatable, Hashable, Sendable {
    public let id: Int
    public let isPlugin: Bool
    /// The user's pane name when set, otherwise the program's last OSC 0/2 title.
    public let title: String
    public let tabID: Int
    public let isFloating: Bool
    public let isSelectable: Bool
    /// The pane's program exited (a held command pane).
    public let exited: Bool
    /// The pane's foreground command line, as Zellij reads it (terminal panes only).
    public let paneCommand: String?

    public init(id: Int, isPlugin: Bool, title: String, tabID: Int, isFloating: Bool, isSelectable: Bool,
                exited: Bool, paneCommand: String?) {
        self.id = id
        self.isPlugin = isPlugin
        self.title = title
        self.tabID = tabID
        self.isFloating = isFloating
        self.isSelectable = isSelectable
        self.exited = exited
        self.paneCommand = paneCommand
    }
}

/// One tab as `list-tabs --json` lists it: its pane counts and whether its floating layer shows.
public struct ZellijTab: Equatable, Hashable, Sendable {
    public let tabID: Int
    public let selectableTiledPanes: Int
    public let selectableFloatingPanes: Int
    public let floatingPanesVisible: Bool

    public init(tabID: Int, selectableTiledPanes: Int, selectableFloatingPanes: Int, floatingPanesVisible: Bool) {
        self.tabID = tabID
        self.selectableTiledPanes = selectableTiledPanes
        self.selectableFloatingPanes = selectableFloatingPanes
        self.floatingPanesVisible = floatingPanesVisible
    }

    /// The panes a user sees in the tab: its selectable tiled panes, plus its floating ones while shown.
    /// One is ADR 0014's single selectable tiled pane with no visible floating pane.
    public var visiblePanes: Int {
        selectableTiledPanes + (floatingPanesVisible ? selectableFloatingPanes : 0)
    }
}

/// One client as `list-clients` lists it: Zellij's id and the pane it focuses (nil for a plugin).
/// Zellij gives a client no tty, pid or host terminal.
public struct ZellijClient: Equatable, Hashable, Sendable {
    public let clientID: String
    public let paneID: Int?

    public init(clientID: String, paneID: Int?) {
        self.clientID = clientID
        self.paneID = paneID
    }
}

/// One running session, read by its own `--session <name>` commands.
public struct ZellijSession: Equatable, Sendable {
    public static let maximumPanes = 1024
    public static let maximumTabs = 256
    public static let maximumClients = 64
    public static let maximumTitleLength = 1024
    public static let maximumCommandLength = 4096

    public let name: String
    public let panes: [ZellijPane]
    public let tabs: [ZellijTab]
    public let clients: [ZellijClient]

    public init(name: String, panes: [ZellijPane], tabs: [ZellijTab], clients: [ZellijClient]) {
        self.name = name
        self.panes = panes
        self.tabs = tabs
        self.clients = clients
    }

    public func terminalPane(_ id: Int) -> ZellijPane? {
        panes.first { !$0.isPlugin && $0.id == id }
    }

    public func tab(_ id: Int) -> ZellijTab? {
        tabs.first { $0.tabID == id }
    }

    /// The three listings, or nil when any is not complete and well formed: unreadable, never repaired.
    public static func parse(name: String, panes: String, tabs: String, clients: String) -> ZellijSession? {
        guard [panes, tabs, clients].allSatisfy({ $0.utf8.count <= ZellijListing.maximumOutput }),
              let paneRows = rows(panes, maximum: maximumPanes), let tabRows = rows(tabs, maximum: maximumTabs) else {
            return nil
        }
        var parsedPanes: [ZellijPane] = []
        for row in paneRows {
            guard let pane = pane(row) else { return nil }
            parsedPanes.append(pane)
        }
        var parsedTabs: [ZellijTab] = []
        for row in tabRows {
            guard let tab = tab(row) else { return nil }
            parsedTabs.append(tab)
        }
        guard let parsedClients = clientRows(clients) else { return nil }
        return ZellijSession(name: name, panes: parsedPanes, tabs: parsedTabs, clients: parsedClients)
    }

    private static func rows(_ json: String, maximum: Int) -> [[String: Any]]? {
        guard let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              rows.count <= maximum else { return nil }
        return rows
    }

    private static func pane(_ row: [String: Any]) -> ZellijPane? {
        guard let id = number(row["id"]), let tabID = number(row["tab_id"]), number(row["tab_position"]) != nil,
              let isPlugin = flag(row["is_plugin"]), let floating = flag(row["is_floating"]),
              let selectable = flag(row["is_selectable"]), let exited = flag(row["exited"]),
              let title = row["title"] as? String, title.count <= maximumTitleLength else { return nil }
        var command: String?
        switch row["pane_command"] {
        case nil, is NSNull: command = nil
        case let value as String:
            guard value.count <= maximumCommandLength else { return nil }
            command = value
        default: return nil
        }
        return ZellijPane(id: id, isPlugin: isPlugin, title: title, tabID: tabID, isFloating: floating,
                          isSelectable: selectable, exited: exited, paneCommand: command)
    }

    private static func tab(_ row: [String: Any]) -> ZellijTab? {
        guard let id = number(row["tab_id"]), let tiled = number(row["selectable_tiled_panes_count"]),
              let floating = number(row["selectable_floating_panes_count"]),
              let visible = flag(row["are_floating_panes_visible"]) else { return nil }
        return ZellijTab(tabID: id, selectableTiledPanes: tiled, selectableFloatingPanes: floating, floatingPanesVisible: visible)
    }

    /// The header, then one row per client: `<id> terminal_<n>|plugin_<n> [<command>]`.
    private static func clientRows(_ output: String) -> [ZellijClient]? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == ZellijListing.clientsHeader,
              lines.count - 1 <= maximumClients else { return nil }
        var clients: [ZellijClient] = []
        for line in lines.dropFirst() {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, digits(fields[0]) != nil else { return nil }
            if fields[1].hasPrefix("terminal_"), let id = digits(fields[1].dropFirst("terminal_".count)) {
                clients.append(ZellijClient(clientID: String(fields[0]), paneID: id))
            } else if fields[1].hasPrefix("plugin_"), digits(fields[1].dropFirst("plugin_".count)) != nil {
                clients.append(ZellijClient(clientID: String(fields[0]), paneID: nil))
            } else {
                return nil
            }
        }
        return clients
    }

    /// A non-negative integer JSON number, never a Boolean or a fraction.
    private static func number(_ value: Any?) -> Int? {
        WezTermJSON.identifier(value)
    }

    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func digits(_ field: Substring) -> Int? {
        guard !field.isEmpty, field.count <= 9, field.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(field)
    }
}

// MARK: - Processes

/// One process from `ps -axo pid=,ppid=,tty=,comm=`: `name` is the executable's basename; arguments
/// are read only for `zellij` processes (SteerApp, from the kernel), to find each session's server.
public struct ZellijProcess: Equatable, Hashable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// Normalized `/dev/ttysNNN`; nil for none (`??`).
    public let tty: String?
    public let name: String

    public init(pid: Int32, ppid: Int32, tty: String?, name: String) {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.name = name
    }
}

/// One running `zellij --server`: a send never reaches a restarted server that reuses pane ids.
public struct ZellijServerIdentity: Equatable, Hashable, Sendable {
    public let pid: Int32
    public let startedAt: Double

    public init(pid: Int32, startedAt: Double) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// The process table behind ADR 0014's Zellij rules: each session's server (its `--server` socket
/// path), the `zellij` client processes (with a controlling tty, not `--server`), and ancestry.
public struct ZellijProcessTable: Equatable, Sendable {
    public static let maximumProcesses = 8192
    public static let maximumDepth = 32
    public static let processName = "zellij"
    /// Executables whose presence above a Zellij client means it runs inside another multiplexer's pane.
    public static let nestingCommands: Set<String> = ["tmux", "herdr", "zellij"]

    public let processes: [Int32: ZellijProcess]
    /// The argument vectors of `zellij` processes, read from the kernel; a missing entry was unreadable.
    public let arguments: [Int32: [String]]
    /// The start times of `zellij` server processes, read from the kernel; a missing entry was unreadable.
    public let startTimes: [Int32: Double]

    public init(processes: [ZellijProcess], arguments: [Int32: [String]], startTimes: [Int32: Double]) {
        self.processes = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        self.arguments = arguments
        self.startTimes = startTimes
    }

    /// `ps -axo pid=,ppid=,tty=,comm=` output, or nil when any row is malformed or there are too many.
    public static func parse(_ output: String, arguments: [Int32: [String]], startTimes: [Int32: Double]) -> ZellijProcessTable? {
        guard output.utf8.count <= ZellijListing.maximumOutput else { return nil }
        var processes: [ZellijProcess] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), pid > 0, let ppid = Int32(fields[1]), ppid >= 0 else {
                return nil
            }
            let command = fields[3].trimmingCharacters(in: .whitespaces)
            let name = command.hasPrefix("/") ? (command as NSString).lastPathComponent : command
            guard !name.isEmpty else { return nil }
            processes.append(ZellijProcess(pid: pid, ppid: ppid, tty: GhosttyTTYMatch.normalizedTTY(String(fields[2])), name: name))
            guard processes.count <= maximumProcesses else { return nil }
        }
        return ZellijProcessTable(processes: processes, arguments: arguments, startTimes: startTimes)
    }

    /// The pids of every `zellij` process, whose arguments SteerApp reads.
    public var zellijPIDs: [Int32] {
        processes.values.filter { $0.name == Self.processName }.map(\.pid).sorted()
    }

    /// The one `zellij --server <socketDirectory>/<session>` with a known start time; nil for none or several.
    public func server(session: String, socketDirectory: String) -> ZellijServerIdentity? {
        let path = "\(socketDirectory)/\(session)"
        let servers = processes.values.filter { process in
            guard process.name == Self.processName, let argv = arguments[process.pid],
                  let flag = argv.firstIndex(of: "--server"), flag + 1 < argv.count else { return false }
            return argv[flag + 1] == path
        }
        guard servers.count == 1, let server = servers.first, let started = startTimes[server.pid] else { return nil }
        return ZellijServerIdentity(pid: server.pid, startedAt: started)
    }

    /// Every `zellij` client process for this user: a `zellij` with a controlling tty that is not a
    /// server. Zellij ties none of them to a session (ADR 0014), so they are counted across all sessions.
    public var clientProcesses: [ZellijProcess] {
        processes.values.filter { process in
            process.name == Self.processName && process.tty != nil
                && !(arguments[process.pid]?.contains("--server") ?? false)
        }.sorted { $0.pid < $1.pid }
    }

    /// `pid`'s ancestors' pids, nearest first, until launchd; nil when a parent is not in the table.
    public func ancestors(of pid: Int32) -> [Int32]? {
        var chain: [Int32] = []
        var current = processes[pid]
        while let process = current, process.ppid > 1, chain.count < Self.maximumDepth {
            chain.append(process.ppid)
            guard let parent = processes[process.ppid] else { return nil }
            current = parent
        }
        return current == nil ? nil : chain
    }

    public func descends(_ pid: Int32, from ancestor: Int32) -> Bool {
        ancestors(of: pid)?.contains(ancestor) ?? false
    }

    /// Processes named `name` whose ancestry reaches `server`.
    public func processes(named name: String, under server: Int32) -> [ZellijProcess] {
        processes.values.filter { $0.name == name && descends($0.pid, from: server) }.sorted { $0.pid < $1.pid }
    }

    /// Whether `client` runs inside another multiplexer's pane (ADR 0014, "Nesting"): a `tmux`, `herdr`
    /// or `zellij` process above it, or an ancestry that could not be read.
    public func isNested(_ client: ZellijProcess) -> Bool {
        guard let chain = ancestors(of: client.pid) else { return true }
        return chain.contains { processes[$0].map { Self.nestingCommands.contains($0.name) } ?? true }
    }
}
