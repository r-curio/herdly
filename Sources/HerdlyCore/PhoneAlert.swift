import Foundation

/// Phone alerts (#352): a notify-only buzz on the user's phone when an approval, a question, or a
/// completion arrives while the Mac is idle. The rule here is pure: the app passes in what it saw,
/// the idle reading, and the switch, and gets back at most one message. Nothing here reads a clock,
/// the network, or the Keychain, and nothing here changes the queue, acknowledgment, or a deadline.

/// How a finished turn ended, as far as the phone says: "finished" only for success, "stopped" for
/// a failed or interrupted turn, and a neutral word when the source did not say.
public enum PhoneAlertCompletion: Equatable, Sendable {
    case finished
    case stopped
    case unknown

    public init(_ status: AgentOutcomeStatus) {
        switch status {
        case .finished: self = .finished
        case .failed, .stopped: self = .stopped
        case .unavailable: self = .unknown
        }
    }
}

/// The kinds of attention that may reach the phone. Running work, unknown waiting sessions, and
/// status-unavailable rows have no phone kind.
public enum PhoneAlertKind: Equatable, Sendable {
    /// Live or handed back at arrival: Codex desktop approvals always hand back at once.
    case approval
    case question
    case completion(PhoneAlertCompletion)

    /// The phone kind for a queue row, or nil for a row that never alerts.
    public init?(_ item: AgentAttentionItem) {
        switch item.kind {
        case .actionableApproval, .handedBackApproval: self = .approval
        case .question: self = .question
        case .outcome, .earlierOutcome:
            guard let outcome = item.outcome else { return nil }
            self = .completion(PhoneAlertCompletion(outcome.status))
        case .waiting, .statusUnavailable, .running: return nil
        }
    }
}

/// How an item entered the queue. Only an item Herdly saw arrive while it was running may alert;
/// a restored, pre-launch, or uncertain item stays silent, as in Recovery.
public enum PhoneAlertArrival: Equatable, Sendable {
    case fresh
    case restored
    /// Arrived while notifications were paused and its kind stays quiet (#456): spent, never sent.
    case paused

    /// Fresh when the item arrived at or after launch; a result uses the rule that decides whether
    /// its card pops (`ResultPop.isFresh`), which also keeps an uncertain result silent.
    public static func of(_ item: AgentAttentionItem, launchedAt: Double) -> PhoneAlertArrival {
        if let outcome = item.outcome { return ResultPop.isFresh(outcome, launchedAt: launchedAt) ? .fresh : .restored }
        return item.arrivedAt >= launchedAt ? .fresh : .restored
    }
}

/// The user's "Alert my phone when I'm away" switch.
public enum PhoneAlertSetting: Equatable, Sendable {
    case off
    case on
}

/// ntfy's priority scale: approvals and questions buzz at high, completions at the default.
public enum PhoneAlertPriority: Int, Equatable, Sendable {
    case standard = 3
    case high = 4
}

/// What the phone shows. It holds only the agent's name, the kind, and the project folder's name:
/// never a prompt, a response, a command, an option, or a path.
public struct PhoneAlertMessage: Equatable, Sendable {
    public let title: String
    public let body: String
    public let priority: PhoneAlertPriority
    /// ntfy tags; each one ntfy knows renders as an emoji beside the title.
    public let tags: [String]

    public init(title: String, body: String, priority: PhoneAlertPriority, tags: [String]) {
        self.title = title
        self.body = body
        self.priority = priority
        self.tags = tags
    }

    /// The one alert "Send Test to Phone" publishes.
    public static let test = PhoneAlertMessage(title: "Herdly test alert", body: "Phone alerts from Herdly reach this phone.",
                                               priority: .standard, tags: ["white_check_mark"])
}

/// One newly queued item, as the policy sees it. `project` is the session's working directory or
/// project name, when Herdly has one; only its last component is ever shown.
public struct PhoneAlertCandidate: Equatable, Sendable {
    public let id: AgentAttentionID
    public let kind: PhoneAlertKind
    public let source: AgentSource
    public let project: String?
    public let arrival: PhoneAlertArrival

    public init(id: AgentAttentionID, kind: PhoneAlertKind, source: AgentSource, project: String?, arrival: PhoneAlertArrival) {
        self.id = id
        self.kind = kind
        self.source = source
        self.project = project
        self.arrival = arrival
    }

    /// The candidate for a queue row, or nil for a row kind that never alerts.
    public init?(_ item: AgentAttentionItem, project: String?, launchedAt: Double) {
        guard let kind = PhoneAlertKind(item) else { return nil }
        self.init(id: item.id, kind: kind, source: item.session.source, project: project,
                  arrival: PhoneAlertArrival.of(item, launchedAt: launchedAt))
    }

    /// This candidate, marked `.paused` when a pause keeps its kind quiet
    /// (`NotificationInterruption.allows`). The ledger still records it, so it never alerts later.
    public func respecting(mayInterrupt: Bool) -> PhoneAlertCandidate {
        guard !mayInterrupt, arrival == .fresh else { return self }
        return PhoneAlertCandidate(id: id, kind: kind, source: source, project: project, arrival: .paused)
    }
}

public enum PhoneAlertPolicy {
    /// No keyboard or pointer input for this long counts as away. Fixed for now (decided 2026-10-22).
    public static let idleThreshold: Double = 120
    /// "2 minutes", for the Settings copy, from `idleThreshold`.
    public static var idleThresholdText: String {
        let minutes = Int((idleThreshold / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// The message for one arrival, or nil when the phone should stay quiet: the switch is off, the
    /// item was restored or was already considered once, the idle reading is unknown, or the user
    /// was active within `idleThreshold` seconds.
    public static func message(for candidate: PhoneAlertCandidate, alreadyConsidered: Bool,
                               idleSeconds: Double?, setting: PhoneAlertSetting) -> PhoneAlertMessage? {
        guard setting == .on, candidate.arrival == .fresh, !alreadyConsidered,
              let idleSeconds, idleSeconds.isFinite, idleSeconds >= idleThreshold else { return nil }
        return text(kind: candidate.kind, source: candidate.source, project: projectName(candidate.project))
    }

    /// The title and body for one kind. The approval body says to decide on the Mac, so it never
    /// implies the request is still live when the user gets back.
    public static func text(kind: PhoneAlertKind, source: AgentSource, project: String?) -> PhoneAlertMessage {
        let agent = source.displayName
        switch kind {
        case .approval:
            return PhoneAlertMessage(title: "\(agent) needs permission",
                                     body: project.map { "\($0) — decide on your Mac" } ?? "Decide on your Mac",
                                     priority: .high, tags: ["lock"])
        case .question:
            return PhoneAlertMessage(title: "\(agent) needs an answer", body: project ?? "Answer on your Mac",
                                     priority: .high, tags: ["question"])
        case let .completion(ending):
            let (title, tag) = switch ending {
            case .finished: ("\(agent) finished", "white_check_mark")
            case .stopped: ("\(agent) stopped", "warning")
            case .unknown: ("\(agent) ended a turn", "bell")
            }
            return PhoneAlertMessage(title: title, body: project ?? "The result is on your Mac",
                                     priority: .standard, tags: [tag])
        }
    }

    /// The folder name only: the last path component, without control characters, at most 64
    /// characters. Nil when nothing readable is left.
    public static func projectName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let component = trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let printable = String(String.UnicodeScalarView(component.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespaces)
        guard !printable.isEmpty, printable != "~" else { return nil }
        return String(printable.prefix(64))
    }
}

/// The items already considered for the phone, kept in memory and bounded. An item is recorded the
/// first time it is seen, sent or not, so duplicate or reordered events, a rescan, or a later idle
/// stretch never publish it. A restart forgets the ledger; restored items are silent anyway.
public struct PhoneAlertLedger: Equatable, Sendable {
    public let capacity: Int
    private var order: [AgentAttentionID] = []
    private var members: Set<AgentAttentionID> = []

    public init(capacity: Int = 1024) {
        self.capacity = max(1, capacity)
    }

    public func contains(_ id: AgentAttentionID) -> Bool { members.contains(id) }
    public var count: Int { members.count }

    /// Records each candidate and returns the messages for the ones that alert, in the given order.
    public mutating func consider(_ candidates: [PhoneAlertCandidate], idleSeconds: Double?,
                                  setting: PhoneAlertSetting) -> [PhoneAlertMessage] {
        var messages: [PhoneAlertMessage] = []
        for candidate in candidates {
            let seen = members.contains(candidate.id)
            if let message = PhoneAlertPolicy.message(for: candidate, alreadyConsidered: seen,
                                                      idleSeconds: idleSeconds, setting: setting) {
                messages.append(message)
            }
            if !seen { record(candidate.id) }
        }
        return messages
    }

    private mutating func record(_ id: AgentAttentionID) {
        members.insert(id)
        order.append(id)
        while order.count > capacity {
            members.remove(order.removeFirst())
        }
    }
}

/// ntfy publishing (https://docs.ntfy.sh/publish/). Herdly uses ntfy's JSON form, a POST to the
/// server root with the topic in the body, so the title and body travel as UTF-8 JSON rather than
/// as HTTP header values, which must be ASCII-safe or RFC 2047 encoded.
public enum NtfyPublish {
    /// Fixed for now (decided 2026-10-22).
    public static let server = URL(string: "https://ntfy.sh/")!
    /// A bounded wait: a slow or absent server never holds an alert open.
    public static let timeout: TimeInterval = 10

    /// The publish request for one message, or nil if it could not be encoded.
    public static func request(topic: NtfyTopic, message: PhoneAlertMessage, server: URL = NtfyPublish.server) -> URLRequest? {
        let payload = Payload(topic: topic.name, title: message.title, message: message.body,
                              priority: message.priority.rawValue, tags: message.tags)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(payload) else { return nil }
        var request = URLRequest(url: server, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private struct Payload: Encodable {
        let topic: String
        let title: String
        let message: String
        let priority: Int
        let tags: [String]
    }
}

/// An ntfy topic name that passed ntfy's rule: letters, digits, `_` and `-`, at most 64 characters.
/// It works like a password: anyone who knows it can read the alerts.
public struct NtfyTopic: Hashable, Sendable {
    public let name: String

    public init?(_ name: String) {
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({
                  ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
              }) else { return nil }
        self.name = name
    }

    static let prefix = "herdly-"
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    static let randomLength = 20

    /// A new private topic: "herdly-" and 20 base32 characters (100 random bits). The generator must
    /// be a secure one (`SystemRandomNumberGenerator`).
    public static func random<Generator: RandomNumberGenerator>(using generator: inout Generator) -> NtfyTopic {
        let suffix = (0..<randomLength).map { _ in alphabet.randomElement(using: &generator)! }
        return NtfyTopic(prefix + String(suffix))!
    }
}
