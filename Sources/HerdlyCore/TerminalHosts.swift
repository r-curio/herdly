import Foundation

/// Every terminal app and multiplexer Herdly can target, in Settings order (product.md, "Agreed
/// terminal host presentation"). Each has its own switch; Herdly scans and contacts only hosts that
/// are switched on.
public enum TerminalHost: String, CaseIterable, Hashable, Sendable {
    case ghostty
    case iTerm2
    case terminalApp
    case wezTerm
    case rex
    case herdrApp
    case tmux
    case zellij
    case herdr

    public enum Kind: Equatable, Sendable {
        /// An app with tabs, listed under Terminals.
        case terminal
        /// Runs inside a terminal tab, listed under Multiplexers (ADR 0014).
        case multiplexer
    }

    public static let terminals = allCases.filter { $0.kind == .terminal }
    public static let multiplexers = allCases.filter { $0.kind == .multiplexer }

    public var kind: Kind {
        switch self {
        case .ghostty, .iTerm2, .terminalApp, .wezTerm, .rex, .herdrApp: .terminal
        case .tmux, .zellij, .herdr: .multiplexer
        }
    }

    public var displayName: String {
        switch self {
        case .ghostty: "Ghostty"
        case .iTerm2: "iTerm2"
        case .terminalApp: "Terminal.app"
        case .wezTerm: "WezTerm"
        case .rex: "Rex"
        // The Herdr desktop app; lowercase "herdr" stays the terminal multiplexer.
        case .herdrApp: "Herdr app"
        case .tmux: "tmux"
        case .zellij: "Zellij"
        case .herdr: "herdr"
        }
    }

    /// Whether Settings shows this host's card. A host's acceptance ticket turns its card on once
    /// its live run in MVP acceptance passes: iTerm2 passed on 2026-10-13 (#243), Terminal.app on 2026-10-14 (#244),
    /// WezTerm on 2026-10-15 (#245), tmux on 2026-10-20 (#246), Zellij on 2026-10-25 (#247). Rex's card is
    /// shown from the start at the user's request, before its own acceptance run, and so is the Herdr app's.
    public var showsCard: Bool {
        switch self {
        case .ghostty, .herdr, .iTerm2, .terminalApp, .wezTerm, .rex, .herdrApp, .tmux, .zellij: true
        }
    }

    /// The host's targeting rule and what Open does when it cannot reach the exact tab or pane, shown
    /// from its row's How Open Works… item. An Open fallback is silent on notch cards (ADR 0015), so
    /// this is where it is explained.
    public var howOpenWorks: String {
        switch self {
        case .ghostty: GhosttyPresentation.howOpenWorks
        case .iTerm2: ITerm2Presentation.howOpenWorks
        case .terminalApp: TerminalAppPresentation.howOpenWorks
        case .wezTerm: WezTermPresentation.howOpenWorks
        case .rex: RexPresentation.howOpenWorks
        case .herdrApp: HerdrAppPresentation.howOpenWorks
        case .tmux: TmuxPresentation.howOpenWorks
        case .zellij: ZellijPresentation.howOpenWorks
        case .herdr: HerdrPresentation.howOpenWorks
        }
    }

    /// The bundle identifier of a terminal app, which a process walk matches (ADR 0015); nil for a
    /// multiplexer, which is not an app.
    public var bundleIdentifier: String? {
        switch self {
        case .ghostty: "com.mitchellh.ghostty"
        case .iTerm2: "com.googlecode.iterm2"
        case .terminalApp: "com.apple.Terminal"
        case .wezTerm: "com.github.wez.wezterm"
        case .rex: RexCLI.bundleIdentifier
        case .herdrApp: HerdrAppCLI.bundleIdentifier
        case .tmux, .zellij, .herdr: nil
        }
    }

    /// The terminal app with this bundle identifier, nil for any other app.
    public init?(bundleIdentifier: String) {
        // A process walk from a Rex terminal reaches the Rex server, which runs every Rex terminal; the app
        // that shows them is Rex.app.
        if bundleIdentifier == RexCLI.serverBundleIdentifier {
            self = .rex
            return
        }
        // Likewise a walk from a Herdr terminal reaches herdr-core's holder (Herdr Core.app), which runs every
        // Herdr terminal; the app that shows them is Herdr.app.
        if bundleIdentifier == HerdrAppCLI.coreBundleIdentifier {
            self = .herdrApp
            return
        }
        guard let host = TerminalHost.terminals.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }
        self = host
    }

    /// The user-defaults key holding the switch. Ghostty keeps the key of the former single
    /// Ghostty controls switch, so its stored choice carries over unchanged.
    public var defaultsKey: String {
        self == .ghostty ? "ghosttyControlsEnabled" : "\(rawValue)HostEnabled"
    }
}

/// The position of every host's switch. Pure value: reading and writing preferences, and the
/// Automation flow that can switch Ghostty back off, belong to the app.
public struct TerminalHostSwitches: Equatable, Sendable {
    public private(set) var enabled: Set<TerminalHost>

    public init(enabled: Set<TerminalHost> = []) {
        self.enabled = enabled
    }

    public func isOn(_ host: TerminalHost) -> Bool { enabled.contains(host) }

    public mutating func set(_ host: TerminalHost, on: Bool) {
        if on { enabled.insert(host) } else { enabled.remove(host) }
    }

    public var anyTerminalOn: Bool { TerminalHost.terminals.contains(where: isOn) }

    /// Whether Herdly may scan or contact `host` at all: its switch is on and, for a multiplexer,
    /// a terminal is on too, because a multiplexer is reached through a terminal tab (ADR 0014).
    /// Each integration still applies its own gate on top of this.
    public func mayContact(_ host: TerminalHost) -> Bool {
        isOn(host) && (host.kind == .terminal || anyTerminalOn)
    }

    /// The switches from stored preferences, and the values to write back.
    ///
    /// Before per-host switches herdr worked whenever Ghostty controls were on, so a missing herdr
    /// value starts where the Ghostty switch is (off when Ghostty has no stored choice either) and
    /// is written back, so a later Ghostty change no longer moves it. Every other missing value is
    /// off and needs no write.
    public static func restore(stored: [TerminalHost: Bool]) -> (switches: TerminalHostSwitches,
                                                                 toPersist: [TerminalHost: Bool]) {
        var switches = TerminalHostSwitches()
        var toPersist: [TerminalHost: Bool] = [:]
        for host in TerminalHost.allCases {
            if let value = stored[host] {
                switches.set(host, on: value)
            } else if host == .herdr {
                let value = stored[.ghostty] ?? false
                switches.set(host, on: value)
                toPersist[host] = value
            }
        }
        return (switches, toPersist)
    }
}
