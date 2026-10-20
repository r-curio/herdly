import Foundation

public enum DesktopEvent: Equatable, Sendable {
    case sessionStarted(session: UUID, receivedAt: String)
    case turnStarted(session: UUID, turn: UUID, receivedAt: String)
    case promptSubmitted(session: UUID, turn: UUID, prompt: String?, receivedAt: String)
    case toolStarted(session: UUID, turn: UUID, useID: String, action: ToolAction?, capturedAt: Double)
    case toolCompleted(session: UUID, turn: UUID, useID: String, capturedAt: Double)
    case turnCompleted(session: UUID, turn: UUID, receivedAt: String)
    case sessionEnded(session: UUID, receivedAt: String)

    public var session: UUID {
        switch self {
        case let .sessionStarted(session, _), let .turnStarted(session, _, _),
             let .promptSubmitted(session, _, _, _), let .toolStarted(session, _, _, _, _),
             let .toolCompleted(session, _, _, _), let .turnCompleted(session, _, _),
             let .sessionEnded(session, _): return session
        }
    }
}

public struct ToolAction: Equatable, Sendable {
    public let rowText: String
    public let fullText: String

    public init?(name: String, input: [String: String]) {
        let lower = name.lowercased()
        if ["bash", "shell", "exec_command"].contains(lower), let command = Self.text(input["command"] ?? input["cmd"]) {
            fullText = command
            rowText = "running `\(Self.short(command, limit: 64))…`"
        } else if ["edit", "write", "multiedit"].contains(lower), let path = Self.text(input["file_path"] ?? input["path"]) {
            fullText = path
            rowText = "editing \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if ["read", "readfile"].contains(lower), let path = Self.text(input["file_path"] ?? input["path"]) {
            fullText = path
            rowText = "reading \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if ["glob", "grep", "search"].contains(lower) {
            fullText = [input["pattern"], input["path"]].compactMap(Self.text).joined(separator: " in ")
            guard !fullText.isEmpty else { return nil }
            rowText = "reading files"
        } else {
            return nil
        }
    }

    private static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private static func short(_ value: String, limit: Int) -> String {
        let oneLine = value.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? value
        return String(oneLine.prefix(limit))
    }
}

public struct DesktopRunningTurn: Equatable, Identifiable, Sendable {
    public let session: UUID
    public let turn: UUID
    public let startedAt: String
    public fileprivate(set) var prompt: String? = nil
    public fileprivate(set) var action: ToolAction? = nil
    fileprivate var toolUseID: String? = nil
    public var id: TurnIdentity { TurnIdentity(session: session, turn: turn) }
    public var rowText: String? { action?.rowText ?? QuestionPrompt.display(prompt, limit: 160) }
    public var fullAction: String? { action?.fullText }
    public var fullPrompt: String? { prompt }
    public var promptIsTruncated: Bool {
        guard action == nil, let prompt else { return false }
        return QuestionPrompt.displayIsTruncated(prompt, limit: 160)
    }
}

public struct DesktopCompletion: Equatable, Identifiable, Sendable {
    public let session: UUID
    public let turn: UUID
    public let receivedAt: String
    public var id: TurnIdentity { TurnIdentity(session: session, turn: turn) }
}

/// Codex's own background jobs, which are not the user's work. Codex runs memory consolidation as a
/// session of its own with the user's hooks: it reports SessionStart, UserPromptSubmit and tool
/// events like any session, but writes no rollout and was seen shutting down without Stop or
/// SessionEnd, so its row would stay working. Codex submits the prompt itself, and this heading is
/// a constant in each Codex checked (CLI 0.154.0, 0.160.1 and 0.161.0, and the desktop app's
/// bundled CLI). If Codex changes it, the job shows as working again rather than hiding a user's
/// session.
public enum CodexBackgroundJob {
    static let memoryConsolidationHeading = "## Memory Writing Agent: Phase 2 (Consolidation)"

    public static func isBackgroundJob(prompt: String?) -> Bool {
        prompt?.hasPrefix(memoryConsolidationHeading) == true
    }
}

public struct DesktopState: Sendable {
    public private(set) var running: [DesktopRunningTurn] = []
    public private(set) var completed: [DesktopCompletion] = []
    /// Sessions identified as Codex's background jobs; their later events add nothing.
    private var backgroundJobs: Set<UUID> = []

    public init() {}

    public mutating func apply(_ event: DesktopEvent) {
        guard !backgroundJobs.contains(event.session) else { return }
        switch event {
        case let .sessionStarted(session, _):
            running.removeAll { $0.session == session }
        case let .turnStarted(session, turn, receivedAt):
            running.removeAll { $0.session == session }
            running.append(DesktopRunningTurn(session: session, turn: turn, startedAt: receivedAt))
        case let .promptSubmitted(session, turn, prompt, receivedAt):
            running.removeAll { $0.session == session }
            if CodexBackgroundJob.isBackgroundJob(prompt: prompt) {
                backgroundJobs.insert(session)
                return
            }
            running.append(DesktopRunningTurn(session: session, turn: turn, startedAt: receivedAt, prompt: prompt))
        case let .toolStarted(session, turn, useID, action, _):
            guard let index = running.firstIndex(where: { $0.session == session && $0.turn == turn }) else { return }
            running[index].toolUseID = useID
            running[index].action = action
        case let .toolCompleted(session, turn, useID, _):
            guard let index = running.firstIndex(where: { $0.session == session && $0.turn == turn }),
                  running[index].toolUseID == useID else { return }
            running[index].toolUseID = nil
            running[index].action = nil
        case let .turnCompleted(session, turn, receivedAt):
            running.removeAll { $0.id == TurnIdentity(session: session, turn: turn) }
            guard !completed.contains(where: { $0.id == TurnIdentity(session: session, turn: turn) }) else { return }
            completed.append(DesktopCompletion(session: session, turn: turn, receivedAt: receivedAt))
        case let .sessionEnded(session, _):
            running.removeAll { $0.session == session }
        }
    }

    public static func replay(_ events: [DesktopEvent], toolEventsSince: Double = -.infinity) -> DesktopState {
        var state = DesktopState()
        events.forEach { event in
            switch event {
            case let .toolStarted(_, _, _, _, capturedAt), let .toolCompleted(_, _, _, capturedAt):
                if capturedAt >= toolEventsSince { state.apply(event) }
            default: state.apply(event)
            }
        }
        return state
    }
}

public enum DesktopEventReader {
    /// A hook input is capped at 64 KiB; normalized metadata and JSON escaping can make its record larger.
    public static let maximumRecordSize = 128 * 1024

    private struct Record: Decodable {
        let hook_event_name: String
        let session_id: UUID
        let turn_id: UUID?
        let received_at: String
        let captured_at: Double?
        let prompt: String?
        let tool_name: String?
        let tool_use_id: String?
        let tool_input: [String: String]?
    }

    /// Replays only the newest `HookEventListing.maximumRecords` records; an overgrown or
    /// unreadable directory yields no events.
    public static func read(from directory: URL) -> [DesktopEvent] {
        read(from: directory, cache: HookFileCache()).events
    }

    /// `read(from:)`, reusing record bytes from `cache` (usually the same scan's
    /// `ReminderScan.hookCache`) while their files are unchanged.
    public static func read(from directory: URL, cache: HookFileCache) -> (events: [DesktopEvent], cache: HookFileCache) {
        var next = HookFileCache()
        guard let listing = HookEventListing.listing(in: directory) else { return ([], next) }
        let events: [DesktopEvent] = listing.records
            .compactMap { url -> (Record, String)? in
                guard let data = cache.bytes(url, limit: maximumRecordSize, next: &next),
                      let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
                return (record, url.lastPathComponent)
            }
            .sorted {
                let left = $0.0.captured_at ?? RolloutTimestamp.parse($0.0.received_at)
                let right = $1.0.captured_at ?? RolloutTimestamp.parse($1.0.received_at)
                if let left, let right, left != right { return left < right }
                return $0.0.received_at == $1.0.received_at ? $0.1 < $1.1 : $0.0.received_at < $1.0.received_at
            }
            .compactMap { source in
                let record = source.0
                switch record.hook_event_name {
                case "SessionStart": return .sessionStarted(session: record.session_id, receivedAt: record.received_at)
                case "UserPromptSubmit":
                    guard let turn = record.turn_id else { return nil }
                    return .promptSubmitted(session: record.session_id, turn: turn, prompt: record.prompt, receivedAt: record.received_at)
                case "PreToolUse":
                    guard let turn = record.turn_id, let name = record.tool_name, let useID = record.tool_use_id else { return nil }
                    return .toolStarted(session: record.session_id, turn: turn, useID: useID,
                                        action: ToolAction(name: name, input: record.tool_input ?? [:]),
                                        capturedAt: record.captured_at ?? RolloutTimestamp.parse(record.received_at) ?? 0)
                case "PostToolUse":
                    guard let turn = record.turn_id, let useID = record.tool_use_id else { return nil }
                    return .toolCompleted(session: record.session_id, turn: turn, useID: useID,
                                          capturedAt: record.captured_at ?? RolloutTimestamp.parse(record.received_at) ?? 0)
                case "Stop":
                    guard let turn = record.turn_id else { return nil }
                    return .turnCompleted(session: record.session_id, turn: turn, receivedAt: record.received_at)
                case "SessionEnd": return .sessionEnded(session: record.session_id, receivedAt: record.received_at)
                default: return nil
                }
            }
        return (events, next)
    }
}
