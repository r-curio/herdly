import Foundation

/// The one valid presentation the notch body can have. A live spotlight outranks passive hover;
/// only an explicit header activation replaces it with the complete queue.
public enum NotchPresentationMode: Equatable, Sendable {
    case collapsed
    case spotlight(AttentionItemID)
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

/// Owns the causal transition between automatic spotlighting and an explicit queue open.
public struct NotchPresentationController: Equatable, Sendable {
    private var spotlight = Spotlight()
    private var manualOpen = false

    public init() {}
    public mutating func present(_ item: AttentionItemID, now: Double) { spotlight.present(item, now: now) }
    public mutating func openQueue() { manualOpen = true }
    public mutating func collapse() { manualOpen = false; spotlight.clear() }
    public mutating func update(interacting: Bool, now: Double, legacyPopup: Bool = false) -> NotchPresentationMode {
        if !interacting { manualOpen = false }
        return NotchPresentationMode.resolve(spotlight: spotlight.update(interacting: interacting, now: now),
                                             manualOpen: manualOpen, interacting: interacting, legacyPopup: legacyPopup)
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

public struct SpotlightField: Equatable, Identifiable, Sendable {
    public let label: String
    public let value: String
    public var id: String { label }
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

/// Stable, tested field ordering for the distilled single-item surface. Views render this projection;
/// they do not rediscover domain state from the queue's optional payloads.
public struct SpotlightDetails: Equatable, Sendable {
    public let context: [SpotlightField]
    public let originalPrompt: String?
    public let response: CompletionPreviewAvailability?

    public static func make(item: AttentionItem, context: SpotlightRecordContext?,
                            response: CompletionPreviewAvailability?,
                            timestamp: (Double) -> String) -> Self {
        var fields: [SpotlightField] = []
        if let details = item.request?.details {
            append(&fields, "task", details.taskName)
            append(&fields, "working directory", details.project)
            append(&fields, "action", details.action)
            append(&fields, "command", details.command)
            append(&fields, "reason", details.reason)
            append(&fields, "full request", details.longText)
        }
        if let context {
            append(&fields, "working directory", context.workingDirectory)
        }
        if let expiresAt = item.request?.expiresAt { fields.append(SpotlightField("deadline", timestamp(expiresAt))) }
        let resolvedResponse: CompletionPreviewAvailability? = item.completion.map { completion in
            response ?? .unavailable(completion.uncertain ? "Response preview unavailable after restart."
                                                     : "Response preview is unavailable.")
        }
        return Self(context: fields, originalPrompt: context?.prompt, response: resolvedResponse)
    }

    private static func append(_ fields: inout [SpotlightField], _ label: String, _ value: String?) {
        guard let value, !value.isEmpty, !fields.contains(where: { $0.label == label }) else { return }
        fields.append(SpotlightField(label, value))
    }
}
