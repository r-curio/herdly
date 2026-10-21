import Foundation

extension AgentAttentionKind {
    /// A result row (D20, #322): a recent or Earlier result, a Claude session waiting, or one whose
    /// status is unavailable. In the open queue it is one line, and a click or Return opens its
    /// session; requests open as their card and a working row opens in place instead.
    public var opensSession: Bool {
        switch self {
        case .outcome, .earlierOutcome, .waiting, .statusUnavailable: true
        case .actionableApproval, .question, .handedBackApproval, .running: false
        }
    }
}

/// Whether a click on a result row can take the user to its session (#322, 8J1): reachable when
/// Herdly offers Open for the session, unreachable when the latest observations rule Open out. It
/// is decided from what the scans saw; a reachable row's click still revalidates the exact target
/// through the session's usual Open route and may only raise its app (ADR 0015), and nothing here
/// selects a target or acknowledges anything.
public enum ResultRowTarget: Equatable, Sendable {
    case reachable
    case unreachable

    /// - Parameters:
    ///   - herdr: the session's herdr Open availability as the notch presents it; any unavailable
    ///     cause rules Open out.
    ///   - scanOffersOpen: the terminal scan has not found Open unavailable (no scan line); true for a
    ///     session the scan does not cover, such as a Codex app thread.
    ///   - codexSessionKnown: a Codex identity names a session Herdly can open (a readable session id).
    ///   - claudeOpenable: a Claude CLI session is live exactly once in complete inventories and Ghostty,
    ///     when on, has its permission (`Companion.canOpenClaude`).
    public static func resolve(source: AgentSource, herdr: HerdrOpenAvailability, scanOffersOpen: Bool,
                               codexSessionKnown: Bool, claudeOpenable: Bool) -> ResultRowTarget {
        if case .unavailable = herdr { return .unreachable }
        switch source {
        case .codex:
            return codexSessionKnown && scanOffersOpen ? .reachable : .unreachable
        case .claude:
            // A herdr pane opens through herdr's own binding; outside herdr the inventories and the
            // terminal scan both have to allow it.
            if herdr == .available { return .reachable }
            return claudeOpenable && scanOffersOpen ? .reachable : .unreachable
        }
    }
}

/// The panel folding back after a result row opened its session (8DW step 2). The Open runs off the
/// main path, so the fold waits for it to finish: an Open that leaves a reason line on the row (a
/// click-time recheck that found the session unavailable) keeps the panel open so the line is seen;
/// any other finish folds it. Presentation only: it never acknowledges or dismisses anything.
public struct RowOpenFold: Equatable, Sendable {
    public enum Settlement: Equatable, Sendable {
        /// No Open from a row is pending, or it is still running.
        case none
        /// The Open finished without a reason line: fold the panel back.
        case collapse
        /// The Open finished with a reason line on the row: keep the panel so the line shows.
        case stay
    }

    public private(set) var pending: AgentSessionIdentity?

    public init() {}

    public mutating func begin(_ session: AgentSessionIdentity) { pending = session }

    /// Forgets a pending Open, as when the panel collapses by other means.
    public mutating func cancel() { pending = nil }

    /// - Parameters:
    ///   - opening: an Open is still running.
    ///   - showsLine: the pending session's row now shows a reason line for Open.
    public mutating func settle(opening: Bool, showsLine: Bool) -> Settlement {
        guard pending != nil, !opening else { return .none }
        pending = nil
        return showsLine ? .stay : .collapse
    }
}
