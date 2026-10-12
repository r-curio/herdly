import Foundation

// WezTerm (#240), from the live proof (docs/evidence/wezterm-live.md): `wezterm cli list --format json`
// gives every pane's integer `window_id`, `tab_id` and `pane_id`, its `tty_name` and its `title`; a split
// is two panes sharing a `tab_id`. `list-clients` gives each client's `focused_pane_id`, which follows
// only the focused window and keeps its last value while another app is in front. `activate-pane`
// reaches a pane only in the focused window, and `send-text --no-paste --pane-id` types into that pane
// alone. Everything here is a pure function of what SteerApp's `wezterm` runs return, `ps -t` reads and
// the frontmost app macOS reports; running the binary, finding its socket and activating WezTerm belong
// to SteerApp.

/// One WezTerm pane. Its `paneID` stands for its tab in ADR 0013's inventory, and `tabID` groups the
/// panes of one tab so a split is visible.
public struct WezTermPane: Equatable, Sendable {
    public let paneID: Int
    public let tabID: Int
    public let windowID: Int
    /// `/dev/ttysNNN`; nil when WezTerm reported none.
    public let tty: String?
    /// The pane's `title`: an OSC 1 icon title wins over a later OSC 2 title (live proof), so Steer's
    /// Claude title can be hidden. Claude binds by tty alone, so that hides nothing Steer needs.
    public let title: String?
}

/// One complete `wezterm cli list` reply.
public struct WezTermSnapshot: Equatable, Sendable {
    /// Largest reply accepted, in bytes.
    public static let maximumReplySize = 2 * 1024 * 1024
    /// Most panes accepted; a larger inventory is malformed rather than truncated.
    public static let maximumPanes = 1024
    /// Longest title kept; a longer one cannot be a title Steer compares and is dropped.
    public static let maximumTitleLength = 1024

    public let panes: [WezTermPane]

    /// The reply in `data`, or nil when it is oversized or malformed in any part: a partial inventory
    /// could hide the pane a session is on, so it never stands for a complete one.
    public static func parse(_ data: Data) -> WezTermSnapshot? {
        guard data.count <= maximumReplySize,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [Any],
              rows.count <= maximumPanes else { return nil }
        var panes: [WezTermPane] = []
        var ids: Set<Int> = []
        for case let row as [String: Any] in rows {
            guard let pane = WezTermJSON.identifier(row["pane_id"]), ids.insert(pane).inserted,
                  let tab = WezTermJSON.identifier(row["tab_id"]),
                  let window = WezTermJSON.identifier(row["window_id"]) else { return nil }
            let tty: String?
            switch row["tty_name"] {
            case nil, is NSNull: tty = nil
            case let value as String where value.isEmpty: tty = nil
            case let value as String:
                guard let normalized = GhosttyTTYMatch.normalizedTTY(value) else { return nil }
                tty = normalized
            default: return nil
            }
            let title: String?
            switch row["title"] {
            case nil, is NSNull: title = nil
            case let value as String: title = value.isEmpty || value.count > maximumTitleLength ? nil : value
            default: return nil
            }
            panes.append(WezTermPane(paneID: pane, tabID: tab, windowID: window, tty: tty, title: title))
        }
        guard panes.count == rows.count else { return nil }
        return WezTermSnapshot(panes: panes)
    }

    public func pane(_ id: Int) -> WezTermPane? {
        panes.first { $0.paneID == id }
    }

    /// How many panes share `tabID`.
    public func paneCount(inTab tabID: Int) -> Int {
        panes.filter { $0.tabID == tabID }.count
    }

    /// ADR 0013's inventory: each pane as a tab, with its pane id as the handle and its tab's pane count.
    public var inventory: TerminalHostInventory {
        .tabs(panes.map { TerminalTab(tabID: String($0.paneID), tty: $0.tty, title: $0.title,
                                      paneCount: paneCount(inTab: $0.tabID)) })
    }

    /// The ttys whose `ps -t` reads ADR 0013's rules need: panes showing one of `codexTitles` (live Codex
    /// sessions' shortened identifiers), and panes on one of `claudeTTYs`. Other panes are never read.
    public func ttysToRead(codexTitles: Set<String>, claudeTTYs: Set<String>) -> Set<String> {
        let claude = Set(claudeTTYs.compactMap(GhosttyTTYMatch.normalizedTTY))
        return Set(panes.compactMap { pane in
            guard let tty = pane.tty else { return nil }
            return claude.contains(tty) || pane.title.map(codexTitles.contains) == true ? tty : nil
        })
    }

    /// As above for every pane titled with any shortened Codex identifier, when WezTerm is read beside
    /// another host that does not know which sessions are live.
    public func ttysToRead(claudeTTYs: Set<String>) -> Set<String> {
        ttysToRead(codexTitles: Set(panes.compactMap(\.title).filter(HerdrBindingRules.isShortenedCodexSessionTitle)),
                   claudeTTYs: claudeTTYs)
    }
}

/// One `wezterm cli list-clients` reply.
public struct WezTermClients: Equatable, Sendable {
    public static let maximumReplySize = 256 * 1024
    public static let maximumClients = 64

    /// Each client's `focused_pane_id`, nil when it reports none.
    public let focusedPaneIDs: [Int?]

    public init(focusedPaneIDs: [Int?]) {
        self.focusedPaneIDs = focusedPaneIDs
    }

    /// The reply in `data`, or nil when it is oversized or malformed in any part.
    public static func parse(_ data: Data) -> WezTermClients? {
        guard data.count <= maximumReplySize,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [Any],
              rows.count <= maximumClients else { return nil }
        var focused: [Int?] = []
        for row in rows {
            guard let client = row as? [String: Any] else { return nil }
            switch client["focused_pane_id"] {
            case nil, is NSNull: focused.append(nil)
            case let value:
                guard let pane = WezTermJSON.identifier(value) else { return nil }
                focused.append(pane)
            }
        }
        return WezTermClients(focusedPaneIDs: focused)
    }

    /// The focused pane of the one client; nil when zero or several clients are attached, or it
    /// reports none. With several clients Steer cannot tell which one the user is looking at.
    public var focusedPane: Int? {
        focusedPaneIDs.count == 1 ? focusedPaneIDs[0] : nil
    }
}

// MARK: - Binary, socket and reads

/// Why WezTerm, running, could not be read. Every reason leaves every session it could hold unavailable
/// (ADR 0013 "Inventory"); none is an empty WezTerm.
public enum WezTermUnreadable: Error, Equatable, Hashable, Sendable {
    /// No `wezterm` binary in its fixed locations (`WezTermCLI.binaryCandidates`).
    case binaryNotFound
    /// No GUI socket belonging to the running WezTerm.
    case socketMissing
    /// The socket is not a Unix socket owned by this user with no group or other permission bits.
    case socketUntrusted
    /// Several running WezTerm instances each have a socket: Steer cannot rule either out.
    case severalInstances
    /// `wezterm cli` exited with an error.
    case commandFailed
    case timedOut
    /// The reply could not be decoded within bounds.
    case malformedReply
}

/// How one `wezterm cli` run ended, from SteerApp's side.
public enum WezTermCommandResult: Equatable, Sendable {
    /// The binary ran and exited; stdout and stderr are bounded.
    case exited(status: Int32, stdout: Data, stderr: String)
    /// Nothing ran: the binary or a trusted socket was not found. Nothing reached WezTerm.
    case notRun(WezTermUnreadable)
    /// The run passed its deadline and was terminated; what it did is unknown.
    case timedOut
}

/// The fixed command lines and environment Steer runs `wezterm` with. The binary resolves only from
/// fixed locations, never from `PATH`, and talks only to the socket Steer checked: the environment
/// carries no inherited `WEZTERM_UNIX_SOCKET` or other variable.
public enum WezTermCLI {
    /// Seconds one run may take.
    public static let timeout: Double = 3
    /// Largest stdout accepted, in bytes.
    public static let outputLimit = WezTermSnapshot.maximumReplySize

    public static func binaryCandidates(home: String) -> [String] {
        ["/Applications/WezTerm.app/Contents/MacOS/wezterm", "\(home)/Applications/WezTerm.app/Contents/MacOS/wezterm"]
    }

    /// Where WezTerm's GUI puts `gui-sock-<pid>` on macOS (the live proof's `WEZTERM_UNIX_SOCKET`).
    public static func socketDirectory(home: String) -> String {
        "\(home)/.local/share/wezterm"
    }

    public static func environment(home: String, socket: String) -> [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "WEZTERM_UNIX_SOCKET": socket]
    }

    public static let list = ["cli", "--no-auto-start", "list", "--format", "json"]
    public static let listClients = ["cli", "--no-auto-start", "list-clients", "--format", "json"]

    /// ADR 0016's select step; nil for a handle that is not a pane id.
    public static func activate(pane: String) -> [String]? {
        paneID(pane).map { ["cli", "--no-auto-start", "activate-pane", "--pane-id", String($0)] }
    }

    /// A pane id as WezTerm prints it: decimal digits only.
    static func paneID(_ handle: String) -> Int? {
        guard !handle.isEmpty, handle.count <= 9, handle.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(handle)
    }
}

/// One `gui-sock-<pid>` entry in the socket directory, and whether `<pid>` is a running WezTerm
/// process (by its app bundle, read by SteerApp). A socket left by an instance that exited is stale.
public struct WezTermSocketCandidate: Equatable, Sendable {
    public let name: String
    public let runsWezTerm: Bool

    public init(name: String, runsWezTerm: Bool) {
        self.name = name
        self.runsWezTerm = runsWezTerm
    }

    /// The pid in a `gui-sock-<pid>` name; nil for any other name.
    public static func pid(fromName name: String) -> Int32? {
        let prefix = "gui-sock-"
        guard name.hasPrefix(prefix) else { return nil }
        let digits = name.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int32(digits)
    }
}

public enum WezTermSocket {
    /// The one live GUI socket among `candidates`. Several instances cannot be told apart, so they are
    /// unreadable rather than a guess.
    public static func choose(_ candidates: [WezTermSocketCandidate]) -> Result<String, WezTermUnreadable> {
        let live = candidates.filter { WezTermSocketCandidate.pid(fromName: $0.name) != nil && $0.runsWezTerm }
        guard let first = live.first else { return .failure(.socketMissing) }
        return live.count == 1 ? .success(first.name) : .failure(.severalInstances)
    }

    /// The trust check, from `lstat` of the socket path (never followed through a symlink): a Unix
    /// socket owned by this user with no group or other permission bits.
    public static func trust(exists: Bool, isSocket: Bool, owner: uid_t, mode: mode_t, me: uid_t) -> WezTermUnreadable? {
        switch AppServerSocketCheck.problem(exists: exists, isSocket: isSocket, owner: owner, mode: mode, me: me) {
        case nil: nil
        case .missing?: .socketMissing
        case .notASocket?, .notOwnedByUser?, .sharedPermissions?: .socketUntrusted
        }
    }

    /// The trust check on the file at `path`. Read-only.
    public static func trust(at path: String) -> WezTermUnreadable? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .socketMissing }
        return trust(exists: true, isSocket: (info.st_mode & S_IFMT) == S_IFSOCK, owner: info.st_uid,
                     mode: info.st_mode & 0o777, me: getuid())
    }
}

/// One WezTerm inventory read.
public enum WezTermRead: Equatable, Sendable {
    /// WezTerm is not running; it holds nothing.
    case notRunning
    case snapshot(WezTermSnapshot)
    /// Running, but it could not be read.
    case unreadable(WezTermUnreadable)

    /// The read from one `list` run.
    public static func list(_ result: WezTermCommandResult) -> WezTermRead {
        switch result {
        case .notRun(let reason): return .unreadable(reason)
        case .timedOut: return .unreadable(.timedOut)
        case .exited(let status, let stdout, _):
            guard status == 0 else { return .unreadable(.commandFailed) }
            return WezTermSnapshot.parse(stdout).map(WezTermRead.snapshot) ?? .unreadable(.malformedReply)
        }
    }

    public var inventory: TerminalHostInventory {
        switch self {
        case .notRunning: .notRunning
        case .snapshot(let value): value.inventory
        case .unreadable: .unreadable
        }
    }

    public var snapshot: WezTermSnapshot? {
        if case .snapshot(let value) = self { return value }
        return nil
    }
}

// MARK: - Visible and Open (ADR 0015, ADR 0016)

extension TerminalVisibility {
    /// WezTerm's visible test (ADR 0016): macOS reports WezTerm frontmost, and the one client's
    /// `focused_pane_id` is the pane returned, by pane id. Whether that pane is a session's bound target on
    /// the same inventory is the caller's comparison. `focused_pane_id` keeps its last value while another
    /// app is in front, so it is never enough alone. A failed read, or several clients (Steer cannot tell
    /// which one the user is looking at), is unknown.
    public static func wezTerm(_ snapshot: WezTermSnapshot?, clients: WezTermClients?,
                               frontmost: TerminalHost?) -> TerminalVisibilityReading<String> {
        guard frontmost == .wezTerm else { return .nothing }
        guard let snapshot, let clients, clients.focusedPaneIDs.count == 1 else { return .unknown }
        guard let focused = clients.focusedPane, snapshot.pane(focused) != nil else { return .nothing }
        return .visible(String(focused))
    }
}

/// What a revalidated WezTerm Open holds to: the bound pane and, for Codex, the title that must still show
/// (ADR 0013 voids a Codex binding when its title changes; a Claude rename voids nothing).
public struct WezTermOpenPlan: Equatable, Sendable {
    public let target: TerminalTabTarget
    public let title: String?

    public init(target: TerminalTabTarget, title: String?) {
        self.target = target
        self.title = title
    }
}

public enum WezTermOpen {
    /// Step 1's outcome from a fresh route and fresh `list` and `list-clients` reads. Only a pane in the
    /// window of the one client's `focused_pane_id` is planned: `activate-pane` cannot raise another
    /// window, and Steer could not read back which tab it shows, so a target there falls back (ADR 0016,
    /// "WezTerm"). Several or no clients name no front window and fall back too. A binding to another
    /// host, or Ghostty's title route, is not WezTerm's to select and falls back.
    public static func plan(_ route: TerminalTabOpenRoute, codexTitle: String?, snapshot: WezTermSnapshot,
                            clients: WezTermClients?) -> Result<WezTermOpenPlan, OpenMiss> {
        let target: TerminalTabTarget
        switch route {
        case .exact(let value) where value.host == .wezTerm: target = value
        case .exact, .ghosttyTitle: return .failure(.fallBack(.noUniqueTarget, candidates: 1))
        case .miss(let miss): return .failure(miss)
        }
        guard let id = WezTermCLI.paneID(target.tabID), let pane = snapshot.pane(id) else {
            return .failure(.unavailable(.sessionEnded))
        }
        guard let clients else { return .failure(.unavailable(.hostUnreadable(.wezTerm))) }
        guard let focused = clients.focusedPane.flatMap(snapshot.pane), focused.windowID == pane.windowID else {
            return .failure(.fallBack(.unsupportedLayout, candidates: 1))
        }
        return .success(WezTermOpenPlan(target: target, title: codexTitle))
    }

    /// Step 3's `activate-pane`, sent once (ADR 0016, "Failures"): an untrusted or missing socket is an
    /// unreadable host; "no such pane" is an ended session; any other error falls back.
    public static func activated(_ result: WezTermCommandResult) -> OpenMiss? {
        switch result {
        case .notRun: return .unavailable(.hostUnreadable(.wezTerm))
        case .exited(0, _, _): return nil
        case .exited(_, _, let stderr) where WezTermInput.reportsNoSuchPane(stderr): return .unavailable(.sessionEnded)
        case .exited, .timedOut: return .fallBack(.notVerified, candidates: 1)
        }
    }

    /// Step 4 over fresh reads and the frontmost app macOS reported after them: the pane is visible
    /// (`TerminalVisibility.wezTerm`), still alone in its tab on the same tty, and for Codex still carries
    /// its title. WezTerm is already active, so any miss falls back, adding nothing.
    public static func verify(_ plan: WezTermOpenPlan, after: WezTermSnapshot?, clients: WezTermClients?,
                              frontmost: TerminalHost?) -> OpenMiss? {
        guard TerminalVisibility.wezTerm(after, clients: clients, frontmost: frontmost) == .visible(plan.target.tabID),
              let id = WezTermCLI.paneID(plan.target.tabID), let pane = after?.pane(id), pane.tty == plan.target.tty,
              after?.paneCount(inTab: pane.tabID) == 1, plan.title == nil || pane.title == plan.title else {
            return .fallBack(.notVerified, candidates: 1)
        }
        return nil
    }

    /// ADR 0016's sequence for a WezTerm pane: revalidate on fresh reads, `activate-pane` once and then
    /// activate WezTerm (`activate` does both), then verify on fresh reads. Nothing is retried.
    ///
    /// - Parameters:
    ///   - revalidate: re-runs ADR 0013's binding on fresh inventories and `ps` reads plus a fresh
    ///     `list-clients`, given the pre-Open time, and returns `plan`'s outcome.
    ///   - activate: runs `activate-pane` for the plan once and, when it exited 0, activates WezTerm.
    ///   - verifyRead: fresh `list` and `list-clients` (nil when unreadable) and the frontmost app.
    public static func run(now: @escaping () -> Double,
                           revalidate: @escaping (Double) async -> Result<WezTermOpenPlan, OpenMiss>,
                           activate: @escaping (WezTermOpenPlan) async -> WezTermCommandResult,
                           verifyRead: @escaping () async -> (WezTermSnapshot?, WezTermClients?, TerminalHost?),
                           isolation: isolated (any Actor)? = #isolation) async -> TerminalOpenRun<WezTermOpenPlan, OpenMiss> {
        await TerminalOpenSequence.run(TerminalOpenSteps<WezTermOpenPlan, OpenMiss>(
            now: now,
            revalidate: revalidate,
            raise: { plan in activated(await activate(plan)) },
            verify: { plan in
                let (after, clients, frontmost) = await verifyRead()
                return verify(plan, after: after, clients: clients, frontmost: frontmost)
            }))
    }
}

// MARK: - Presentation

/// The latest WezTerm read's outcome, for the Settings card.
public enum WezTermScanStatus: Equatable, Sendable {
    /// None has run since the switch was turned on, or nothing needed reading.
    case notRead
    case read
    case notRunning
    case unreadable(WezTermUnreadable)
}

/// One WezTerm problem line; each is a separate fix (product.md, "Problem lines"). WezTerm needs no
/// Automation access, so there is no permission line.
public enum WezTermSettingsProblem: Equatable, Hashable, Sendable {
    /// No `wezterm` in its fixed locations.
    case notFound
    /// The socket fails the owner-only trust check.
    case untrustedSocket
    /// Any other failed read: no socket, several running copies, an error, a timeout or a malformed reply.
    /// The exact reason goes to diagnostics only.
    case unreadable

    public var message: String {
        switch self {
        case .notFound: "Steer can't find WezTerm in /Applications or ~/Applications."
        case .untrustedSocket: "Steer can't read WezTerm: its socket in ~/.local/share/wezterm isn't private to you."
        case .unreadable: OpenUnavailableReason.hostUnreadable(.wezTerm).cardLine
        }
    }
}

/// The WezTerm card's state: the status badge and every problem that applies. Hidden until acceptance
/// (#245): `TerminalHost.showsCard` stays false.
public struct WezTermSettingsRow: Equatable, Sendable {
    public let badge: HerdrReadinessBadge
    public let problems: [WezTermSettingsProblem]

    public init(badge: HerdrReadinessBadge, problems: [WezTermSettingsProblem]) {
        self.badge = badge
        self.problems = problems
    }
}

public enum WezTermPresentation {
    /// The card's targeting rule and what Open does otherwise; a fallback is silent on notch cards (ADR
    /// 0015), so this is where it is explained. It says nothing about question digits, so it stays true
    /// when `WezTermInput.questionDigitsProvenLive` is turned on (#245).
    public static let footer =
        "Steer returns to unsplit tabs in WezTerm's front window; otherwise Open raises WezTerm. Replies are typed into the exact pane."

    /// The card from the switch, whether a `wezterm` binary is in its fixed locations, the latest read,
    /// and whether a live session has been seen bound to a WezTerm pane.
    public static func settingsRow(on: Bool, installed: Bool, scan: WezTermScanStatus, inUse: Bool) -> WezTermSettingsRow {
        guard on else { return WezTermSettingsRow(badge: .off, problems: []) }
        var problems: [WezTermSettingsProblem] = []
        if !installed { problems.append(.notFound) }
        if case .unreadable(let reason) = scan {
            switch reason {
            case .binaryNotFound: if installed { problems.append(.notFound) }
            case .socketUntrusted: problems.append(.untrustedSocket)
            case .severalInstances, .socketMissing, .commandFailed, .timedOut, .malformedReply: problems.append(.unreadable)
            }
        }
        let badge: HerdrReadinessBadge = !problems.isEmpty ? .needsAttention : inUse ? .ready : .notInUse
        return WezTermSettingsRow(badge: badge, problems: problems)
    }
}

// MARK: - Typed input (ADR 0017)

/// WezTerm's send: `send-text --no-paste --pane-id <id>`, which types into that pane alone (live proof).
public enum WezTermInput {
    /// Whether WezTerm may carry a Codex question's digit. ADR 0017 keeps a host's question route off
    /// until a live run shows the digit alone commits there; no run has shown it in WezTerm yet. The
    /// relay is built and tested behind this gate; WezTerm's acceptance (#245) flips it once §3d H9's
    /// question line passes. Until then a Codex question in WezTerm shows "Answer this in Codex."
    public static let questionDigitsProvenLive = false

    /// What one `send-text` carries for a write: Claude's text and CR together; Codex's text, then a CR
    /// alone (the live proof: Codex leaves text plus CR in its composer).
    public static func payload(_ write: TypedWrite) -> String {
        switch write {
        case .text(let text): text
        case .textAndSubmit(let text): text + "\r"
        case .submit: "\r"
        }
    }

    /// The command line for one send into `pane`; nil for a handle that is not a pane id. `--` keeps a
    /// payload starting with `-` from being read as an option.
    public static func send(_ payload: String, pane: String) -> [String]? {
        WezTermCLI.paneID(pane).map {
            ["cli", "--no-auto-start", "send-text", "--no-paste", "--pane-id", String($0), "--", payload]
        }
    }

    /// The delivery of one `send-text`. Nothing ran, or WezTerm reported no such pane (the proof: exit 1,
    /// nothing written): not written. Exit 0: written. Anything else, a timeout included, may have typed
    /// and counts as sent.
    public static func delivery(_ result: WezTermCommandResult) -> TypedInputDelivery {
        switch result {
        case .notRun: .notWritten
        case .exited(0, _, _): .written
        case .exited(_, _, let stderr) where reportsNoSuchPane(stderr): .notWritten
        case .exited, .timedOut: .possiblyWritten
        }
    }

    static func reportsNoSuchPane(_ stderr: String) -> Bool {
        stderr.contains("no such pane")
    }
}

enum WezTermJSON {
    /// A non-negative integer JSON number, never a Boolean or a fraction.
    static func identifier(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let int = number.intValue
        return Double(int) == number.doubleValue && int >= 0 ? int : nil
    }
}
