import Foundation

// Host-neutral (added by #238 for iTerm2; any tty-bound host can use it): where an Open goes from a
// fresh ADR 0013 tab binding (the exact tab, Ghostty's title route, or a miss that ADR 0015 resolves to
// a fallback or an unavailable line), the Codex title carriers ADR 0015's amendment walks to find the
// app, and which host's route keeps a Codex session. Pure; SteerApp takes the reads. Host-specific steps
// live in each host's own file.

public enum TerminalTabOpenRoute: Equatable, Sendable {
    /// The session is bound to this tab; the host's Open selects, raises and verifies it (ADR 0016).
    case exact(TerminalTabTarget)
    /// The only tab carrying the title is in a Ghostty without `tty`: ADR 0005's title route decides
    /// (ADR 0013, "Ghostty").
    case ghosttyTitle
    case miss(OpenMiss)
}

/// One enabled tab carrying a Codex session's title, as ADR 0015's amendment walks it: from the tab's
/// single foreground `codex` (`codexPID`, nil when there is none or the tty could not be read). A
/// Ghostty tab has no tty until Ghostty exposes it (ADR 0013), so it is in Ghostty by its own inventory.
public struct TerminalCodexCarrier: Equatable, Hashable, Sendable {
    public let host: TerminalHost
    public let tty: String?
    public let codexPID: Int32?

    public init(host: TerminalHost, tty: String?, codexPID: Int32?) {
        self.host = host
        self.tty = tty
        self.codexPID = codexPID
    }
}

public enum TerminalTabOpen {
    /// Every tab of every enabled terminal host showing `title`, except a title decoy: its `ps -t` shows no
    /// foreground `codex`, so it is skipped rather than failing the walk (ADR 0015's 2026-10-13 amendment,
    /// #268; `TerminalTabBindingRules.isCodexTitleDecoy`). A titled tab whose `ps` was not read stays, with
    /// no `codex` to walk from. Hosts switched off, not running or unreadable contribute nothing; an
    /// unreadable host already makes the Open unavailable.
    public static func codexCarriers(title: String, switches: TerminalHostSwitches,
                                     inventories: [TerminalHost: TerminalHostInventory],
                                     processes: [String: [TerminalProcess]]) -> [TerminalCodexCarrier] {
        var carriers: [TerminalCodexCarrier] = []
        for host in TerminalHost.terminals where switches.mayContact(host) {
            guard case .tabs(let tabs)? = inventories[host] else { continue }
            for tab in tabs where tab.title == title
                && !TerminalTabBindingRules.isCodexTitleDecoy(tab, processes: processes) {
                let tty = tab.tty.flatMap(GhosttyTTYMatch.normalizedTTY)
                let codex = tty.flatMap { processes[$0] }?
                    .filter { $0.foreground && $0.name == HerdrCodexBindingRules.processName }
                carriers.append(TerminalCodexCarrier(host: host, tty: tty,
                                                     codexPID: codex?.count == 1 ? codex?.first?.pid : nil))
            }
        }
        return carriers
    }

    /// The amendment's candidates: a walk from each carrier's `codex` and its tty's modification time.
    /// A tty-less Ghostty carrier is in Ghostty with no time (`GhosttyTitleOpen.codexCandidates`); any
    /// other carrier without a `codex` to walk from cannot be identified, so `OpenFallback.codexApp`
    /// never guesses past it.
    public static func codexCandidates(_ carriers: [TerminalCodexCarrier], walk: (Int32) -> TerminalAppWalk,
                                       ttyWrittenAt: (String) -> Double?) -> [CodexOpenCandidate] {
        carriers.map { carrier in
            if carrier.host == .ghostty, carrier.tty == nil {
                return CodexOpenCandidate(walk: .reached(.ghostty), ttyWrittenAt: nil)
            }
            return CodexOpenCandidate(walk: carrier.codexPID.map(walk) ?? .failed,
                                      ttyWrittenAt: carrier.tty.flatMap(ttyWrittenAt))
        }
    }

    /// Whether `host`'s own Open route keeps a Codex session, given whether one of its tabs or panes carries
    /// the session's title and the cross-host binding (ADR 0013) on the same reads. A title decoy (no
    /// foreground `codex`, #268) may sit in one host while the binding names a tab in another; that session
    /// goes on to the route of the host holding it rather than falling back here. A session bound nowhere
    /// stays with every host carrying its title, whose Open reports the miss.
    public static func codexStays(in host: TerminalHost, carriesTitle: Bool, binding: TerminalTabBinding) -> Bool {
        guard carriesTitle else { return false }
        if case .bound(let target) = binding { return target.host == host }
        return true
    }

    /// The route for a binding re-run on fresh reads, immediately before Open (ADR 0013, "Freshness").
    public static func route(_ binding: TerminalTabBinding) -> TerminalTabOpenRoute {
        switch binding {
        case .bound(let target): return .exact(target)
        case .unavailable(.ttyUnknown(.ghostty)): return .ghosttyTitle
        case .unavailable(let reason): return .miss(miss(reason))
        }
    }

    /// ADR 0015's categories: an unreadable host, an ended session or a process that cannot be followed
    /// stays unavailable; no unique target or an unsupported layout falls back. `candidates` counts the
    /// tabs carrying a Codex title where the reason says (zero or several); elsewhere it is one.
    public static func miss(_ reason: TerminalTabUnavailable) -> OpenMiss {
        switch reason {
        case .hostUnreadable(let host): .unavailable(.hostUnreadable(host))
        // The process is gone, its PID was reused, or Codex no longer lists the session as live.
        case .sessionEnded, .sessionNotLive, .processEnded, .processStartMismatch: .unavailable(.sessionEnded)
        // No single process names the session's app (ADR 0015, "Which app and window").
        case .processUnidentified, .processAmbiguous: .unavailable(.appNotIdentified)
        case .split: .fallBack(.unsupportedLayout, candidates: 1)
        case .titleNotFound: .fallBack(.noUniqueTarget, candidates: 0)
        case .duplicateTitles(let count): .fallBack(.noUniqueTarget, candidates: count)
        case .sessionPrefixNotUnique, .ttyUnknown, .titleChanged, .foregroundProcesses, .processesUnreadable,
             .noTerminal, .ttyNotInEnabledHost, .duplicateTTYs, .conflictingTitle, .agentProcessNotInForeground:
            .fallBack(.noUniqueTarget, candidates: 1)
        }
    }
}
