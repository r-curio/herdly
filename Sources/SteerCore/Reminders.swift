import Foundation

public struct Reminder: Codable, Equatable, Identifiable, Sendable {
    public let request_id: UUID
    public let session_id: UUID
    public let turn_id: UUID
    public let outcome: String
    public let source: AttentionSource?
    public let received_at: String?
    public let captured_at: Double?
    public let task_name: String?
    public let project: String?
    public let action: String?
    public let command: String?
    public let reason: String?
    public let long_text: String?
    public var id: UUID { request_id }

    public init(request_id: UUID, session_id: UUID, turn_id: UUID, outcome: String,
                received_at: String? = nil, captured_at: Double? = nil, source: AttentionSource? = nil,
                task_name: String? = nil, project: String? = nil, action: String? = nil,
                command: String? = nil, reason: String? = nil, long_text: String? = nil) {
        self.request_id = request_id
        self.session_id = session_id
        self.turn_id = turn_id
        self.outcome = outcome
        self.source = source
        self.received_at = received_at
        self.captured_at = captured_at
        self.task_name = task_name
        self.project = project
        self.action = action
        self.command = command
        self.reason = reason
        self.long_text = long_text
    }
}

public struct TurnIdentity: Hashable, Codable, Sendable {
    public let session: UUID
    public let turn: UUID
    public init(session: UUID, turn: UUID) {
        self.session = session
        self.turn = turn
    }
}

public struct ReminderScan: Sendable {
    public var reminders: [Reminder] = []
    public var attentionRequests: [AttentionRequest] = []
    /// Fresh pending requests with no companion receipt yet; the app issues receipts for them.
    public var awaitingReceipt: [ApprovalRequest] = []
    /// Native resolutions read from session rollouts for handed-back requests.
    public var resolvedRequests: [ApprovalResolution] = []
    /// Latest SessionEnd hook time per session; a request received before it cannot still be pending.
    public var sessionEnds: [UUID: Double] = [:]
    public var completed: Set<TurnIdentity> = []
    public var canceled: Set<TurnIdentity> = []
    /// Exact-turn response excerpts found during this scan. The app only retains excerpts for
    /// completions first observed during this launch; they are never persisted.
    public var completionPreviews: [TurnIdentity: CompletionPreview] = [:]
    public var turnContexts: [TurnIdentity: SpotlightRecordContext] = [:]
    /// User-input calls still waiting for an answer, and those the rollout shows answered.
    public var questions: [AttentionQuestion] = []
    public var answeredQuestions: Set<QuestionIdentity> = []
    public var cliEvents: [CLIEvent] = []
    public var cliCompletions: [CLICompletion] = []
    public var cliSessions: Set<UUID> = []
    public var liveCLISessions: Set<UUID> = []
    public var cliState = CLIState()
    /// Sessions that ended and did not start again. `sessionEnds` keeps a session's latest end even
    /// after a resume (`codex resume`, or the TUI reopening a thread) starts it again, because a
    /// request received before that end still cannot be pending; liveness must not use it alone.
    public var endedSessions: Set<UUID> { Set(sessionEnds.keys).subtracting(cliState.liveSessions) }
    /// Sessions whose session-id title was in this scan's Ghostty inventory. The app remembers them
    /// across scans so a session stays CLI, and can end, after its tab is gone.
    public var titledCLISessions: Set<UUID> = []
}

public struct ReminderQueue: Sendable {
    public private(set) var items: [Reminder] = []
    private var resolved: Set<TurnIdentity> = []
    public init() {}
    public func visibleItems(cliSessions: Set<UUID>, desktopForeground: Bool) -> [Reminder] {
        items.filter { !desktopForeground || cliSessions.contains($0.session_id) }
    }
    public mutating func apply(_ scan: ReminderScan) {
        resolved.formUnion(scan.completed)
        resolved.formUnion(scan.canceled)
        for item in scan.reminders where item.outcome == "no_decision" && !items.contains(where: { $0.id == item.id }) {
            items.append(item)
        }
        items.removeAll { resolved.contains(TurnIdentity(session: $0.session_id, turn: $0.turn_id)) }
    }
}

public enum ReminderReader {
    private static func bounded(_ url: URL, limit: Int) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
        return bytes
    }

    /// The first line of a rollout, read without loading the file; nil when it is longer than `limit`.
    private static func firstLine(_ url: URL, limit: Int) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: limit), let end = bytes.firstIndex(of: 10) else { return nil }
        return bytes[bytes.startIndex..<end]
    }

    /// The session id and, for a sub-agent thread, its parent's id from a rollout's `session_meta`.
    /// Codex desktop records spawned agents and guardian reviews as their own rollouts whose
    /// `parent_thread_id` (or `forked_from_id`) names the thread that owns them.
    static func rolloutParent(_ url: URL) -> (session: UUID, parent: UUID?)? {
        guard let line = firstLine(url, limit: 64 * 1024),
              let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              event["type"] as? String == "session_meta",
              let payload = event["payload"] as? [String: Any],
              let session = (payload["id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        let parent = ((payload["parent_thread_id"] as? String) ?? (payload["forked_from_id"] as? String)).flatMap(UUID.init(uuidString:))
        return (session, parent)
    }

    /// At most this many rollout heads are read per scan when looking for sub-agent threads.
    static let maximumChildProbes = 200

    public static func completed(in data: Data, session: UUID) -> Set<TurnIdentity> {
        evidence(in: data, session: session).completed
    }

    /// Everything one pass over a session rollout tells the queue: ended turns and the user-input
    /// calls Codex posed, split into those still without an output and those answered.
    public struct RolloutEvidence: Equatable, Sendable {
        public var completed: Set<TurnIdentity> = []
        public var canceled: Set<TurnIdentity> = []
        public var completionPreviews: [TurnIdentity: CompletionPreview] = [:]
        public var turnContexts: [TurnIdentity: SpotlightRecordContext] = [:]
        public var pendingQuestions: [AttentionQuestion] = []
        public var answeredQuestions: Set<QuestionIdentity> = []
        public init() {}
    }

    static let userInputTool = "request_user_input"
    static let maximumCallID = 256

    /// Fails closed as a whole: any line that cannot be read yields empty evidence, which the queue
    /// treats as "nothing new this scan", never as resolution or as a new question.
    /// `owner` is the thread that owns this rollout when it is a sub-agent's: Codex writes the
    /// child's own id as `id` and the parent's id as `session_id`.
    public static func evidence(in data: Data, session: UUID, owner: UUID? = nil) -> RolloutEvidence {
        guard data.last == 10, data.count <= 32 * 1024 * 1024 else { return RolloutEvidence() }
        var result = RolloutEvidence()
        var calls: [String: AttentionQuestion] = [:]
        var outputs: Set<String> = []
        var workingDirectory: String?
        var prompts: [UUID: String] = [:]
        var activeTurn: UUID?
        for (index, line) in data.split(separator: 10, omittingEmptySubsequences: false).dropLast().enumerated() {
            guard line.count <= 1024 * 1024,
                  let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = event["payload"] as? [String: Any] else { return RolloutEvidence() }
            if index == 0 {
                guard event["type"] as? String == "session_meta",
                      let id = payload["id"] as? String, UUID(uuidString: id) == session else { return RolloutEvidence() }
                if let explicit = payload["session_id"],
                   (explicit as? String).flatMap(UUID.init(uuidString:)) != (owner ?? session) { return RolloutEvidence() }
                workingDirectory = payload["cwd"] as? String
            } else if event["type"] as? String == "session_meta" {
                // A forked sub-agent rollout repeats its parent's header as its second line.
                guard let owner, (payload["id"] as? String).flatMap(UUID.init(uuidString:)) == owner else { return RolloutEvidence() }
            }
            let type = event["type"] as? String
            let kind = payload["type"] as? String
            if type == "event_msg", kind == "task_started" {
                guard let id = payload["turn_id"] as? String, let turn = UUID(uuidString: id) else { return RolloutEvidence() }
                activeTurn = turn
                result.turnContexts[TurnIdentity(session: session, turn: turn)] = SpotlightRecordContext(
                    workingDirectory: workingDirectory)
            } else if type == "event_msg", let kind, ["task_complete", "turn_aborted"].contains(kind) {
                guard let id = payload["turn_id"] as? String, let turn = UUID(uuidString: id) else { return RolloutEvidence() }
                let identity = TurnIdentity(session: session, turn: turn)
                if kind == "task_complete" {
                    result.completed.insert(identity)
                    result.turnContexts[identity] = SpotlightRecordContext(
                        workingDirectory: workingDirectory, prompt: prompts[turn])
                    if let message = payload["last_agent_message"] as? String,
                       let preview = CompletionPreview(message) {
                        result.completionPreviews[identity] = preview
                    }
                }
                else { result.canceled.insert(identity) }
                if activeTurn == turn { activeTurn = nil }
            } else if type == "event_msg", kind == "user_message", let turn = activeTurn,
                      let message = payload["message"] as? String {
                prompts[turn] = message
                result.turnContexts[TurnIdentity(session: session, turn: turn)] = SpotlightRecordContext(
                    workingDirectory: workingDirectory, prompt: message)
            } else if type == "response_item", kind == "function_call_output" {
                if let callID = payload["call_id"] as? String { outputs.insert(callID) }
            } else if type == "response_item", kind == "function_call", payload["name"] as? String == userInputTool {
                // The call is the evidence Codex is blocked; without an id, turn and time it can be
                // neither cleared nor opened, so it is not recorded. Unreadable text is still a question.
                guard let callID = payload["call_id"] as? String, !callID.isEmpty, callID.utf8.count <= maximumCallID,
                      let turn = ((payload["internal_chat_message_metadata_passthrough"] as? [String: Any])?["turn_id"] as? String)
                        .flatMap(UUID.init(uuidString:)),
                      let at = (event["timestamp"] as? String).flatMap(RolloutTimestamp.parse),
                      calls[callID] == nil else { continue }
                let parsed = (payload["arguments"] as? String).flatMap(QuestionPrompt.parseCall(arguments:))
                calls[callID] = AttentionQuestion(source: .desktop, session: session, turn: turn, callID: callID,
                                                  arrivedAt: at, prompts: parsed?.prompts ?? [], questionCount: parsed?.count)
            }
        }
        for (callID, question) in calls {
            if outputs.contains(callID) { result.answeredQuestions.insert(question.id) }
            else { result.pendingQuestions.append(question) }
        }
        result.pendingQuestions.sort { $0.arrivedAt == $1.arrivedAt ? $0.callID < $1.callID : $0.arrivedAt < $1.arrivedAt }
        return result
    }

    /// The one rollout file for a session, found the way `scan` finds it: a `.jsonl` whose name ends
    /// in the session id. Nil when there is none, more than one, or the tree is too large to walk.
    public static func rolloutURL(for session: UUID, in rollouts: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: rollouts, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { return nil }
        let suffix = session.uuidString.lowercased() + ".jsonl"
        var found: [URL] = []
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count > 50000 { return nil }
            guard url.pathExtension == "jsonl", url.lastPathComponent.lowercased().hasSuffix(suffix) else { continue }
            found.append(url)
        }
        return found.count == 1 ? found[0] : nil
    }

    /// The rollout's evidence as of right now, for the pre-send check before a key is relayed.
    /// Empty when the file cannot be found or read, which the caller treats as "not pending".
    public static func currentEvidence(for session: UUID, in rollouts: URL) -> RolloutEvidence {
        guard let url = rolloutURL(for: session, in: rollouts), let bytes = bounded(url, limit: 32 * 1024 * 1024) else {
            return RolloutEvidence()
        }
        return evidence(in: bytes, session: session)
    }

    /// How long after its SessionStart a daemon-loaded terminal session may go without a tab title
    /// in a Ghostty inventory before `scan` ends it, so a new tab can be inventoried first.
    public static let surfaceGrace: Double = 15
    public static let desktopOriginator = "Codex Desktop"

    /// True when the session's latest end is at or after its latest SessionStart: it is already
    /// ended. A resume after an end makes this false, so a closed tab can end it again.
    private static func endedSinceLatestStart(_ end: Double?, latestStart: Double?) -> Bool {
        guard let end else { return false }
        guard let latestStart else { return true }
        return end >= latestStart
    }

    /// `ghostty` is Ghostty's current terminal-title inventory and `knownCLISessions` the sessions an
    /// earlier inventory already proved. A session is a CLI session when its rollout header says
    /// `source: cli`, when its session-id title is in the inventory, or when it was proved before: a
    /// TUI attached to Codex's app-server daemon is recorded as `vscode`, the desktop's value, so
    /// the header alone no longer tells the surfaces apart (CLI 0.154.0, issue #42).
    ///
    /// A title-proved session whose title is absent from a later inventory has lost its surface.
    /// The daemon keeps the thread loaded and fires no SessionEnd, so Steer dates a session end at
    /// the inventory itself. Only for sessions proved by title: a `source: cli` session in another
    /// terminal is never in Ghostty and still ends by its own hook.
    /// `daemonThreads` are the threads Codex's app-server daemon currently has loaded. The desktop
    /// app runs its own engine, so a loaded thread whose rollout `originator` is not the desktop's
    /// is a terminal session on the daemon (a TUI, or `codex agents`): CLI, even before or after
    /// Ghostty shows its title. Such a session with no tab title in an inventory taken at least
    /// `surfaceGrace` seconds after its SessionStart has no surface, and ends.
    ///
    /// `herdrTitles` says what herdr's panes show (ADR 0012, `HerdrPaneTitles`). A Codex TUI titles
    /// its terminal with its shortened session ID, so that title on a herdr pane proves a CLI
    /// session with a live surface, exactly as a Ghostty tab title does; such a session is not
    /// ended for lacking a Ghostty tab. It does not make the session Ghostty-titled
    /// (`titledCLISessions`): its tab is herdr's, not its own. While the titles are `unknown`, a
    /// session may be on a pane Steer cannot see, so none is ended for lacking a Ghostty tab.
    public static func scan(events: URL, rollouts: URL, ghostty: GhosttyInventory? = nil,
                            knownCLISessions: Set<UUID> = [], daemonThreads: Set<UUID> = [],
                            herdrTitles: HerdrPaneTitles = .notInUse) -> ReminderScan {
        let cliTitles = ghostty?.titles ?? []
        // The titles herdr's panes show, and whether a session lacking a Ghostty tab may end: not
        // while herdr may show its title on a pane Steer cannot read.
        let (paneTitles, tablessMayEnd): (Set<String>, Bool) = switch herdrTitles {
        case .notInUse: ([], true)
        case .unknown: ([], false)
        case .known(let titles): (titles, true)
        }
        var result = ReminderScan()
        guard let ordered = HookEventListing.entries(in: events) else { return result }
        var probes: [UUID: [ApprovalResolutionProbe]] = [:]
        for url in ordered where url.pathExtension == "approval" {
            if let bytes = bounded(url, limit: 65536), let item = try? JSONDecoder().decode(ApprovalRequest.self, from: bytes),
               [.pending, .noDecision].contains(item.outcome) {
                let source = AttentionSource.desktop
                let receipt = ApprovalReceipts.existing(for: item.id, in: events)
                if item.outcome == .pending, item.receivedAt == 0, receipt == nil {
                    // The helper stops waiting for a receipt after the connection timeout. A request first
                    // seen later than that has no live helper, so it is handed back without controls.
                    let published = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    if Date().timeIntervalSince(published) <= ApprovalTiming.connectionTimeout {
                        result.awaitingReceipt.append(item)
                        continue
                    }
                }
                // Restart revalidation: while the helper still reports `pending`, a saved decision record
                // decides the state. A helper-written `no_decision` outcome is authoritative on its own.
                let decided = item.outcome == .pending ? ApprovalDecisions.existing(for: item.id, in: events) : nil
                if decided?.decision.isUserDecision == true { continue }
                // A request that never got a receipt has no arrival time of its own; its file's creation
                // time stands in so ordering, session-end and rollout matching never treat it as ancient.
                let published = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate?.timeIntervalSince1970) ?? 0
                let receivedAt = receipt?.receivedAt ?? (item.receivedAt > 0 ? item.receivedAt : published)
                let expiresAt = receipt?.expiresAt ?? (item.expiresAt > 0 ? item.expiresAt : receivedAt + ApprovalTiming.handoffTimeout)
                let actionable = item.outcome == .pending && receipt != nil && decided == nil
                probes[item.sessionID, default: []].append(ApprovalResolutionProbe(requestID: item.id, turn: item.turnID,
                                                                                    command: item.details.command, notBefore: receivedAt))
                result.attentionRequests.append(AttentionRequest(id: item.id, source: source, session: item.sessionID, turn: item.turnID,
                                                                 arrivedAt: receivedAt, expiresAt: expiresAt,
                                                                 state: actionable ? .actionable : .handedBack,
                                                                 details: item.details))
                if item.outcome == .noDecision {
                    result.reminders.append(Reminder(request_id: item.id, session_id: item.sessionID, turn_id: item.turnID,
                                                     outcome: item.outcome.rawValue, captured_at: item.receivedAt, source: source,
                                                     task_name: item.details.taskName, project: item.details.project,
                                                     action: item.details.action, command: item.details.command,
                                                     reason: item.details.reason, long_text: item.details.longText))
                }
            } else if let bytes = bounded(url, limit: 65536), let item = try? JSONDecoder().decode(Reminder.self, from: bytes),
                      ["pending", "no_decision"].contains(item.outcome) {
                let arrival = item.captured_at ?? item.received_at.flatMap(RolloutTimestamp.parse)
                    ?? ((try? url.resourceValues(forKeys: [.creationDateKey]).creationDate?.timeIntervalSince1970) ?? 0)
                result.attentionRequests.append(AttentionRequest(id: item.id, source: item.source ?? .desktop,
                                                                 session: item.session_id, turn: item.turn_id,
                                                                 arrivedAt: arrival, state: item.outcome == "no_decision" ? .handedBack : .actionable,
                                                                 details: ApprovalDetails(taskName: item.task_name, project: item.project,
                                                                                          action: item.action, command: item.command,
                                                                                          reason: item.reason, longText: item.long_text)))
                if item.outcome == "no_decision" { result.reminders.append(item) }
            }
        }
        struct Hook: Decodable {
            let hook_event_name: String
            let session_id: UUID
            let turn_id: UUID?
            let received_at: String
        }
        func hook(_ url: URL) -> Hook? {
            guard let bytes = bounded(url, limit: 65536) else { return nil }
            return try? JSONDecoder().decode(Hook.self, from: bytes)
        }
        let window = HookEventListing.newestRecords(ordered)
        var hooks = window.compactMap(hook)
        // Request files are always read, but their session's end can be older than the window. A
        // handed-back reminder resolves from it, so look further back, newest first and bounded,
        // only for SessionEnd records of sessions that still hold a request.
        let waiting = Set(result.attentionRequests.map(\.session))
            .subtracting(hooks.filter { $0.hook_event_name == "SessionEnd" }.map(\.session_id))
        if !waiting.isEmpty {
            let older = ordered.filter { $0.pathExtension == "json" }.dropLast(window.count)
            let ends = older.reversed().prefix(HookEventListing.maximumRecords).compactMap(hook).filter {
                $0.hook_event_name == "SessionEnd" && waiting.contains($0.session_id)
            }
            hooks.insert(contentsOf: ends.reversed(), at: 0)
        }
        for hook in hooks where hook.hook_event_name == "SessionEnd" {
            guard let ended = RolloutTimestamp.parse(hook.received_at) else { continue }
            result.sessionEnds[hook.session_id] = max(result.sessionEnds[hook.session_id] ?? 0, ended)
        }
        let sessions = Set(result.attentionRequests.map(\.session)).union(hooks.map(\.session_id))
        guard !sessions.isEmpty,
              let enumerator = FileManager.default.enumerator(at: rollouts, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { return result }
        var paths: [UUID: [URL]] = [:]
        var count = 0
        var rolloutFiles: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count > 50000 { return result }
            guard url.pathExtension == "jsonl" else { continue }
            rolloutFiles.append(url)
            for session in sessions where url.lastPathComponent.lowercased().hasSuffix(session.uuidString.lowercased() + ".jsonl") {
                paths[session, default: []].append(url)
            }
        }
        // A request raised by a sub-agent thread carries the parent's session id and the sub-agent's
        // turn id, which ends only in the sub-agent's own rollout. For sessions still holding a
        // request, read the heads of rollouts newer than the parent's (file names sort by start
        // time) and credit ended turns of any child thread to the parent. Bounded and best effort:
        // a miss leaves the request waiting, exactly as before.
        var headReads = 0
        for session in Set(result.attentionRequests.map(\.session)) {
            guard let parentFile = paths[session], parentFile.count == 1 else { continue }
            let parentName = parentFile[0].lastPathComponent
            for url in rolloutFiles where url.lastPathComponent > parentName && url != parentFile[0] {
                headReads += 1
                if headReads > maximumChildProbes { break }
                guard let head = rolloutParent(url), head.parent == session,
                      let bytes = bounded(url, limit: 32 * 1024 * 1024) else { continue }
                let child = evidence(in: bytes, session: head.session, owner: session)
                result.completed.formUnion(child.completed.map { TurnIdentity(session: session, turn: $0.turn) })
                result.canceled.formUnion(child.canceled.map { TurnIdentity(session: session, turn: $0.turn) })
            }
        }
        // ponytail: bounded full rereads every two seconds; use cursors if histories grow.
        for (session, urls) in paths where urls.count == 1 {
            if let bytes = bounded(urls[0], limit: 32 * 1024 * 1024) {
                let terminal = evidence(in: bytes, session: session)
                let finished = terminal.completed
                result.completed.formUnion(finished)
                result.canceled.formUnion(terminal.canceled)
                result.completionPreviews.merge(terminal.completionPreviews) { _, latest in latest }
                result.turnContexts.merge(terminal.turnContexts) { _, latest in latest }
                result.questions += terminal.pendingQuestions
                result.answeredQuestions.formUnion(terminal.answeredQuestions)
                if let sessionProbes = probes[session] {
                    result.resolvedRequests += ApprovalResolutionReader.resolutions(in: bytes, session: session, probes: sessionProbes)
                }
                guard let first = bytes.split(separator: 10).first,
                      let event = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
                      event["type"] as? String == "session_meta",
                      let meta = event["payload"] as? [String: Any],
                      (meta["id"] as? String).flatMap(UUID.init(uuidString:)) == session,
                      meta["source"] as? String == "cli" || cliTitles.contains(GhosttyMatch.title(session))
                        || paneTitles.contains(GhosttyMatch.title(session))
                        || knownCLISessions.contains(session)
                        || (daemonThreads.contains(session) && meta["originator"] as? String != desktopOriginator) else { continue }
                result.cliSessions.insert(session)
                let sessionHooks = hooks.filter { $0.session_id == session }.sorted { $0.received_at < $1.received_at }
                if cliTitles.contains(GhosttyMatch.title(session)) {
                    result.titledCLISessions.insert(session)
                } else if paneTitles.contains(GhosttyMatch.title(session)) {
                    // Its surface is a herdr pane; the herdr snapshot is its tab inventory.
                } else if let ghostty, tablessMayEnd, meta["source"] as? String != "cli",
                          case let started = sessionHooks.last(where: { $0.hook_event_name == "SessionStart" })
                            .flatMap({ RolloutTimestamp.parse($0.received_at) }),
                          !endedSinceLatestStart(result.sessionEnds[session], latestStart: started) {
                    // No tab shows this session. Proved by title earlier: its tab closed. Known only
                    // from the daemon: give a new session time for its tab to be inventoried first.
                    // Timed from the latest start, so a resumed session gets the same grace. While
                    // herdr's titles are unknown, a pane may still show the title: no end.
                    let ended = knownCLISessions.contains(session)
                        || (daemonThreads.contains(session) && started.map { ghostty.takenAt - $0 >= surfaceGrace } == true)
                    if ended {
                        result.sessionEnds[session] = ghostty.takenAt
                        result.cliEvents.append(.sessionEnded(session: session, receivedAt: RolloutTimestamp.format(ghostty.takenAt)))
                    }
                }
                for hook in sessionHooks {
                    switch hook.hook_event_name {
                    case "SessionStart":
                        result.cliEvents.append(.sessionStarted(session: session, receivedAt: hook.received_at))
                    case "UserPromptSubmit":
                        if let turn = hook.turn_id {
                            result.cliEvents.append(.turnStarted(session: session, turn: turn, receivedAt: hook.received_at))
                        }
                    case "Stop":
                        if let turn = hook.turn_id {
                            result.cliEvents.append(.turnCompleted(session: session, turn: turn, receivedAt: hook.received_at))
                            if finished.contains(TurnIdentity(session: session, turn: turn)) {
                                result.cliCompletions.append(CLICompletion(session: session, turn: turn, receivedAt: hook.received_at))
                            }
                        }
                    case "SessionEnd":
                        result.cliEvents.append(.sessionEnded(session: session, receivedAt: hook.received_at))
                    default:
                        break
                    }
                }
            }
        }
        result.cliEvents.sort { $0.receivedAt < $1.receivedAt }
        result.cliState = CLIState.replay(result.cliEvents)
        result.cliState.end(turns: result.completed.union(result.canceled))
        result.liveCLISessions = result.cliState.liveSessions
        result.attentionRequests = result.attentionRequests.map { request in
            guard result.cliSessions.contains(request.session), request.source != .cli else { return request }
            return AttentionRequest(id: request.id, source: .cli, session: request.session, turn: request.turn,
                                    arrivedAt: request.arrivedAt,
                                    expiresAt: request.expiresAt, state: request.state, details: request.details)
        }
        result.questions = result.questions.map { result.cliSessions.contains($0.session) ? $0.with(source: .cli) : $0 }
        result.answeredQuestions = Set(result.answeredQuestions.map {
            result.cliSessions.contains($0.session) ? QuestionIdentity(source: .cli, session: $0.session, callID: $0.callID) : $0
        })
        result.cliCompletions.sort { $0.receivedAt < $1.receivedAt }
        return result
    }
}
