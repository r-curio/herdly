import Foundation

/// The one valid presentation the notch body can have. A live spotlight outranks passive hover;
/// only an explicit header activation replaces it with the complete queue. A clicked card is the
/// one approval or question the user opened from the queue (docs/product.md, D5/D18).
public enum NotchPresentationMode: Equatable, Sendable {
    case collapsed
    case spotlight(AttentionItemID)
    case agentSpotlight(AgentAttentionID)
    case clickedCard(AgentAttentionID)
    case queue

    public static func resolve(spotlight: AttentionItemID?, manualOpen: Bool,
                               interacting: Bool, legacyPopup: Bool = false) -> Self {
        if manualOpen { return .queue }
        if let spotlight { return .spotlight(spotlight) }
        if interacting || legacyPopup { return .queue }
        return .collapsed
    }

    public var expanded: Bool { self != .collapsed }
    public var showsAll: Bool { self == .queue }
    /// The one item a spotlight or clicked card shows; nil for the queue and the collapsed strip.
    public var singleCard: AgentAttentionID? {
        switch self {
        case let .agentSpotlight(id), let .clickedCard(id): return id
        case .collapsed, .spotlight, .queue: return nil
        }
    }
    public var showsSingleCard: Bool { singleCard != nil }
    public var clickedCard: AgentAttentionID? {
        if case let .clickedCard(id) = self { return id }
        return nil
    }
}

/// Chooses among fresh source-aware cards after each card class has applied its own
/// presentation policy. Queue order is the product priority order.
public enum AgentPresentationSelection {
    /// The fresh item to spotlight, by the pre-#314 priority rule: highest-priority kind, then oldest
    /// arrival, then identity. It ignores list order, so the queue's soonest-deadline order for live
    /// approvals (D12) never changes which request opens on arrival.
    public static func highestPriority(in items: [AgentAttentionItem],
                                       candidates: Set<AgentAttentionID>) -> AgentAttentionID? {
        items.filter { candidates.contains($0.id) }.min {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.arrivedAt != $1.arrivedAt { return $0.arrivedAt < $1.arrivedAt }
            return AgentAttentionQueue.sortKey($0.id) < AgentAttentionQueue.sortKey($1.id)
        }?.id
    }
}

/// Claude has no verified foreground target in the current integration. Its fresh
/// cards may present while Codex is foreground; Codex keeps the existing foreground gate.
public enum AgentPresentationEligibility {
    public static func foregroundGate(source: AgentSource, codexForeground: Bool?) -> Bool? {
        source == .claude ? false : codexForeground
    }
}

/// What one Escape did: a clicked card steps back to the queue; anything else collapses (D6).
/// Neither dismisses an item.
public enum NotchEscape: Equatable, Sendable {
    case backToQueue
    case collapse
}

/// How long a fresh agent card stays open on its own (Settings › General › Keep new cards open).
/// Interaction holds any card open past its time; Until I act holds it until the user interacts.
/// None of these touch an approval's 30-second handoff deadline.
public enum CardOpenDuration: String, CaseIterable, Sendable {
    case threeSeconds = "3s"
    case fiveSeconds = "5s"
    case tenSeconds = "10s"
    case untilIAct

    public static let standard = Self.threeSeconds

    public var title: String {
        switch self {
        case .threeSeconds: "3 seconds"
        case .fiveSeconds: "5 seconds"
        case .tenSeconds: "10 seconds"
        case .untilIAct: "Until I act"
        }
    }

    /// The saved choice, migrating the old on/off "Keep new cards open until I act" switch: a
    /// readable saved duration wins; otherwise a saved `true` becomes Until I act, and `false`, no
    /// value, or an unreadable duration becomes the 3-second default.
    public static func resolve(saved: String?, legacyKeepCardsOpen: Bool?) -> Self {
        if let saved = saved.flatMap(Self.init(rawValue:)) { return saved }
        return legacyKeepCardsOpen == true ? .untilIAct : .standard
    }

    /// The timed close, or nil for Until I act.
    public var seconds: Double? {
        switch self {
        // The default shares the legacy spotlight's constant so 3 seconds is defined once.
        case .threeSeconds: Spotlight.duration
        case .fiveSeconds: 5
        case .tenSeconds: 10
        case .untilIAct: nil
        }
    }
}

/// Owns the causal transition between automatic spotlighting, an explicit queue open, and a card
/// the user clicked open from the queue.
public struct NotchPresentationController: Equatable, Sendable {
    private var spotlight = Spotlight()
    private var agentSpotlight = AgentSpotlight()
    private var manualOpen = false
    /// The exact approval or question the user clicked open. It has no timed close and never
    /// touches its request's deadline; it ends on Escape, ‹ Queue, an action, the end of
    /// interaction, or its item leaving the queue.
    private var clicked: AgentAttentionID?

    public init() {}
    public mutating func present(_ item: AttentionItemID, now: Double) { spotlight.present(item, now: now) }
    /// A timed card closes `duration.seconds` after it opens unless the user is interacting then.
    /// Until I act keeps it open until the user interacts with it, then closes it once that
    /// interaction ends. Approval deadlines are separate and never move.
    public mutating func present(_ item: AgentAttentionID, now: Double, duration: CardOpenDuration = .standard) {
        guard clicked == nil else { return }
        agentSpotlight.present(item, now: now, duration: duration)
    }
    public func agentSpotlightIsActive(interacting: Bool, now: Double) -> Bool {
        agentSpotlight.isActive(interacting: interacting, now: now)
    }
    /// Whether a fresh card may take the spotlight now. Never while one is active or a clicked card
    /// is open, and never while the user has unsent text in a field on screen, which a new card
    /// would take away.
    public func acceptsAgentSpotlight(interacting: Bool, draftInProgress: Bool, now: Double) -> Bool {
        clicked == nil && !draftInProgress && !agentSpotlight.isActive(interacting: interacting, now: now)
    }
    /// The header's explicit open: the whole queue, leaving any clicked card.
    public mutating func openQueue() { manualOpen = true; clicked = nil }
    /// Opens one approval or question as its own card in place of the queue. Other rows (results,
    /// running work) are not cards here and return false.
    @discardableResult
    public mutating func openCard(_ item: AgentAttentionID) -> Bool {
        guard item.isRequest else { return false }
        clicked = item
        manualOpen = true
        agentSpotlight.clear()
        spotlight.clear()
        return true
    }
    /// ‹ Queue, or an action taken on the card: back to the queue. Nothing is dismissed.
    public mutating func backToQueue() {
        guard clicked != nil else { return }
        clicked = nil
        manualOpen = true
    }
    /// Approve, Deny, or Send taken on the clicked card `item` (D10): back to the queue, where the
    /// row note shows. A decision on any other request leaves the open card alone. Returns whether
    /// it left.
    @discardableResult
    public mutating func leaveCard(after item: AgentAttentionID) -> Bool {
        guard clicked == item else { return false }
        backToQueue()
        return true
    }
    /// The one Escape rule (D6): a clicked card returns to the queue; otherwise the panel collapses.
    public mutating func escape() -> NotchEscape {
        if clicked != nil {
            backToQueue()
            return .backToQueue
        }
        collapse()
        return .collapse
    }
    public mutating func collapse() { manualOpen = false; clicked = nil; spotlight.clear(); agentSpotlight.clear() }
    /// `draftInProgress` (unsent text in a field on screen) keeps the current card open like
    /// interaction does, so a hover or focus gap cannot swap it for the queue mid-answer. It does
    /// not open anything by itself; Escape still ends the hold through `escape()`.
    /// `queued` is the queue's current identities: a clicked card whose item has left falls back to
    /// the queue and never shows another item. Nil leaves the clicked card unchecked.
    public mutating func update(interacting: Bool, draftInProgress: Bool = false, now: Double,
                                legacyPopup: Bool = false, queued: Set<AgentAttentionID>? = nil) -> NotchPresentationMode {
        if let card = clicked {
            if let queued, !queued.contains(card) {
                clicked = nil
            } else if interacting || draftInProgress {
                return .clickedCard(card)
            } else {
                // The card closes with the panel, as the queue it was opened from does.
                clicked = nil
                manualOpen = false
            }
        }
        if !interacting { manualOpen = false }
        if let id = agentSpotlight.update(interacting: interacting || draftInProgress, now: now) {
            return manualOpen ? .queue : .agentSpotlight(id)
        }
        return NotchPresentationMode.resolve(spotlight: spotlight.update(interacting: interacting, now: now),
                                             manualOpen: manualOpen, interacting: interacting, legacyPopup: legacyPopup)
    }
}

/// Keyboard selection over the open queue's rows (Up and Down arrows). The selection follows its
/// row's identity through reorders and goes when that row leaves; it never jumps to another row
/// by position.
public struct QueueRowSelection: Equatable, Sendable {
    public enum Direction: Sendable { case up, down }

    /// What a click on a row, or Return on the selected row (the same action), asks for: a request
    /// opens as its clicked card (D5, D18), a working row opens or closes in place (#319), and a
    /// result row opens its session (D20, #322) through the session's usual Open, which revalidates
    /// the exact target.
    public enum RowAction: Equatable, Sendable {
        case openCard(AgentAttentionID)
        case openInPlace(AgentAttentionID)
        case openSession(AgentSessionIdentity)
    }

    public private(set) var selected: AgentAttentionID?

    public init(selected: AgentAttentionID? = nil) { self.selected = selected }

    /// Moves one row, stopping at either end. With nothing selected, Down selects the first row
    /// and Up the last.
    public mutating func move(_ direction: Direction, in rows: [AgentAttentionID]) {
        guard !rows.isEmpty else { selected = nil; return }
        guard let selected, let index = rows.firstIndex(of: selected) else {
            self.selected = direction == .down ? rows.first : rows.last
            return
        }
        let next = direction == .down ? min(rows.count - 1, index + 1) : max(0, index - 1)
        self.selected = rows[next]
    }

    public mutating func reconcile(rows: [AgentAttentionID]) {
        if let selected, !rows.contains(selected) { self.selected = nil }
    }

    public mutating func clear() { selected = nil }

    /// Nil for a result row whose session is unreachable: its click and Return do nothing, and the
    /// key goes on unhandled. `target` is read only for result rows.
    public static func action(for row: AgentAttentionItem, target: ResultRowTarget) -> RowAction? {
        if row.id.isRequest { return .openCard(row.id) }
        if row.kind == .running { return .openInPlace(row.id) }
        guard row.kind.opensSession, target == .reachable else { return nil }
        return .openSession(row.session)
    }
}

private struct AgentSpotlight: Equatable, Sendable {
    private var item: AgentAttentionID?
    private var until: Double = 0

    mutating func present(_ item: AgentAttentionID, now: Double, duration: CardOpenDuration) {
        self.item = item
        until = duration.seconds.map { now + $0 } ?? .infinity
    }

    mutating func update(interacting: Bool, now: Double) -> AgentAttentionID? {
        guard let item else { return nil }
        // A held card ends with the user's first interaction rather than at a time.
        if interacting && until == .infinity { until = now }
        if interacting || now < until { return item }
        clear()
        return nil
    }

    func isActive(interacting: Bool, now: Double) -> Bool {
        guard item != nil else { return false }
        return interacting || now < until
    }

    mutating func clear() {
        item = nil
        until = 0
    }
}

/// A bounded, transient excerpt from the exact turn's terminal record. It is deliberately not
/// Codable so it cannot accidentally become part of the persisted attention snapshot.
public struct CompletionPreview: Equatable, Sendable {
    public static let maximumCharacters = 600
    public static let maximumLines = 5
    /// The most of the message "Show all" keeps (#323); longer text is cut and the card says so.
    public static let maximumFullCharacters = 20_000
    /// How much of the message `text` shows, and what "Show all" has beyond it (#323). Transient like `text`.
    public enum Extent: Equatable, Sendable {
        /// `text` is the whole message: nothing more to show.
        case whole
        /// `text` was shortened; `full` is the whole message.
        case cut(full: String)
        /// `text` was shortened and the message was longer than `maximumFullCharacters`; `full` is its
        /// start, so the card says the rest is only in the agent.
        case cutAndCapped(full: String)
    }

    public let text: String
    public let extent: Extent
    public var truncated: Bool { extent != .whole }

    public init?(_ source: String) {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
        let normalized = lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let keptLines = Array(normalized.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.maximumLines))
        var value = keptLines.joined(separator: "\n")
        var wasTruncated = keptLines.count < normalized.split(separator: "\n", omittingEmptySubsequences: false).count
        if value.count > Self.maximumCharacters || (wasTruncated && value.count == Self.maximumCharacters) {
            value = String(value.prefix(Self.maximumCharacters - 1))
            wasTruncated = true
        }
        text = wasTruncated ? value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) + "…" : value
        if !wasTruncated {
            extent = .whole
        } else if normalized.count > Self.maximumFullCharacters {
            extent = .cutAndCapped(full: String(normalized.prefix(Self.maximumFullCharacters)))
        } else {
            extent = .cut(full: normalized)
        }
    }
}

public enum CompletionPreviewAvailability: Equatable, Sendable {
    case available(CompletionPreview)
    case unavailable(String)
}

/// Exact-turn rollout context for a spotlight notification. This is transient and intentionally
/// non-Codable, so prompts and working directories never enter the attention snapshot.
public struct SpotlightRecordContext: Equatable, Sendable {
    public let workingDirectory: String?
    public let prompt: String?

    public init(workingDirectory: String? = nil, prompt: String? = nil) {
        self.workingDirectory = workingDirectory
        self.prompt = prompt
    }
}

/// A working directory as the spotlight shows it: the home folder shortened to `~` for reading,
/// with the full path kept for hover, copy, and VoiceOver.
public struct SpotlightDirectory: Equatable, Sendable {
    public let display: String
    public let full: String

    init?(_ path: String?, home: String?) {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        full = path
        display = Self.abbreviate(path, home: home)
    }

    static func abbreviate(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == base { return "~" }
        return path.hasPrefix(base + "/") ? "~" + path.dropFirst(base.count) : path
    }
}

/// One approval request read the way the spotlight presents it: Codex's own ask, the action and
/// command it wants to run, where it runs, and its timing. Every value is one Codex supplied;
/// nothing is written on Codex's behalf.
public struct SpotlightRequest: Equatable, Sendable {
    /// Codex's reason, or failing that a top-level `description`/`justification` string from its tool input.
    public let ask: String?
    public let action: String?
    public let command: String?
    public let task: String?
    public let directory: SpotlightDirectory?
    /// The raw request, kept only when it carries something the card does not already show.
    public let fullRequest: String?
    public let arrivedAt: Double
    public let expiresAt: Double

    init(details: ApprovalDetails?, contextDirectory: String?, arrivedAt: Double, expiresAt: Double, home: String?) {
        let input = details?.longText.flatMap(Self.object(from:))
        let lifted = ["description", "justification"].lazy.compactMap { input?[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let ask = details?.reason.flatMap(Self.nonEmpty) ?? lifted
        let command = details?.command.flatMap(Self.nonEmpty)
        self.ask = ask
        self.command = command
        action = details?.action.flatMap(Self.nonEmpty)
        task = details?.taskName.flatMap(Self.nonEmpty)
        directory = SpotlightDirectory(details?.project.flatMap(Self.nonEmpty) ?? contextDirectory, home: home)
        fullRequest = details?.longText.flatMap(Self.nonEmpty).flatMap { text in
            Self.addsDetail(input, ask: ask, command: command) ? text : nil
        }
        self.arrivedAt = arrivedAt
        self.expiresAt = expiresAt
    }

    /// The same card read from a source-neutral approval (#320): its own details, arrival, and
    /// deadline, so a Claude request reads top to bottom like a Codex one. `contextDirectory` places
    /// the card when the request names no project, such as a Claude session's own directory.
    public init(approval: AgentApproval, contextDirectory: String?, home: String?) {
        self.init(details: approval.details, contextDirectory: contextDirectory,
                  arrivedAt: approval.arrivedAt, expiresAt: approval.expiresAt, home: home)
    }

    /// What the card says where the command would be when the agent sent none (D9). Herdly never
    /// guesses the command.
    public static func missingCommand(from source: AgentSource) -> String {
        "\(source.displayName) didn't say which command."
    }

    /// True when the raw request holds anything beyond the command and ask the card already shows.
    /// Unparseable or non-object text is kept: Herdly cannot prove the card already shows it.
    private static func addsDetail(_ input: [String: Any]?, ask: String?, command: String?) -> Bool {
        guard let input else { return true }
        return input.contains { key, value in
            switch key {
            // A value that is not a string is never what the card shows, even when its field is empty.
            case "command":
                guard let value = value as? String else { return true }
                return value != command
            case "description", "justification":
                guard let value = value as? String else { return true }
                return value.trimmingCharacters(in: .whitespacesAndNewlines) != ask
            default: return true
            }
        }
    }

    private static func object(from text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Codex's task name for the card's place line, or nil when there is none or the session's own
    /// name (which its label already shows) is exactly that task. A task that merely appears inside a
    /// longer name, or beside an unnamed session, is still shown.
    public func task(besidesSessionName name: String?) -> String? {
        guard let task else { return nil }
        return name == task ? nil : task
    }

    /// A compact elapsed time for a status line: "just now", "4m ago", "2h ago", "3d ago".
    public static func elapsed(since start: Double, now: Double) -> String {
        let seconds = max(0, now - start)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

/// The distilled single-item surface. Views render this projection; they do not rediscover
/// domain state from the queue's optional payloads.
public struct SpotlightDetails: Equatable, Sendable {
    public let request: SpotlightRequest?
    /// The exact turn's working directory for a card that is not a request.
    public let directory: SpotlightDirectory?
    public let originalPrompt: String?
    public let response: CompletionPreviewAvailability?

    public static func make(item: AttentionItem, context: SpotlightRecordContext?,
                            response: CompletionPreviewAvailability?, home: String? = nil) -> Self {
        let request = item.request.map { request in
            SpotlightRequest(details: request.details, contextDirectory: context?.workingDirectory,
                             arrivedAt: request.arrivedAt, expiresAt: request.expiresAt, home: home)
        }
        let directory = request == nil ? SpotlightDirectory(context?.workingDirectory, home: home) : nil
        let resolvedResponse: CompletionPreviewAvailability? = item.completion.map { completion in
            response ?? .unavailable(completion.uncertain ? "Response preview unavailable after restart."
                                                     : "Response preview is unavailable.")
        }
        return Self(request: request, directory: directory, originalPrompt: context?.prompt, response: resolvedResponse)
    }
}
