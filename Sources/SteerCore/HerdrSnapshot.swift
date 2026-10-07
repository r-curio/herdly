import Foundation

// herdr's JSON socket replies, `herdr integration status` output and `lsof` client listings,
// decoded within fixed bounds (ADR 0009). Everything here is a pure function of bytes or text so
// SteerApp owns only the socket, the subprocesses and scheduling. Binding a pane to a session
// (ADR 0008) is not decided here.

/// Why herdr cannot be used for a target right now. Every reason makes the target unavailable; no
/// reason clears attention, grants a decision, or falls back to another pane, and hook
/// notifications continue (ADR 0009). Which reasons the user sees, and where, follows
/// `docs/product.md` ("Agreed herdr presentation"), not this type.
public enum HerdrUnavailableReason: Error, Equatable, Hashable, Sendable {
    /// No executable `herdr` in `~/.local/bin`, `/opt/homebrew/bin` or `/usr/local/bin`.
    case herdrNotFound
    /// No socket at the default path, or nothing accepts connections on it.
    case notRunning
    /// The socket is not a Unix socket owned by this user with no group or other permission bits.
    case untrustedSocket
    /// The running server reports a protocol outside `HerdrProtocol.supported`.
    case unsupportedProtocol(Int)
    /// `herdr integration status` does not report `current (vN)` for this agent. Not installed,
    /// outdated, needs repair and unparseable output all land here.
    case integrationNotCurrent(HerdrAgentKind)
    /// Zero or several TUI clients are attached to the server.
    case wrongClientCount(Int)
    /// The single client's process ancestry does not reach Ghostty.
    case nonGhosttyClient
    /// The pane's tab holds more than one pane, or is a zoomed split.
    case split
    /// The session's socket is not herdr's default socket.
    case namedSession
    /// ADR 0008's binding does not hold for the session.
    case voidBinding
    /// A socket request or subprocess did not finish within its deadline.
    case timeout
    /// A reply or command output could not be decoded within bounds, or answered another request.
    case malformedReply
    /// herdr answered with an error object; `code` is herdr's own, truncated.
    case requestRefused(code: String)
}

/// The agents Steer binds in herdr; the raw value is herdr's integration target label.
public enum HerdrAgentKind: String, CaseIterable, Hashable, Sendable {
    case claude
    case codex
}

/// herdr protocol versions Steer has verified. Checked before any other herdr use; an unlisted
/// protocol disables herdr targeting and relay (ADR 0008).
public enum HerdrProtocol {
    /// Protocol 22 is herdr 0.9.3, the build the live proof (#102) ran.
    public static let supported: Set<Int> = [22]

    public static func check(_ version: Int) -> HerdrUnavailableReason? {
        supported.contains(version) ? nil : .unsupportedProtocol(version)
    }
}

/// herdr's default socket trust rule (ADR 0009) expressed over `AppServerSocketCheck`, which
/// already requires a Unix socket owned by this user with no group or other bits. herdr's config
/// directory may be `0755`; only the socket's own mode is checked.
public enum HerdrSocketTrust {
    public static func reason(for problem: AppServerSocketCheck.Problem?) -> HerdrUnavailableReason? {
        switch problem {
        case nil: return nil
        case .missing?: return .notRunning
        case .notASocket?, .notOwnedByUser?, .sharedPermissions?: return .untrustedSocket
        }
    }

    public static func reason(at path: String) -> HerdrUnavailableReason? {
        reason(for: AppServerSocketCheck.problem(at: path))
    }
}

// MARK: - Snapshot models

/// herdr's agent state as reported by screen detection. It is not a hook fact and must never drive
/// approval or question state.
public enum HerdrAgentStatus: Equatable, Hashable, Sendable {
    case idle, working, blocked, done, unknown
    /// A value this build does not know, preserved rather than guessed.
    case other(String)

    init(raw: String) {
        switch raw {
        case "idle": self = .idle
        case "working": self = .working
        case "blocked": self = .blocked
        case "done": self = .done
        case "unknown": self = .unknown
        default: self = .other(String(raw.prefix(64)))
        }
    }
}

/// The session an agent integration reported from inside a pane. herdr never verifies it.
public struct HerdrAgentSession: Equatable, Hashable, Sendable, Decodable {
    public let source: String
    public let agent: String
    /// `id` or `path`.
    public let kind: String
    public let value: String

    public init(source: String, agent: String, kind: String, value: String) {
        self.source = source
        self.agent = agent
        self.kind = kind
        self.value = value
    }
}

public struct HerdrPane: Equatable, Sendable {
    public let paneID: String
    public let tabID: String
    public let workspaceID: String
    public let focused: Bool
    /// The detected agent, e.g. `codex`; nil when herdr detects none.
    public let agent: String?
    public let agentStatus: HerdrAgentStatus
    public let agentSession: HerdrAgentSession?
    /// `terminal_title_stripped`: the title written inside the pane, which stops at herdr.
    public let terminalTitle: String?

    public init(paneID: String, tabID: String, workspaceID: String, focused: Bool, agent: String?,
                agentStatus: HerdrAgentStatus, agentSession: HerdrAgentSession?, terminalTitle: String?) {
        self.paneID = paneID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.focused = focused
        self.agent = agent
        self.agentStatus = agentStatus
        self.agentSession = agentSession
        self.terminalTitle = terminalTitle
    }
}

public struct HerdrTab: Equatable, Sendable {
    public let tabID: String
    public let workspaceID: String
    public let focused: Bool
    public let paneCount: Int

    public init(tabID: String, workspaceID: String, focused: Bool, paneCount: Int) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.focused = focused
        self.paneCount = paneCount
    }
}

public struct HerdrLayout: Equatable, Sendable {
    public let tabID: String
    public let zoomed: Bool
    public let paneIDs: [String]

    public init(tabID: String, zoomed: Bool, paneIDs: [String]) {
        self.tabID = tabID
        self.zoomed = zoomed
        self.paneIDs = paneIDs
    }
}

/// One `session.snapshot` result. Unknown fields are ignored; the fields Steer relies on are
/// required, and a missing one makes the whole reply malformed.
public struct HerdrSnapshot: Equatable, Sendable {
    public let version: String
    public let protocolVersion: Int
    public let focusedWorkspaceID: String?
    public let focusedTabID: String?
    public let focusedPaneID: String?
    public let tabs: [HerdrTab]
    public let panes: [HerdrPane]
    public let layouts: [HerdrLayout]

    public init(version: String, protocolVersion: Int, focusedWorkspaceID: String?, focusedTabID: String?,
                focusedPaneID: String?, tabs: [HerdrTab], panes: [HerdrPane], layouts: [HerdrLayout]) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.focusedWorkspaceID = focusedWorkspaceID
        self.focusedTabID = focusedTabID
        self.focusedPaneID = focusedPaneID
        self.tabs = tabs
        self.panes = panes
        self.layouts = layouts
    }

    public func pane(_ paneID: String) -> HerdrPane? { panes.first { $0.paneID == paneID } }
    public func tab(_ tabID: String) -> HerdrTab? { tabs.first { $0.tabID == tabID } }
}

// MARK: - Pane processes

/// One process in a pane's foreground process group, as herdr reads it from the pane's own
/// terminal (`pane.process_info`). `name` is the executable name; `argv` is never used to decide
/// what runs in the pane (ADR 0012).
public struct HerdrForegroundProcess: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let argv: [String]?
    public let cwd: String?

    public init(pid: Int32, name: String, argv: [String]?, cwd: String?) {
        self.pid = pid
        self.name = name
        self.argv = argv
        self.cwd = cwd
    }

    /// The number of `processes` whose executable name is exactly `name`.
    public static func count(named name: String, in processes: [HerdrForegroundProcess]) -> Int {
        processes.filter { $0.name == name }.count
    }
}

/// One `pane.process_info` result. herdr reports it from the pane's terminal, not from any agent
/// report, so a shared Codex daemon cannot affect it (docs/evidence/herdr-daemon-pane-signals.md).
public struct HerdrProcessInfo: Equatable, Sendable {
    public let paneID: String
    public let shellPID: Int32?
    public let foregroundProcessGroupID: Int32?
    public let foregroundProcesses: [HerdrForegroundProcess]

    public init(paneID: String, shellPID: Int32?, foregroundProcessGroupID: Int32?,
                foregroundProcesses: [HerdrForegroundProcess]) {
        self.paneID = paneID
        self.shellPID = shellPID
        self.foregroundProcessGroupID = foregroundProcessGroupID
        self.foregroundProcesses = foregroundProcesses
    }
}

// MARK: - Socket replies

/// One decoded socket reply that answered Steer's request.
public enum HerdrReply: Equatable, Sendable {
    case pong(version: String, protocolVersion: Int)
    case snapshot(HerdrSnapshot)
    /// A `pane.process_info` result. The caller checks it names the pane it asked about.
    case processInfo(HerdrProcessInfo)
    /// A success whose result type Steer does not decode further (focus, send_keys).
    case accepted(type: String)
}

public enum HerdrWire {
    /// Largest reply line accepted, newline excluded (ADR 0009).
    public static let maximumReply = 2 * 1024 * 1024
    /// Fixed bounds on snapshot collections; a larger snapshot is malformed rather than truncated.
    public static let maximumRecords = 4096
    /// Fixed bounds on one `pane.process_info` result: foreground processes, and `argv` entries per
    /// process. A larger result is malformed rather than truncated.
    public static let maximumProcesses = 256
    public static let maximumArguments = 1024

    /// One newline-terminated request line. `params` must be JSON-serializable; nil when not.
    public static func requestLine(id: String, method: String, params: [String: Any]) -> Data? {
        let object: [String: Any] = ["id": id, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Decodes one reply line (without its newline) that must answer request `id`. A reply with
    /// another id, an oversized line, invalid JSON, or a missing relied-on field is malformed; an
    /// error object is refused with herdr's code. The protocol allowlist is applied to `pong` and
    /// snapshot replies.
    public static func decodeReply(_ line: Data, expectedID: String) -> Result<HerdrReply, HerdrUnavailableReason> {
        guard line.count <= maximumReply,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: line),
              envelope.id == expectedID else { return .failure(.malformedReply) }
        if let error = envelope.error {
            guard envelope.result == nil else { return .failure(.malformedReply) }
            return .failure(.requestRefused(code: String(error.code.prefix(64))))
        }
        guard let result = envelope.result else { return .failure(.malformedReply) }
        switch result {
        case .pong(let version, let protocolVersion):
            if let reason = HerdrProtocol.check(protocolVersion) { return .failure(reason) }
            return .success(.pong(version: version, protocolVersion: protocolVersion))
        case .snapshot(let wire):
            if let reason = HerdrProtocol.check(wire.protocolVersion) { return .failure(reason) }
            guard let snapshot = wire.snapshot else { return .failure(.malformedReply) }
            return .success(.snapshot(snapshot))
        case .processInfo(let wire):
            guard let info = wire.info else { return .failure(.malformedReply) }
            return .success(.processInfo(info))
        case .other(let type):
            return .success(.accepted(type: type))
        }
    }

    private struct Envelope: Decodable {
        let id: String
        let result: ResultBody?
        let error: ErrorBody?
    }

    private struct ErrorBody: Decodable {
        let code: String
    }

    private enum ResultBody: Decodable {
        case pong(String, Int)
        case snapshot(WireSnapshot)
        case processInfo(WireProcessInfo)
        case other(String)

        private enum Keys: String, CodingKey { case type, version, `protocol`, snapshot, process_info }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "pong":
                self = .pong(try container.decode(String.self, forKey: .version),
                             try container.decode(Int.self, forKey: .protocol))
            case "session_snapshot":
                self = .snapshot(try container.decode(WireSnapshot.self, forKey: .snapshot))
            case "pane_process_info":
                self = .processInfo(try container.decode(WireProcessInfo.self, forKey: .process_info))
            default:
                self = .other(String(type.prefix(64)))
            }
        }
    }

    /// The snapshot as sent. The protocol is decoded first so an unlisted protocol reports as
    /// unsupported even when the rest of its shape changed.
    private struct WireSnapshot: Decodable {
        let protocolVersion: Int
        let snapshot: HerdrSnapshot?

        private enum Keys: String, CodingKey {
            case version, `protocol`, focused_workspace_id, focused_tab_id, focused_pane_id, tabs, panes, layouts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            protocolVersion = try container.decode(Int.self, forKey: .protocol)
            guard HerdrProtocol.check(protocolVersion) == nil else { snapshot = nil; return }
            let tabs = try container.decode([WireTab].self, forKey: .tabs)
            let panes = try container.decode([WirePane].self, forKey: .panes)
            let layouts = try container.decode([WireLayout].self, forKey: .layouts)
            guard tabs.count <= HerdrWire.maximumRecords, panes.count <= HerdrWire.maximumRecords,
                  layouts.count <= HerdrWire.maximumRecords else { snapshot = nil; return }
            snapshot = HerdrSnapshot(
                version: try container.decode(String.self, forKey: .version),
                protocolVersion: protocolVersion,
                focusedWorkspaceID: try container.decodeIfPresent(String.self, forKey: .focused_workspace_id),
                focusedTabID: try container.decodeIfPresent(String.self, forKey: .focused_tab_id),
                focusedPaneID: try container.decodeIfPresent(String.self, forKey: .focused_pane_id),
                tabs: tabs.map { HerdrTab(tabID: $0.tab_id, workspaceID: $0.workspace_id, focused: $0.focused,
                                          paneCount: $0.pane_count) },
                panes: panes.map { HerdrPane(paneID: $0.pane_id, tabID: $0.tab_id, workspaceID: $0.workspace_id,
                                             focused: $0.focused, agent: $0.agent,
                                             agentStatus: HerdrAgentStatus(raw: $0.agent_status),
                                             agentSession: $0.agent_session,
                                             terminalTitle: $0.terminal_title_stripped) },
                layouts: layouts.map { HerdrLayout(tabID: $0.tab_id, zoomed: $0.zoomed,
                                                   paneIDs: $0.panes.map(\.pane_id)) })
        }
    }

    /// `pane.process_info` as sent. `info` is nil when a bound is exceeded or a PID is out of range.
    private struct WireProcessInfo: Decodable {
        let info: HerdrProcessInfo?

        private enum Keys: String, CodingKey { case pane_id, shell_pid, foreground_process_group_id, foreground_processes }

        private struct Process: Decodable {
            let pid: Int
            let name: String
            let argv: [String]?
            let cwd: String?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let paneID = try container.decode(String.self, forKey: .pane_id)
            let shell = try container.decodeIfPresent(Int.self, forKey: .shell_pid)
            let group = try container.decodeIfPresent(Int.self, forKey: .foreground_process_group_id)
            // herdr omits the list for a pane with nothing in the foreground; that is zero processes.
            let processes = try container.decodeIfPresent([Process].self, forKey: .foreground_processes) ?? []
            guard processes.count <= HerdrWire.maximumProcesses,
                  processes.allSatisfy({ ($0.argv?.count ?? 0) <= HerdrWire.maximumArguments }),
                  let pids = Self.pids(processes.map(\.pid)),
                  Self.pids([shell, group].compactMap { $0 }) != nil else { info = nil; return }
            info = HerdrProcessInfo(
                paneID: paneID, shellPID: shell.flatMap(Int32.init(exactly:)),
                foregroundProcessGroupID: group.flatMap(Int32.init(exactly:)),
                foregroundProcesses: zip(processes, pids).map {
                    HerdrForegroundProcess(pid: $1, name: $0.name, argv: $0.argv, cwd: $0.cwd)
                })
        }

        /// Each value as a positive `Int32`, or nil when any is out of range.
        private static func pids(_ values: [Int]) -> [Int32]? {
            let converted = values.compactMap { $0 > 0 ? Int32(exactly: $0) : nil }
            return converted.count == values.count ? converted : nil
        }
    }

    private struct WireTab: Decodable {
        let tab_id: String
        let workspace_id: String
        let focused: Bool
        let pane_count: Int
    }

    private struct WirePane: Decodable {
        let pane_id: String
        let tab_id: String
        let workspace_id: String
        let focused: Bool
        let agent: String?
        let agent_status: String
        let agent_session: HerdrAgentSession?
        let terminal_title_stripped: String?
    }

    private struct WireLayout: Decodable {
        struct Pane: Decodable { let pane_id: String }
        let tab_id: String
        let zoomed: Bool
        let panes: [Pane]
    }
}

// MARK: - `herdr integration status`

/// One agent's line from `herdr integration status`, which prints
/// `<target>: <state> (<path>)` per installed integration (herdr 0.9.3 `src/cli/integration.rs`).
/// The same value feeds ADR 0008's binding rules (`HerdrObservation.integrations`) unchanged, so
/// there is one integration-state type. Only `current` permits targeting.
public enum HerdrIntegrationState: Equatable, Hashable, Sendable {
    case current(version: Int)
    /// Not listed, or listed as `not installed`.
    case notInstalled
    /// `outdated (…)` or `needs repair (…)`.
    case outdated
    /// A line for the agent that Steer cannot read.
    case unparseable
}

public struct HerdrIntegrationReport: Equatable, Sendable {
    public static let maximumOutput = 64 * 1024

    public let states: [HerdrAgentKind: HerdrIntegrationState]

    public init(states: [HerdrAgentKind: HerdrIntegrationState]) {
        self.states = states
    }

    /// Parses the command's stdout. Output over the bound is treated as unreadable for every agent.
    public init(parsing output: String) {
        guard output.utf8.count <= Self.maximumOutput else {
            states = Dictionary(uniqueKeysWithValues: HerdrAgentKind.allCases.map { ($0, .unparseable) })
            return
        }
        var states: [HerdrAgentKind: HerdrIntegrationState] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":"),
                  let agent = HerdrAgentKind(rawValue: String(line[..<colon])) else { continue }
            let state = Self.state(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            // A repeated line for one agent cannot be resolved, so neither copy is trusted.
            states[agent] = states[agent] == nil ? state : .unparseable
        }
        for agent in HerdrAgentKind.allCases where states[agent] == nil { states[agent] = .notInstalled }
        self.states = states
    }

    private static func state(_ text: String) -> HerdrIntegrationState {
        if text.hasPrefix("not installed") { return .notInstalled }
        if text.hasPrefix("outdated (") || text.hasPrefix("needs repair (") { return .outdated }
        guard text.hasPrefix("current (v"),
              let close = text.firstIndex(of: ")") else { return .unparseable }
        let digits = text[text.index(text.startIndex, offsetBy: "current (v".count)..<close]
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy(\.isASCII), let version = Int(digits),
              version > 0 else { return .unparseable }
        return .current(version: version)
    }

    public func reason(for agent: HerdrAgentKind) -> HerdrUnavailableReason? {
        if case .current? = states[agent] { return nil }
        return .integrationNotCurrent(agent)
    }
}

// MARK: - Attached clients (`lsof -nP -U -F pfdn`)

/// One process on the way from a herdr client to its outer terminal.
public struct HerdrProcessAncestor: Equatable, Sendable {
    public let pid: Int32
    /// The executable's file name, e.g. `herdr`, `login`, `ghostty`.
    public let command: String
    /// The controlling terminal's device name, e.g. `ttys015`; nil when it has none.
    public let tty: String?

    public init(pid: Int32, command: String, tty: String?) {
        self.pid = pid
        self.command = command
        self.tty = tty
    }
}

/// The herdr server and the TUI clients attached to it, read from unix-socket peers on the
/// client socket. herdr's API reports nothing about clients.
public struct HerdrClientListing: Equatable, Sendable {
    public static let maximumOutput = 8 * 1024 * 1024

    public let serverPIDs: [Int32]
    public let clientPIDs: [Int32]

    public init(serverPIDs: [Int32], clientPIDs: [Int32]) {
        self.serverPIDs = serverPIDs
        self.clientPIDs = clientPIDs
    }

    /// Parses `lsof -nP -U -F pfdn`. The listener and its accepted connections all carry the
    /// client socket path as their name; a client is a process whose peer (`->0x…`) is one of those
    /// devices. Nil when the output exceeds the bound or a record cannot be read.
    public static func parse(lsof output: String, clientSocketPath: String) -> HerdrClientListing? {
        guard output.utf8.count <= maximumOutput else { return nil }
        var records: [(pid: Int32, device: String?, name: String)] = []
        var pid: Int32?
        var device: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let tag = line.first
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                guard let parsed = Int32(value), parsed > 0 else { return nil }
                pid = parsed
                device = nil
            case "f":
                device = nil
            case "d":
                device = value
            case "n":
                guard let pid else { return nil }
                records.append((pid, device, value))
            default:
                continue
            }
        }
        let owned = records.filter { $0.name == clientSocketPath }
        let servers = Set(owned.map(\.pid))
        let devices = Set(owned.compactMap(\.device))
        let clients = Set(records.compactMap { record -> Int32? in
            guard record.name.hasPrefix("->"), devices.contains(String(record.name.dropFirst(2))),
                  !servers.contains(record.pid) else { return nil }
            return record.pid
        })
        return HerdrClientListing(serverPIDs: servers.sorted(), clientPIDs: clients.sorted())
    }
}

/// The single attached client that every Open or relay requires: exactly one, hosted by Ghostty.
public struct HerdrAttachedClient: Equatable, Sendable {
    public let pid: Int32
    /// The client's own terminal, which ADR 0011 joins to a Ghostty terminal's `tty`.
    public let tty: String?
    public let serverPID: Int32?

    public init(pid: Int32, tty: String?, serverPID: Int32?) {
        self.pid = pid
        self.tty = tty
        self.serverPID = serverPID
    }

    /// The client verdict (ADR 0008): zero or several clients are `wrongClientCount`; a client
    /// whose ancestry has no `ghostty` process is `nonGhosttyClient`. `ancestry` starts at the
    /// client itself.
    public static func verdict(listing: HerdrClientListing,
                               ancestry: (Int32) -> [HerdrProcessAncestor]) -> Result<HerdrAttachedClient, HerdrUnavailableReason> {
        guard listing.clientPIDs.count == 1, let pid = listing.clientPIDs.first else {
            return .failure(.wrongClientCount(listing.clientPIDs.count))
        }
        let chain = ancestry(pid)
        guard chain.first?.pid == pid, chain.dropFirst().contains(where: { $0.command == "ghostty" }) else {
            return .failure(.nonGhosttyClient)
        }
        return .success(HerdrAttachedClient(pid: pid, tty: chain.first?.tty,
                                    serverPID: listing.serverPIDs.count == 1 ? listing.serverPIDs.first : nil))
    }
}

// MARK: - Scan

/// What one scan reads beyond `ping`, the snapshot and `lsof`, decided by the caller from the gate
/// inputs (ADR 0009). `herdr integration status` concerns Claude Code only (ADR 0008), so it runs
/// only when a Claude session opened the gate. `pane.process_info` is requested for each pane whose
/// title is one of `processInfoTitles`, the shortened identifiers of live Codex sessions (ADR 0012).
public struct HerdrScanRequest: Equatable, Hashable, Sendable {
    /// At most this many `pane.process_info` requests per scan, each with ADR 0009's deadline.
    public static let maximumProcessInfoRequests = 16

    public let includeIntegration: Bool
    public let processInfoTitles: Set<String>

    public init(includeIntegration: Bool = true, processInfoTitles: Set<String> = []) {
        self.includeIntegration = includeIntegration
        self.processInfoTitles = processInfoTitles
    }

    /// The panes to ask about, in pane ID order, at most `maximumProcessInfoRequests`. A pane past
    /// the bound gets no reply, which leaves any binding to it unavailable rather than guessed.
    public func processInfoPanes(in snapshot: HerdrSnapshot) -> [String] {
        guard !processInfoTitles.isEmpty else { return [] }
        let panes = Set(snapshot.panes.filter { $0.terminalTitle.map(processInfoTitles.contains) == true }.map(\.paneID))
        return Array(panes.sorted().prefix(Self.maximumProcessInfoRequests))
    }
}

/// Everything one herdr scan read, taken together. Scan-wide failures (socket, protocol, reply,
/// subprocess) are reported by `HerdrScanOutcome.unavailable`; the client verdict, integration
/// state and each pane's process info are per target. The first two surface through
/// `targetReason(for:)`; process info is read by the binding rules.
public struct HerdrScan: Equatable, Sendable {
    public let snapshot: HerdrSnapshot
    public let integration: HerdrIntegrationReport
    public let client: Result<HerdrAttachedClient, HerdrUnavailableReason>
    /// `pane.process_info` per pane ID the request selected. A pane that is absent was not asked
    /// about; a failure is that request's own typed reason.
    public let processInfo: [String: Result<HerdrProcessInfo, HerdrUnavailableReason>]
    /// When the one herdr server process listening on the client socket started, in seconds since
    /// 1970 (the clock of hook records' `captured_at`). It is the server identity ADR 0008's
    /// restart check compares against. Nil when the listing showed zero or several server
    /// processes or the kernel could not report a start time; a binding is then unavailable.
    public let serverStartedAt: Double?

    public init(snapshot: HerdrSnapshot, integration: HerdrIntegrationReport,
                client: Result<HerdrAttachedClient, HerdrUnavailableReason>, serverStartedAt: Double? = nil,
                processInfo: [String: Result<HerdrProcessInfo, HerdrUnavailableReason>] = [:]) {
        self.snapshot = snapshot
        self.integration = integration
        self.client = client
        self.serverStartedAt = serverStartedAt
        self.processInfo = processInfo
    }

    /// The first scan-level reason a session of `agent` cannot be targeted, or nil when exactly one
    /// Ghostty-hosted client is attached and, for Claude Code, its integration is current. Codex
    /// needs no herdr integration (ADR 0012). Binding, split and named-session checks are applied
    /// by the binding rules, not here.
    public func targetReason(for agent: HerdrAgentKind) -> HerdrUnavailableReason? {
        if agent == .claude, let reason = integration.reason(for: agent) { return reason }
        if case .failure(let reason) = client { return reason }
        return nil
    }
}

public enum HerdrScanOutcome: Equatable, Sendable {
    case available(HerdrScan)
    case unavailable(HerdrUnavailableReason)

    public var scan: HerdrScan? {
        if case .available(let scan) = self { return scan }
        return nil
    }

    public func targetReason(for agent: HerdrAgentKind) -> HerdrUnavailableReason? {
        switch self {
        case .available(let scan): return scan.targetReason(for: agent)
        case .unavailable(let reason): return reason
        }
    }
}
