import Foundation

// iTerm2 Open (#238): ADR 0013's tab binding, ADR 0015's fallback and ADR 0016's Open sequence and
// visible test over iTerm2's AppleScript surface (docs/evidence/iterm2-live.md). Everything here is a
// pure function of what HerdlyApp's bundled ITerm2.js reports, `ps -t` reads and the frontmost app macOS
// reports; running the script, asking for Automation access and activating iTerm2 belong to HerdlyApp.
// iTerm2 gets no typed input at all (ADR 0017): nothing here addresses a session for input.

/// One iTerm2 session (a pane). A tab has no id of its own, so a session stands for its tab, and
/// `tabSessionCount` shows a split (ADR 0013, "Target checks").
public struct ITerm2Session: Equatable, Sendable {
    /// The session's AppleScript `id`: a GUID equal to the part after `:` in `ITERM_SESSION_ID`.
    public let id: String
    public let window: Int
    /// `/dev/ttysNNN`; nil when iTerm2 reported none.
    public let tty: String?
    /// The OSC title: `terminalWindowName` (OSC 0 or 2), else `terminalIconName` (OSC 0 or 1). Codex's
    /// OSC 0 title shows in both; Herdly's Claude title (OSC 2) only in the window name. The composite
    /// tab `name` (`<title> (<job>)`) is never read.
    public let title: String?
    public let tabSessionCount: Int
}

/// The current session of the current tab of iTerm2's current window. iTerm2 keeps one while another
/// app is in front, so it says nothing about visibility alone (ADR 0016).
public struct ITerm2Current: Equatable, Sendable {
    public let window: Int
    public let session: String

    public init(window: Int, session: String) {
        self.window = window
        self.session = session
    }
}

/// One complete ITerm2.js inventory.
public struct ITerm2Snapshot: Equatable, Sendable {
    public let sessions: [ITerm2Session]
    public let current: ITerm2Current?

    /// ADR 0013's inventory: each session as a tab whose pane count is its tab's session count.
    public var inventory: TerminalHostInventory {
        .tabs(sessions.map { TerminalTab(tabID: $0.id, tty: $0.tty, title: $0.title, paneCount: $0.tabSessionCount) })
    }

    public func session(_ id: String) -> ITerm2Session? {
        sessions.first { $0.id == id }
    }

    /// The ttys whose `ps -t` reads ADR 0013's rules need: sessions showing one of `codexTitles` (live
    /// Codex sessions' shortened identifiers), and sessions on one of `claudeTTYs` (the ttys of Claude's
    /// registered processes). Every other tab's processes are never read.
    public func ttysToRead(codexTitles: Set<String>, claudeTTYs: Set<String>) -> Set<String> {
        let claude = Set(claudeTTYs.compactMap(GhosttyTTYMatch.normalizedTTY))
        return Set(sessions.compactMap { session in
            guard let tty = session.tty else { return nil }
            return claude.contains(tty) || session.title.map(codexTitles.contains) == true ? tty : nil
        })
    }
}

/// What one ITerm2.js inventory request returned.
public enum ITerm2Reading: Equatable, Sendable {
    /// iTerm2 was not running when the script ran; it holds no tab (ADR 0013).
    case notRunning
    case snapshot(ITerm2Snapshot)

    /// Largest reply accepted, in bytes.
    public static let maximumBytes = 2 * 1024 * 1024
    /// Most sessions accepted; a larger inventory is malformed rather than truncated.
    public static let maximumSessions = 512
    /// Longest title kept; a longer one cannot be a title Herdly compares and is dropped.
    public static let maximumTitleLength = 1024

    /// The reading in `data`, or nil when it is oversized or malformed in any part: a partial
    /// inventory could hide the tab a session is on, so it never stands for a complete one.
    public static func parse(_ data: Data) -> ITerm2Reading? {
        guard data.count <= maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["status"] as? String else { return nil }
        if status == "not_running" { return .notRunning }
        guard status == "ok", let windows = root["windows"] as? [Any] else { return nil }
        var sessions: [ITerm2Session] = []
        var ids: Set<String> = []
        for case let window as [String: Any] in windows {
            guard let windowID = integer(window["id"]), let tabs = window["tabs"] as? [Any] else { return nil }
            for case let tab as [String: Any] in tabs {
                // A tab with no sessions holds nothing (iTerm2 can keep one after its processes end).
                guard let members = tab["sessions"] as? [Any] else { return nil }
                for case let member as [String: Any] in members {
                    guard let id = sessionID(member["id"]), ids.insert(id).inserted else { return nil }
                    let tty: String?
                    switch member["tty"] {
                    case nil, is NSNull: tty = nil
                    case let value as String where value.isEmpty: tty = nil
                    case let value as String:
                        guard let normalized = GhosttyTTYMatch.normalizedTTY(value) else { return nil }
                        tty = normalized
                    default: return nil
                    }
                    guard case .success(let title) = title(window: member["window_name"], icon: member["icon_name"]) else {
                        return nil
                    }
                    sessions.append(ITerm2Session(id: id, window: windowID, tty: tty, title: title,
                                                  tabSessionCount: members.count))
                    guard sessions.count <= maximumSessions else { return nil }
                }
                guard members.allSatisfy({ $0 is [String: Any] }) else { return nil }
            }
            guard tabs.allSatisfy({ $0 is [String: Any] }) else { return nil }
        }
        guard windows.allSatisfy({ $0 is [String: Any] }) else { return nil }
        var current: ITerm2Current?
        switch root["current"] {
        case nil, is NSNull: current = nil
        case let value as [String: Any]:
            guard let window = integer(value["window"]), let session = sessionID(value["session"]) else { return nil }
            current = ITerm2Current(window: window, session: session)
        default: return nil
        }
        return .snapshot(ITerm2Snapshot(sessions: sessions, current: current))
    }

    /// An upper-case GUID, as iTerm2 reports session ids.
    private static func sessionID(_ value: Any?) -> String? {
        guard let text = value as? String, let uuid = UUID(uuidString: text) else { return nil }
        return uuid.uuidString == text.uppercased() ? text.uppercased() : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let int = number.intValue
        return NSNumber(value: int) == number ? int : nil
    }

    /// The window name when iTerm2 has one, else the icon name; `.failure` when either is neither a
    /// string nor null, which makes the whole reply malformed. An overlong window name is no title; it
    /// never falls through to the icon name.
    private static func title(window: Any?, icon: Any?) -> Result<String?, ITerm2MalformedReply> {
        func text(_ value: Any?) -> Result<String, ITerm2MalformedReply> {
            switch value {
            case nil, is NSNull: .success("")
            case let string as String: .success(string)
            default: .failure(ITerm2MalformedReply())
            }
        }
        guard case .success(let windowName) = text(window), case .success(let iconName) = text(icon) else {
            return .failure(ITerm2MalformedReply())
        }
        let chosen = windowName.isEmpty ? iconName : windowName
        return .success(chosen.isEmpty || chosen.count > maximumTitleLength ? nil : chosen)
    }
}

/// A reply part of the wrong type.
struct ITerm2MalformedReply: Error {}

/// What a revalidated iTerm2 Open holds to: the bound session and, for Codex, the title that must still
/// show (ADR 0013 voids a Codex binding when its title changes; a Claude rename voids nothing).
public struct ITerm2OpenPlan: Equatable, Sendable {
    public let target: TerminalTabTarget
    public let title: String?

    public init(target: TerminalTabTarget, title: String?) {
        self.target = target
        self.title = title
    }
}

/// ITerm2.js's reply to `select`. No reply at all (a scripting error, a timeout, Automation denied) is
/// passed as nil.
public enum ITerm2SelectReply: Equatable, Sendable {
    /// The window, tab and session were selected, then iTerm2 activated. Nothing is verified yet.
    case ok
    /// No session has the GUID: its tab closed. Nothing was selected.
    case gone
    /// The session's tty no longer matches, or its tab now holds several sessions. Nothing was selected.
    case changed
    /// The script got no reply and a fresh check shows macOS Automation access denied.
    case denied
    /// Any other script error or timeout: what iTerm2 did is unknown.
    case noReply

    /// The script's own `status`. Only its three statuses are read; anything else selected nothing
    /// Herdly can name and counts as changed.
    public init(status: String) {
        switch status {
        case "ok": self = .ok
        case "gone": self = .gone
        default: self = .changed
        }
    }
}

public enum ITerm2Open {
    /// Step 1's outcome from a fresh route: an iTerm2 plan only for a binding to an iTerm2 session.
    /// `codexTitle` is the Codex session's shortened identifier, nil for Claude. A binding to another
    /// host, or Ghostty's title route, is not iTerm2's to select and falls back.
    public static func plan(_ route: TerminalTabOpenRoute, codexTitle: String?) -> Result<ITerm2OpenPlan, OpenMiss> {
        switch route {
        case .exact(let target) where target.host == .iTerm2: .success(ITerm2OpenPlan(target: target, title: codexTitle))
        case .exact, .ghosttyTitle: .failure(.fallBack(.noUniqueTarget, candidates: 1))
        case .miss(let miss): .failure(miss)
        }
    }

    /// Step 3's outcome (ADR 0016, "Failures"): an Automation denial is an unreadable host; a target
    /// that is gone is an ended session; any other error or refusal falls back.
    public static func selection(_ reply: ITerm2SelectReply) -> OpenMiss? {
        switch reply {
        case .denied: .unavailable(.hostUnreadable(.iTerm2))
        case .gone: .unavailable(.sessionEnded)
        case .changed, .noReply: .fallBack(.notVerified, candidates: 1)
        case .ok: nil
        }
    }

    /// Step 4 over a fresh inventory and the frontmost app macOS reported after it: the session is
    /// visible (`TerminalVisibility.iTerm2`), still alone in its tab on the same tty, and for Codex still
    /// carries its title. iTerm2 is already active, so any miss falls back, adding nothing.
    public static func verify(_ plan: ITerm2OpenPlan, after: ITerm2Snapshot?, frontmost: TerminalHost?) -> OpenMiss? {
        guard TerminalVisibility.iTerm2(after, frontmost: frontmost) == .visible(plan.target.tabID),
              let session = after?.session(plan.target.tabID), session.tty == plan.target.tty,
              session.tabSessionCount == 1, plan.title == nil || session.title == plan.title else {
            return .fallBack(.notVerified, candidates: 1)
        }
        return nil
    }

    /// ADR 0016's sequence for an iTerm2 session: revalidate on fresh reads, select the window, tab and
    /// session and activate iTerm2 once, then verify on a fresh read. Nothing is retried.
    ///
    /// - Parameters:
    ///   - revalidate: re-runs ADR 0013's binding on fresh inventories and `ps` reads, given the pre-Open
    ///     time; a binding to another host or tab is a miss here.
    ///   - select: sends ITerm2.js `select` for the plan once and returns its reply.
    ///   - verifyRead: a fresh inventory (nil when unreadable) and the app macOS reports frontmost.
    public static func run(now: @escaping () -> Double,
                           revalidate: @escaping (Double) async -> Result<ITerm2OpenPlan, OpenMiss>,
                           select: @escaping (ITerm2OpenPlan) async -> ITerm2SelectReply,
                           verifyRead: @escaping () async -> (ITerm2Snapshot?, TerminalHost?),
                           isolation: isolated (any Actor)? = #isolation) async -> TerminalOpenRun<ITerm2OpenPlan, OpenMiss> {
        await TerminalOpenSequence.run(TerminalOpenSteps<ITerm2OpenPlan, OpenMiss>(
            now: now,
            revalidate: revalidate,
            raise: { plan in selection(await select(plan)) },
            verify: { plan in
                let (after, frontmost) = await verifyRead()
                return verify(plan, after: after, frontmost: frontmost)
            }))
    }
}

extension TerminalVisibility {
    /// iTerm2's visible test (ADR 0016): macOS reports iTerm2 frontmost, and the current session of
    /// its current window's current tab is the one returned, by GUID. Whether that session is a
    /// session's bound target on the same inventory is the caller's comparison. iTerm2 keeps a current
    /// session while another app is in front, so its own answer is never enough. An inventory that
    /// could not be read is unknown.
    public static func iTerm2(_ snapshot: ITerm2Snapshot?, frontmost: TerminalHost?) -> TerminalVisibilityReading<String> {
        guard let snapshot else { return .unknown }
        guard frontmost == .iTerm2, let current = snapshot.current,
              snapshot.session(current.session)?.window == current.window else { return .nothing }
        return .visible(current.session)
    }
}

// MARK: - Presentation

/// The latest iTerm2 inventory request's outcome, for the Settings card.
public enum ITerm2ScanStatus: Equatable, Sendable {
    /// None has run since the switch was turned on, or iTerm2 has nothing Herdly needs to read.
    case notRead
    case read
    case notRunning
    /// A scripting error, a timeout or a malformed reply.
    case unreadable
}

/// One iTerm2 problem line; each is a separate fix (product.md, "Problem lines").
public enum ITerm2SettingsProblem: CaseIterable, Equatable, Hashable, Sendable {
    /// Launch Services knows no iTerm2.
    case notFound
    /// macOS Automation access was denied.
    case automationDenied
    /// iTerm2 is running but its windows could not be read.
    case unreadable

    public var message: String {
        switch self {
        case .notFound: "Herdly can't find iTerm2 on this Mac."
        case .automationDenied: "Herdly isn't allowed to control iTerm2. Turn on Herdly › iTerm2 in System Settings › Privacy & Security › Automation, then turn iTerm2 on here."
        case .unreadable: "Herdly can't read iTerm2's windows. Check that iTerm2 is responding."
        }
    }
}

/// The iTerm2 card's state: the status badge, the Automation badge and every problem that applies.
public struct ITerm2SettingsRow: Equatable, Sendable {
    public let badge: HerdrReadinessBadge
    public let problems: [ITerm2SettingsProblem]

    public init(badge: HerdrReadinessBadge, problems: [ITerm2SettingsProblem]) {
        self.badge = badge
        self.problems = problems
    }
}

public enum ITerm2Presentation {
    /// The row's targeting rule and what Open does otherwise, shown by How Open Works…; a fallback is
    /// silent on notch cards (ADR 0015), so this is where it is explained.
    public static let howOpenWorks = "Herdly returns to unsplit tabs; otherwise Open raises iTerm2."
    /// The typed-input line for a session in iTerm2 (ADR 0017: Broadcast Input cannot be ruled out, so
    /// Herdly types nothing there). It never points to Settings.
    public static let typedInputLine = "Herdly can't type into iTerm2. Reply in the session."

    /// The card from the switch, whether iTerm2 is installed, the latest Automation check (the Ghostty
    /// consent type, which describes any Apple Events target), the latest inventory, and whether a live
    /// session has been seen bound to an iTerm2 tab.
    public static func settingsRow(on: Bool, installed: Bool, access: GhosttyAutomationAccess?,
                                   scan: ITerm2ScanStatus, inUse: Bool) -> ITerm2SettingsRow {
        var problems: [ITerm2SettingsProblem] = []
        if !installed { problems.append(.notFound) }
        if access == .denied { problems.append(.automationDenied) }
        if on, scan == .unreadable { problems.append(.unreadable) }
        let badge: HerdrReadinessBadge = !on ? .off : !problems.isEmpty ? .needsAttention : inUse ? .ready : .notInUse
        return ITerm2SettingsRow(badge: badge, problems: problems)
    }
}

// MARK: - Typed input (ADR 0017)

/// Why a Codex session gets no typed input because of iTerm2. Typed input is never sent to iTerm2, and
/// while iTerm2 is on it counts toward ADR 0013's title uniqueness for every other host's key route.
public enum ITerm2TypedInputBlock: Equatable, Sendable {
    /// An iTerm2 tab shows the session's title: its input target is, or may be, in iTerm2.
    case inITerm2
    /// iTerm2 is on and running but could not be read, so it cannot be ruled out.
    case iTerm2Unreadable

    /// The card's line (product.md, "Typed input unavailable"); neither points to Settings.
    public var line: String {
        switch self {
        case .inITerm2: ITerm2Presentation.typedInputLine
        case .iTerm2Unreadable: "Herdly can't reach this session's tab. Reply in the session."
        }
    }
}

/// A small host check that the shared typed-input route (#239) can absorb: before a question key or
/// typed reply reaches a Codex session through another host (Ghostty's relay), on a fresh iTerm2 read.
public enum ITerm2TypedInput {
    /// - Parameters:
    ///   - title: the session's shortened identifier (ADR 0005).
    ///   - iTerm2: a fresh iTerm2 inventory, or nil while iTerm2's switch is off (never read).
    ///   - processes: `ps -t` reads of the scan's titled ttys; a tab whose read shows no foreground `codex`
    ///     is a title decoy (#268), and a titled tab whose `ps` was not read still blocks.
    /// - Returns: nil when iTerm2 cannot hold the session: switched off, not running, or no tab shows
    ///   the title except title decoys.
    public static func codexBlock(title: String, processes: [String: [TerminalProcess]],
                                  iTerm2: TerminalHostInventory?) -> ITerm2TypedInputBlock? {
        switch iTerm2 {
        case nil, .notRunning?: nil
        case .unreadable?: .iTerm2Unreadable
        case .tabs(let tabs)?: TerminalTabBindingRules.carriesCodexTitle(tabs, title: title, processes: processes) ? .inITerm2 : nil
        }
    }
}
