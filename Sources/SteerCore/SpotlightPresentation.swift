import Foundation

/// The one valid presentation the notch body can have. A live spotlight outranks passive hover;
/// only an explicit header activation replaces it with the complete queue.
public enum NotchPresentationMode: Equatable, Sendable {
    case collapsed
    case spotlight(AttentionItemID)
    case agentSpotlight(AgentAttentionID)
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
}

/// Chooses among fresh source-aware cards after each card class has applied its own
/// presentation policy. Queue order is the product priority order.
public enum AgentPresentationSelection {
    public static func highestPriority(in items: [AgentAttentionItem],
                                       candidates: Set<AgentAttentionID>) -> AgentAttentionID? {
        items.first { candidates.contains($0.id) }?.id
    }
}

/// Claude has no verified foreground target in the current integration. Its fresh
/// cards may present while Codex is foreground; Codex keeps the existing foreground gate.
public enum AgentPresentationEligibility {
    public static func foregroundGate(source: AgentSource, codexForeground: Bool?) -> Bool? {
        source == .claude ? false : codexForeground
    }
}

/// Owns the causal transition between automatic spotlighting and an explicit queue open.
public struct NotchPresentationController: Equatable, Sendable {
    private var spotlight = Spotlight()
    private var agentSpotlight = AgentSpotlight()
    private var manualOpen = false

    public init() {}
    public mutating func present(_ item: AttentionItemID, now: Double) { spotlight.present(item, now: now) }
    public mutating func present(_ item: AgentAttentionID, now: Double) { agentSpotlight.present(item, now: now) }
    public func agentSpotlightIsActive(interacting: Bool, now: Double) -> Bool {
        agentSpotlight.isActive(interacting: interacting, now: now)
    }
    public mutating func openQueue() { manualOpen = true }
    public mutating func collapse() { manualOpen = false; spotlight.clear(); agentSpotlight.clear() }
    public mutating func update(interacting: Bool, now: Double, legacyPopup: Bool = false) -> NotchPresentationMode {
        if !interacting { manualOpen = false }
        if let id = agentSpotlight.update(interacting: interacting, now: now) {
            return manualOpen ? .queue : .agentSpotlight(id)
        }
        return NotchPresentationMode.resolve(spotlight: spotlight.update(interacting: interacting, now: now),
                                             manualOpen: manualOpen, interacting: interacting, legacyPopup: legacyPopup)
    }
}

private struct AgentSpotlight: Equatable, Sendable {
    private var item: AgentAttentionID?
    private var until: Double = 0

    mutating func present(_ item: AgentAttentionID, now: Double) {
        self.item = item
        until = now + Spotlight.duration
    }

    mutating func update(interacting: Bool, now: Double) -> AgentAttentionID? {
        guard let item else { return nil }
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
    public let text: String
    public let truncated: Bool

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
        truncated = wasTruncated
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

    /// True when the raw request holds anything beyond the command and ask the card already shows.
    /// Unparseable or non-object text is kept: Steer cannot prove the card already shows it.
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

    /// Codex's task name for the card's place line, or nil when there is none or the session label
    /// already names exactly that task (`"<Source> · <task>"`). Only an exact name hides it, so a task
    /// that merely appears inside a longer label is still shown.
    public func task(besides sessionLabel: String) -> String? {
        guard let task else { return nil }
        return sessionLabel.hasSuffix(" · " + task) ? nil : task
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
