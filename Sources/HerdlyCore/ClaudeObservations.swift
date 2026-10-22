import Foundation

/// The bounded, source-scoped projection of one Claude hook directory.
public struct ClaudeObservationScan: Equatable, Sendable {
    public let sourceScope: String
    public let observations: [AgentObservation]
    public let available: Bool
    /// What each turn's result card shows, keyed by the exact turn. Transient: never persisted.
    public let results: [AgentTurnIdentity: ClaudeTurnResult]
    /// When the newest SessionStart record was captured, nil when there is none. It clears this
    /// agent's Restart required after an update (AgentUpdates).
    public let latestSessionStartAt: Double?

    public init(sourceScope: String, observations: [AgentObservation] = [], available: Bool = true,
                results: [AgentTurnIdentity: ClaudeTurnResult] = [:], latestSessionStartAt: Double? = nil) {
        self.sourceScope = sourceScope
        self.observations = observations
        self.available = available
        self.results = results
        self.latestSessionStartAt = latestSessionStartAt
    }
}

/// One Claude turn's prompt and the last message its latest Stop carried, for the result card (#341).
/// Deliberately not Codable, like `CompletionPreview`, so neither text enters the attention snapshot.
public struct ClaudeTurnResult: Equatable, Sendable {
    public let identity: AgentTurnIdentity
    /// The bounded prompt fallback, already ending in "…" when shortened.
    public let prompt: String?
    /// Nil when the latest Stop carried none (older Claude Code, malformed field) or the turn went on after it.
    public let message: String?
    /// True when the helper kept only the start of the message; the rest stays in Claude.
    public let messageShortened: Bool

    public init(identity: AgentTurnIdentity, prompt: String?, message: String?, messageShortened: Bool = false) {
        self.identity = identity
        self.prompt = prompt
        self.message = message
        self.messageShortened = messageShortened
    }

    /// The result card's body, read the way a Codex result reads: the message clamped by
    /// `CompletionPreview` and the prompt to fold. A missing message shows no message line at all.
    public var details: SpotlightDetails {
        let preview = message.flatMap { CompletionPreview($0, sourceShortened: messageShortened) }
        return SpotlightDetails(request: nil, directory: nil, originalPrompt: prompt,
                                response: preview.map { .available($0) })
    }
}

/// What earlier scans decoded from one Claude hook directory, reused while a record file's
/// `FileStamp` is unchanged. The helper writes each record once, atomically, under a new name, so
/// normally only new records are opened. A scan carries forward only the files it listed, and the
/// whole cache resets when the installation or observation start differs.
public struct ClaudeRecordCache: Sendable {
    fileprivate struct Entry: Sendable {
        let stamp: FileStamp
        let record: ClaudeObservationReader.Record?
    }

    fileprivate var installationID: String?
    fileprivate var observingSince: Double?
    fileprivate var entries: [String: Entry] = [:]

    public init() {}

    /// Number of record files held, for tests.
    var count: Int { entries.count }
}

/// Reads only Herdly's normalized Claude records. A malformed record is ignored; an unreadable
/// directory makes the whole root unavailable so it cannot clear another root's state.
public enum ClaudeObservationReader {
    public static let maximumRecordSize = 128 * 1024
    public static let maximumIdentifier = 256
    /// Claude's prompt is kept only as the working row's fallback text, so at most this many
    /// characters of it are stored. A longer prompt is shortened, never dropped.
    public static let maximumPrompt = 240
    /// The record key the helper sets when it stored only the start of the prompt.
    public static let promptShortenedKey = "prompt_shortened"
    /// Claude's Stop input field holding its last reply, kept under the same key in Herdly's record.
    public static let lastMessageKey = "last_assistant_message"
    /// The record key the helper sets when it stored only the start of the last message.
    public static let lastMessageShortenedKey = "last_assistant_message_shortened"
    /// The most of the last message kept: what the card's "Show all" can show.
    public static let maximumLastMessage = CompletionPreview.maximumFullCharacters
    /// A byte cap on the kept message, so even a message JSON doubles when escaping keeps its record
    /// well under `maximumRecordSize`; otherwise the whole Stop record would be ignored.
    public static let maximumLastMessageBytes = 32 * 1024
    public static let maximumToolFreshness: Double = 30

    // `@unchecked Sendable`: `toolInput` holds only the immutable Foundation property-list values
    // `JSONSerialization` returned (read without mutable-container options), and a record is never
    // mutated after decoding, so sharing it between scans on different threads is safe.
    fileprivate struct Record: @unchecked Sendable {
        let fileName: String
        let event: String
        let session: String
        let capturedAt: Double
        let promptID: String?
        let prompt: String?
        let promptShortened: Bool
        /// A Stop's bounded last message and whether it was shortened.
        let lastMessage: KeptText?
        let toolName: String?
        let toolUseID: String?
        let helperRequestID: String?
        let hookRequestID: String?
        let toolInput: [String: Any]
        /// What the helper validated and bounded for a decidable non-Bash request (ClaudeDirectApproval).
        let approvalDetails: ApprovalDetails?
    }

    private struct Tool {
        let id: String
        let name: String
        let input: [String: String]
        let at: Double
        /// The absolute file or notebook path the call targets, kept apart from the display-bounded input.
        var target: String? = nil
    }

    private struct Turn {
        let session: String
        let prompt: String
        var promptText: String?
        var promptShortened: Bool
        /// The latest Stop's last message; cleared when the turn goes on after it.
        var lastMessage: KeptText?
        var startedAt: Double
        var updatedAt: Double
        var tool: Tool?
        var tools: [String: Tool]
        var question: AgentQuestion?
        var approval: AgentApproval?
        var terminal: AgentOutcome?
        var provisionalStopAt: Double?
        var closedAt: Double?
    }

    public static func scan(events: URL, sourceScope: String, installationID: String,
                            observingSince: Double = -.infinity,
                            now: Double = Date().timeIntervalSince1970) -> ClaudeObservationScan {
        scan(events: events, sourceScope: sourceScope, installationID: installationID, observingSince: observingSince,
             now: now, cache: ClaudeRecordCache()).scan
    }

    /// `scan`, reusing records decoded by the previous scan of the same directory (`cache`, as the
    /// previous call returned it) while their files are unchanged.
    public static func scan(events: URL, sourceScope: String, installationID: String,
                            observingSince: Double = -.infinity, now: Double = Date().timeIntervalSince1970,
                            cache: ClaudeRecordCache) -> (scan: ClaudeObservationScan, cache: ClaudeRecordCache) {
        let scope = normalizedScope(sourceScope)
        guard isDirectory(events),
              let listing = HookEventListing.listing(in: events) else {
            return (ClaudeObservationScan(sourceScope: scope, available: false), cache)
        }
        let reusable = cache.installationID == installationID && cache.observingSince == observingSince
        var next = ClaudeRecordCache()
        next.installationID = installationID
        next.observingSince = observingSince
        let records = listing.records
            .compactMap { url -> Record? in
                // A link or a path that cannot be stat'ed is never a record, as `record(at:)` decides.
                guard let stamp = FileStamp(url, followingLinks: false) else { return nil }
                if reusable, let entry = cache.entries[url.path], entry.stamp == stamp {
                    next.entries[url.path] = entry
                    return entry.record
                }
                let record = stamp.isRegularFile ? record(at: url, installationID: installationID, observingSince: observingSince) : nil
                next.entries[url.path] = ClaudeRecordCache.Entry(stamp: stamp, record: record)
                return record
            }
            .sorted {
                if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
                if $0.session != $1.session { return $0.session < $1.session }
                return $0.fileName < $1.fileName
            }

        var turns: [AgentTurnIdentity: Turn] = [:]
        var sessionPrompts: [String: String] = [:]
        var endedSessions = Set<String>()
        var sessionEndAt: [String: Double] = [:]
        var seenApprovals = Set<AgentCallIdentity>()
        var seenQuestions = Set<AgentCallIdentity>()
        var latestSessionStartAt: Double?

        for record in records {
            switch record.event {
            case "SessionStart":
                latestSessionStartAt = max(latestSessionStartAt ?? record.capturedAt, record.capturedAt)
                endedSessions.remove(record.session)
                sessionEndAt.removeValue(forKey: record.session)
            case "SessionEnd":
                endedSessions.insert(record.session)
                sessionEndAt[record.session] = max(sessionEndAt[record.session] ?? -.infinity,
                                                   record.capturedAt)
                if let prompt = sessionPrompts[record.session] {
                    let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                        session: record.session, surface: .cli)
                    let turnID = AgentTurnIdentity(session: identity, turn: prompt)
                    if var turn = turns[turnID] {
                        turn.tool = nil
                        turn.tools.removeAll()
                        turn.question = nil
                        turn.approval = nil
                        turn.updatedAt = max(turn.updatedAt, record.capturedAt)
                        turn.closedAt = max(turn.closedAt ?? record.capturedAt, record.capturedAt)
                        turns[turnID] = turn
                    }
                }
            case "UserPromptSubmit":
                guard let promptID = valid(record.promptID) else { continue }
                if let endedAt = sessionEndAt[record.session], record.capturedAt > endedAt {
                    endedSessions.remove(record.session)
                    sessionEndAt.removeValue(forKey: record.session)
                }
                if let previousPrompt = sessionPrompts[record.session], previousPrompt != promptID {
                    let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                        session: record.session, surface: .cli)
                    let previousID = AgentTurnIdentity(session: identity, turn: previousPrompt)
                    if var previous = turns[previousID] {
                        previous.tool = nil
                        previous.tools.removeAll()
                        previous.question = nil
                        previous.approval = nil
                        previous.updatedAt = max(previous.updatedAt, record.capturedAt)
                        previous.closedAt = max(previous.closedAt ?? record.capturedAt, record.capturedAt)
                        turns[previousID] = previous
                    }
                }
                sessionPrompts[record.session] = promptID
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                if var existing = turns[turnID] {
                    if existing.terminal == nil, let closedAt = existing.closedAt, record.capturedAt > closedAt {
                        existing.closedAt = nil
                    }
                    if existing.promptText == nil, let prompt = promptFallback(record.prompt) {
                        existing.promptText = prompt.text
                        existing.promptShortened = record.promptShortened || prompt.shortened
                    }
                    existing.startedAt = min(existing.startedAt, record.capturedAt)
                    turns[turnID] = existing
                } else {
                    let prompt = promptFallback(record.prompt)
                    turns[turnID] = Turn(session: record.session, prompt: promptID,
                                         promptText: prompt?.text,
                                         promptShortened: prompt.map { record.promptShortened || $0.shortened } ?? false,
                                         lastMessage: nil, startedAt: record.capturedAt,
                                         updatedAt: record.capturedAt, tool: nil, tools: [:], question: nil,
                                         approval: nil, terminal: nil, provisionalStopAt: nil, closedAt: nil)
                }
            case "PreToolUse":
                guard let promptID = valid(record.promptID), let toolID = valid(record.toolUseID),
                      let name = bounded(record.toolName), !name.isEmpty else { continue }
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                guard var turn = turns[turnID] else { continue }
                if let closedAt = turn.closedAt {
                    guard record.capturedAt > closedAt else { continue }
                    turn.closedAt = nil
                    turn.terminal = nil
                    turn.provisionalStopAt = nil
                    turn.lastMessage = nil
                }
                if let endedAt = sessionEndAt[record.session], record.capturedAt > endedAt {
                    endedSessions.remove(record.session)
                    sessionEndAt.removeValue(forKey: record.session)
                }
                let input = stringInput(record.toolInput)
                let tool = Tool(id: toolID, name: name, input: input, at: record.capturedAt,
                                target: ClaudeDirectApproval.target(toolName: name, toolInput: record.toolInput))
                turn.tools[toolID] = tool
                turn.tool = tool
                turn.updatedAt = max(turn.updatedAt, record.capturedAt)
                if name == "AskUserQuestion", let question = question(from: record, identity: identity,
                                                                         turn: promptID, at: record.capturedAt) {
                    if seenQuestions.insert(question.id).inserted
                        || (turn.question?.helperRequestID == nil && question.helperRequestID != nil) {
                        turn.question = question
                    }
                }
                turn.terminal = nil
                turns[turnID] = turn
            case "PostToolUse", "PostToolUseFailure":
                guard let promptID = valid(record.promptID), let toolID = valid(record.toolUseID) else { continue }
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                guard var turn = turns[turnID], let tool = turn.tools[toolID],
                      tool.at <= record.capturedAt else { continue }
                turn.tools.removeValue(forKey: toolID)
                turn.tool = turn.tools.values.max { lhs, rhs in
                    lhs.at == rhs.at ? lhs.id < rhs.id : lhs.at < rhs.at
                }
                if turn.question?.identity.call == toolID { turn.question = nil }
                if turn.approval?.identity.call == toolID { turn.approval = nil }
                turn.updatedAt = max(turn.updatedAt, record.capturedAt)
                turn.provisionalStopAt = nil
                turns[turnID] = turn
            case "PostToolBatch":
                guard let promptID = valid(record.promptID) else { continue }
                let ids = record.toolInput["tool_use_ids"] as? [String]
                    ?? (record.toolInput["tool_uses"] as? [[String: Any]] ?? []).compactMap { $0["tool_use_id"] as? String }
                guard !ids.isEmpty else { continue }
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                guard var turn = turns[turnID] else { continue }
                let matching = turn.tools.values.filter { ids.contains($0.id) && $0.at <= record.capturedAt }
                guard !matching.isEmpty else { continue }
                for tool in matching { turn.tools.removeValue(forKey: tool.id) }
                turn.tool = turn.tools.values.max { lhs, rhs in
                    lhs.at == rhs.at ? lhs.id < rhs.id : lhs.at < rhs.at
                }
                if let question = turn.question, matching.contains(where: { $0.id == question.identity.call }) {
                    turn.question = nil
                }
                if let approval = turn.approval, matching.contains(where: { $0.id == approval.identity.call }) {
                    turn.approval = nil
                }
                turn.updatedAt = max(turn.updatedAt, record.capturedAt)
                turns[turnID] = turn
            case "PermissionRequest":
                guard let promptID = valid(record.promptID), let name = bounded(record.toolName),
                      ClaudeDirectApproval.tools.contains(name) else { continue }
                // A file request is shown only with the helper's validated details, and only for the one
                // uncompleted call of that tool on the same path. Bash keeps its original rule.
                let fileDetails = name == "Bash" ? nil : record.approvalDetails
                guard name == "Bash" || fileDetails?.command != nil else { continue }
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                guard var turn = turns[turnID] else { continue }
                let candidates = turn.tools.values.filter {
                    $0.name == name && $0.at <= record.capturedAt && (fileDetails == nil || $0.target == fileDetails?.command)
                }
                guard candidates.count == 1, let tool = candidates.first else { continue }
                let call = AgentCallIdentity(session: identity, turn: promptID, call: tool.id)
                guard seenApprovals.insert(call).inserted else { continue }
                let command = tool.input["command"] ?? tool.input["cmd"]
                let details = fileDetails ?? ApprovalDetails(action: "Bash", command: command)
                turn.approval = AgentApproval(session: identity, turn: promptID, call: tool.id,
                                              arrivedAt: record.capturedAt, details: details,
                                              hookRequestID: record.hookRequestID)
                turns[turnID] = turn
            case "StopFailure":
                guard let promptID = valid(record.promptID) else { continue }
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                guard var turn = turns[turnID] else { continue }
                turn.tool = nil
                turn.tools.removeAll()
                turn.question = nil
                turn.approval = nil
                turn.updatedAt = max(turn.updatedAt, record.capturedAt)
                turn.closedAt = max(turn.closedAt ?? record.capturedAt, record.capturedAt)
                turn.provisionalStopAt = nil
                turn.lastMessage = nil
                turn.terminal = AgentOutcome(session: identity, turn: promptID, status: .failed,
                                             arrivedAt: record.capturedAt)
                turns[turnID] = turn
            case "Stop":
                // Stop can continue into another prompt. It clears a stale tool label but never
                // becomes Finished without the later inventory confirmation slice.
                guard let promptID = valid(record.promptID) else { continue }
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                if var turn = turns[turnID] {
                    turn.tool = nil
                    turn.tools.removeAll()
                    turn.question = nil
                    turn.approval = nil
                    turn.updatedAt = max(turn.updatedAt, record.capturedAt)
                    turn.closedAt = max(turn.closedAt ?? record.capturedAt, record.capturedAt)
                    turn.provisionalStopAt = record.capturedAt
                    // The latest Stop decides: one without a message never keeps an earlier Stop's.
                    turn.lastMessage = record.lastMessage
                    turns[turnID] = turn
                }
            default:
                continue
            }
        }

        let observations = turns.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.prompt < $1.prompt
        }.flatMap { turn -> [AgentObservation] in
            let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                session: turn.session, surface: .cli)
            // Every submitted prompt is a reply, including one in a session that has since ended.
            let replied = AgentObservation.replied(AgentTurnIdentity(session: identity, turn: turn.prompt),
                                                   submittedAt: turn.startedAt)
            let isCurrentPrompt = sessionPrompts[turn.session] == turn.prompt
            guard ((!endedSessions.contains(turn.session) && (turn.closedAt == nil || isCurrentPrompt))
                   || turn.terminal != nil) else { return [replied] }
            var result: [AgentObservation] = [replied]
            if let terminal = turn.terminal {
                result.append(.outcome(terminal))
            } else {
                let freshTool = turn.tool.flatMap { tool -> Tool? in
                    guard now.isFinite, tool.at.isFinite, tool.at <= now,
                          now - tool.at <= maximumToolFreshness else { return nil }
                    return tool
                }
                result.append(.running(AgentRunning(session: identity, turn: turn.prompt, arrivedAt: turn.startedAt,
                                                    updatedAt: turn.updatedAt,
                                                    prompt: turn.promptText, promptShortened: turn.promptShortened,
                                                    toolName: freshTool?.name,
                                                    toolInput: freshTool?.input ?? [:])))
                if let question = turn.question { result.append(.question(question)) }
                if let approval = turn.approval { result.append(.approval(approval)) }
            }
            if let stopAt = turn.provisionalStopAt {
                result.append(.provisionalStop(AgentProvisionalStop(identity: AgentTurnIdentity(session: identity,
                                                                                               turn: turn.prompt),
                                                                     arrivedAt: stopAt)))
            }
            return result
        }
        var results: [AgentTurnIdentity: ClaudeTurnResult] = [:]
        for turn in turns.values where turn.promptText != nil || turn.lastMessage != nil {
            let identity = AgentTurnIdentity(session: AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                                           session: turn.session, surface: .cli),
                                             turn: turn.prompt)
            results[identity] = ClaudeTurnResult(identity: identity, prompt: turn.promptText,
                                                 message: turn.lastMessage?.text,
                                                 messageShortened: turn.lastMessage?.shortened ?? false)
        }
        return (ClaudeObservationScan(sourceScope: scope, observations: observations, results: results,
                                      latestSessionStartAt: latestSessionStartAt), next)
    }

    private static func record(at url: URL, installationID: String, observingSince: Double) -> Record? {
        guard isRegularFile(url), let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: maximumRecordSize + 1) else { return nil }
        try? handle.close()
        guard data.count <= maximumRecordSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["source"] as? String == ClaudeSetupRequirements.helperSource,
              object["installation_id"] as? String == installationID,
              let event = bounded(object["hook_event_name"] as? String), !event.isEmpty,
              let session = valid(object["session_id"] as? String),
              let captured = (object["captured_at"] as? NSNumber)?.doubleValue,
              captured.isFinite, captured >= observingSince else { return nil }
        return Record(fileName: url.lastPathComponent, event: event, session: session, capturedAt: captured,
                      promptID: object["prompt_id"] as? String, prompt: object["prompt"] as? String,
                      promptShortened: object[promptShortenedKey] as? Bool ?? false,
                      lastMessage: event == "Stop"
                        ? lastMessage(object[lastMessageKey] as? String).map {
                            KeptText(text: $0.text, shortened: $0.shortened || object[lastMessageShortenedKey] as? Bool == true)
                        } : nil,
                      toolName: object["tool_name"] as? String, toolUseID: object["tool_use_id"] as? String,
                      helperRequestID: valid(object["helper_request_id"] as? String),
                      hookRequestID: valid(object["approval_request_id"] as? String),
                      toolInput: object["tool_input"] as? [String: Any] ?? [:],
                      approvalDetails: approvalDetails(object["approval_details"]))
    }

    /// The helper's display details for a decidable file or web request, re-bounded: an action, an absolute
    /// path, URL, or query matching its label, and at most a few previews. Anything else is dropped, so the
    /// request stays native.
    private static func approvalDetails(_ value: Any?) -> ApprovalDetails? {
        guard let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let details = try? JSONDecoder().decode(ApprovalDetails.self, from: data),
              let action = details.action, bounded(action) != nil,
              ClaudeDirectApproval.validCommand(details.command, label: details.commandLabel),
              let command = details.command,
              (details.longText?.count ?? 0) <= ClaudeDirectApproval.maximumPreview * 2 + 512,
              details.longText?.contains(where: { $0 == "\u{1b}" || $0 == "\u{7}" || $0 == "\u{0}" }) != true
        else { return nil }
        return ApprovalDetails(action: action, command: command, longText: details.longText,
                               commandLabel: details.commandLabel)
    }

    private static func question(from record: Record, identity: AgentSessionIdentity, turn: String,
                                 at: Double) -> AgentQuestion? {
        guard let call = valid(record.toolUseID),
              let parsed = QuestionPrompt.parseCall(toolInput: record.toolInput),
              !parsed.prompts.isEmpty, parsed.count <= QuestionPrompt.maximumQuestions else { return nil }
        return AgentQuestion(session: identity, turn: turn, call: call, arrivedAt: at,
                             prompts: parsed.prompts, helperRequestID: record.helperRequestID)
    }

    private static func stringInput(_ input: [String: Any]) -> [String: String] {
        input.compactMapValues { value in
            guard let text = value as? String else { return nil }
            return boundedText(text)
        }
    }

    private static func valid(_ value: String?) -> String? {
        guard let value = bounded(value), !value.isEmpty else { return nil }
        return value
    }

    private static func bounded(_ value: String?, limit: Int = maximumIdentifier) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= limit,
              !value.contains(where: { $0.isNewline || $0 == "\u{1b}" || $0 == "\u{7}" }) else { return nil }
        return value
    }

    /// Text the helper stored and the reader re-bounds: the kept text, and whether it is only the start.
    public struct KeptText: Equatable, Sendable {
        public let text: String
        public let shortened: Bool
    }

    /// The prompt as the helper stores it and the reader shows it: trimmed and, past
    /// `maximumPrompt` characters, cut to that many plus an ellipsis. Nil when empty or when the
    /// prompt holds a character a terminal could act on.
    public static func promptFallback(_ value: String?) -> KeptText? {
        guard let value, !value.contains(where: { $0 == "\u{1b}" || $0 == "\u{7}" || $0 == "\u{0}" }),
              let text = QuestionPrompt.display(value, limit: maximumPrompt) else { return nil }
        return KeptText(text: text, shortened: QuestionPrompt.displayIsTruncated(value, limit: maximumPrompt))
    }

    /// Claude's last message as the helper stores it and the reader re-reads it: line breaks kept
    /// (CR and CRLF become LF), tabs kept, every other control character removed, trimmed, and past
    /// `maximumLastMessage` characters or `maximumLastMessageBytes` UTF-8 bytes cut to its start, with no
    /// ellipsis (the card adds one). Nil when nothing readable is left.
    public static func lastMessage(_ value: String?) -> KeptText? {
        guard let value else { return nil }
        let lines = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in lines.unicodeScalars where scalar == "\n" || scalar == "\t"
            || !(scalar.properties.generalCategory == .control) {
            scalars.append(scalar)
        }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var kept = ""
        var bytes = 0
        var count = 0
        for character in text {
            let size = character.utf8.count
            guard count < maximumLastMessage, bytes + size <= maximumLastMessageBytes else {
                return KeptText(text: kept.trimmingCharacters(in: .whitespacesAndNewlines), shortened: true)
            }
            kept.append(character)
            bytes += size
            count += 1
        }
        return KeptText(text: kept, shortened: false)
    }

    private static func boundedText(_ value: String?, limit: Int = maximumIdentifier) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= limit,
              !value.contains(where: { $0 == "\u{1b}" || $0 == "\u{7}" || $0 == "\u{0}" }) else { return nil }
        return value
    }

    private static func normalizedScope(_ value: String) -> String {
        URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { return false }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { return false }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }
}

public extension AgentAttentionQueue {
    /// Reconciles one Claude root only. An unavailable root leaves its existing observations intact.
    mutating func apply(_ scan: ClaudeObservationScan, now: Double? = nil) {
        guard scan.available else { return }
        let scope = scan.sourceScope
        let incoming = scan.observations
        let ids = Set(incoming.compactMap { observation -> AgentAttentionID? in
            switch observation {
            case let .approval(value): return .approval(value.id)
            case let .question(value): return .question(value.id)
            case let .outcome(value): return .outcome(value.id)
            case let .running(value): return .running(value.id)
            case .provisionalStop, .replied: return nil
            case .resolved: return nil
            }
        })
        reconcile(source: .claude, sourceScope: scope, keeping: ids)
        for observation in incoming { apply(observation, now: now) }
    }
}
