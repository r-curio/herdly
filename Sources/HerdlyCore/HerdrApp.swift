import Foundation

// The Herdr desktop app (Herdr.app, herdr.dev), from the live probe (docs/herdr-app-investigation.md). It is
// not `herdr`, the terminal multiplexer Herdly reads as `.herdr`. Herdr.app's terminals run in herdr-core
// (`hc`), a per-user core that keeps them alive when the window closes; the app only shows them, arranged
// in spaces, tabs and split panes. Each core terminal (`t1`, `t2`…) has its own pty. Herdly reads the
// core's terminals with one JSON-RPC `terminal.list` on the core's own socket (never through `hc`, which
// starts a core when none runs), and asks the app's command line (`Herdr ls`, `Herdr status`) which pane
// shows which terminal and which pane has focus. Open runs `Herdr do agent.focus`; replies go through the
// core's `terminal.send` (paste, then Enter). Everything here is a pure function of those replies, kernel
// reads of each terminal's process and the frontmost app macOS reports.

/// One live local herdr-core terminal. Its `address` stands for its tab in ADR 0013's inventory: every
/// terminal has its own pty and `agent.focus` reaches it exactly, so a split tab holds several one-pane targets.
public struct HerdrAppTerminal: Equatable, Sendable {
    /// `t1`: this terminal forever on this core.
    public let address: String
    /// `/dev/ttysNNN` of the terminal's process; nil when it could not be read.
    public let tty: String?
    public let title: String?
    /// The window's space and tab (`herdr.space`, `herdr.tab` labels); nil for a terminal the window doesn't show.
    public let spaceID: String?
    public let tabID: String?

    public init(address: String, tty: String?, title: String?, spaceID: String? = nil, tabID: String? = nil) {
        self.address = address
        self.tty = tty
        self.title = title
        self.spaceID = spaceID
        self.tabID = tabID
    }
}

/// One complete `terminal.list` reply.
public struct HerdrAppSnapshot: Equatable, Sendable {
    public static let maximumReplySize = 2 * 1024 * 1024
    public static let maximumTerminals = 1024
    public static let maximumTitleLength = 1024
    public static let maximumIDLength = 128

    /// Live terminals on this machine only: a `machine/t7` terminal runs elsewhere.
    public let terminals: [HerdrAppTerminal]

    public init(terminals: [HerdrAppTerminal]) {
        self.terminals = terminals
    }

    /// The reply line in `data` to request `id`, with each terminal's tty read from its process by `tty`; nil
    /// when the line is oversized, an error, or malformed in any part, since a partial inventory could hide
    /// the terminal a session is on.
    public static func parse(_ data: Data, id: String, tty: (Int32) -> String?) -> HerdrAppSnapshot? {
        guard data.count <= maximumReplySize, case .result(let result)? = HerdrAppRPC.envelope(data, id: id),
              let rows = result["terminals"] as? [Any], rows.count <= maximumTerminals else { return nil }
        var terminals: [HerdrAppTerminal] = [], seen: Set<String> = []
        for row in rows {
            guard let terminal = row as? [String: Any], let address = terminal["address"] as? String,
                  !address.isEmpty, address.count <= maximumIDLength, seen.insert(address).inserted,
                  let state = terminal["state"] as? String else { return nil }
            // Another machine's terminal: no pty here.
            if address.contains("/") { continue }
            guard HerdrAppJSON.isID(address, prefix: "t") else { return nil }
            guard state == "live" else { continue }
            let pid: Int32?
            switch terminal["pid"] {
            case nil, is NSNull: pid = nil
            case let value:
                guard let number = WezTermJSON.identifier(value), number > 0, number <= Int(Int32.max) else { return nil }
                pid = Int32(number)
            }
            let title: String?
            switch terminal["title"] {
            case nil, is NSNull: title = nil
            case let value as String: title = value.isEmpty || value.count > maximumTitleLength ? nil : value
            default: return nil
            }
            let labels: [String: Any]
            switch terminal["labels"] {
            case nil, is NSNull: labels = [:]
            case let value as [String: Any]: labels = value
            default: return nil
            }
            terminals.append(HerdrAppTerminal(
                address: address, tty: pid.flatMap(tty).flatMap(GhosttyTTYMatch.normalizedTTY), title: title,
                spaceID: (labels["herdr.space"] as? String).flatMap { HerdrAppJSON.isID($0, prefix: "sp") ? $0 : nil },
                tabID: (labels["herdr.tab"] as? String).flatMap { HerdrAppJSON.isID($0, prefix: "tb") ? $0 : nil }))
        }
        return HerdrAppSnapshot(terminals: terminals)
    }

    public func terminal(_ address: String) -> HerdrAppTerminal? {
        terminals.first { $0.address == address }
    }

    /// ADR 0013's inventory: each terminal as a one-pane tab, its address the handle.
    public var inventory: TerminalHostInventory {
        .tabs(terminals.map { TerminalTab(tabID: $0.address, tty: $0.tty, title: $0.title, paneCount: 1) })
    }

    /// The ttys whose `ps -t` reads ADR 0013's rules need: terminals showing one of `codexTitles`, and
    /// terminals on one of `claudeTTYs`. Other terminals are never read.
    public func ttysToRead(codexTitles: Set<String>, claudeTTYs: Set<String>) -> Set<String> {
        let claude = Set(claudeTTYs.compactMap(GhosttyTTYMatch.normalizedTTY))
        return Set(terminals.compactMap { terminal in
            guard let tty = terminal.tty else { return nil }
            return claude.contains(tty) || terminal.title.map(codexTitles.contains) == true ? tty : nil
        })
    }

    /// As above for every terminal titled with any shortened Codex identifier, when Herdr is read beside
    /// another host that does not know which sessions are live.
    public func ttysToRead(claudeTTYs: Set<String>) -> Set<String> {
        ttysToRead(codexTitles: Set(terminals.compactMap(\.title).filter(HerdrBindingRules.isShortenedCodexSessionTitle)),
                   claudeTTYs: claudeTTYs)
    }
}

/// What Herdr's window shows: which pane shows which terminal, and the shown space, tab and focused pane.
public struct HerdrAppWindow: Equatable, Sendable {
    public struct Pane: Equatable, Sendable {
        public let terminal: String
        public let spaceID: String
        public let tabID: String

        public init(terminal: String, spaceID: String, tabID: String) {
            self.terminal = terminal
            self.spaceID = spaceID
            self.tabID = tabID
        }
    }

    public static let maximumReplySize = 2 * 1024 * 1024
    public static let maximumPanes = 1024

    /// Each pane id to the terminal it shows.
    public let panes: [String: Pane]
    public let shownSpaceID: String?
    public let shownTabID: String?
    public let focusedPaneID: String?

    public init(panes: [String: Pane], shownSpaceID: String?, shownTabID: String?, focusedPaneID: String?) {
        self.panes = panes
        self.shownSpaceID = shownSpaceID
        self.shownTabID = shownTabID
        self.focusedPaneID = focusedPaneID
    }

    /// `Herdr ls` and `Herdr status`; nil when either is oversized or malformed.
    public static func parse(ls: Data, status: Data) -> HerdrAppWindow? {
        guard ls.count <= maximumReplySize, status.count <= 64 * 1024,
              let list = try? JSONSerialization.jsonObject(with: ls) as? [String: Any],
              let state = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
              let spaces = list["spaces"] as? [Any] else { return nil }
        var panes: [String: Pane] = [:]
        for case let space as [String: Any] in spaces {
            guard let spaceID = space["id"] as? String, HerdrAppJSON.isID(spaceID, prefix: "sp"),
                  let tabs = space["tabs"] as? [Any] else { return nil }
            for case let tab as [String: Any] in tabs {
                guard let tabID = tab["id"] as? String, HerdrAppJSON.isID(tabID, prefix: "tb"),
                      let rows = tab["terminals"] as? [Any] else { return nil }
                for case let row as [String: Any] in rows {
                    // A terminal without a pane (a parked sub-agent) shows nowhere.
                    guard let paneID = row["pane"] as? String else {
                        guard row["pane"] == nil || row["pane"] is NSNull else { return nil }
                        continue
                    }
                    guard HerdrAppJSON.isID(paneID, prefix: "p"), let terminal = row["terminal"] as? String,
                          !terminal.isEmpty, terminal.count <= HerdrAppSnapshot.maximumIDLength,
                          panes[paneID] == nil, panes.count < maximumPanes else { return nil }
                    panes[paneID] = Pane(terminal: terminal, spaceID: spaceID, tabID: tabID)
                }
                guard rows.allSatisfy({ $0 is [String: Any] }) else { return nil }
            }
            guard tabs.allSatisfy({ $0 is [String: Any] }) else { return nil }
        }
        guard spaces.allSatisfy({ $0 is [String: Any] }),
              let space = HerdrAppJSON.optionalID(state["space"], prefix: "sp"),
              let tab = HerdrAppJSON.optionalID(state["tab"], prefix: "tb"),
              let focused = HerdrAppJSON.optionalID(state["focused_pane"], prefix: "p") else { return nil }
        return HerdrAppWindow(panes: panes, shownSpaceID: space, shownTabID: tab, focusedPaneID: focused)
    }

    /// The terminal the window shows with focus: the focused pane's, when it is in the shown space and tab.
    public var shownTerminal: String? {
        guard let paneID = focusedPaneID, let pane = panes[paneID], pane.spaceID == shownSpaceID,
              pane.tabID == shownTabID else { return nil }
        return pane.terminal
    }
}

enum HerdrAppJSON {
    /// A Herdr id such as `t1`, `pcb50…` or `sp8c42…`: the expected prefix, then ASCII letters and digits, bounded.
    static func isID(_ text: String, prefix: String) -> Bool {
        text.hasPrefix(prefix) && text.count > prefix.count && text.count <= HerdrAppSnapshot.maximumIDLength
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `.some(nil)` for null, the id when valid, nil (malformed) for anything else.
    static func optionalID(_ value: Any?, prefix: String) -> String?? {
        switch value {
        case nil, is NSNull: return .some(nil)
        case let text as String where isID(text, prefix: prefix): return .some(text)
        default: return nil
        }
    }
}

// MARK: - Wire

/// herdr-core's JSON-RPC 2.0: one request line, one reply line with the same id.
public enum HerdrAppRPC {
    public enum Envelope {
        case result([String: Any])
        /// The core's stable `data.kind`, such as `not_found` or `blocked`.
        case error(kind: String?)
    }

    public static func requestLine(id: String, method: String, params: [String: Any]) -> Data? {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }

    /// The reply to `id`, nil when it is not one well-formed reply to that request.
    public static func envelope(_ line: Data, id: String) -> Envelope? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["id"] as? String == id else { return nil }
        if let error = object["error"] as? [String: Any] {
            let kind = (error["data"] as? [String: Any])?["kind"] as? String
            return .error(kind: kind.map { String($0.prefix(64)) })
        }
        guard let result = object["result"] as? [String: Any] else { return nil }
        return .result(result)
    }
}

/// Why Herdr, running, could not be read. Every reason leaves every session it could hold unavailable
/// (ADR 0013 "Inventory"); none is an empty Herdr.
public enum HerdrAppUnreadable: Error, Equatable, Hashable, Sendable {
    /// No Herdr.app in /Applications or ~/Applications, so its command line can't be run.
    case appNotFound
    /// A socket is not a Unix socket owned by this user, or others may write to it or its folder.
    case socketUntrusted
    /// The core or the app's command line reported an error.
    case commandFailed
    case timedOut
    /// A reply could not be decoded within bounds.
    case malformedReply
}

/// How one exchange on the core's socket ended, from HerdlyApp's side.
public enum HerdrAppExchange: Equatable, Sendable {
    /// The reply line (without its newline).
    case reply(Data)
    /// No core socket, or nothing accepted the connection: no core runs, and nothing was written.
    case notRunning
    /// Nothing was written: the socket failed its trust check.
    case notSent(HerdrAppUnreadable)
    /// The request may have been written, then the exchange failed.
    case failed(HerdrAppUnreadable)
}

/// How one run of the app's command line (`Herdr ls`, `status`, `do`) ended.
public enum HerdrAppCommandResult: Equatable, Sendable {
    case exited(status: Int32, stdout: Data, stderr: String)
    /// Nothing ran: Herdr.app is not installed, its window's socket is missing, or untrusted.
    case notRun(HerdrAppCommandSkip)
    case timedOut
}

public enum HerdrAppCommandSkip: Equatable, Sendable {
    case appNotFound
    /// No window socket: the window isn't open (its terminals still run in the core).
    case noWindow
    case socketUntrusted
}

/// Fixed paths, requests and command lines. The app's command line runs only from Herdr.app's own
/// executable in /Applications or ~/Applications, never from `PATH`, always with arguments (alone, it opens
/// the window), and only while the window's socket exists; the core is reached only on its own socket.
public enum HerdrAppCLI {
    public static let bundleIdentifier = "dev.herdr.app"
    /// herdr-core's app bundle (`~/.local/share/herdr-core/active/Herdr Core.app`): a process walk from a
    /// Herdr terminal reaches its holder process, which runs every terminal (ADR 0015).
    public static let coreBundleIdentifier = "dev.herdr.core"
    /// Seconds a read or a focus may take.
    public static let timeout: Double = 3
    /// Seconds a reply's `terminal.send` may take: the core waits for about three seconds of quiet first.
    public static let sendTimeout: Double = 10
    public static let outputLimit = HerdrAppWindow.maximumReplySize

    public static func appBinaryCandidates(home: String) -> [String] {
        ["/Applications/Herdr.app/Contents/MacOS/Herdr", "\(home)/Applications/Herdr.app/Contents/MacOS/Herdr"]
    }

    /// The default core session's socket (`HC_SESSION` unset). Named sessions are not read.
    public static func coreSocketPath(home: String) -> String {
        "\(home)/.local/state/herdr-core/default/default.sock"
    }

    /// The open window's socket (`HERDR_APP_HOME` unset).
    public static func appSocketPath(home: String) -> String {
        "\(home)/.config/herdr-app/herdr-app.sock"
    }

    public static func environment(home: String) -> [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    public static let listMethod = "terminal.list"
    public static let statusMethod = "server.status"
    public static let ls = ["ls"]
    public static let status = ["status"]

    /// ADR 0016's select step: show the terminal's space and tab and focus its pane.
    public static func focus(_ terminal: HerdrAppTerminal) -> [String] {
        ["do", "agent.focus", json(["terminal": terminal.address])]
    }

    /// The core's `version` from `server.status`; nil for anything else.
    public static func version(_ line: Data, id: String) -> String? {
        guard line.count <= 64 * 1024, case .result(let result)? = HerdrAppRPC.envelope(line, id: id),
              let version = result["version"] as? String, !version.isEmpty, version.count <= 64,
              version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._+".contains($0)) }) else { return nil }
        return version
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum HerdrAppSocketState: Equatable, Sendable {
    case trusted
    case missing
    case untrusted
}

public enum HerdrAppSocket {
    /// The trust check, from `lstat` of the socket (never followed through a symlink) and of its folder: a
    /// Unix socket owned by this user that no one else may write to (connecting needs write permission), in a
    /// folder owned by this user that no one else may change. herdr-core and Herdr.app create their sockets
    /// `0755`, so the owner-only `0600` check Rex and WezTerm use would refuse them. A missing socket is a
    /// core or window that isn't running, not a problem.
    public static func trust(exists: Bool, isSocket: Bool, owner: uid_t, mode: mode_t, folderOwner: uid_t,
                             folderMode: mode_t, me: uid_t) -> HerdrAppSocketState {
        guard exists else { return .missing }
        guard isSocket, owner == me, mode & 0o022 == 0, folderOwner == me, folderMode & 0o022 == 0 else { return .untrusted }
        return .trusted
    }

    public static func trust(at path: String) -> HerdrAppSocketState {
        var info = stat(), folder = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        guard lstat((path as NSString).deletingLastPathComponent, &folder) == 0 else { return .untrusted }
        return trust(exists: true, isSocket: (info.st_mode & S_IFMT) == S_IFSOCK, owner: info.st_uid,
                     mode: info.st_mode & 0o777, folderOwner: folder.st_uid,
                     folderMode: (folder.st_mode & S_IFMT) == S_IFDIR ? folder.st_mode & 0o777 : 0o777, me: getuid())
    }
}

/// One core inventory read.
public enum HerdrAppRead: Equatable, Sendable {
    /// No core: Herdr holds nothing.
    case notRunning
    case snapshot(HerdrAppSnapshot)
    case unreadable(HerdrAppUnreadable)

    /// The read from one `terminal.list` exchange sent as `id`.
    public static func inventory(_ exchange: HerdrAppExchange, id: String, tty: (Int32) -> String?) -> HerdrAppRead {
        switch exchange {
        case .notRunning: return .notRunning
        case .notSent(let reason), .failed(let reason): return .unreadable(reason)
        case .reply(let line):
            if case .error? = HerdrAppRPC.envelope(line, id: id) { return .unreadable(.commandFailed) }
            return HerdrAppSnapshot.parse(line, id: id, tty: tty).map(HerdrAppRead.snapshot) ?? .unreadable(.malformedReply)
        }
    }

    public var inventory: TerminalHostInventory {
        switch self {
        case .notRunning: .notRunning
        case .snapshot(let value): value.inventory
        case .unreadable: .unreadable
        }
    }

    public var snapshot: HerdrAppSnapshot? {
        if case .snapshot(let value) = self { return value }
        return nil
    }
}

/// One window read: `Herdr ls` then `Herdr status`.
public enum HerdrAppWindowRead: Equatable, Sendable {
    /// The window isn't open: it shows nothing.
    case closed
    case window(HerdrAppWindow)
    case unreadable

    public static func from(ls: HerdrAppCommandResult, status: HerdrAppCommandResult) -> HerdrAppWindowRead {
        if case .notRun(.noWindow) = ls { return .closed }
        guard case .exited(0, let list, _) = ls, case .exited(0, let state, _) = status,
              let window = HerdrAppWindow.parse(ls: list, status: state) else { return .unreadable }
        return .window(window)
    }

    public var window: HerdrAppWindow? {
        if case .window(let value) = self { return value }
        return nil
    }
}

// MARK: - Visible and Open (ADR 0015, ADR 0016)

extension TerminalVisibility {
    /// Herdr's visible test (ADR 0016): macOS reports Herdr frontmost, and the window's focused pane in its
    /// shown space and tab shows a terminal the core lists. An unreadable window or core is unknown.
    public static func herdrApp(_ snapshot: HerdrAppSnapshot?, window: HerdrAppWindowRead,
                                frontmost: TerminalHost?) -> TerminalVisibilityReading<String> {
        guard frontmost == .herdrApp else { return .nothing }
        switch window {
        case .closed: return .nothing
        case .unreadable: return .unknown
        case .window(let value):
            guard let snapshot else { return .unknown }
            guard let shown = value.shownTerminal, snapshot.terminal(shown) != nil else { return .nothing }
            return .visible(shown)
        }
    }
}

/// What a revalidated Herdr Open holds to: the bound terminal and, for Codex, the title that must still show.
public struct HerdrAppOpenPlan: Equatable, Sendable {
    public let target: TerminalTabTarget
    public let terminal: HerdrAppTerminal
    public let title: String?

    public init(target: TerminalTabTarget, terminal: HerdrAppTerminal, title: String?) {
        self.target = target
        self.terminal = terminal
        self.title = title
    }
}

public enum HerdrAppOpen {
    /// Step 1's outcome from a fresh route and a fresh inventory. A binding to another host, or Ghostty's
    /// title route, is not Herdr's to select and falls back.
    public static func plan(_ route: TerminalTabOpenRoute, codexTitle: String?,
                            snapshot: HerdrAppSnapshot) -> Result<HerdrAppOpenPlan, OpenMiss> {
        let target: TerminalTabTarget
        switch route {
        case .exact(let value) where value.host == .herdrApp: target = value
        case .exact, .ghosttyTitle: return .failure(.fallBack(.noUniqueTarget, candidates: 1))
        case .miss(let miss): return .failure(miss)
        }
        guard let terminal = snapshot.terminal(target.tabID) else { return .failure(.unavailable(.sessionEnded)) }
        return .success(HerdrAppOpenPlan(target: target, terminal: terminal, title: codexTitle))
    }

    /// Step 3's `agent.focus`, sent once: exit 0 passed; Herdr reporting no running terminal is an ended
    /// session; Herdr.app missing or an untrusted socket is an unreadable host; a closed window or any other
    /// error falls back (ADR 0015 then raises Herdr, if it runs).
    public static func focused(_ result: HerdrAppCommandResult) -> OpenMiss? {
        switch result {
        case .exited(0, _, _): return nil
        case .exited(_, let stdout, let stderr) where reportsNoTerminal(stdout: stdout, stderr: stderr):
            return .unavailable(.sessionEnded)
        case .notRun(.appNotFound), .notRun(.socketUntrusted): return .unavailable(.hostUnreadable(.herdrApp))
        case .notRun(.noWindow), .exited, .timedOut: return .fallBack(.notVerified, candidates: 1)
        }
    }

    /// Herdr's `{"error": "no running terminal \"t9\""}`, on stdout or stderr.
    static func reportsNoTerminal(stdout: Data, stderr: String) -> Bool {
        String(decoding: stdout.prefix(4096), as: UTF8.self).contains("no running terminal")
            || stderr.contains("no running terminal")
    }

    /// Step 4 over a fresh inventory, a fresh window read and the frontmost app macOS reported after them:
    /// Herdr is frontmost, the terminal is still on the same tty, for Codex it still carries its title, and the
    /// window shows it with focus. Herdr is already active, so any miss falls back, adding nothing.
    public static func verify(_ plan: HerdrAppOpenPlan, after: HerdrAppSnapshot?, window: HerdrAppWindow?,
                              frontmost: TerminalHost?) -> OpenMiss? {
        guard frontmost == .herdrApp, let after, let terminal = after.terminal(plan.terminal.address),
              terminal.tty == plan.target.tty, plan.title == nil || terminal.title == plan.title,
              window?.shownTerminal == plan.terminal.address else {
            return .fallBack(.notVerified, candidates: 1)
        }
        return nil
    }

    /// ADR 0016's sequence for a Herdr terminal: revalidate on fresh reads; ask the window to show and focus
    /// the terminal once, then activate Herdr (`raise` does both, returning the focus result); then verify on
    /// fresh reads.
    public static func run(now: @escaping () -> Double,
                           revalidate: @escaping (Double) async -> Result<HerdrAppOpenPlan, OpenMiss>,
                           raise: @escaping (HerdrAppOpenPlan) async -> HerdrAppCommandResult,
                           verifyRead: @escaping () async -> (HerdrAppSnapshot?, HerdrAppWindow?, TerminalHost?),
                           isolation: isolated (any Actor)? = #isolation) async -> TerminalOpenRun<HerdrAppOpenPlan, OpenMiss> {
        await TerminalOpenSequence.run(TerminalOpenSteps<HerdrAppOpenPlan, OpenMiss>(
            now: now,
            revalidate: revalidate,
            raise: { plan in focused(await raise(plan)) },
            verify: { plan in
                let (after, window, frontmost) = await verifyRead()
                return verify(plan, after: after, window: window, frontmost: frontmost)
            }))
    }
}

// MARK: - Presentation

/// The latest Herdr read's outcome, for the Settings card.
public enum HerdrAppScanStatus: Equatable, Sendable {
    case notRead
    case read
    case notRunning
    case unreadable(HerdrAppUnreadable)
}

/// One Herdr problem line; each is a separate fix (product.md, "Problem lines").
public enum HerdrAppSettingsProblem: Equatable, Hashable, Sendable {
    /// No Herdr.app in /Applications or ~/Applications.
    case notFound
    /// A socket fails the trust check.
    case untrustedSocket
    /// Any other failed read. The exact reason goes to diagnostics only.
    case unreadable

    public var message: String {
        switch self {
        case .notFound: "Herdly can't find Herdr in /Applications or ~/Applications."
        case .untrustedSocket: "Herdly can't read Herdr: its socket isn't private to you."
        case .unreadable: OpenUnavailableReason.hostUnreadable(.herdrApp).cardLine
        }
    }
}

public struct HerdrAppSettingsRow: Equatable, Sendable {
    public let badge: HerdrReadinessBadge
    public let problems: [HerdrAppSettingsProblem]

    public init(badge: HerdrReadinessBadge, problems: [HerdrAppSettingsProblem]) {
        self.badge = badge
        self.problems = problems
    }
}

public enum HerdrAppPresentation {
    public static let howOpenWorks =
        "Herdly returns to the exact pane in the Herdr app, splits included: Herdr shows the pane's space and tab and focuses it; otherwise Open raises Herdr. Herdr's window must be open to show a session. Replies are pasted into the exact pane."

    public static func settingsRow(on: Bool, installed: Bool, scan: HerdrAppScanStatus, inUse: Bool) -> HerdrAppSettingsRow {
        guard on else { return HerdrAppSettingsRow(badge: .off, problems: []) }
        var problems: [HerdrAppSettingsProblem] = []
        if !installed { problems.append(.notFound) }
        if case .unreadable(let reason) = scan {
            switch reason {
            case .appNotFound: if installed { problems.append(.notFound) }
            case .socketUntrusted: problems.append(.untrustedSocket)
            case .commandFailed, .timedOut, .malformedReply: problems.append(.unreadable)
            }
        }
        let badge: HerdrReadinessBadge = !problems.isEmpty ? .needsAttention : inUse ? .ready : .notInUse
        return HerdrAppSettingsRow(badge: badge, problems: problems)
    }
}

// MARK: - Typed input (ADR 0017)

/// Herdr's send: herdr-core's `terminal.send`, which pastes the text into that terminal alone and then presses
/// Enter itself after a pause, for Claude and Codex alike (`TypedReplyWrites.plan` gives Herdr one write). It
/// waits for about three seconds of quiet, and for a person's unsent draft in that terminal up to 60 s, and it
/// refuses a program that reports `blocked`, so it never answers a permission dialog.
public enum HerdrAppInput {
    /// Whether Herdr may carry a Codex question's digit. ADR 0017 keeps a host's question route off until a
    /// live run shows the digit alone commits there; Herdr has had no such run. Off, a Codex question in
    /// Herdr shows "Answer this in Codex."
    public static let questionDigitsProvenLive = false

    /// The core request for one write: the text, which the core submits; nil for a submit alone, which Herdr's
    /// plan never holds.
    public static func send(_ write: TypedWrite, terminal: String) -> (method: String, params: [String: Any])? {
        switch write {
        case .text(let text), .textAndSubmit(let text): ("terminal.send", ["terminal": terminal, "text": text])
        case .submit: nil
        }
    }

    /// The core request for one question digit: one named key, never Enter.
    public static func key(_ key: String, terminal: String) -> (method: String, params: [String: Any]) {
        ("terminal.keys", ["terminal": terminal, "keys": [key]])
    }

    /// The core's error kinds that refuse before typing anything.
    static let refusedKinds: Set<String> = ["not_found", "blocked", "finished", "status_mismatch", "needs_target"]

    /// The delivery of one send exchanged as `id`. Nothing written, or the core refused before typing: not
    /// written. A result: written. Anything else, a timeout or an unreadable reply included, may have typed and
    /// counts as sent.
    public static func delivery(_ exchange: HerdrAppExchange, id: String) -> TypedInputDelivery {
        switch exchange {
        case .notRunning, .notSent: return .notWritten
        case .failed: return .possiblyWritten
        case .reply(let line):
            switch HerdrAppRPC.envelope(line, id: id) {
            case .result?: return .written
            case .error(let kind)? where kind.map(refusedKinds.contains) == true: return .notWritten
            case .error?, nil: return .possiblyWritten
            }
        }
    }
}
