import Foundation

// Rex (superlogical.com/rex), from the live probe (docs/rex-cli-investigation.md): a Rex server owns
// every terminal; Rex.app is one client of it. A Rex *session* holds *windows* (the app's tabs), and a
// window holds *blocks* (panes), each with its own pty and a `block:<uuid>` id. One `rex do` Lua script
// returns every session's windows, the window each session shows, each window's focused block, and each
// local terminal block's foreground pid and title. `session.focus_block` focuses one exact block and makes
// its window the session's active window; block method `write` types raw bytes into that block alone. Which
// Rex session the app shows is not readable, and selecting one (`session.select`) needs the app's Remote
// Control setting, which is off by default. Everything here is a pure function of what HerdlyApp's `rex`
// runs return, kernel reads of the foreground pids and the frontmost app macOS reports.

/// One Rex terminal block. Its `blockID` stands for its tab in ADR 0013's inventory: every block has its
/// own pty and `session.focus_block` reaches it exactly, so a split window holds several one-pane targets.
public struct RexBlock: Equatable, Sendable {
    public let blockID: String
    public let windowID: String
    public let sessionID: String
    /// `/dev/ttysNNN` of the block's foreground process; nil when it could not be read.
    public let tty: String?
    public let title: String?

    public init(blockID: String, windowID: String, sessionID: String, tty: String?, title: String?) {
        self.blockID = blockID
        self.windowID = windowID
        self.sessionID = sessionID
        self.tty = tty
        self.title = title
    }
}

/// One Rex window (tab): its blocks of every kind, and which one has focus.
public struct RexWindow: Equatable, Sendable {
    public let windowID: String
    public let sessionID: String
    public let focusedBlockID: String?

    public init(windowID: String, sessionID: String, focusedBlockID: String?) {
        self.windowID = windowID
        self.sessionID = sessionID
        self.focusedBlockID = focusedBlockID
    }
}

/// One complete inventory script reply.
public struct RexSnapshot: Equatable, Sendable {
    public static let maximumReplySize = 2 * 1024 * 1024
    public static let maximumSessions = 256
    public static let maximumBlocks = 1024
    public static let maximumTitleLength = 1024
    public static let maximumIDLength = 128

    /// Local terminal blocks only: another host's block runs on another machine, and a non-terminal
    /// block has no process.
    public let blocks: [RexBlock]
    public let windows: [RexWindow]
    /// Each session's active window, the one the app shows while it shows that session.
    public let activeWindows: [String: String]
    /// Every session, in the server's order.
    public let sessionIDs: [String]
    /// The server process, for diagnostics.
    public let serverPID: Int32?

    public init(blocks: [RexBlock], windows: [RexWindow], activeWindows: [String: String], sessionIDs: [String],
                serverPID: Int32? = nil) {
        self.blocks = blocks
        self.windows = windows
        self.activeWindows = activeWindows
        self.sessionIDs = sessionIDs
        self.serverPID = serverPID
    }

    /// The reply in `data`, with each block's tty read from its foreground pid by `tty`; nil when the reply
    /// is oversized or malformed in any part, since a partial inventory could hide the block a session is on.
    public static func parse(_ data: Data, tty: (Int32) -> String?) -> RexSnapshot? {
        guard data.count <= maximumReplySize,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionRows = RexJSON.array(root["sessions"]), sessionRows.count <= maximumSessions else { return nil }
        var blocks: [RexBlock] = [], windows: [RexWindow] = [], active: [String: String] = [:], sessionIDs: [String] = []
        var blockIDs: Set<String> = [], windowIDs: Set<String> = []
        var seen = 0
        for case let session as [String: Any] in sessionRows {
            guard let sessionID = RexJSON.id(session["session_id"], prefix: "session:"), !sessionIDs.contains(sessionID),
                  let windowRows = RexJSON.array(session["windows"]) else { return nil }
            sessionIDs.append(sessionID)
            switch session["active_window_id"] {
            case nil, is NSNull: break
            case let value:
                guard let window = RexJSON.id(value, prefix: "window:") else { return nil }
                active[sessionID] = window
            }
            for case let window as [String: Any] in windowRows {
                guard let windowID = RexJSON.id(window["window_id"], prefix: "window:"), windowIDs.insert(windowID).inserted,
                      let blockRows = RexJSON.array(window["blocks"]) else { return nil }
                let focused: String?
                switch window["focused_block_id"] {
                case nil, is NSNull: focused = nil
                case let value:
                    guard let id = RexJSON.id(value, prefix: "block:") else { return nil }
                    focused = id
                }
                windows.append(RexWindow(windowID: windowID, sessionID: sessionID, focusedBlockID: focused))
                for case let block as [String: Any] in blockRows {
                    seen += 1
                    guard seen <= maximumBlocks, let blockID = RexJSON.id(block["block_id"], prefix: "block:"),
                          blockIDs.insert(blockID).inserted,
                          let terminal = block["terminal"] as? Bool, let local = block["local"] as? Bool else { return nil }
                    guard terminal, local else { continue }
                    let pid: Int32?
                    switch block["foreground_pid"] {
                    case nil, is NSNull: pid = nil
                    case let value:
                        guard let number = WezTermJSON.identifier(value), number > 0, number <= Int(Int32.max) else { return nil }
                        pid = Int32(number)
                    }
                    let title: String?
                    switch block["title"] {
                    case nil, is NSNull: title = nil
                    case let value as String: title = value.isEmpty || value.count > maximumTitleLength ? nil : value
                    default: return nil
                    }
                    blocks.append(RexBlock(blockID: blockID, windowID: windowID, sessionID: sessionID,
                                           tty: pid.flatMap(tty).flatMap(GhosttyTTYMatch.normalizedTTY), title: title))
                }
                guard blockRows.allSatisfy({ $0 is [String: Any] }) else { return nil }
            }
            guard windowRows.allSatisfy({ $0 is [String: Any] }) else { return nil }
        }
        guard sessionRows.allSatisfy({ $0 is [String: Any] }) else { return nil }
        let serverPID = WezTermJSON.identifier(root["server_pid"]).flatMap { $0 <= Int(Int32.max) ? Int32($0) : nil }
        return RexSnapshot(blocks: blocks, windows: windows, activeWindows: active, sessionIDs: sessionIDs,
                           serverPID: serverPID)
    }

    public func block(_ id: String) -> RexBlock? {
        blocks.first { $0.blockID == id }
    }

    public func window(_ id: String) -> RexWindow? {
        windows.first { $0.windowID == id }
    }

    /// Whether `block` is what its session shows: its window is the session's active window and the block
    /// has that window's focus. Whether the app shows that session is a separate question.
    public func isShown(_ block: RexBlock) -> Bool {
        activeWindows[block.sessionID] == block.windowID && window(block.windowID)?.focusedBlockID == block.blockID
    }

    /// ADR 0013's inventory: each terminal block as a one-pane tab, its block id the handle.
    public var inventory: TerminalHostInventory {
        .tabs(blocks.map { TerminalTab(tabID: $0.blockID, tty: $0.tty, title: $0.title, paneCount: 1) })
    }

    /// The ttys whose `ps -t` reads ADR 0013's rules need: blocks showing one of `codexTitles`, and blocks
    /// on one of `claudeTTYs`. Other blocks are never read.
    public func ttysToRead(codexTitles: Set<String>, claudeTTYs: Set<String>) -> Set<String> {
        let claude = Set(claudeTTYs.compactMap(GhosttyTTYMatch.normalizedTTY))
        return Set(blocks.compactMap { block in
            guard let tty = block.tty else { return nil }
            return claude.contains(tty) || block.title.map(codexTitles.contains) == true ? tty : nil
        })
    }

    /// As above for every block titled with any shortened Codex identifier, when Rex is read beside
    /// another host that does not know which sessions are live.
    public func ttysToRead(claudeTTYs: Set<String>) -> Set<String> {
        ttysToRead(codexTitles: Set(blocks.compactMap(\.title).filter(HerdrBindingRules.isShortenedCodexSessionTitle)),
                   claudeTTYs: claudeTTYs)
    }
}

enum RexJSON {
    /// A JSON array; Lua serializes an empty table as `{}`, so an empty object is an empty array too.
    static func array(_ value: Any?) -> [Any]? {
        if let rows = value as? [Any] { return rows }
        if let object = value as? [String: Any], object.isEmpty { return [] }
        return nil
    }

    /// A Rex id such as `block:<uuid>`: the expected prefix, then letters, digits and dashes, bounded.
    static func id(_ value: Any?, prefix: String) -> String? {
        guard let text = value as? String, text.hasPrefix(prefix), text.count > prefix.count,
              text.count <= RexSnapshot.maximumIDLength,
              text.dropFirst(prefix.count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return text
    }
}

// MARK: - Binary, socket and reads

/// Why Rex, running, could not be read. Every reason leaves every session it could hold unavailable
/// (ADR 0013 "Inventory"); none is an empty Rex.
public enum RexUnreadable: Error, Equatable, Hashable, Sendable {
    /// No `rex` binary in its fixed locations (`RexCLI.binaryCandidates`).
    case binaryNotFound
    /// The server socket is not a Unix socket owned by this user with no group or other permission bits.
    case socketUntrusted
    /// `rex` exited with an error.
    case commandFailed
    case timedOut
    /// The reply could not be decoded within bounds.
    case malformedReply
}

/// How one `rex` run ended, from HerdlyApp's side.
public enum RexCommandResult: Equatable, Sendable {
    /// The binary ran and exited; stdout and stderr are bounded.
    case exited(status: Int32, stdout: Data, stderr: String)
    /// Nothing ran: the binary or a trusted socket was not found. Nothing reached Rex.
    case notRun(RexUnreadable)
    /// The run passed its deadline and was terminated; what it did is unknown.
    case timedOut
}

/// The fixed command lines and environment Herdly runs `rex` with. The binary resolves only from fixed
/// locations, never from `PATH`; it talks only to the socket Herdly checked (`REX_SERVER`, never an
/// inherited value) and never starts a server (`--autostart=false`).
public enum RexCLI {
    /// Seconds one run may take.
    public static let timeout: Double = 3
    public static let outputLimit = RexSnapshot.maximumReplySize
    public static let bundleIdentifier = "com.superlogical.rex"
    /// The server's own app bundle, which a process walk from a Rex terminal reaches (ADR 0015).
    public static let serverBundleIdentifier = "com.superlogical.rex.server"

    /// The installed server's copy first (the one the running server came from), then the copy inside Rex.app.
    public static func binaryCandidates(home: String) -> [String] {
        ["\(home)/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
         "/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
         "\(home)/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"]
    }

    /// The local server's socket (`server.status`'s primary listener).
    public static func socketPath(home: String) -> String {
        "\(home)/Library/Application Support/rex/server.sock"
    }

    /// `REX_SERVER` for `socket`: a `unix://` URL with the path percent-encoded, as Rex prints it.
    public static func serverAddress(socket: String) -> String {
        "unix://" + (socket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? socket)
    }

    public static func environment(home: String, socket: String) -> [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "REX_SERVER": serverAddress(socket: socket)]
    }

    static let global = ["--autostart=false", "--color", "never"]

    /// The inventory script, read from stdin (`rex do -`). It fails as a whole when any call fails, so a
    /// reply is always complete.
    public static let inventory = global + ["do", "-"]

    public static let inventoryScript = """
    local function must(value, err)
      if err ~= nil or value == nil then error(tostring(err), 0) end
      return value
    end
    local status = must(rex.call("server.status", {}))
    local list = must(rex.call("session.list", {}))
    local sessions = {}
    for _, s in ipairs(list.sessions or {}) do
      must(rex.call("session.attach", { session_id = s.session_id }))
      local view = must(rex.call("session.view", { session_id = s.session_id }))
      local windows = {}
      for _, w in ipairs(view.windows or {}) do
        local blocks = {}
        for _, layer in ipairs(w.layers or {}) do
          for _, b in ipairs(layer.blocks or {}) do
            local entry = { block_id = b.block_id, terminal = b.creator_name == "com.superlogical.terminal",
                            ["local"] = b.host_id == status.host_id }
            if entry.terminal and entry["local"] then
              local p = must(rex.call("block.method", { session_id = s.session_id, block_id = b.block_id, method = "process" }))
              local t = must(rex.call("block.method", { session_id = s.session_id, block_id = b.block_id, method = "title" }))
              entry.foreground_pid = p.foreground and p.foreground.pid or nil
              entry.title = t.title
            end
            blocks[#blocks + 1] = entry
          end
        end
        windows[#windows + 1] = { window_id = w.window_id, focused_block_id = w.focused_block_id, blocks = blocks }
      end
      sessions[#sessions + 1] = { session_id = s.session_id, active_window_id = view.active_window_id, windows = windows }
    end
    return { server_pid = status.pid, sessions = sessions }
    """

    public static let versionArguments = global + ["api", "call", "server.version", "{}"]

    /// `rex_version` from `server.version`; nil for anything else.
    public static func version(_ stdout: Data) -> String? {
        guard stdout.count <= 4096, let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let version = object["rex_version"] as? String, !version.isEmpty, version.count <= 64,
              version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._+".contains($0)) }) else { return nil }
        return version
    }

    /// ADR 0016's select step: focus the block and make its window its session's active window.
    public static func focus(_ block: RexBlock) -> [String] {
        global + ["api", "call", "session.focus_block", json(["session_id": block.sessionID, "block_id": block.blockID])]
    }

    /// Asks the one app client to show the block's session and window. Refused while Remote Control is off.
    public static func select(_ block: RexBlock, client: String) -> [String] {
        global + ["api", "call", "client.perform",
                  json(["client_id": client, "action": "session.select", "origin": "api", "timeout_ms": 2000,
                        "args": ["session_id": block.sessionID, "window_id": block.windowID]])]
    }

    public static let listClients = global + ["api", "call", "client.list", "{}"]

    /// One `write` of `payload` into `block` alone.
    public static func write(_ payload: String, block: RexBlock) -> [String] {
        global + ["api", "call", "block.method",
                  json(["session_id": block.sessionID, "block_id": block.blockID, "method": "write", "args": ["data": payload]])]
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The Rex app clients `client.list` reports, by id; CLI and script clients are left out.
public enum RexClients {
    public static func appClients(_ stdout: Data) -> [String]? {
        guard stdout.count <= 256 * 1024, let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let rows = RexJSON.array(object["clients"]) else { return nil }
        var ids: [String] = []
        for case let row as [String: Any] in rows {
            guard let info = row["info"] as? [String: Any], info["kind"] as? String == "app",
                  row["connection_state"] as? String == "connected",
                  let id = RexJSON.id(row["client_id"], prefix: "client:") else { continue }
            ids.append(id)
        }
        return ids
    }
}

public enum RexSocket {
    /// The trust check, from `lstat` of the socket path (never followed through a symlink): a Unix socket
    /// owned by this user with no group or other permission bits. A missing socket is a Rex that isn't
    /// running, not a problem.
    public static func trust(exists: Bool, isSocket: Bool, owner: uid_t, mode: mode_t, me: uid_t) -> RexSocketState {
        switch AppServerSocketCheck.problem(exists: exists, isSocket: isSocket, owner: owner, mode: mode, me: me) {
        case nil: .trusted
        case .missing?: .missing
        case .notASocket?, .notOwnedByUser?, .sharedPermissions?: .untrusted
        }
    }

    public static func trust(at path: String) -> RexSocketState {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        return trust(exists: true, isSocket: (info.st_mode & S_IFMT) == S_IFSOCK, owner: info.st_uid,
                     mode: info.st_mode & 0o777, me: getuid())
    }
}

public enum RexSocketState: Equatable, Sendable {
    case trusted
    case missing
    case untrusted
}

/// One Rex inventory read.
public enum RexRead: Equatable, Sendable {
    /// No Rex server socket: Rex holds nothing.
    case notRunning
    case snapshot(RexSnapshot)
    case unreadable(RexUnreadable)

    /// The read from one inventory run.
    public static func inventory(_ result: RexCommandResult, tty: (Int32) -> String?) -> RexRead {
        switch result {
        case .notRun(let reason): return .unreadable(reason)
        case .timedOut: return .unreadable(.timedOut)
        case .exited(let status, let stdout, _):
            guard status == 0 else { return .unreadable(.commandFailed) }
            return RexSnapshot.parse(stdout, tty: tty).map(RexRead.snapshot) ?? .unreadable(.malformedReply)
        }
    }

    public var inventory: TerminalHostInventory {
        switch self {
        case .notRunning: .notRunning
        case .snapshot(let value): value.inventory
        case .unreadable: .unreadable
        }
    }

    public var snapshot: RexSnapshot? {
        if case .snapshot(let value) = self { return value }
        return nil
    }
}

// MARK: - Visible and Open (ADR 0015, ADR 0016)

extension TerminalVisibility {
    /// Rex's visible test (ADR 0016): macOS reports Rex frontmost, the server has exactly one session (Rex
    /// does not report which session the app shows), and that session's active window's focused block is
    /// the block returned. With several sessions nothing can be seen as visible, so it is unknown.
    public static func rex(_ snapshot: RexSnapshot?, frontmost: TerminalHost?) -> TerminalVisibilityReading<String> {
        guard frontmost == .rex else { return .nothing }
        guard let snapshot, snapshot.sessionIDs.count == 1 else { return .unknown }
        guard let window = snapshot.activeWindows[snapshot.sessionIDs[0]],
              let focused = snapshot.window(window)?.focusedBlockID, snapshot.block(focused) != nil else { return .nothing }
        return .visible(focused)
    }
}

/// What a revalidated Rex Open holds to: the bound block and, for Codex, the title that must still show.
public struct RexOpenPlan: Equatable, Sendable {
    public let target: TerminalTabTarget
    public let block: RexBlock
    public let title: String?
    /// The server holds other sessions, so the app must be asked to show this one.
    public let needsSelect: Bool

    public init(target: TerminalTabTarget, block: RexBlock, title: String?, needsSelect: Bool) {
        self.target = target
        self.block = block
        self.title = title
        self.needsSelect = needsSelect
    }
}

public enum RexOpen {
    /// Step 1's outcome from a fresh route and a fresh inventory. A binding to another host, or Ghostty's
    /// title route, is not Rex's to select and falls back.
    public static func plan(_ route: TerminalTabOpenRoute, codexTitle: String?,
                            snapshot: RexSnapshot) -> Result<RexOpenPlan, OpenMiss> {
        let target: TerminalTabTarget
        switch route {
        case .exact(let value) where value.host == .rex: target = value
        case .exact, .ghosttyTitle: return .failure(.fallBack(.noUniqueTarget, candidates: 1))
        case .miss(let miss): return .failure(miss)
        }
        guard let block = snapshot.block(target.tabID) else { return .failure(.unavailable(.sessionEnded)) }
        return .success(RexOpenPlan(target: target, block: block, title: codexTitle,
                                    needsSelect: snapshot.sessionIDs.count != 1))
    }

    /// Step 3's `session.focus_block`, sent once: nothing run is an unreadable host; `not_found` is an
    /// ended session; any other error falls back.
    public static func focused(_ result: RexCommandResult) -> OpenMiss? {
        switch result {
        case .notRun: return .unavailable(.hostUnreadable(.rex))
        case .exited(0, _, _): return nil
        case .exited(_, _, let stderr) where RexInput.reportsNotFound(stderr): return .unavailable(.sessionEnded)
        case .exited, .timedOut: return .fallBack(.notVerified, candidates: 1)
        }
    }

    /// Step 4 over a fresh inventory and the frontmost app macOS reported after it: Rex is frontmost, the
    /// block is still on the same tty, its session shows it, for Codex it still carries its title, and the
    /// app shows its session (the server's only one, or `selected`: the app performed `session.select`).
    /// Rex is already active, so any miss falls back, adding nothing.
    public static func verify(_ plan: RexOpenPlan, after: RexSnapshot?, selected: Bool,
                              frontmost: TerminalHost?) -> OpenMiss? {
        guard frontmost == .rex, let after, let block = after.block(plan.block.blockID),
              block.tty == plan.target.tty, block.sessionID == plan.block.sessionID, after.isShown(block),
              plan.title == nil || block.title == plan.title,
              after.sessionIDs.count == 1 || selected else {
            return .fallBack(.notVerified, candidates: 1)
        }
        return nil
    }

    /// ADR 0016's sequence for a Rex block: revalidate on fresh reads; focus the block once, ask the app to
    /// show its session when the server holds several, and activate Rex (`raise` does all three, returning
    /// the focus result and whether the app showed the session); then verify on a fresh read.
    public static func run(now: @escaping () -> Double,
                           revalidate: @escaping (Double) async -> Result<RexOpenPlan, OpenMiss>,
                           raise: @escaping (RexOpenPlan) async -> (RexCommandResult, selected: Bool),
                           verifyRead: @escaping () async -> (RexSnapshot?, TerminalHost?),
                           isolation: isolated (any Actor)? = #isolation) async -> TerminalOpenRun<RexOpenPlan, OpenMiss> {
        let selection = RexSelection()
        return await TerminalOpenSequence.run(TerminalOpenSteps<RexOpenPlan, OpenMiss>(
            now: now,
            revalidate: revalidate,
            raise: { plan in
                let (result, selected) = await raise(plan)
                selection.selected = selected
                return focused(result)
            },
            verify: { plan in
                let (after, frontmost) = await verifyRead()
                return verify(plan, after: after, selected: selection.selected, frontmost: frontmost)
            }))
    }

    /// Whether a `client.perform session.select` run shows the app performed it.
    public static func selected(_ result: RexCommandResult) -> Bool {
        if case .exited(0, _, _) = result { return true }
        return false
    }
}

/// Carries `raise`'s selection to `verify` within one Open, on the caller's isolation.
private final class RexSelection: @unchecked Sendable {
    // Written by `raise` and read by `verify`, which `TerminalOpenSequence.run` awaits one after the other
    // on one isolation, so the accesses never overlap.
    var selected = false
}

// MARK: - Presentation

/// The latest Rex read's outcome, for the Settings card.
public enum RexScanStatus: Equatable, Sendable {
    case notRead
    case read
    case notRunning
    case unreadable(RexUnreadable)
}

/// One Rex problem line; each is a separate fix (product.md, "Problem lines").
public enum RexSettingsProblem: Equatable, Hashable, Sendable {
    /// No `rex` in its fixed locations.
    case notFound
    /// The socket fails the owner-only trust check.
    case untrustedSocket
    /// Any other failed read. The exact reason goes to diagnostics only.
    case unreadable

    public var message: String {
        switch self {
        case .notFound: "Herdly can't find Rex in /Applications or ~/Applications."
        case .untrustedSocket: "Herdly can't read Rex: its server socket isn't private to you."
        case .unreadable: OpenUnavailableReason.hostUnreadable(.rex).cardLine
        }
    }
}

public struct RexSettingsRow: Equatable, Sendable {
    public let badge: HerdrReadinessBadge
    public let problems: [RexSettingsProblem]

    public init(badge: HerdrReadinessBadge, problems: [RexSettingsProblem]) {
        self.badge = badge
        self.problems = problems
    }
}

public enum RexPresentation {
    public static let howOpenWorks =
        "Herdly returns to the exact pane in Rex, splits included. With several Rex sessions, turn on Remote Control in Rex's Settings so Herdly can switch sessions; otherwise Open raises Rex. Replies are typed into the exact pane."

    public static func settingsRow(on: Bool, installed: Bool, scan: RexScanStatus, inUse: Bool) -> RexSettingsRow {
        guard on else { return RexSettingsRow(badge: .off, problems: []) }
        var problems: [RexSettingsProblem] = []
        if !installed { problems.append(.notFound) }
        if case .unreadable(let reason) = scan {
            switch reason {
            case .binaryNotFound: if installed { problems.append(.notFound) }
            case .socketUntrusted: problems.append(.untrustedSocket)
            case .commandFailed, .timedOut, .malformedReply: problems.append(.unreadable)
            }
        }
        let badge: HerdrReadinessBadge = !problems.isEmpty ? .needsAttention : inUse ? .ready : .notInUse
        return RexSettingsRow(badge: badge, problems: problems)
    }
}

// MARK: - Typed input (ADR 0017)

/// Rex's send: block method `write`, which types raw bytes into that block alone (live probe: no bracketed
/// paste, nothing added).
public enum RexInput {
    /// Whether Rex may carry a Codex question's digit. ADR 0017 keeps a host's question route off until a
    /// live run shows the digit alone commits there; Rex has had no such run, so a Codex question in Rex
    /// shows "Answer this in Codex."
    public static let questionDigitsProvenLive = false

    /// Claude's text and CR together; Codex's text, then a CR alone, as on WezTerm.
    public static func payload(_ write: TypedWrite) -> String {
        WezTermInput.payload(write)
    }

    /// The delivery of one `write`. Nothing ran, or Rex reported no such block: not written. Exit 0:
    /// written. Anything else, a timeout included, may have typed and counts as sent.
    public static func delivery(_ result: RexCommandResult) -> TypedInputDelivery {
        switch result {
        case .notRun: .notWritten
        case .exited(0, _, _): .written
        case .exited(_, _, let stderr) where reportsNotFound(stderr): .notWritten
        case .exited, .timedOut: .possiblyWritten
        }
    }

    static func reportsNotFound(_ stderr: String) -> Bool {
        stderr.contains("not_found") || stderr.contains("session_not_found") || stderr.contains("code=not_found")
    }
}
