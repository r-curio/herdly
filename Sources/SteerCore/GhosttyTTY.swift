import Foundation

/// Whether the Ghostty bundle Steer drives can report each terminal's `tty` (ADR 0011).
/// Decided from the bundle's scripting dictionary alone, without a version comparison or Apple Events.
public enum GhosttyTTYSupport: Equatable, Sendable {
    case supported
    case unsupported
}

/// Pure checks over the Ghostty bundle's `Info.plist` and scripting dictionary bytes.
/// Reading the files belongs to the app; every missing, oversized or malformed input is unsupported.
public enum GhosttyScriptingDictionary {
    /// Upper bound for `Info.plist` and the dictionary file. Ghostty 1.3.1's dictionary is about 16 KB.
    public static let maximumFileSize = 1024 * 1024

    /// The dictionary file name from `Info.plist` key `OSAScriptingDefinition`, only when it is a plain
    /// file name inside `Contents/Resources` (no path separators, no `.` or `..`).
    public static func definitionName(infoPlist: Data) -> String? {
        guard infoPlist.count <= maximumFileSize,
              let plist = try? PropertyListSerialization.propertyList(from: infoPlist, format: nil) as? [String: Any],
              let name = plist["OSAScriptingDefinition"] as? String,
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        return name
    }

    /// Supported only when a `class` with code `Gtrm` (terminal) directly declares a `property` with
    /// code `Gtty` and type `text`. Codes are matched rather than names; external entities are never resolved.
    public static func ttySupport(dictionary: Data?) -> GhosttyTTYSupport {
        guard let dictionary, !dictionary.isEmpty, dictionary.count <= maximumFileSize else { return .unsupported }
        let parser = XMLParser(data: dictionary)
        parser.shouldResolveExternalEntities = false
        let scan = TerminalTTYScan()
        parser.delegate = scan
        guard parser.parse(), scan.declaresTTY else { return .unsupported }
        return .supported
    }
}

private final class TerminalTTYScan: NSObject, XMLParserDelegate {
    private var path: [(name: String, code: String?)] = []
    private(set) var declaresTTY = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if elementName == "property", attributes["code"] == "Gtty", attributes["type"] == "text",
           let parent = path.last, parent.name == "class", parent.code == "Gtrm" {
            declaresTTY = true
        }
        path.append((elementName, attributes["code"]))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        _ = path.popLast()
    }
}

/// The result of joining a herdr client's TTY to one Ghostty terminal (ADR 0011). Only `matched`
/// permits raising Ghostty; every other case is a typed reason the tab cannot be identified.
public enum GhosttyTTYJoin: Equatable, Sendable {
    /// Exactly one terminal has the client's TTY, alone in its tab, in the current Ghostty window.
    case matched(GhosttyTarget)
    /// The Ghostty bundle does not declare `tty`, or the inventory was taken without it, and the
    /// sole-terminal rule does not hold (Ghostty has more than one terminal surface, or its surfaces
    /// could not be read).
    case ttyUnsupported
    /// The inventory is not a complete fresh snapshot (status other than ok, or an empty identifier).
    case inventoryUnavailable
    /// The client's TTY from `lsof` is not a `/dev/ttysNNN` device path.
    case invalidClientTTY
    /// No terminal has the client's TTY and every terminal reported a usable one.
    case noMatch
    /// No terminal has the client's TTY, but some terminal reported an empty or unusable `tty`
    /// (Ghostty returns "" when its scripting is disabled or the surface has no model), so the
    /// client's terminal cannot be ruled out.
    case emptyValue
    /// More than one terminal reports the client's TTY.
    case multipleMatches
    /// The only matching terminal shares its tab with another terminal (ADR 0004).
    case split
    /// The only matching terminal is in a Ghostty window other than the current one.
    case otherWindow
}

public enum GhosttyTTYMatch {
    /// `/dev/ttysNNN` for either `/dev/ttysNNN` or `ttysNNN`; nil for anything else, including "".
    public static func normalizedTTY(_ value: String) -> String? {
        let name = value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
        guard name.hasPrefix("ttys"), name.count > 4, name.count <= 16,
              name.dropFirst(4).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "/dev/" + name
    }

    /// Joins `clientTTY` (from `lsof`) to the single Ghostty terminal reporting the same TTY in
    /// `snapshot`, which must be a fresh inventory taken with `tty` when `support` is supported.
    /// Without `tty` (Ghostty 1.3.1) the sole-terminal rule applies instead; see `soleTerminalJoin`.
    public static func join(clientTTY: String, support: GhosttyTTYSupport, snapshot: GhosttySnapshot) -> GhosttyTTYJoin {
        guard support == .supported else { return soleTerminalJoin(clientTTY: clientTTY, snapshot: snapshot) }
        guard snapshot.status == "ok" else { return .inventoryUnavailable }
        guard let client = normalizedTTY(clientTTY) else { return .invalidClientTTY }
        var matches: [(target: GhosttyTarget, terminalsInTab: Int)] = []
        var unusable = false
        for window in snapshot.windows {
            guard !window.id.isEmpty else { return .inventoryUnavailable }
            for tab in window.tabs {
                guard !tab.id.isEmpty else { return .inventoryUnavailable }
                for terminal in tab.terminals {
                    guard !terminal.id.isEmpty else { return .inventoryUnavailable }
                    guard let tty = terminal.tty else { return .ttyUnsupported }
                    guard let value = normalizedTTY(tty) else {
                        unusable = true
                        continue
                    }
                    if value == client {
                        matches.append((GhosttyTarget(window_id: window.id, tab_id: tab.id, terminal_id: terminal.id),
                                        tab.terminals.count))
                    }
                }
            }
        }
        guard matches.count <= 1 else { return .multipleMatches }
        guard let match = matches.first else { return unusable ? .emptyValue : .noMatch }
        guard match.terminalsInTab == 1 else { return .split }
        guard snapshot.front_window_id == match.target.window_id else { return .otherWindow }
        return .matched(match.target)
    }

    /// ADR 0011's sole-terminal rule for a Ghostty without `tty`. The join holds only when Ghostty
    /// owns exactly one terminal surface, by both of two independent readings, and that surface's
    /// TTY is the herdr client's:
    /// - Ghostty's child processes (`surface_ttys`) hold exactly one TTY, equal to `clientTTY`. This
    ///   counts every surface, including the quick terminal, which scripting may not list.
    /// - The scripting inventory lists exactly one terminal, alone in its tab, in the front window.
    /// More than one surface, or surfaces that could not be read, is `ttyUnsupported`: only a Ghostty
    /// with `tty` can tell them apart.
    static func soleTerminalJoin(clientTTY: String, snapshot: GhosttySnapshot) -> GhosttyTTYJoin {
        guard snapshot.status == "ok" else { return .inventoryUnavailable }
        guard let client = normalizedTTY(clientTTY) else { return .invalidClientTTY }
        guard let raw = snapshot.surface_ttys else { return .ttyUnsupported }
        let surfaces = raw.map(normalizedTTY)
        guard !surfaces.contains(nil) else { return .emptyValue }
        guard Set(surfaces.compactMap { $0 }).count == 1, surfaces.count == 1 else { return .ttyUnsupported }
        guard surfaces[0] == client else { return .noMatch }
        var terminals: [(target: GhosttyTarget, terminalsInTab: Int)] = []
        for window in snapshot.windows {
            guard !window.id.isEmpty else { return .inventoryUnavailable }
            for tab in window.tabs {
                guard !tab.id.isEmpty else { return .inventoryUnavailable }
                for terminal in tab.terminals {
                    guard !terminal.id.isEmpty else { return .inventoryUnavailable }
                    terminals.append((GhosttyTarget(window_id: window.id, tab_id: tab.id, terminal_id: terminal.id),
                                      tab.terminals.count))
                }
            }
        }
        // One surface by process but not exactly one scripted terminal: the two readings disagree.
        guard terminals.count == 1 else { return .ttyUnsupported }
        let only = terminals[0]
        guard only.terminalsInTab == 1 else { return .split }
        guard snapshot.front_window_id == only.target.window_id else { return .otherWindow }
        return .matched(only.target)
    }
}
