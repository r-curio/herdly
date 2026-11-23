import Foundation

/// What one terminal host besides herdr shows, for ending a daemon-held Codex session that no tab
/// shows (`ReminderReader.scan`, #265). Codex titles its terminal with its shortened session ID in
/// every host, so that title on any switched-on host's tab or pane is the session's surface, exactly
/// as a Ghostty tab title is. Ghostty's own inventory reaches the scan as `GhosttyInventory`; Ghostty
/// appears here only while switched off, as `unseen`.
public enum TerminalHostTitles: Equatable, Sendable {
    /// The host is switched on and its inventory, read at `takenAt`, lists these titles.
    case known(Set<String>, takenAt: Double)
    /// The host is switched on and was not running at `takenAt`: it holds no tab now. A session it
    /// last showed may come back when it is relaunched, so that session is not ended (H7).
    case notRunning(takenAt: Double)
    /// The host is switched on and running but no readable inventory is held: before its first read,
    /// or after an unreadable one at `takenAt`. A tab there may show the title.
    case unknown(takenAt: Double)
    /// Herdly cannot read this host's tabs (it is switched off, cannot be contacted, or is a
    /// multiplexer some of whose Codex TUIs run on a server other than its default one), and a running
    /// Codex TUI's process ancestry reaches it. That TUI's session may be there: product.md says its app cannot be identified,
    /// not that it has ended.
    case unseen

    /// The hosts these titles cover: every Codex tab host besides Ghostty (`ReminderReader.scan`'s
    /// own inventory while switched on) and herdr (`HerdrPaneTitles`).
    public static let hosts: [TerminalHost] = [.iTerm2, .terminalApp, .wezTerm, .rex, .tmux, .zellij]

    /// A switched-on host's inventory read at `takenAt`.
    public init(inventory: TerminalHostInventory, takenAt: Double) {
        switch inventory {
        case .notRunning: self = .notRunning(takenAt: takenAt)
        case .unreadable: self = .unknown(takenAt: takenAt)
        case .tabs(let tabs): self = .known(Set(tabs.compactMap(\.title)), takenAt: takenAt)
        }
    }

    /// When this reading was taken; nil for `unseen`, which is never held.
    public var takenAt: Double? {
        switch self {
        case .known(_, let takenAt), .notRunning(let takenAt), .unknown(let takenAt): takenAt
        case .unseen: nil
        }
    }

    /// `held` with the reading of each host in `inventories` that is in `contactable` merged in. The
    /// newer reading wins, so a scan that started earlier but finished later cannot overwrite a newer
    /// one, whatever either says; an equally old one replaces it.
    public static func merged(_ held: [TerminalHost: TerminalHostTitles],
                              inventories: [TerminalHost: TerminalHostInventory], takenAt: Double,
                              contactable: Set<TerminalHost>) -> [TerminalHost: TerminalHostTitles] {
        var result = held
        for host in hosts where contactable.contains(host) {
            guard let inventory = inventories[host] else { continue }
            if let previous = result[host]?.takenAt, previous > takenAt { continue }
            result[host] = TerminalHostTitles(inventory: inventory, takenAt: takenAt)
        }
        return result
    }

    /// The scan's view of the hosts. `latest` holds the readings the host scans recorded,
    /// `appsRunning` the terminal apps macOS reports running, and `codexReach` how many running Codex
    /// TUIs' ancestry reaches each host (`CodexCLIProcesses.hostsReached`). Nothing here contacts a host.
    ///   - A contactable terminal app that is not running: `notRunning` as of `now`.
    ///   - A contactable host otherwise: its latest reading, `unknown` when it has none or when the
    ///     reading says not running though macOS says the app is. A multiplexer is `unseen` when more
    ///     Codex TUIs run under its servers than its default server's reading shows Codex titles: some
    ///     run on a server on another socket (or have not titled their pane yet), which Herdly never reads.
    ///   - Any other host, Ghostty included while switched off: `unseen` while a Codex TUI reaches it,
    ///     absent otherwise, since then it holds no Codex session Herdly could miss.
    public static func forScan(switches: TerminalHostSwitches, latest: [TerminalHost: TerminalHostTitles],
                               appsRunning: Set<TerminalHost>, codexReach: [TerminalHost: Int],
                               now: Double) -> [TerminalHost: TerminalHostTitles] {
        var result: [TerminalHost: TerminalHostTitles] = [:]
        if !switches.isOn(.ghostty), codexReach[.ghostty] != nil { result[.ghostty] = .unseen }
        for host in hosts {
            let codexUnder = codexReach[host] ?? 0
            guard switches.mayContact(host) else {
                if codexUnder > 0 { result[host] = .unseen }
                continue
            }
            if host.kind == .terminal, !appsRunning.contains(host) {
                result[host] = .notRunning(takenAt: now)
                continue
            }
            switch latest[host] {
            case nil, .unseen?: result[host] = .unknown(takenAt: now)
            case .notRunning(let takenAt)?:
                if host.kind == .terminal {
                    result[host] = .unknown(takenAt: takenAt)
                } else {
                    result[host] = codexUnder > 0 ? .unseen : .notRunning(takenAt: takenAt)
                }
            case .known(let titles, _)? where host.kind == .multiplexer
                && codexUnder > titles.filter(HerdrBindingRules.isShortenedCodexSessionTitle).count:
                result[host] = .unseen
            case let reading?: result[host] = reading
            }
        }
        return result
    }
}
