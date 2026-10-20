import Foundation

// ADR 0014 "Host-tab join": a multiplexer's single client runs in one terminal tab, found only by its
// tty. Host-neutral (tmux's `client_tty` here; herdr's `lsof` and Zellij's client process can use it).
// Pure over the enabled hosts' fresh inventories; HerdlyApp reads them and raises the tab.

/// Where a multiplexer client's tty leads among the enabled terminal hosts.
public enum MultiplexerHostJoin: Equatable, Sendable {
    /// Exactly one unsplit tab of an enabled host lists the client's tty.
    case tab(TerminalTabTarget)
    /// No tty-listing tab matches, and an enabled Ghostty lists tabs without `tty`: Ghostty's own join
    /// (ADR 0011, its sole-terminal rule included) decides.
    case ghostty
    /// No exact host tab: ADR 0015's fallback or an unavailable reason.
    case miss(OpenMiss)
}

/// The host tab an Open raises after the pane verified (ADR 0014 step 4).
public enum MultiplexerHostTarget: Equatable, Sendable {
    /// The joined tab, raised by its host's own Open.
    case tab(TerminalTabTarget)
    /// Decided by Ghostty's join (ADR 0011, its sole-terminal rule included) when the tab is raised.
    case ghostty
}

/// The tty of the tab each host shows in front, by that host's own visible test (ADR 0016), for a
/// multiplexer pane's visit: the pane is visible when its client runs on this tty and shows it.
/// Frontmost comes from macOS. An unread host is unknown; another app in front shows nothing.
public enum MultiplexerHostFront {
    public static func iTerm2(_ snapshot: ITerm2Snapshot?, frontmost: TerminalHost?) -> TerminalVisibilityReading<String> {
        switch TerminalVisibility.iTerm2(snapshot, frontmost: frontmost) {
        case .visible(let session):
            return snapshot?.session(session)?.tty.flatMap(GhosttyTTYMatch.normalizedTTY).map { .visible($0) } ?? .unknown
        case .unknown: return .unknown
        case .nothing, .unchecked: return .nothing
        }
    }

    public static func terminalApp(_ snapshot: TerminalAppSnapshot?, frontmost: TerminalHost?,
                                   onScreenWindowIDs: Set<Int>?) -> TerminalVisibilityReading<String> {
        switch TerminalVisibility.terminalApp(snapshot, frontmost: frontmost, onScreenWindowIDs: onScreenWindowIDs) {
        case .visible(let target): return .visible(target.tty)
        case .unknown: return .unknown
        case .nothing, .unchecked: return .nothing
        }
    }

    /// WezTerm's one GUI client's focused pane (`TerminalVisibility.wezTerm`).
    public static func wezTerm(_ snapshot: WezTermSnapshot?, clients: WezTermClients?,
                               frontmost: TerminalHost?) -> TerminalVisibilityReading<String> {
        switch TerminalVisibility.wezTerm(snapshot, clients: clients, frontmost: frontmost) {
        case .visible(let pane):
            return Int(pane).flatMap { snapshot?.pane($0)?.tty }.flatMap(GhosttyTTYMatch.normalizedTTY)
                .map { .visible($0) } ?? .unknown
        case .unknown: return .unknown
        case .nothing, .unchecked: return .nothing
        }
    }

    /// Ghostty's selected terminal in its front window. Without `tty` (Ghostty 1.3.1) the terminal's
    /// tty is unknown, so nothing hosted there is ever visible until Ghostty exposes it (#251).
    public static func ghostty(_ snapshot: GhosttySnapshot?, frontmost: TerminalHost?) -> TerminalVisibilityReading<String> {
        switch TerminalVisibility.ghostty(snapshot, frontmost: frontmost) {
        case .visible(let target):
            let terminal = snapshot?.windows.first { $0.id == target.window_id }?.tabs.first { $0.id == target.tab_id }?
                .terminals.first { $0.id == target.terminal_id }
            return terminal?.tty.flatMap(GhosttyTTYMatch.normalizedTTY).map { .visible($0) } ?? .unknown
        case .unknown: return .unknown
        case .nothing, .unchecked: return .nothing
        }
    }
}

public enum MultiplexerHostTab {
    /// Joins `clientTTY` to the one tab across the enabled terminal inventories. Hosts switched off are
    /// never read; an enabled host whose inventory is unreadable or missing cannot be ruled out, so the
    /// join is unavailable. Several matches, or none, fall back; a split host tab falls back.
    public static func join(clientTTY: String, switches: TerminalHostSwitches,
                            inventories: [TerminalHost: TerminalHostInventory]) -> MultiplexerHostJoin {
        guard let client = GhosttyTTYMatch.normalizedTTY(clientTTY) else {
            return .miss(.fallBack(.noUniqueTarget, candidates: 0))
        }
        var matches: [(target: TerminalTabTarget, panes: Int)] = []
        var ttylessGhostty = false
        for host in TerminalHost.terminals where switches.mayContact(host) {
            switch inventories[host] {
            case .notRunning?: continue
            case .unreadable?, nil: return .miss(.unavailable(.hostUnreadable(host)))
            case .tabs(let tabs)?:
                for tab in tabs {
                    guard let tty = tab.tty.flatMap(GhosttyTTYMatch.normalizedTTY) else {
                        if host == .ghostty { ttylessGhostty = true }
                        continue
                    }
                    if tty == client { matches.append((TerminalTabTarget(host: host, tabID: tab.tabID, tty: tty), tab.paneCount)) }
                }
            }
        }
        if matches.count > 1 { return .miss(.fallBack(.noUniqueTarget, candidates: matches.count)) }
        if let match = matches.first {
            return match.panes == 1 ? .tab(match.target) : .miss(.fallBack(.unsupportedLayout, candidates: 1))
        }
        return ttylessGhostty ? .ghostty : .miss(.fallBack(.noUniqueTarget, candidates: 0))
    }
}
