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

/// Whether a click on a result row can take the user to its session (#322, 8J1).
public enum ResultRowTarget: Equatable, Sendable {
    case reachable
    case unreachable
}

/// The line a result row shows under its name: why Open is not offered, or why the last click did
/// not open. Each case is copy the cards already show (product.md, "Open unavailable").
public enum ResultRowLine: Equatable, Sendable {
    /// herdr's grouped reason line (`HerdrPresentation.cardLine`).
    case herdr(HerdrUnavailableCause)
    /// The terminal scan's line, or a click's (`OpenUnavailableLines.cardLine`).
    case terminal(OpenUnavailableReason)
    /// A Claude session no longer live: the app its process last walked to (#280).
    case claudeLastSeen(OpenUnavailableReason)
    /// A Claude session Herdly cannot verify as live (`Companion.claudeReturnUnavailableMessage`).
    case claudeNotVerified
}

/// What the latest scans observed about reaching a row's session. Every field is an observation the
/// cards already read; nothing here contacts a host or selects a target.
public struct ResultRowObservation: Equatable, Sendable {
    public var source: AgentSource
    /// herdr's Open availability as the notch presents it (`HerdrOpenAvailability.presented`).
    public var herdr: HerdrOpenAvailability
    /// The terminal scan has not found Open unavailable; true for a session it does not cover, such
    /// as a Codex app thread.
    public var scanOffersOpen: Bool
    /// The terminal line the card would show: the scan's, otherwise a click's.
    public var terminalLine: OpenUnavailableReason?
    /// A Codex identity names a session Herdly can open (a readable session id).
    public var codexSessionKnown: Bool
    /// A Codex terminal session while every terminal host is switched off: the scan skips it and its
    /// app cannot be identified (ADR 0015's amendment). Always false for a Codex app thread.
    public var codexTerminalHostsOff: Bool
    /// A Claude CLI session is live exactly once in complete inventories and Ghostty, when on, has
    /// its permission (`Companion.canOpenClaude`).
    public var claudeOpenable: Bool
    /// A Claude background (parked) session.
    public var claudeBackground: Bool
    /// The last-seen app's line for a Claude session that is no longer live (#280).
    public var claudeLastSeen: OpenUnavailableReason?

    /// Every input is required, so a missing observation can never read as reachable.
    public init(source: AgentSource, herdr: HerdrOpenAvailability, scanOffersOpen: Bool,
                terminalLine: OpenUnavailableReason?, codexSessionKnown: Bool, codexTerminalHostsOff: Bool,
                claudeOpenable: Bool, claudeBackground: Bool, claudeLastSeen: OpenUnavailableReason?) {
        self.source = source
        self.herdr = herdr
        self.scanOffersOpen = scanOffersOpen
        self.terminalLine = terminalLine
        self.codexSessionKnown = codexSessionKnown
        self.codexTerminalHostsOff = codexTerminalHostsOff
        self.claudeOpenable = claudeOpenable
        self.claudeBackground = claudeBackground
        self.claudeLastSeen = claudeLastSeen
    }
}

/// One reading of a result row's session (#322): whether a click can reach it, and the line under
/// its name. The word, the line, the click and Return all read it. A reachable row's click still
/// revalidates the exact target through the session's usual Open and may only raise its app (ADR
/// 0015); nothing here acknowledges anything. An unreachable row always has a line.
public struct ResultRowReading: Equatable, Sendable {
    public let target: ResultRowTarget
    public let line: ResultRowLine?

    public init(target: ResultRowTarget, line: ResultRowLine?) {
        self.target = target
        self.line = line
    }

    public static func resolve(_ observed: ResultRowObservation) -> ResultRowReading {
        if case let .unavailable(cause) = observed.herdr { return unreachable(.herdr(cause)) }
        // The scan's own line; `terminalLine` is always set when the scan rules Open out.
        let scanLine = ResultRowLine.terminal(observed.terminalLine ?? .appNotIdentified)
        let clickLine = observed.terminalLine.map(ResultRowLine.terminal)
        switch observed.source {
        case .codex:
            // Adapters only file Codex sessions by their UUID, so an unreadable id is malformed data:
            // Herdly cannot tell where the session is, which is what this line says.
            guard observed.codexSessionKnown else { return unreachable(.terminal(.appNotIdentified)) }
            // A switched-off app cannot be identified, so with every host off no Open is offered.
            guard !observed.codexTerminalHostsOff else { return unreachable(.terminal(.appNotIdentified)) }
            guard observed.scanOffersOpen else { return unreachable(scanLine) }
            return ResultRowReading(target: .reachable, line: clickLine)
        case .claude:
            // A herdr pane opens through herdr's own binding; the Ghostty rules are not read.
            if observed.herdr == .available { return ResultRowReading(target: .reachable, line: nil) }
            guard observed.claudeOpenable else {
                if let lastSeen = observed.claudeLastSeen { return unreachable(.claudeLastSeen(lastSeen)) }
                // A background session's card shows the terminal line when there is one; otherwise
                // every not-live session says Herdly cannot verify it.
                if observed.claudeBackground, let clickLine { return unreachable(clickLine) }
                return unreachable(.claudeNotVerified)
            }
            guard observed.scanOffersOpen else { return unreachable(scanLine) }
            return ResultRowReading(target: .reachable, line: clickLine)
        }
    }

    private static func unreachable(_ line: ResultRowLine) -> ResultRowReading {
        ResultRowReading(target: .unreachable, line: line)
    }
}

extension HerdrOpenAvailability {
    /// herdr's availability as the notch presents it: with Ghostty controls off a herdr session keeps
    /// its Set up Ghostty path, so that one reason is presented by the Ghostty rules.
    public var presented: HerdrOpenAvailability {
        if case .unavailable(.session(.ghosttyControlsOff)) = self { return .notInHerdr }
        return self
    }
}

/// The panel folding back after a result row opened its session (8DW step 2). The Open runs off the
/// main path, so the fold waits for it to finish: an Open that leaves a reason line from this click
/// (a recheck that found the session unavailable, or a scan that ruled Open out meanwhile) keeps the
/// panel open so the line is seen; any other finish, an Open fallback included, folds it. A click
/// line older than this Open is stale and does not hold the panel. Presentation only: it never
/// acknowledges or dismisses anything.
public struct RowOpenFold: Equatable, Sendable {
    public enum Settlement: Equatable, Sendable {
        /// No Open from a row is pending, or it is still running.
        case none
        /// The Open finished without a new reason line: fold the panel back.
        case collapse
        /// The Open finished with a reason line from this click: keep the panel so the line shows.
        case stay
    }

    public private(set) var pending: AgentSessionIdentity?
    private var startedAt: Double = 0

    public init() {}

    public mutating func begin(_ session: AgentSessionIdentity, at now: Double) {
        pending = session
        startedAt = now
    }

    /// Forgets a pending Open, as when the panel collapses by other means.
    public mutating func cancel() { pending = nil }

    /// - Parameters:
    ///   - opening: an Open is still running.
    ///   - reading: the pending session's row reading now.
    ///   - clickLineAt: when its terminal click line was recorded (`OpenUnavailableLines.clickedAt`).
    public mutating func settle(opening: Bool, reading: ResultRowReading, clickLineAt: Double?) -> Settlement {
        guard pending != nil, !opening else { return .none }
        pending = nil
        if reading.target == .unreachable { return .stay }
        let fresh = clickLineAt.map { $0 >= startedAt } ?? false
        return reading.line != nil && fresh ? .stay : .collapse
    }
}
