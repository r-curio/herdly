import Foundation

public struct GhosttyTarget: Codable, Equatable, Sendable {
    public let window_id: String
    public let tab_id: String
    public let terminal_id: String
}
public struct GhosttySnapshot: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public struct Tab: Decodable, Sendable {
            public struct Terminal: Decodable, Sendable {
                let id: String
                let name: String
                /// Present only in inventories taken with `tty` support (ADR 0011); "" when Ghostty
                /// cannot report it for this terminal.
                let tty: String?
            }
            let id: String
            let terminals: [Terminal]
        }
        let id: String
        let tabs: [Tab]
    }
    public let status: String
    public let windows: [Window]
    public let front_window_id: String?
    public let selected: GhosttyTarget?
    /// The TTYs of every terminal surface the running Ghostty owns, from its child processes rather
    /// than its scripting dictionary, so the quick terminal and any surface scripting cannot list
    /// are included. Filled by Steer only for a Ghostty without `tty` (ADR 0011's sole-terminal
    /// rule); nil when not read or unreadable. Never part of Ghostty's own reply.
    public var surface_ttys: [String]?

    /// Every terminal title in the inventory. A session whose `GhosttyMatch.title` is among them
    /// is a CLI session, whatever its rollout header says (see `ReminderReader.scan`).
    public var terminalNames: Set<String> {
        Set(windows.flatMap { $0.tabs.flatMap { $0.terminals.map(\.name) } })
    }

    /// The title of `target`'s terminal, nil when this inventory does not hold it: a multiplexer's host
    /// tab title veto (Zellij's `<session> | `, ADR 0014) reads it once Ghostty's own join chose the tab.
    public func terminalName(_ target: GhosttyTarget) -> String? {
        windows.first { $0.id == target.window_id }?.tabs.first { $0.id == target.tab_id }?
            .terminals.first { $0.id == target.terminal_id }?.name
    }
}
/// Ghostty's terminal titles as of one inventory, with when it was taken (Unix seconds). Passed
/// into every reminder scan: a session-id title proves a CLI session, and its later absence is the
/// end of that session's surface.
public struct GhosttyInventory: Equatable, Sendable {
    public let titles: Set<String>
    public let takenAt: Double

    public init(titles: Set<String>, takenAt: Double) {
        self.titles = titles
        self.takenAt = takenAt
    }
}

public enum GhosttyMatch {
    public static func title(_ session: UUID) -> String { String(session.uuidString.lowercased().prefix(29)) + "..." }
    public static func claudeTitle(_ sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID), uuid.uuidString.lowercased() == sessionID else { return nil }
        return ClaudeSetupRequirements.titlePrefix + sessionID
    }
    /// The sessions among `candidates` whose session-ID title is on some Ghostty terminal right
    /// now. Presence only: it says nothing about which tab is selected or whether it is unsplit.
    public static func sessions(in snapshot: GhosttySnapshot, among candidates: Set<UUID>) -> Set<UUID> {
        guard snapshot.status == "ok" else { return [] }
        let names = Set(snapshot.windows.flatMap { $0.tabs.flatMap { $0.terminals.map(\.name) } })
        return candidates.filter { names.contains(title($0)) }
    }

    public static func target(session: UUID, live: Set<UUID>, snapshot: GhosttySnapshot) -> GhosttyTarget? {
        target(title: title(session), live: live.map(title), snapshot: snapshot)
    }

    public static func target(claudeSessionID: String, live: [String], snapshot: GhosttySnapshot) -> GhosttyTarget? {
        guard let title = claudeTitle(claudeSessionID) else { return nil }
        guard live.allSatisfy({ claudeTitle($0) != nil }) else { return nil }
        return target(title: title, live: live.map { claudeTitle($0)! }, snapshot: snapshot)
    }

    public static func target(claudeSessionID: String, live: Set<String>, snapshot: GhosttySnapshot) -> GhosttyTarget? {
        target(claudeSessionID: claudeSessionID, live: Array(live), snapshot: snapshot)
    }

    public static func target(title: String, live: [String], snapshot: GhosttySnapshot) -> GhosttyTarget? {
        guard snapshot.status == "ok", live.filter({ $0 == title }).count == 1 else { return nil }
        var matches: [(GhosttyTarget, Int)] = []
        for window in snapshot.windows {
            guard !window.id.isEmpty else { return nil }
            for tab in window.tabs {
                guard !tab.id.isEmpty else { return nil }
                for terminal in tab.terminals {
                    guard !terminal.id.isEmpty else { return nil }
                    if terminal.name == title {
                        matches.append((GhosttyTarget(window_id: window.id, tab_id: tab.id, terminal_id: terminal.id), tab.terminals.count))
                    }
                }
            }
        }
        guard matches.count == 1, matches[0].1 == 1 else { return nil }
        return matches[0].0
    }

    public static func target(title: String, live: Set<String>, snapshot: GhosttySnapshot) -> GhosttyTarget? {
        target(title: title, live: Array(live), snapshot: snapshot)
    }

    public static func isInCurrentWindow(_ target: GhosttyTarget, snapshot: GhosttySnapshot) -> Bool {
        snapshot.front_window_id == target.window_id
    }
}
