import Foundation

/// Where one approval card stands at the card's own `now` (#320), and so which controls it offers.
/// It only reads the request's deadline; nothing here moves it, and only the user's own Approve or
/// Deny produces a decision. Whether the source can take a decision from Herdly at all (a Codex CLI
/// request, or a Claude request with a verified live receipt) is the app's check on top of this.
public enum ApprovalCardStage: Equatable, Sendable {
    /// Before the deadline: Approve, Deny, and Open, with the seconds left.
    case live(ApprovalCountdown)
    /// The card's clock has reached the deadline but the hand-back is not recorded yet. Approve and
    /// Deny stay in place but cannot be pressed, and no countdown shows (never "0s left").
    case expired
    /// Handed back with no decision: only Open, to decide in the agent itself.
    case handedBack

    /// The card stage of an approval row; nil for every other row.
    public init?(_ item: AgentAttentionItem, now: Double) {
        guard let approval = item.approval else { return nil }
        switch item.kind {
        case .handedBackApproval:
            self = .handedBack
        case .actionableApproval:
            self = ApprovalCountdown(arrivedAt: approval.arrivedAt, expiresAt: approval.expiresAt, now: now)
                .map(Self.live) ?? .expired
        case .question, .waiting, .outcome, .earlierOutcome, .statusUnavailable, .running:
            return nil
        }
    }

    public var countdown: ApprovalCountdown? {
        if case let .live(countdown) = self { return countdown }
        return nil
    }

    /// Approve and Deny can be pressed.
    public var offersDecision: Bool { countdown != nil }

    /// Approve and Deny are drawn, pressable or not. A handed-back card offers only Open.
    public var showsDecisionControls: Bool { self != .handedBack }

    /// Open's visible label. Beside Approve and Deny it is plain "Open"; once handed back it names
    /// the agent the user now decides in. VoiceOver keeps "Open Session: <subject>" either way.
    public func openTitle(for source: AgentSource) -> String {
        self == .handedBack ? "Open in \(source.displayName)" : "Open"
    }
}

/// The word after the place in a single approval card's header. The open queue's rows carry no
/// kind word (D17); only the card does.
public enum ApprovalCardKindWord: Equatable, Sendable {
    /// "Approve" in a well pill while the request can still be decided here.
    case approve
    /// The queue's own exception word, such as "Handed back".
    case exception(RowException)

    /// The kind word of an approval row's card: "Handed back" once handed back; "Approve" only while
    /// `decidable`, the source taking a decision from Herdly (a Codex CLI request, or a Claude request
    /// with a verified live helper); otherwise none, since the request is decided in the agent. Nil
    /// for every other row. It reads the row's kind, not a clock, so a request past its deadline
    /// keeps "Approve" until its hand-back is recorded.
    public init?(_ item: AgentAttentionItem, decidable: Bool) {
        switch item.kind {
        case .handedBackApproval: self = .exception(.handedBack)
        case .actionableApproval where decidable: self = .approve
        default: return nil
        }
    }

    public var word: String {
        switch self {
        case .approve: "Approve"
        case let .exception(exception): exception.word
        }
    }
}
