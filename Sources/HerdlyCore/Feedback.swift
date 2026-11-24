import Foundation

/// Send Feedback (Paper "Herdly Settings", page "Send feedback (2026-11-24)", frames 01–05): an
/// anonymous note from the menu bar item, emailed to the maintainer through the feedback relay
/// (`relay/feedback`). The app never holds mail credentials; the relay does.

/// What the note is about, as the Kind picker offers it.
public enum FeedbackKind: String, CaseIterable, Codable, Sendable {
    case bug
    case idea
    case other

    public var title: String {
        switch self {
        case .bug: "Bug"
        case .idea: "Idea"
        case .other: "Something else"
        }
    }
}

/// Which part of Herdly the note is about, as the "Part of Herdly" picker offers it.
public enum FeedbackArea: String, CaseIterable, Codable, Sendable {
    case notSure
    case notch
    case approvals
    case questions
    case completions
    case settings
    case terminals
    case phoneAlerts

    public var title: String {
        switch self {
        case .notSure: "Not sure"
        case .notch: "Notch"
        case .approvals: "Approvals"
        case .questions: "Questions"
        case .completions: "Completions"
        case .settings: "Settings"
        case .terminals: "Terminals"
        case .phoneAlerts: "Phone alerts"
        }
    }
}

/// One screenshot the user attached. Only image types the relay accepts are admitted.
public struct FeedbackAttachment: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let filename: String
    public let contentType: String
    public let data: Data

    public static let allowedContentTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "heic": "image/heic", "gif": "image/gif", "tiff": "image/tiff", "tif": "image/tiff"
    ]

    /// Nil when the file extension is not an accepted image type or the file is empty.
    public init?(filename: String, data: Data, id: UUID = UUID()) {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard let type = Self.allowedContentTypes[ext], !data.isEmpty else { return nil }
        self.id = id
        self.filename = filename
        self.contentType = type
        self.data = data
    }
}

/// The form's contents. Pure value: the window owns one and asks it what can be sent.
public struct FeedbackDraft: Equatable, Sendable {
    public static let maxAttachments = 5
    /// 20 MB of screenshots per send (frame 02). Base64 makes the request about a third larger;
    /// the relay's body limit allows for that.
    public static let maxAttachmentBytes = 20 * 1024 * 1024
    public static let maxDescriptionLength = 5_000

    public var kind: FeedbackKind = .bug
    public var area: FeedbackArea = .notSure
    public var description = ""
    public private(set) var attachments: [FeedbackAttachment] = []
    public var includeDetails = true

    public init() {}

    public var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Send stays disabled until there is something to read, and while the note is over length.
    public var canSend: Bool {
        !trimmedDescription.isEmpty && description.count <= Self.maxDescriptionLength
    }

    public var attachmentBytes: Int { attachments.reduce(0) { $0 + $1.data.count } }

    public enum AddResult: Equatable, Sendable {
        case added
        case tooMany
        case tooLarge
    }

    /// Adds one screenshot unless that would pass five or 20 MB; the draft is unchanged on refusal.
    public mutating func add(_ attachment: FeedbackAttachment) -> AddResult {
        guard attachments.count < Self.maxAttachments else { return .tooMany }
        guard attachmentBytes + attachment.data.count <= Self.maxAttachmentBytes else { return .tooLarge }
        attachments.append(attachment)
        return .added
    }

    public mutating func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }
}

/// "Include app details": a handful of lines naming versions and connection state. Built from
/// values passed in, so it never reads prompts, code, paths, or session titles.
public struct FeedbackAppDetails: Equatable, Sendable {
    public let lines: [String]

    public init(herdlyVersion: String, herdlyBuild: String?, macOSVersion: String,
                codexConnected: Bool?, codexCLIVersion: String?, codexDesktopVersion: String?,
                claudeConnected: Bool?, claudeVersion: String?,
                ghosttyEnabled: Bool) {
        func connection(_ connected: Bool?) -> String {
            switch connected {
            case true?: "connected"
            case false?: "not connected"
            case nil: "checking"
            }
        }
        let build = herdlyBuild.map { " (\($0))" } ?? ""
        var codex = "Codex: \(connection(codexConnected))"
        if let codexCLIVersion { codex += " · CLI \(codexCLIVersion)" }
        if let codexDesktopVersion { codex += " · Desktop \(codexDesktopVersion)" }
        var claude = "Claude Code: \(connection(claudeConnected))"
        if let claudeVersion { claude += " · \(claudeVersion)" }
        lines = [
            "Herdly \(herdlyVersion)\(build) · macOS \(macOSVersion)",
            codex,
            claude,
            "Ghostty: \(ghosttyEnabled ? "on" : "off")"
        ]
    }

    public var text: String { lines.joined(separator: "\n") }
}

/// What a send ended in. The draft is kept on every failure so nothing typed is lost.
public enum FeedbackSendOutcome: Equatable, Sendable {
    case sent
    case failed(String)
}

/// The relay request and the reading of its answer.
public enum FeedbackRelay {
    /// The deployed relay (`relay/feedback`, Railway project "herdly-feedback", service "relay").
    public static let endpoint = URL(string: "https://relay-production-ea0cde5f.up.railway.app/feedback")!
    /// Screenshots can take a while on a slow uplink; still bounded.
    public static let timeout: TimeInterval = 60

    public static func request(draft: FeedbackDraft, details: FeedbackAppDetails?,
                               endpoint: URL = FeedbackRelay.endpoint) -> URLRequest? {
        guard draft.canSend else { return nil }
        let payload = Payload(
            kind: draft.kind.rawValue, area: draft.area.rawValue, description: draft.trimmedDescription,
            details: draft.includeDetails ? details?.lines : nil,
            attachments: draft.attachments.map {
                Payload.Attachment(filename: $0.filename, contentType: $0.contentType,
                                   content: $0.data.base64EncodedString())
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(payload) else { return nil }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// The footer's problem line for an HTTP answer (frame 04).
    public static func outcome(statusCode: Int) -> FeedbackSendOutcome {
        switch statusCode {
        case 200..<300: .sent
        case 413: .failed("Couldn't send: the screenshots are too large.")
        case 429: .failed("Couldn't send: too many notes from this network. Try again in an hour.")
        case 400..<500: .failed("Couldn't send: the feedback service turned the note down (\(statusCode)).")
        default: .failed("Couldn't send: the feedback service is having trouble. Try again later.")
        }
    }

    public static let offline = FeedbackSendOutcome.failed("Couldn't send: Herdly couldn't reach the feedback service.")

    private struct Payload: Encodable {
        struct Attachment: Encodable {
            let filename: String
            let contentType: String
            let content: String
        }
        let kind: String
        let area: String
        let description: String
        let details: [String]?
        let attachments: [Attachment]
    }
}
