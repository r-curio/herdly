import Foundation

// ADR 0015 and its 2026-10-11 amendment: an Open fallback. When Open cannot reach the exact tab or
// pane but the session is live and its terminal app is identified and running, Herdly raises that app
// as a whole and nothing more. Everything here is a pure function of observations HerdlyApp passes in
// (process walks, tty modification times, whether an app is running); activating the app belongs to
// HerdlyApp. A fallback never selects a window, tab or pane, acknowledges nothing, and is never an
// input target.

/// Where a walk from a process up its parents ended (ADR 0015, "Which app and window").
public enum TerminalAppWalk: Equatable, Sendable {
    /// The nearest app above the process is this supported terminal app.
    case reached(TerminalHost)
    /// The nearest app above the process is not a supported terminal app.
    case unsupportedApp
    /// No app was found: the process exited, could not be read, or its ancestry reaches no app
    /// (a multiplexer server under launchd, for example).
    case failed

    /// The walk over one ancestry, from the process itself up: each entry is the bundle identifier
    /// of the app whose main executable that process runs, or nil for a process that is not an app.
    /// The nearest app decides, so a terminal above an unsupported app is never reached.
    public init(ancestorBundleIdentifiers: [String?]) {
        guard let nearest = ancestorBundleIdentifiers.lazy.compactMap({ $0 }).first else {
            self = .failed
            return
        }
        self = TerminalHost(bundleIdentifier: nearest).map(TerminalAppWalk.reached) ?? .unsupportedApp
    }
}

/// Why Open is unavailable rather than falling back (ADR 0015, "When Open falls back"). Each case is
/// one of the agreed card lines (docs/product.md, "Agreed terminal host presentation").
public enum OpenUnavailableReason: Error, Equatable, Hashable, Sendable {
    /// The host cannot be read: a scripting error, Automation denied, or a socket that is missing or
    /// fails its trust check. Raising the app would hide a problem the user must fix.
    case hostUnreadable(TerminalHost)
    /// The session's process is gone or its tab is closed.
    case sessionEnded
    /// The identified terminal app is not running. Herdly never launches it.
    case appNotRunning(TerminalHost)
    /// The session's terminal app cannot be identified (ADR 0015 and its amendment).
    case appNotIdentified
    /// The identified app was still running but macOS did not activate it. Click-time only; not one of
    /// the agreed card causes, so it is never claimed as "isn't running".
    case activationFailed(TerminalHost)

    /// The one line that replaces Open on a card, and the click's message.
    public var cardLine: String {
        switch self {
        case .hostUnreadable(let host): "Herdly can't read \(host.displayName). Check Settings › Terminals."
        case .sessionEnded: "This session has ended."
        case .appNotRunning(let host): "\(host.displayName) isn't running."
        case .appNotIdentified: "Herdly can't tell which terminal this session is in."
        case .activationFailed(let host): "Herdly couldn't bring \(host.displayName) forward."
        }
    }
}

/// An Open step that did not reach the exact target: either it may fall back, or it is unavailable.
/// It has no exact case, so resolving one can never report a verified Open.
public enum OpenMiss: Error, Equatable, Sendable {
    /// The exact target cannot be reached. `candidates` is how many tabs in the host's own inventory
    /// carry the session's title, which identifies the app for a Codex session.
    case fallBack(OpenFallbackReason, candidates: Int)
    case unavailable(OpenUnavailableReason)
}

/// One tab carrying a Codex session's title, as the amendment's walk sees it: where the walk from the
/// tab's single foreground `codex` ended, and when the tab's tty device was last modified (Unix
/// seconds, nil when it could not be read).
public struct CodexOpenCandidate: Equatable, Sendable {
    public let walk: TerminalAppWalk
    public let ttyWrittenAt: Double?

    public init(walk: TerminalAppWalk, ttyWrittenAt: Double?) {
        self.walk = walk
        self.ttyWrittenAt = ttyWrittenAt
    }
}

public enum OpenFallback {
    /// Two candidates whose tty times are this close or closer cannot be ordered (the amendment).
    public static let recencyTie: Double = 1

    /// The app a Codex CLI session's fallback raises (ADR 0015 amendment). Candidates come from the
    /// enabled hosts' inventories. Every walk must reach a supported, switched-on terminal app: a
    /// session in a switched-off app is never seen there, so it cannot be identified. When the walks
    /// reach different apps, the candidate whose tty was written most recently decides; an unreadable
    /// time, or any two candidates within `recencyTie` of each other, cannot be identified. This is a
    /// guess the user accepted for a rare case; it never selects a tab.
    public static func codexApp(candidates: [CodexOpenCandidate],
                                switches: TerminalHostSwitches) -> Result<TerminalHost, OpenUnavailableReason> {
        var apps: [TerminalHost] = []
        for candidate in candidates {
            guard case .reached(let host) = candidate.walk, switches.isOn(host) else { return .failure(.appNotIdentified) }
            apps.append(host)
        }
        guard let first = apps.first else { return .failure(.appNotIdentified) }
        if apps.allSatisfy({ $0 == first }) { return .success(first) }
        let times = candidates.compactMap(\.ttyWrittenAt)
        guard times.count == candidates.count, times.allSatisfy(\.isFinite) else { return .failure(.appNotIdentified) }
        let ordered = zip(times, apps).sorted { $0.0 < $1.0 }
        for (earlier, later) in zip(ordered, ordered.dropFirst()) where later.0 - earlier.0 <= recencyTie {
            return .failure(.appNotIdentified)
        }
        return .success(ordered[ordered.count - 1].1)
    }

    /// The app a fallback raises from walks of live processes: a Claude session's registry process,
    /// or each client attached to the session's multiplexer (ADR 0015, continuing from ADR 0014's host
    /// join). Every walk must reach the same supported terminal app; none, a failed walk, an unsupported
    /// app, or clients in different apps cannot be identified. A Claude session in a switched-off app
    /// still falls back, because its own process names the app; a Codex session there does not
    /// (the amendment).
    public static func processApp(walks: [TerminalAppWalk], agent: AgentSource,
                                  switches: TerminalHostSwitches) -> Result<TerminalHost, OpenUnavailableReason> {
        guard case .reached(let host)? = walks.first,
              walks.allSatisfy({ $0 == .reached(host) }) else { return .failure(.appNotIdentified) }
        guard agent == .claude || switches.isOn(host) else { return .failure(.appNotIdentified) }
        return .success(host)
    }

    /// The result of an Open that could not reach its exact target for `reason`: the identified app
    /// is raised only while it is running. Herdly never launches it.
    public static func resolve(_ reason: OpenFallbackReason, app: Result<TerminalHost, OpenUnavailableReason>,
                               isRunning: (TerminalHost) -> Bool) -> TerminalOpenResult {
        switch app {
        case .failure(let unavailable): return .unavailable(unavailable)
        case .success(let host):
            return isRunning(host) ? .fellBack(host, reason) : .unavailable(.appNotRunning(host))
        }
    }

    /// The result of a miss: unavailable stays so; a fallback identifies the app from the number of
    /// title candidates and raises it only while running.
    /// `app` is consulted only for a fallback.
    public static func resolve(_ miss: OpenMiss, app: (Int) -> Result<TerminalHost, OpenUnavailableReason>,
                               isRunning: (TerminalHost) -> Bool) -> TerminalOpenResult {
        switch miss {
        case .unavailable(let reason): return .unavailable(reason)
        case .fallBack(let reason, let candidates): return resolve(reason, app: app(candidates), isRunning: isRunning)
        }
    }

    /// A fallback after HerdlyApp tried to activate its app. A failed activation is "isn't running" only
    /// when a fresh running check says so; otherwise it is `activationFailed`. Other results pass through.
    public static func afterActivation(_ result: TerminalOpenResult, activated: Bool,
                                       stillRunning: Bool) -> TerminalOpenResult {
        guard case .fellBack(let host, _) = result, !activated else { return result }
        return .unavailable(stillRunning ? .activationFailed(host) : .appNotRunning(host))
    }
}

/// Why an Open could not reach its exact target but may fall back (ADR 0015, "When Open falls back";
/// ADR 0016, "Failures"). For diagnostics; the card shows nothing for any of them.
public enum OpenFallbackReason: Equatable, Hashable, Sendable {
    /// Zero or several tabs or panes match, including colliding titles and a Ghostty without `tty`
    /// outside ADR 0011's sole-terminal rule.
    case noUniqueTarget
    /// A split tab, a multiplexer with several panes or clients, or an exact tab in a window the
    /// host's Open does not cross to.
    case unsupportedLayout
    /// An exact step succeeded and verified, but a later one could not; the verified steps are kept.
    case partialReach
    /// A select or raise command failed without showing the target gone, or its result did not
    /// verify (ADR 0016).
    case notVerified
}

/// What one Open did. Only `opened` is a verified visit: a fallback raised an app without selecting a
/// window, tab or pane, so it acknowledges nothing, clears nothing, and never makes anything an input
/// target; typed input keeps requiring the exact binding.
public enum TerminalOpenResult: Equatable, Sendable {
    case opened
    case fellBack(TerminalHost, OpenFallbackReason)
    case unavailable(OpenUnavailableReason)

    /// Whether this Open acknowledges the session's completions (ADR 0016, "Acknowledgment").
    public var acknowledges: Bool { self == .opened }

    /// Whether this Open hands its actionable request back with no decision or answer (ADR 0015,
    /// #411): it reached the session or raised its app. An unavailable Open hands nothing back, so the
    /// request stays where it was.
    public var handsBackRequest: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// The agreed line for an unavailable Open; nil otherwise. A fallback is silent (ADR 0015,
    /// "Presentation"), and a verified Open's host says what opened.
    public var unavailableLine: String? {
        if case .unavailable(let reason) = self { return reason.cardLine }
        return nil
    }
}
