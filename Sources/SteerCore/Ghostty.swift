import Foundation

public struct GhosttyTarget: Codable, Equatable, Sendable {
    public let window_id: String
    public let tab_id: String
    public let terminal_id: String
}
public struct GhosttySnapshot: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public struct Tab: Decodable, Sendable {
            public struct Terminal: Decodable, Sendable { let id: String; let name: String }
            let id: String
            let terminals: [Terminal]
        }
        let id: String
        let tabs: [Tab]
    }
    public let status: String
    public let windows: [Window]
    public let selected: GhosttyTarget?
}
public enum GhosttyMatch {
    public static func title(_ session: UUID) -> String { String(session.uuidString.lowercased().prefix(29)) + "..." }
    /// The sessions among `candidates` whose session-ID title is on some Ghostty terminal right
    /// now. Presence only: it says nothing about which tab is selected or whether it is unsplit.
    public static func sessions(in snapshot: GhosttySnapshot, among candidates: Set<UUID>) -> Set<UUID> {
        guard snapshot.status == "ok" else { return [] }
        let names = Set(snapshot.windows.flatMap { $0.tabs.flatMap { $0.terminals.map(\.name) } })
        return candidates.filter { names.contains(title($0)) }
    }

    public static func target(session: UUID, live: Set<UUID>, snapshot: GhosttySnapshot) -> GhosttyTarget? {
        guard snapshot.status == "ok", live.contains(session),
              live.filter({ title($0) == title(session) }).count == 1 else { return nil }
        var matches: [(GhosttyTarget, Int)] = []
        for window in snapshot.windows {
            guard !window.id.isEmpty else { return nil }
            for tab in window.tabs {
                guard !tab.id.isEmpty else { return nil }
                for terminal in tab.terminals {
                    guard !terminal.id.isEmpty else { return nil }
                    if terminal.name == title(session) {
                        matches.append((GhosttyTarget(window_id: window.id, tab_id: tab.id, terminal_id: terminal.id), tab.terminals.count))
                    }
                }
            }
        }
        guard matches.count == 1, matches[0].1 == 1 else { return nil }
        return matches[0].0
    }
}
