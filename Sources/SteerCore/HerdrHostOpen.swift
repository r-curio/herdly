import Foundation

// ADR 0014 generalizes herdr's Ghostty-only gate (ADR 0009) and Ghostty tty join (ADR 0011) to every
// enabled terminal host (#241). A herdr client hosted by Ghostty keeps ADR 0011's sequence exactly
// (`HerdrOpenSequence`); a client hosted by another enabled host joins that host's tab by tty
// (`MultiplexerHostTab`) and is raised by that host's own Open. Pure; SteerApp runs the steps.

extension TerminalHost {
    /// The executable a terminal app's process runs (its `Contents/MacOS` name), which a multiplexer
    /// client's ancestry must reach; nil for a multiplexer.
    public var executableName: String? {
        switch self {
        case .ghostty: "ghostty"
        case .iTerm2: "iTerm2"
        case .terminalApp: "Terminal"
        case .wezTerm: "wezterm-gui"
        case .tmux, .zellij, .herdr: nil
        }
    }

    public static func executableNames(of hosts: Set<TerminalHost>) -> Set<String> {
        Set(hosts.compactMap(\.executableName))
    }
}

/// What step 1 established for a herdr pane whose client runs in another host's tab.
public struct HerdrHostOpenPlan: Equatable, Sendable {
    public let pane: HerdrPaneTarget
    public let clientPID: Int32
    /// Normalized `/dev/ttysNNN`.
    public let clientTTY: String
    public let host: MultiplexerHostTarget

    public init(pane: HerdrPaneTarget, clientPID: Int32, clientTTY: String, host: MultiplexerHostTarget) {
        self.pane = pane
        self.clientPID = clientPID
        self.clientTTY = clientTTY
        self.host = host
    }
}

/// A herdr step's own typed reason (shown and resolved as ADR 0011's), or a host-tab step's ADR 0015 miss.
public enum HerdrHostOpenFailure: Error, Equatable, Sendable {
    case herdr(HerdrOpenFailure)
    case host(OpenMiss)
}

public enum HerdrHostOpen {
    /// Step 1: the herdr half exactly as ADR 0011 checks it, then the client's tty joined to one tab of
    /// the enabled hosts.
    public static func plan(binding: HerdrSessionBinding, outcome: HerdrScanOutcome?,
                            join: (String) -> MultiplexerHostJoin) -> Result<HerdrHostOpenPlan, HerdrHostOpenFailure> {
        if let failure = HerdrOpen.herdrFailure(binding: binding, outcome: outcome) { return .failure(.herdr(failure)) }
        guard let pane = binding.target, let client = HerdrOpen.attachedClient(outcome), let tty = client.tty else {
            return .failure(.herdr(.clientTTYUnknown))
        }
        switch join(tty) {
        case .tab(let tab): return .success(HerdrHostOpenPlan(pane: pane, clientPID: client.pid, clientTTY: tty, host: .tab(tab)))
        case .ghostty: return .success(HerdrHostOpenPlan(pane: pane, clientPID: client.pid, clientTTY: tty, host: .ghostty))
        case .miss(let miss): return .failure(.host(miss))
        }
    }

    /// Step 3, as ADR 0011's: the fresh binding is the same pane, herdr focuses it, the client is unchanged.
    public static func verifyPane(_ plan: HerdrHostOpenPlan, binding: HerdrSessionBinding,
                                  outcome: HerdrScanOutcome?) -> HerdrHostOpenFailure? {
        HerdrOpen.verifyPane(plan.pane, clientPID: plan.clientPID, clientTTY: plan.clientTTY, binding: binding,
                             outcome: outcome).map(HerdrHostOpenFailure.herdr)
    }
}

/// The titles of the enabled hosts' known inventories for herdr's Codex gate and route (ADR 0012 as
/// ADR 0014 reads it: "any enabled host's inventory is known").
public enum HerdrHostTitles {
    /// While Ghostty's controls are on, Ghostty's known inventory alone, unchanged; otherwise the union of
    /// every other enabled host's latest known titles (iTerm2, Terminal.app, WezTerm), nil while none is known.
    public static func known(ghosttyEnabled: Bool, ghostty: Set<String>?, otherHosts: [Set<String>?]) -> Set<String>? {
        if ghosttyEnabled { return ghostty }
        let known = otherHosts.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(into: Set<String>()) { $0.formUnion($1) }
    }
}
