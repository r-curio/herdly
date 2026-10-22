import Foundation

// Terminal.app (#239), from the live proof (docs/evidence/terminal-app-live.md): every ⌘T tab is its
// own scripting window, tabs have no id, and the read-only `tty` is the only exact handle. The
// showing tab comes from front-window order, Codex's and Herdly's Claude titles show exactly in
// `custom title`, setting the tab-window's `frontmost` (plus `activate`) opens it, and `do script …
// in <tab>` types into that tab alone, always followed by a newline. Everything here is a pure
// function of what HerdlyApp's `TerminalApp.js` returns; Apple Events, `ps`, the window server and
// macOS's frontmost app belong to HerdlyApp.

/// One Terminal.app inventory: its scripting windows in front-to-back order, each with its tabs.
public struct TerminalAppSnapshot: Equatable, Sendable {
    public static let maximumReplySize = 1024 * 1024
    public static let maximumWindows = 512
    public static let maximumTabsPerWindow = 64
    public static let maximumTitleLength = 1024

    public struct Tab: Equatable, Sendable {
        /// `/dev/ttysNNN`.
        public let tty: String
        /// The tab's `custom title`, nil when Terminal could not report it.
        public let title: String?
    }

    public struct Window: Equatable, Sendable {
        /// Terminal's window `id`, which equals its CGWindowID (live proof).
        public let id: Int
        public let tabs: [Tab]
    }

    /// Front window first.
    public let windows: [Window]

    /// The reply of the inventory request, or nil when it is not a complete, well-formed inventory:
    /// unreadable, never repaired.
    public static func parse(_ data: Data) -> TerminalAppSnapshot? {
        guard data.count <= maximumReplySize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "ok",
              let rawWindows = object["windows"] as? [Any], rawWindows.count <= maximumWindows else { return nil }
        var windows: [Window] = []
        for raw in rawWindows {
            guard let window = raw as? [String: Any], let id = exactInt(window["id"]), id > 0,
                  let rawTabs = window["tabs"] as? [Any], rawTabs.count <= maximumTabsPerWindow else { return nil }
            var tabs: [Tab] = []
            for rawTab in rawTabs {
                guard let tab = rawTab as? [String: Any], let rawTTY = tab["tty"] as? String,
                      let tty = GhosttyTTYMatch.normalizedTTY(rawTTY) else { return nil }
                let title: String?
                switch tab["title"] {
                case nil, is NSNull: title = nil
                case let value as String where value.count <= maximumTitleLength: title = value
                default: return nil
                }
                tabs.append(Tab(tty: tty, title: title))
            }
            windows.append(Window(id: id, tabs: tabs))
        }
        return TerminalAppSnapshot(windows: windows)
    }

    /// The front window's id, nil when Terminal has no window.
    public var frontWindowID: Int? { windows.first?.id }

    /// How many tabs Terminal lists in window `id`; 0 when it lists no such window.
    public func tabsInWindow(_ id: Int) -> Int {
        windows.first { $0.id == id }?.tabs.count ?? 0
    }

    /// ADR 0013's inventory: one tab per listed tab, its window id as the tab handle, one pane each.
    /// Terminal's split view shows the same tty twice, so a tab never holds a second pane.
    public var inventory: TerminalHostInventory {
        .tabs(windows.flatMap { window in
            window.tabs.map { TerminalTab(tabID: String(window.id), tty: $0.tty, title: $0.title, paneCount: 1) }
        })
    }

    /// The ttys whose `ps -t` read ADR 0013 needs: tabs titled with a shortened Codex identifier, and
    /// tabs on one of `claudeTTYs`. Other tabs are never read.
    public func ttysToRead(claudeTTYs: Set<String>) -> Set<String> {
        Set(windows.flatMap(\.tabs).filter { tab in
            claudeTTYs.contains(tab.tty) || tab.title.map(HerdrBindingRules.isShortenedCodexSessionTitle) == true
        }.map(\.tty))
    }

    /// An integer JSON number, never a Boolean or a fraction.
    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let int = number.intValue
        return Double(int) == number.doubleValue ? int : nil
    }
}

/// How one script request to Terminal.app ended, from HerdlyApp's side.
public enum TerminalAppScriptResult: Equatable, Sendable {
    /// The script ran and printed this reply.
    case reply(Data)
    /// macOS refused the Apple Event: Automation is not allowed (errAEEventNotPermitted, -1743).
    case denied
    /// Any other failure: a script error, a timeout, Terminal not answering.
    case failed

    /// The reply's `status`, nil for anything but a well-formed reply.
    public var status: String? {
        guard case .reply(let data) = self, data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["status"] as? String
    }
}

extension TerminalVisibility {
    /// Terminal.app's test (ADR 0016): macOS reports Terminal frontmost, its front window is a tab-window
    /// holding one tab, and the window server lists that window on screen. The tab returned is that
    /// window's; whether it is a session's bound target, still bound on fresh reads, is the caller's
    /// comparison. Terminal keeps a front window while another app is in front, so its answer alone is
    /// never enough. An inventory or window list that could not be read is unknown.
    public static func terminalApp(_ snapshot: TerminalAppSnapshot?, frontmost: TerminalHost?,
                                   onScreenWindowIDs: Set<Int>?) -> TerminalVisibilityReading<TerminalTabTarget> {
        guard let snapshot, let onScreenWindowIDs else { return .unknown }
        guard frontmost == .terminalApp, let front = snapshot.windows.first, front.tabs.count == 1,
              onScreenWindowIDs.contains(front.id) else { return .nothing }
        return .visible(TerminalTabTarget(host: .terminalApp, tabID: String(front.id), tty: front.tabs[0].tty))
    }
}

/// ADR 0016's Open steps for a Terminal.app tab: set the tab-window's `frontmost`, `activate`, then
/// read back. Each returns nil when it passed, or the miss ADR 0015 resolves.
public enum TerminalAppOpen {
    /// Whether an Open leaves the session to another route: one is on (Ghostty's title route, iTerm2's
    /// cross-host Open, or for Claude its own process's walk) and a fresh Terminal.app inventory holds
    /// no tab of the session (its title for Codex, its process's tty for Claude). An unreadable
    /// Terminal.app keeps the session here, where it is unavailable (ADR 0013); the other route reads
    /// every enabled host for the binding too.
    public static func leavesToOtherRoute(otherRouteOn: Bool, inventory: TerminalHostInventory, holdsSession: Bool) -> Bool {
        guard otherRouteOn, inventory != .unreadable else { return false }
        return !holdsSession
    }

    /// Revalidate: the fresh binding must name one Terminal.app tab, alone in its window. A tab inside a
    /// window of several tabs cannot be picked (`selected` did nothing live), so it falls back.
    public static func plan(_ binding: TerminalTabBinding, snapshot: TerminalAppSnapshot) -> Result<TerminalTabTarget, OpenMiss> {
        switch binding {
        case .unavailable(let reason):
            return .failure(TerminalTabOpen.miss(reason))
        case .bound(let target):
            guard target.host == .terminalApp, let window = Int(target.tabID),
                  snapshot.tabsInWindow(window) == 1 else {
                return .failure(.fallBack(.unsupportedLayout, candidates: 1))
            }
            return .success(target)
        }
    }

    /// Select and raise, sent once: Automation denied or the tab gone from every window is unavailable;
    /// a tab that moved, a window that gained a tab or a duplicated tty is a layout change and falls
    /// back, as does any other error or reply.
    public static func raised(_ result: TerminalAppScriptResult) -> OpenMiss? {
        if result == .denied { return .unavailable(.hostUnreadable(.terminalApp)) }
        switch result.status {
        case "ok": return nil
        case "gone": return .unavailable(.sessionEnded)
        case "moved": return .fallBack(.unsupportedLayout, candidates: 1)
        default: return .fallBack(.notVerified, candidates: 1)
        }
    }

    /// Verify on a fresh read: the target is visible. Terminal is already activated, so a failure
    /// falls back and adds nothing.
    public static func verified(_ target: TerminalTabTarget, snapshot: TerminalAppSnapshot?, frontmost: TerminalHost?,
                                onScreenWindowIDs: Set<Int>?) -> OpenMiss? {
        let reading = TerminalVisibility.terminalApp(snapshot, frontmost: frontmost, onScreenWindowIDs: onScreenWindowIDs)
        return reading == .visible(target) ? nil : .fallBack(.notVerified, candidates: 1)
    }
}

/// The Terminal.app card in Settings › Terminals (docs/product.md, "Agreed terminal host
/// presentation"). Hidden until acceptance (#244): `TerminalHost.showsCard` stays false.
public struct TerminalAppSettingsRow: Equatable, Sendable {
    public enum Badge: Equatable, Sendable {
        case off, notInUse, ready, needsAttention

        public var title: String {
            switch self {
            case .off: "Off"
            case .notInUse: "Not in use"
            case .ready: "Ready"
            case .needsAttention: "Needs attention"
            }
        }
    }

    public let badge: Badge
    /// One line per problem, each a separate fix.
    public let problems: [TerminalAppSettingsProblem]
}

/// One fix under Terminal.app's row. Both share the agreed unreadable line; only a denial offers
/// Open Settings….
public enum TerminalAppSettingsProblem: Equatable, Hashable, Sendable {
    /// macOS Automation access for Terminal.app was denied, by the check or by a scan (#279).
    case automationDenied
    /// Terminal.app is running but its latest inventory could not be read.
    case unreadable

    public var message: String { TerminalAppPresentation.unreadableLine }

    /// Whether the line offers Open Settings…, which opens Privacy & Security › Automation.
    public var opensAutomationSettings: Bool { self == .automationDenied }
}

/// What the latest scan that could tell showed about Terminal.app's Automation permission (#279). A scan
/// meeting a denial keeps the switch on and the checked answer as it is, so scanning goes on; the
/// Permission row shows Not allowed until a readable scan. Any other failure tells nothing.
public enum TerminalAppScanPermission: Equatable, Sendable {
    case allowed
    case denied

    /// How one scan's Terminal.app read ended, as far as permission goes.
    public enum Outcome: Equatable, Sendable {
        /// An inventory was read.
        case readable
        /// macOS refused the Apple Event (-1743), confirmed by a fresh consent check.
        case denied
        /// Anything else: a script error, a timeout, Terminal quitting or an unparseable reply.
        case other
    }

    /// The scan permission after `outcome`; any other outcome keeps `previous`.
    public static func after(_ previous: Self?, _ outcome: Outcome) -> Self? {
        switch outcome {
        case .readable: .allowed
        case .denied: .denied
        case .other: previous
        }
    }

    /// The Automation answer the Permission row shows: a scan's denial overrides the last check.
    public static func shown(checked: GhosttyAutomationAccess?, scan: Self?) -> GhosttyAutomationAccess? {
        scan == .denied ? .denied : checked
    }
}

public enum TerminalAppPresentation {
    public static let unreadableLine =
        "Herdly can't read Terminal.app. Allow Herdly under System Settings › Privacy & Security › Automation › Terminal."
    public static let howOpenWorks =
        "Herdly returns to unsplit tabs; otherwise Open raises Terminal.app. Replies are typed into the exact tab; Codex questions are answered in Codex."

    /// - Parameters:
    ///   - access: macOS's Automation answer for Terminal.app, nil before the first check.
    ///   - readable: whether the latest inventory could be read, nil before one was taken.
    ///   - sessionsSeen: whether a scan has seen a session's tab in Terminal.app.
    public static func settingsRow(on: Bool, access: GhosttyAutomationAccess?, readable: Bool?,
                                   sessionsSeen: Bool) -> TerminalAppSettingsRow {
        guard on else { return TerminalAppSettingsRow(badge: .off, problems: []) }
        if access == .denied {
            return TerminalAppSettingsRow(badge: .needsAttention, problems: [.automationDenied])
        }
        if readable == false {
            return TerminalAppSettingsRow(badge: .needsAttention, problems: [.unreadable])
        }
        return TerminalAppSettingsRow(badge: sessionsSeen ? .ready : .notInUse, problems: [])
    }
}
