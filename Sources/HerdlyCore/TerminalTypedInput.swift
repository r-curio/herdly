import Foundation

// ADR 0017: typed input, a session reply (and, on hosts that allow it, a question option's digit)
// typed into the one pane a session is bound to. This is the reply route beside the daemon's
// `turn/start`, kept host-neutral: each host supplies its bound pane, its own send for the writes
// below and how its send reports delivery. Approvals are never typed input. Everything here is pure;
// the host calls, the rollout and inventory reads, and the one-second pause belong to HerdlyApp.

extension TerminalHost {
    /// Whether Herdly types session replies into this host's bound pane (ADR 0017's table, as built).
    /// Terminal.app replies (#239), WezTerm replies (#240), Rex replies, tmux replies (#241), Zellij replies (#242).
    /// Ghostty and herdr only after a live proof of their text send; iTerm2 never (Broadcast Input).
    public var typesReplies: Bool {
        switch self {
        case .terminalApp, .wezTerm, .rex, .tmux, .zellij: true
        case .ghostty, .iTerm2, .herdr: false
        }
    }

    /// Whether a Codex question's digit may be typed here. Ghostty (ADR 0006) and herdr (ADR 0010) have
    /// their own relays. Terminal.app never: `do script`'s forced newline could answer the next
    /// question. iTerm2 never. WezTerm's relay (#240) is on since its live digit proof (#245,
    /// `WezTermInput.questionDigitsProvenLive`), tmux's (#241) since its own (#246,
    /// `TmuxInput.questionDigitsProvenLive`) and Zellij's (#242) since its own (#247,
    /// `ZellijInput.questionDigitsProvenLive`).
    public var typesQuestionDigits: Bool {
        switch self {
        case .ghostty, .herdr: true
        case .wezTerm: WezTermInput.questionDigitsProvenLive
        case .rex: RexInput.questionDigitsProvenLive
        case .tmux: TmuxInput.questionDigitsProvenLive
        case .zellij: ZellijInput.questionDigitsProvenLive
        case .terminalApp, .iTerm2: false
        }
    }
}

/// The one pane typed input may reach: its host and the host's own handle for it (a Terminal.app
/// tab-window id, a WezTerm pane id, a tmux `%pane`). `tty` is nil for a host that has none (Zellij).
public struct TypedInputPane: Equatable, Hashable, Sendable {
    public let host: TerminalHost
    public let paneID: String
    public let tty: String?

    public init(host: TerminalHost, paneID: String, tty: String?) {
        self.host = host
        self.paneID = paneID
        self.tty = tty
    }
}

/// Where a reply typed into a terminal would go for one session, from its fresh binding.
public enum TerminalReplyRoute: Equatable, Hashable, Sendable {
    /// The exact binding, on a host that types replies.
    case pane(TypedInputPane)
    /// No exact binding (switched off, no unique match, a split, two hosts, an unreadable host). An
    /// Open fallback is never an input target.
    case unreachable
    /// Bound on a host that never types (iTerm2).
    case hostCannotType(TerminalHost)

    /// The route for a tab binding (ADR 0013). nil leaves the session to the routes it already has: a
    /// tab bound in, or only titled by, a host whose replies are not built (Ghostty without `tty`), or a
    /// Zellij pane, which Zellij's own rule binds and routes (`ZellijInput.route`, #242).
    public static func from(_ binding: TerminalTabBinding) -> TerminalReplyRoute? {
        switch binding {
        case .bound(let target):
            if target.host.typesReplies {
                return .pane(TypedInputPane(host: target.host, paneID: target.tabID, tty: target.tty))
            }
            return target.host == .iTerm2 ? .hostCannotType(.iTerm2) : nil
        case .unavailable(.ttyUnknown(let host)) where !host.typesReplies || host == .zellij:
            return nil
        case .unavailable:
            return .unreachable
        }
    }

    /// One session's route from two hosts' latest scans (#240): a host that saw nothing leaves the other's
    /// route; the same pane agrees; anything else is not one exact pane, and a route that is not a pane
    /// wins over a pane, the first such route kept.
    public static func merging(_ first: TerminalReplyRoute?, _ second: TerminalReplyRoute?) -> TerminalReplyRoute? {
        guard let first else { return second }
        guard let second else { return first }
        switch (first, second) {
        case (.pane(let a), .pane(let b)): return a == b ? first : .unreachable
        case (.pane, _): return second
        default: return first
        }
    }
}

/// Why a typed reply's text is refused (ADR 0017, "Text").
public enum TypedReplyTextRejection: Error, Equatable, Sendable {
    case emptyText, textTooLong
    /// A newline or another control character: one line, plain text only.
    case notOneLine
    /// Starts with `/` or `!`, which would run a slash command or a shell command.
    case commandText
}

public enum TypedReplyText {
    public static let maximumLength = 4000

    /// The trimmed text, 1 to 4000 characters, one line without control characters, never starting with
    /// `/` or `!`.
    public static func sendable(_ text: String) -> Result<String, TypedReplyTextRejection> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyText) }
        guard trimmed.count <= maximumLength else { return .failure(.textTooLong) }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.notOneLine)
        }
        guard let first = trimmed.first, first != "/", first != "!" else { return .failure(.commandText) }
        return .success(trimmed)
    }
}

/// One write into the bound pane.
public enum TypedWrite: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The text, without submitting it.
    case text(String)
    /// The text and a submit in one write (Claude).
    case textAndSubmit(String)
    /// A submit alone (Codex's separate CR).
    case submit

    public var description: String {
        switch self {
        case .text(let text): "text(\"\(text)\")"
        case .textAndSubmit(let text): "textAndSubmit(\"\(text)\")"
        case .submit: "submit"
        }
    }
}

public enum TypedReplyWrites {
    /// Seconds between Codex's text and its separate submit.
    public static let submitDelay: Double = 1

    /// Claude submits text plus CR from one write on every host tested; Codex leaves that in its
    /// composer and needs a separate CR (every live proof).
    public static func plan(agent: AgentSource, text: String) -> [TypedWrite] {
        agent == .claude ? [.textAndSubmit(text)] : [.text(text), .submit]
    }
}

/// How one host write ended, from Herdly's side.
public enum TypedInputDelivery: Equatable, Sendable {
    /// The host reported the write done. The bytes reached the pane; the agent reading them is not
    /// established.
    case written
    /// The write may have reached the pane (a timeout, an error after the send began). It counts as
    /// sent and is never resent.
    case possiblyWritten
    /// Nothing was written.
    case notWritten

    public var countsAsSent: Bool { self != .notWritten }
}

/// What a fresh read shows immediately before a write (ADR 0017, "Fresh check").
public struct TypedReplyFreshState: Equatable, Sendable {
    /// The card's completion is still on the queue.
    public var completionQueued: Bool
    /// It belongs to the session's latest turn.
    public var latestTurn: Bool
    /// No turn is running: for Codex the rollout shows the turn ended; for Claude a fresh interactive
    /// inventory reading says idle.
    public var sessionIdle: Bool
    /// A question or approval of the session is pending.
    public var pendingInteraction: Bool
    /// The daemon now holds the thread, which would win the route.
    public var daemonHoldsThread: Bool
    /// The binding re-run on fresh reads (agent still in the foreground included).
    public var route: TerminalReplyRoute?

    public init(completionQueued: Bool, latestTurn: Bool, sessionIdle: Bool, pendingInteraction: Bool,
                daemonHoldsThread: Bool, route: TerminalReplyRoute?) {
        self.completionQueued = completionQueued
        self.latestTurn = latestTurn
        self.sessionIdle = sessionIdle
        self.pendingInteraction = pendingInteraction
        self.daemonHoldsThread = daemonHoldsThread
        self.route = route
    }
}

/// Why a typed reply was stopped before a write. Nothing was sent by that write.
public enum TypedReplyVeto: Error, Equatable, CaseIterable, Sendable {
    case notInQueue, notLatestTurn, sessionBusy, pendingInteraction, daemonHoldsThread, unreachable, paneChanged

    public var message: String {
        switch self {
        case .notInQueue: "This completion is no longer on the queue; nothing was sent."
        case .notLatestTurn: "The session has a newer turn; nothing was sent. Reply in the session."
        case .sessionBusy: "The session is working again; nothing was sent. Reply in the session."
        case .pendingInteraction: "The session is waiting on a question or approval; nothing was sent."
        case .daemonHoldsThread: "Codex's daemon now holds this session; nothing was sent. Reply in Codex."
        case .unreachable, .paneChanged: "Herdly can't reach this session's tab; nothing was sent. Reply in the session."
        }
    }
}

public enum TypedReplyCheck {
    /// nil when the write may go to `spent`, the pane the click chose.
    public static func veto(_ state: TypedReplyFreshState, spent: TypedInputPane) -> TypedReplyVeto? {
        guard state.completionQueued else { return .notInQueue }
        guard state.latestTurn else { return .notLatestTurn }
        guard state.sessionIdle else { return .sessionBusy }
        guard !state.pendingInteraction else { return .pendingInteraction }
        guard !state.daemonHoldsThread else { return .daemonHoldsThread }
        guard case .pane(let pane)? = state.route else { return .unreachable }
        return pane == spent ? nil : .paneChanged
    }
}

/// How one typed reply ended.
public enum TypedReplyRun: Equatable, Sendable {
    public enum NotSent: Equatable, Sendable {
        case vetoed(TypedReplyVeto)
        case notWritten
    }

    /// Nothing reached the pane; the card says why and never retries.
    case notSent(NotSent)
    /// Every write counts as sent.
    case sent
    /// Codex's text counts as sent but its submit did not go: the text may be waiting in the composer,
    /// and Herdly never presses Enter later.
    case sentTextOnly
}

public enum TypedReplySequence {
    /// Sends `writes` in order, each at most once, with a fresh check immediately before each and
    /// `TypedReplyWrites.submitDelay` before a submit that follows text. The first write that is
    /// vetoed or certainly not written ends the run; once text counts as sent, nothing is retried.
    public static func run(writes: [TypedWrite], check: () async -> TypedReplyVeto?,
                           write: (TypedWrite) async -> TypedInputDelivery,
                           pause: (Double) async -> Void,
                           isolation: isolated (any Actor)? = #isolation) async -> TypedReplyRun {
        var sentAny = false
        for (index, next) in writes.enumerated() {
            if index > 0, next == .submit { await pause(TypedReplyWrites.submitDelay) }
            if let veto = await check() { return sentAny ? .sentTextOnly : .notSent(.vetoed(veto)) }
            let delivery = await write(next)
            guard delivery.countsAsSent else { return sentAny ? .sentTextOnly : .notSent(.notWritten) }
            sentAny = true
        }
        return .sent
    }
}

/// The fresh check behind Ghostty's question key while other terminal hosts are switched on (ADR 0013
/// "Inventory" and "Freshness", ADR 0017's question fresh check). Ghostty binds Codex by title alone, so
/// the key may go only when every other enabled host was read fresh and none carries the session's
/// title. Host-neutral: each host's fresh inventory is passed in.
public enum TerminalKeyRelayCheck {
    /// The enabled hosts other than Ghostty that must be read fresh before a Ghostty key: every terminal,
    /// tmux and Zellij, whose panes carry Codex titles too (#241, #242).
    public static func hostsToRead(switches: TerminalHostSwitches) -> [TerminalHost] {
        TerminalHost.titleCounted.filter { $0 != .ghostty && switches.mayContact($0) }
    }

    /// nil when the key may go. A host missing from `fresh` or unreadable fails closed; a host whose tab
    /// carries `title` holds the session, which gets no Ghostty key, unless that tab is a title decoy
    /// (`TerminalTabBindingRules.isCodexTitleDecoy` over `processes`, `ps -t` read after `fresh`; #268). A
    /// titled tab whose `ps` was not read still vetoes.
    public static func ghosttyVeto(title: String, processes: [String: [TerminalProcess]], switches: TerminalHostSwitches,
                                   fresh: [TerminalHost: TerminalHostInventory]) -> HerdrQuestionRelayUnavailable? {
        for host in hostsToRead(switches: switches) {
            switch fresh[host] {
            case .notRunning?: continue
            case .tabs(let tabs)?:
                if TerminalTabBindingRules.carriesCodexTitle(tabs, title: title, processes: processes) {
                    return .noQuestionKeys(host)
                }
            case .unreadable?, nil:
                return .otherHostUnreadable(host)
            }
        }
        return nil
    }
}

/// Terminal.app's send (ADR 0017): `do script "<text>" in <tab>`, which always appends a newline.
public enum TerminalAppInput {
    /// The text one `do script` carries for a write. The forced newline is Claude's submit; Codex's text
    /// stays in its composer, and its submit is a second, empty `do script`.
    public static func script(_ write: TypedWrite) -> String {
        switch write {
        case .text(let text), .textAndSubmit(let text): text
        case .submit: ""
        }
    }

    /// The delivery of one `do script` request. Herdly's script finds the tab-window by id and tty first
    /// and reports `gone` without typing when it is not there, and `not_running` when no event reached
    /// Terminal's process (#270); Automation denied sends nothing. Any other failure may have typed and
    /// counts as sent.
    public static func delivery(_ result: TerminalAppScriptResult) -> TypedInputDelivery {
        if result == .denied { return .notWritten }
        switch result.status {
        case "ok": return .written
        case "gone", "moved", "not_running": return .notWritten
        default: return .possiblyWritten
        }
    }
}
