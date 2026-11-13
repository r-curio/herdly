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
///
/// It also holds the last scan's result with the directory's own stamp. Every record arrives as a
/// new name, which changes that stamp, so while it is unchanged a scan checks no record file and,
/// while every session's part still stands, rebuilds nothing. A record rewritten in place leaves the
/// directory's stamp alone, so every file is checked again once the last full check is
/// `ClaudeObservationReader.maximumUncheckedAge` old.
///
/// When the directory does change, two more things are reused until that same full check. A record
/// already read is not looked at again while the directory still lists its name under the inode it
/// was read under (a replaced file has a new inode). And each session's part of the result is kept:
/// sessions share no state, so only a session whose records changed, whose open tool call has become
/// fresh or stopped being fresh, or whose listed subagent has reached
/// `ClaudeObservationReader.maximumSubagentAge` (#404), is built again.
///
/// A kept record holds what a build needs from it, already bounded, so building a session again
/// converts nothing (`ClaudeObservationReader.Record`).
public struct ClaudeRecordCache: Sendable {
    fileprivate struct Entry: Sendable {
        let stamp: FileStamp
        let record: ClaudeObservationReader.Record?
    }

    fileprivate var installationID: String?
    fileprivate var observingSince: Double?
    fileprivate var entries: [String: Entry] = [:]
    /// The directory's stamp, taken before the last full check listed it; nil when it had none.
    fileprivate var directoryStamp: FileStamp?
    /// The `now` of the last scan that checked every record file.
    fileprivate var checkedAt: Double?
    /// That check's records, in scan order.
    fileprivate var records: [ClaudeObservationReader.Record] = []
    /// The last result built from `records`, and the `now` it was built for.
    fileprivate var result: ClaudeObservationScan?
    fileprivate var resultNow: Double = -.infinity
    /// Each session's part of `result`, by session id. The result stands while every part does.
    fileprivate var sessions: [String: ClaudeObservationReader.SessionPart] = [:]

    public init() {}

    /// Number of record files held, for tests.
    var count: Int { entries.count }
    /// The sessions whose parts are held, for tests.
    var heldSessions: Set<String> { Set(sessions.keys) }
    /// What the scan that returned this cache did, for tests: how many record files it opened, and
    /// the sessions it built, in scan order.
    fileprivate(set) var recordsRead = 0
    fileprivate(set) var sessionsBuilt: [String] = []
}

/// Reads only Herdly's normalized Claude records. A malformed record is ignored; an unreadable
/// directory makes the whole root unavailable so it cannot clear another root's state.
public enum ClaudeObservationReader {
    public static let maximumRecordSize = 128 * 1024
    public static let maximumIdentifier = 256
    /// The longest tool-input value kept, in UTF-8 bytes: the helper's own bound, so a Bash command it
    /// stored (often over 256 bytes with a long `cd` prefix) reaches the approval card whole.
    public static let maximumToolInput = 4_096
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
    /// How long a scan may trust an unchanged directory stamp before it checks every record file
    /// again (`ClaudeRecordCache`). Bounds how late a record rewritten in place is noticed.
    public static let maximumUncheckedAge: Double = 30
    /// Session-wide events that end every running subagent of their session: only the session's end.
    /// A subagent otherwise ends on its own `SubagentStop`. A turn's end does not end it, because a
    /// background subagent (`run_in_background`) keeps running after its parent's `Stop` and sends its
    /// own stop later (#404). Retention keeps a start by the same rule (`ClaudeSubagentLifetimes`).
    static let subagentsEndingEvents: Set<String> = ["SessionEnd"]
    /// Turn ends in a session. A subagent that started before one of them, or before a submit of another
    /// prompt, has outlived its parent's turn, so without its own stop it is listed only until
    /// `maximumSubagentAge` (`ClaudeSubagentLifetimes`).
    static let turnEndingEvents: Set<String> = ["Stop", "StopFailure"]
    /// How long after its `SubagentStart` a subagent that outlived a turn end is still listed with no
    /// `SubagentStop` of its own (owner decision 2026-11-10, #404), so a lost stop cannot leave it
    /// running forever. A subagent inside a live turn has no age bound: a foreground one may run longer.
    public static let maximumSubagentAge: Double = 30 * 60

    /// Whether a subagent that started at `startedAt`, with no `SubagentStop` of its own and no
    /// `subagentsEndingEvents` record since, is still running at `now`. `latestTurnEndAt` is the latest end
    /// of its parent turn (`ClaudeSubagentLifetimes` decides it), nil when there is none.
    static func subagentIsListed(startedAt: Double, latestTurnEndAt: Double?, now: Double) -> Bool {
        guard let expiresAt = subagentExpiresAt(startedAt: startedAt, latestTurnEndAt: latestTurnEndAt) else { return true }
        return now < expiresAt
    }

    /// When such a subagent stops being listed: `maximumSubagentAge` after its start once a turn end at or
    /// after its start bounds it, nil while it has none (it then runs until its own stop or session end).
    static func subagentExpiresAt(startedAt: Double, latestTurnEndAt: Double?) -> Double? {
        guard let ended = latestTurnEndAt, ended >= startedAt else { return nil }
        return startedAt + maximumSubagentAge
    }

    /// Folds one record into each session's latest `turnEndingEvents` capture time, the
    /// `latestTurnEndAt` that `subagentIsListed` takes. The reader and retention build it the same way.
    static func noteTurnEnd(event: String, session: String, at capturedAt: Double, in ends: inout [String: Double]) {
        guard turnEndingEvents.contains(event) else { return }
        ends[session] = max(ends[session] ?? capturedAt, capturedAt)
    }

    /// A record's `agent_id` when it is one the reader accepts: a bounded identifier, else nil.
    static func subagentID(in object: [String: Any]) -> String? {
        Agent(object["agent_id"]).id
    }

    /// A record's `prompt_id` when the reader accepts it (a bounded identifier), else nil. The reader and
    /// retention judge a subagent's parent turn by it (`ClaudeSubagentLifetimes`).
    static func promptID(_ value: String?) -> String? {
        valid(value)
    }

    /// One record as a session's build reads it. Everything a build needs from the record alone is
    /// worked out here, once, when the file is decoded: a session is built again on every scan while
    /// it is active, and bounding the same tool inputs again each time was most of a scan's cost (#306).
    fileprivate struct Record: Sendable {
        let fileName: String
        let event: String
        let session: String
        let capturedAt: Double
        /// `prompt_id` when it is a bounded identifier, else nil.
        let promptID: String?
        /// A UserPromptSubmit's `promptFallback`, and whether the helper stored only the prompt's start.
        let prompt: KeptText?
        let promptShortened: Bool
        /// A Stop's bounded last message and whether it was shortened.
        let lastMessage: KeptText?
        /// `tool_name` when it is a bounded identifier, else nil.
        let toolName: String?
        /// `tool_use_id` when it is a bounded identifier, else nil.
        let toolUseID: String?
        let helperRequestID: String?
        let hookRequestID: String?
        /// A PreToolUse's string inputs, each bounded to `maximumToolInput`.
        let input: [String: String]
        /// The file, notebook, URL or query a PreToolUse targets (`ClaudeDirectApproval.target`).
        let target: String?
        /// A Bash call's or request's exact command, unshortened.
        let command: String?
        /// The calls a PostToolBatch completes.
        let batchToolIDs: [String]
        /// An AskUserQuestion call's prompts, nil unless there are between one and `maximumQuestions`.
        let questionPrompts: [QuestionPrompt]?
        /// What the helper validated and bounded for a decidable non-Bash request (ClaudeDirectApproval).
        let approvalDetails: ApprovalDetails?
        /// Which subagent the event belongs to (`agent_id`), if any.
        let agent: Agent
        /// The subagent's `agent_type`, nil when missing or malformed.
        let agentType: String?
    }

    /// A record's `agent_id`: absent for the session's own events; `invalid` when present but malformed
    /// or oversized, so the event is still kept off the session's own "now" without naming a subagent.
    fileprivate enum Agent: Equatable, Sendable {
        case none
        case invalid
        case id(String)

        init(_ value: Any?) {
            guard let value else { self = .none; return }
            guard let text = ClaudeObservationReader.valid(value as? String) else { self = .invalid; return }
            self = .id(text)
        }

        var isSubagent: Bool { self != .none }
        var id: String? { if case let .id(value) = self { return value }; return nil }
    }

    private struct Subagent {
        let id: String
        let type: String?
        let startedAt: Double
        var tools: [String: Tool]
        /// Its start or its newest tool start or finish (#419).
        var lastActivityAt: Double
    }

    private struct Tool {
        let id: String
        let name: String
        let input: [String: String]
        let at: Double
        /// The absolute file or notebook path the call targets, kept apart from the display-bounded input.
        var target: String? = nil
        /// A Bash call's exact command as the helper recorded it, unshortened, so a permission request
        /// can be matched to its own call while parallel subagents run other Bash calls in the same turn.
        var command: String? = nil
        /// The subagent the call ran inside (`agent_id`), `.none` for the session's own call. Its
        /// `SubagentStop`, or its drop at `maximumSubagentAge`, resolves the call's request.
        var agent: Agent = .none

        /// The call ran inside a subagent, so it is never the session's own "now".
        var inSubagent: Bool { agent.isSubagent }

        /// The latest call: the newest capture, then the greater id.
        static func latest(_ tools: some Sequence<Tool>) -> Tool? {
            tools.max { lhs, rhs in lhs.at == rhs.at ? lhs.id < rhs.id : lhs.at < rhs.at }
        }
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
        /// The turn's latest activity (#419): its prompt and the tool starts and finishes it owns,
        /// including a subagent's while the turn is open. Not a Stop, StopFailure or SessionEnd, which
        /// move `updatedAt` only.
        var activityAt: Double
        var tool: Tool?
        var tools: [String: Tool]
        var question: AgentQuestion?
        var approval: AgentApproval?
        var terminal: AgentOutcome?
        var provisionalStopAt: Double?
        var closedAt: Double?

        /// Whether `calls` all ran inside subagents after this turn closed: a subagent outliving its
        /// parent's turn (a background one, #404). Such activity never reopens or updates the turn, so it
        /// keeps its pending Stop, result message, outcome and update time.
        func isLateSubagentActivity(_ calls: [Tool]) -> Bool {
            closedAt != nil && !calls.isEmpty && calls.allSatisfy(\.inSubagent)
        }

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
        // Cleared here, once, so the cache any path below returns says only what this scan did.
        var cache = cache
        cache.recordsRead = 0
        cache.sessionsBuilt = []
        let scope = normalizedScope(sourceScope)
        // Taken before the directory is listed, so a change during the scan shows as a new stamp next time.
        let directoryStamp = FileStamp(events, followingLinks: true)
        guard isDirectory(events),
              let listing = HookEventListing.detailedListing(in: events) else {
            return (ClaudeObservationScan(sourceScope: scope, available: false), cache)
        }
        let reusable = cache.installationID == installationID && cache.observingSince == observingSince
        // A session's part names its scope in every identity, so it serves only the same scope.
        let sameScope = reusable && cache.result?.sourceScope == scope
        // Unchanged directory, checked recently: the same records, with no file looked at.
        if reusable, let stamp = directoryStamp, cache.directoryStamp == stamp, let checkedAt = cache.checkedAt,
           now.isFinite, now >= checkedAt, now - checkedAt < maximumUncheckedAge {
            // Every session's part still stands, so the result built from them does.
            if let result = cache.result, result.sourceScope == scope, now >= cache.resultNow,
               cache.sessions.values.allSatisfy({ stands($0, at: now) }) {
                return (result, cache)
            }
            var next = cache
            let built = build(cache.records, scope: scope, now: now, previous: sameScope ? cache.sessions : [:], changed: [])
            next.result = built.scan
            next.resultNow = now
            next.sessions = built.sessions
            next.sessionsBuilt = built.rebuilt
            return (built.scan, next)
        }
        // The directory changed, but the last full check is recent: a record already read is trusted
        // while the directory lists it under the same inode, and only the others are looked at.
        let recentlyChecked: Bool
        if reusable, let checkedAt = cache.checkedAt, now.isFinite, now >= checkedAt, now - checkedAt < maximumUncheckedAge {
            recentlyChecked = true
        } else {
            recentlyChecked = false
        }
        var next = ClaudeRecordCache()
        next.installationID = installationID
        next.observingSince = observingSince
        next.directoryStamp = directoryStamp
        next.checkedAt = recentlyChecked ? cache.checkedAt : (now.isFinite ? now : nil)
        // Sessions with a record read from its file in this scan.
        var changed = Set<String>()
        let records = zip(listing.records, listing.recordInodes)
            .compactMap { url, inode -> Record? in
                let path = url.path
                if recentlyChecked, let entry = cache.entries[path], entry.stamp.inode == inode, entry.stamp.isRegularFile {
                    next.entries[path] = entry
                    return entry.record
                }
                // A link or a path that cannot be stat'ed is never a record, as `record(at:)` decides.
                guard let stamp = FileStamp(url, followingLinks: false) else { return nil }
                if reusable, let entry = cache.entries[path], entry.stamp == stamp {
                    next.entries[path] = entry
                    return entry.record
                }
                if stamp.isRegularFile { next.recordsRead += 1 }
                let record = stamp.isRegularFile ? record(at: url, installationID: installationID, observingSince: observingSince) : nil
                next.entries[path] = ClaudeRecordCache.Entry(stamp: stamp, record: record)
                if let record { changed.insert(record.session) }
                return record
            }
            .sorted {
                if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
                if $0.session != $1.session { return $0.session < $1.session }
                return $0.fileName < $1.fileName
            }
        let built = build(records, scope: scope, now: now, previous: sameScope ? cache.sessions : [:], changed: changed)
        next.records = records
        next.result = built.scan
        next.resultNow = now
        next.sessions = built.sessions
        next.sessionsBuilt = built.rebuilt
        return (built.scan, next)
    }

    /// The scan with every record replayed in one pass and nothing kept between scans, as scans were
    /// built before sessions were built apart. The reference the per-session build must equal; tests only.
    static func referenceScan(events: URL, sourceScope: String, installationID: String,
                              observingSince: Double = -.infinity, now: Double) -> ClaudeObservationScan {
        let scope = normalizedScope(sourceScope)
        guard isDirectory(events), let listing = HookEventListing.listing(in: events) else {
            return ClaudeObservationScan(sourceScope: scope, available: false)
        }
        let records = listing.records
            .compactMap { url -> Record? in
                guard FileStamp(url, followingLinks: false)?.isRegularFile == true else { return nil }
                return record(at: url, installationID: installationID, observingSince: observingSince)
            }
            .sorted {
                if $0.capturedAt != $1.capturedAt { return $0.capturedAt < $1.capturedAt }
                if $0.session != $1.session { return $0.session < $1.session }
                return $0.fileName < $1.fileName
            }
        let all = buildSession(records, scope: scope, now: now)
        let observations = all.turns.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.prompt != $1.prompt { return $0.prompt < $1.prompt }
            return $0.session < $1.session
        }.flatMap(\.observations)
        return ClaudeObservationScan(sourceScope: scope, observations: observations, results: all.results,
                                     latestSessionStartAt: all.latestSessionStartAt)
    }

    /// One session's part of a scan: sessions share no state, so each is built from its own records.
    fileprivate struct SessionPart: Sendable {
        /// The session's record files, in scan order: the part stands only for exactly these.
        let fileNames: [String]
        let turns: [TurnPart]
        let results: [AgentTurnIdentity: ClaudeTurnResult]
        let latestSessionStartAt: Double?
        /// The finite capture times of the uncompleted tool calls left open, and the `now` the part
        /// was built for: `now` changes a part only through those calls' freshness.
        let openToolTimes: [Double]
        let builtNow: Double
        /// The earliest `now` at which a subagent the part lists reaches `maximumSubagentAge`: with no new
        /// record, that changes the part's switcher list, held row and requests (#404).
        let subagentExpiresAt: Double
    }

    /// Whether a call captured at `at` is within `maximumToolFreshness` of `now`: `fresh`'s rule.
    private static func isFresh(_ at: Double, now: Double) -> Bool {
        now.isFinite && at.isFinite && at <= now && now - at <= maximumToolFreshness
    }

    /// Whether `part` is still its session's part at `now`, given the session's records are the ones it
    /// was built from: time has not gone back, every open call is fresh or not exactly as it was when the
    /// part was built, and no listed subagent has reached its age bound since.
    private static func stands(_ part: SessionPart, at now: Double) -> Bool {
        guard now.isFinite, now >= part.builtNow, now < part.subagentExpiresAt else { return false }
        return part.openToolTimes.allSatisfy { isFresh($0, now: now) == isFresh($0, now: part.builtNow) }
    }

    /// One turn's observations with what orders turns across sessions.
    fileprivate struct TurnPart: Sendable {
        let startedAt: Double
        let prompt: String
        let session: String
        let observations: [AgentObservation]
    }

    /// The scan `records` (in scan order) give at `now`, with each session's part for the next scan and
    /// the sessions built rather than reused, in scan order. A part in `previous` is reused when its
    /// session has exactly the same record files, none of them read in this scan (`changed`), and it
    /// still stands at `now` (`stands`).
    private static func build(_ records: [Record], scope: String, now: Double, previous: [String: SessionPart],
                              changed: Set<String>)
        -> (scan: ClaudeObservationScan, sessions: [String: SessionPart], rebuilt: [String]) {
        var order: [String] = []
        var grouped: [String: [Record]] = [:]
        for record in records {
            if grouped[record.session] == nil { order.append(record.session) }
            grouped[record.session, default: []].append(record)
        }
        var sessions: [String: SessionPart] = [:]
        sessions.reserveCapacity(order.count)
        var built: [String] = []
        for session in order {
            let own = grouped[session] ?? []
            if let part = previous[session], !changed.contains(session), stands(part, at: now),
               part.fileNames.count == own.count, part.fileNames.elementsEqual(own.lazy.map(\.fileName)) {
                sessions[session] = part
            } else {
                sessions[session] = buildSession(own, scope: scope, now: now)
                built.append(session)
            }
        }
        let parts = order.compactMap { sessions[$0] }
        // Oldest turn first, then prompt; the session only settles a tie the same way every time.
        let observations = parts.flatMap(\.turns).sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.prompt != $1.prompt { return $0.prompt < $1.prompt }
            return $0.session < $1.session
        }.flatMap(\.observations)
        var results: [AgentTurnIdentity: ClaudeTurnResult] = [:]
        for part in parts { results.merge(part.results) { _, latest in latest } }
        let latestSessionStartAt = parts.compactMap(\.latestSessionStartAt).max()
        return (ClaudeObservationScan(sourceScope: scope, observations: observations, results: results,
                                      latestSessionStartAt: latestSessionStartAt), sessions, built)
    }

    /// One session's part at `now`, from that session's records alone, in scan order.
    private static func buildSession(_ records: [Record], scope: String, now: Double) -> SessionPart {
        var turns: [AgentTurnIdentity: Turn] = [:]
        var sessionPrompts: [String: String] = [:]
        var endedSessions = Set<String>()
        var sessionEndAt: [String: Double] = [:]
        var seenApprovals = Set<AgentCallIdentity>()
        var seenQuestions = Set<AgentCallIdentity>()
        var latestSessionStartAt: Double?
        // Each session's running subagents by agent id, listed flat however deeply they nest.
        var subagents: [String: [String: Subagent]] = [:]
        // When each subagent runs, shared with retention: decides whether a subagent's call has ended.
        var lifetimes = ClaudeSubagentLifetimes()
        for record in records {
            lifetimes.note(event: record.event, session: record.session, agent: record.agent.id,
                           prompt: record.promptID, at: record.capturedAt)
        }
        /// Ends a turn's own activity at its Stop, StopFailure or a newer prompt. A call of a subagent Herdly saw
        /// start, and that subagent's request, stay: the subagent can outlive its parent's turn (#404) and
        /// ends them itself (`ClaudeSubagentLifetimes`). The session's own calls and request end here.
        func endOwnActivity(_ turn: inout Turn) {
            let session = turn.session
            turn.tool = nil
            turn.tools = turn.tools.filter { _, tool in
                tool.agent.id.map { lifetimes.run(session: session, agent: $0, holding: tool.at) != nil } ?? false
            }
            turn.question = nil
            if let approval = turn.approval, approval.subagentID == nil || turn.tools[approval.identity.call] == nil {
                turn.approval = nil
            }
        }
        func finishSubagentCalls(_ ids: [String], of record: Record) {
            guard var running = subagents[record.session] else { return }
            for (agent, var subagent) in running {
                for id in ids where (subagent.tools[id]?.at ?? .infinity) <= record.capturedAt {
                    subagent.tools.removeValue(forKey: id)
                    subagent.lastActivityAt = max(subagent.lastActivityAt, record.capturedAt)
                }
                running[agent] = subagent
            }
            subagents[record.session] = running
        }

        for record in records {
            if subagentsEndingEvents.contains(record.event) { subagents.removeValue(forKey: record.session) }
            switch record.event {
            case "SessionStart":
                latestSessionStartAt = max(latestSessionStartAt ?? record.capturedAt, record.capturedAt)
                endedSessions.remove(record.session)
                sessionEndAt.removeValue(forKey: record.session)
            case "SubagentStart":
                guard let agent = record.agent.id, subagents[record.session]?[agent] == nil else { continue }
                subagents[record.session, default: [:]][agent] = Subagent(id: agent, type: record.agentType,
                                                                          startedAt: record.capturedAt, tools: [:],
                                                                          lastActivityAt: record.capturedAt)
            case "SubagentStop":
                guard let agent = record.agent.id else { continue }
                subagents[record.session]?.removeValue(forKey: agent)
                // A stopped subagent has no call left to run: its uncompleted calls end, and a request for
                // one is resolved, even with no completion (a native "No" fires no hook). Other subagents'
                // calls and the session's own are untouched.
                for (id, var turn) in turns where turn.session == record.session {
                    let ended = turn.tools.values.filter { $0.agent.id == agent && $0.at <= record.capturedAt }.map(\.id)
                    guard !ended.isEmpty else { continue }
                    for call in ended { turn.tools.removeValue(forKey: call) }
                    if let approval = turn.approval, ended.contains(approval.identity.call) { turn.approval = nil }
                    turns[id] = turn
                }
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
                guard let promptID = record.promptID else { continue }
                if let endedAt = sessionEndAt[record.session], record.capturedAt > endedAt {
                    endedSessions.remove(record.session)
                    sessionEndAt.removeValue(forKey: record.session)
                }
                if let previousPrompt = sessionPrompts[record.session], previousPrompt != promptID {
                    let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                        session: record.session, surface: .cli)
                    let previousID = AgentTurnIdentity(session: identity, turn: previousPrompt)
                    if var previous = turns[previousID] {
                        endOwnActivity(&previous)
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
                    if existing.promptText == nil, let prompt = record.prompt {
                        existing.promptText = prompt.text
                        existing.promptShortened = record.promptShortened || prompt.shortened
                    }
                    existing.startedAt = min(existing.startedAt, record.capturedAt)
                    existing.activityAt = max(existing.activityAt, record.capturedAt)
                    turns[turnID] = existing
                } else {
                    let prompt = record.prompt
                    turns[turnID] = Turn(session: record.session, prompt: promptID,
                                         promptText: prompt?.text,
                                         promptShortened: prompt.map { record.promptShortened || $0.shortened } ?? false,
                                         lastMessage: nil, startedAt: record.capturedAt,
                                         updatedAt: record.capturedAt, activityAt: record.capturedAt,
                                         tool: nil, tools: [:], question: nil,
                                         approval: nil, terminal: nil, provisionalStopAt: nil, closedAt: nil)
                }
            case "PreToolUse":
                guard let promptID = record.promptID, let toolID = record.toolUseID,
                      let name = record.toolName else { continue }
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                let tool = Tool(id: toolID, name: name, input: record.input, at: record.capturedAt,
                                target: record.target, command: record.command, agent: record.agent)
                if let agent = record.agent.id, var subagent = subagents[record.session]?[agent] {
                    subagent.tools[toolID] = tool
                    subagent.lastActivityAt = max(subagent.lastActivityAt, record.capturedAt)
                    subagents[record.session]?[agent] = subagent
                }
                guard var turn = turns[turnID] else { continue }
                if let closedAt = turn.closedAt {
                    guard record.capturedAt > closedAt else { continue }
                    if turn.isLateSubagentActivity([tool]) {
                        // It keeps the turn's prompt id, but an older turn never becomes a second working row.
                        // The call stays matchable for a permission request.
                        turn.tools[toolID] = tool
                        turns[turnID] = turn
                        continue
                    }
                    turn.closedAt = nil
                    turn.terminal = nil
                    turn.provisionalStopAt = nil
                    turn.lastMessage = nil
                }
                if let endedAt = sessionEndAt[record.session], record.capturedAt > endedAt {
                    endedSessions.remove(record.session)
                    sessionEndAt.removeValue(forKey: record.session)
                }
                // Every call stays matchable for approvals; only the session's own call is its "now".
                turn.tools[toolID] = tool
                if !tool.inSubagent { turn.tool = tool }
                turn.updatedAt = max(turn.updatedAt, record.capturedAt)
                turn.activityAt = max(turn.activityAt, record.capturedAt)
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
                guard let promptID = record.promptID, let toolID = record.toolUseID else { continue }
                finishSubagentCalls([toolID], of: record)
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                guard var turn = turns[turnID], let tool = turn.tools[toolID],
                      tool.at <= record.capturedAt else { continue }
                turn.tools.removeValue(forKey: toolID)
                turn.tool = sessionTool(turn.tools)
                if turn.question?.identity.call == toolID { turn.question = nil }
                if turn.approval?.identity.call == toolID { turn.approval = nil }
                if !turn.isLateSubagentActivity([tool]) {
                    turn.updatedAt = max(turn.updatedAt, record.capturedAt)
                    turn.activityAt = max(turn.activityAt, record.capturedAt)
                    turn.provisionalStopAt = nil
                }
                turns[turnID] = turn
            case "PostToolBatch":
                guard let promptID = record.promptID else { continue }
                let ids = record.batchToolIDs
                guard !ids.isEmpty else { continue }
                finishSubagentCalls(ids, of: record)
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                guard var turn = turns[turnID] else { continue }
                let matching = turn.tools.values.filter { ids.contains($0.id) && $0.at <= record.capturedAt }
                guard !matching.isEmpty else { continue }
                for tool in matching { turn.tools.removeValue(forKey: tool.id) }
                turn.tool = sessionTool(turn.tools)
                if let question = turn.question, matching.contains(where: { $0.id == question.identity.call }) {
                    turn.question = nil
                }
                if let approval = turn.approval, matching.contains(where: { $0.id == approval.identity.call }) {
                    turn.approval = nil
                }
                if !turn.isLateSubagentActivity(matching) {
                    turn.updatedAt = max(turn.updatedAt, record.capturedAt)
                    turn.activityAt = max(turn.activityAt, record.capturedAt)
                }
                turns[turnID] = turn
            case "PermissionRequest":
                guard let promptID = record.promptID, let name = record.toolName,
                      ClaudeDirectApproval.tools.contains(name) else { continue }
                // A file request is shown only with the helper's validated details, and only for the one
                // uncompleted call of that tool on the same path. A Bash request that carries its command
                // matches only the uncompleted call with that exact command (parallel subagents share the
                // session and prompt); one without it keeps the name-only rule.
                let fileDetails = name == "Bash" ? nil : record.approvalDetails
                guard name == "Bash" || fileDetails?.command != nil else { continue }
                let requestedCommand = record.command
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                guard var turn = turns[turnID] else { continue }
                let candidates = turn.tools.values.filter {
                    $0.name == name && $0.at <= record.capturedAt && (fileDetails == nil || $0.target == fileDetails?.command)
                        && (requestedCommand == nil || $0.command == requestedCommand)
                }
                guard candidates.count == 1, let tool = candidates.first else { continue }
                let call = AgentCallIdentity(session: identity, turn: promptID, call: tool.id)
                guard seenApprovals.insert(call).inserted else { continue }
                let command = tool.input["command"] ?? tool.input["cmd"]
                let details = fileDetails ?? ApprovalDetails(action: "Bash", command: command)
                turn.approval = AgentApproval(session: identity, turn: promptID, call: tool.id,
                                              arrivedAt: record.capturedAt, details: details,
                                              hookRequestID: record.hookRequestID,
                                              // Only a run Herdly saw start can end with its own stop or the
                                              // bound; a call no run holds is treated as not running (no shield).
                                              subagentID: tool.agent.id.flatMap {
                                                  lifetimes.run(session: record.session, agent: $0, holding: tool.at) == nil ? nil : $0
                                              })
                turns[turnID] = turn
            case "StopFailure":
                guard let promptID = record.promptID else { continue }
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                guard var turn = turns[turnID] else { continue }
                endOwnActivity(&turn)
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
                guard let promptID = record.promptID else { continue }
                let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                    session: record.session, surface: .cli)
                let turnID = AgentTurnIdentity(session: identity, turn: promptID)
                if var turn = turns[turnID] {
                    endOwnActivity(&turn)
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

        // Subagents still running at `now`, by the run rule retention shares (`ClaudeSubagentLifetimes`).
        var listed: [String: [String: Subagent]] = [:]
        for (session, running) in subagents {
            listed[session] = running.filter { agent, subagent in
                lifetimes.call(session: session, agent: agent, at: subagent.startedAt, now: now) == .running
            }
        }
        /// The turn's request still pending at `now`: nil once its subagent's run has ended (its own stop,
        /// the session's end, or the age bound), which resolves the request.
        func pendingApproval(_ turn: Turn) -> AgentApproval? {
            guard let approval = turn.approval else { return nil }
            if let agent = approval.subagentID, let call = turn.tools[approval.identity.call],
               lifetimes.call(session: turn.session, agent: agent, at: call.at, now: now) == .ended { return nil }
            return approval
        }
        let turnParts = turns.values.map { turn -> TurnPart in
            let observations: [AgentObservation] = {
            let identity = AgentSessionIdentity(source: .claude, sourceScope: scope,
                                                session: turn.session, surface: .cli)
            // Every submitted prompt is a reply, including one in a session that has since ended.
            let replied = AgentObservation.replied(AgentTurnIdentity(session: identity, turn: turn.prompt),
                                                   submittedAt: turn.startedAt)
            let isCurrentPrompt = sessionPrompts[turn.session] == turn.prompt
            guard ((!endedSessions.contains(turn.session) && (turn.closedAt == nil || isCurrentPrompt))
                   || turn.terminal != nil) else {
                // A background subagent's request in an older, closed turn still reaches the queue.
                guard !endedSessions.contains(turn.session), let approval = pendingApproval(turn),
                      turn.tools[approval.identity.call]?.inSubagent == true else { return [replied] }
                return [replied, .approval(approval)]
            }
            var result: [AgentObservation] = [replied]
            if let terminal = turn.terminal {
                result.append(.outcome(terminal))
                // A known subagent's request after its parent's failure still reaches the queue. One with no
                // usable or known agent id is not shielded, so the failure would resolve it: it is left out.
                if !endedSessions.contains(turn.session), let approval = pendingApproval(turn), approval.subagentID != nil {
                    result.append(.approval(approval))
                }
            } else {
                let freshTool = turn.tool.flatMap { fresh($0, now: now) }
                let activity = isCurrentPrompt ? subagentActivity(listed[turn.session] ?? [:], now: now) : []
                result.append(.running(AgentRunning(session: identity, turn: turn.prompt, arrivedAt: turn.startedAt,
                                                    updatedAt: turn.updatedAt,
                                                    prompt: turn.promptText, promptShortened: turn.promptShortened,
                                                    toolName: freshTool?.name,
                                                    toolInput: freshTool?.input ?? [:],
                                                    subagents: activity, activityAt: turn.activityAt,
                                                    toolStartedAt: freshTool?.at)))
                if let question = turn.question { result.append(.question(question)) }
                if let approval = pendingApproval(turn) { result.append(.approval(approval)) }
            }
            if let stopAt = turn.provisionalStopAt {
                result.append(.provisionalStop(AgentProvisionalStop(identity: AgentTurnIdentity(session: identity,
                                                                                               turn: turn.prompt),
                                                                     arrivedAt: stopAt)))
            }
            return result
            }()
            return TurnPart(startedAt: turn.startedAt, prompt: turn.prompt, session: turn.session, observations: observations)
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
        let openTools = turns.values.flatMap { $0.tools.values + ($0.tool.map { [$0] } ?? []) }
            + subagents.values.flatMap { $0.values.flatMap(\.tools.values) }
        let openToolTimes = openTools.map(\.at).filter(\.isFinite)
        let firstSubagentExpiry = listed.flatMap { session, running in
            running.compactMap { agent, subagent in lifetimes.expiresAt(session: session, agent: agent, at: subagent.startedAt) }
        }.min() ?? .infinity
        return SessionPart(fileNames: records.map(\.fileName), turns: turnParts, results: results,
                           latestSessionStartAt: latestSessionStartAt, openToolTimes: openToolTimes, builtNow: now,
                           subagentExpiresAt: firstSubagentExpiry)
    }

    /// The session's own latest uncompleted call; a subagent's call never is.
    private static func sessionTool(_ tools: [String: Tool]) -> Tool? {
        Tool.latest(tools.values.filter { !$0.inSubagent })
    }

    /// `tool` while it is within `maximumToolFreshness` of `now`.
    private static func fresh(_ tool: Tool, now: Double) -> Tool? {
        guard isFresh(tool.at, now: now) else { return nil }
        return tool
    }

    /// One session's running subagents, oldest first, named by type in start order, each with its
    /// latest fresh uncompleted call as the "now" line.
    private static func subagentActivity(_ running: [String: Subagent], now: Double) -> [SubagentActivity] {
        let ordered = running.values.sorted { SubagentActivity.startsBefore(($0.startedAt, $0.id), ($1.startedAt, $1.id)) }
        let names = SubagentActivity.names(ordered.map { (id: $0.id, base: $0.type) })
        return ordered.map { subagent in
            let latest = Tool.latest(subagent.tools.values).flatMap { fresh($0, now: now) }
            return SubagentActivity(id: subagent.id, name: names[subagent.id] ?? SubagentActivity.unnamed,
                                    startedAt: subagent.startedAt,
                                    latestAction: latest.flatMap { RunningRowDetails.now(toolName: $0.name, toolInput: $0.input) },
                                    lastActivityAt: subagent.lastActivityAt)
        }
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
        let toolName = bounded(object["tool_name"] as? String)
        let toolInput = object["tool_input"] as? [String: Any] ?? [:]
        let isCall = event == "PreToolUse"
        return Record(fileName: url.lastPathComponent, event: event, session: session, capturedAt: captured,
                      promptID: valid(object["prompt_id"] as? String),
                      prompt: event == "UserPromptSubmit" ? promptFallback((object["prompt"] as? String).map(native)) : nil,
                      promptShortened: object[promptShortenedKey] as? Bool ?? false,
                      lastMessage: event == "Stop"
                        ? lastMessage(object[lastMessageKey] as? String).map {
                            KeptText(text: $0.text, shortened: $0.shortened || object[lastMessageShortenedKey] as? Bool == true)
                        } : nil,
                      toolName: toolName, toolUseID: valid(object["tool_use_id"] as? String),
                      helperRequestID: valid(object["helper_request_id"] as? String),
                      hookRequestID: valid(object["approval_request_id"] as? String),
                      input: isCall ? stringInput(toolInput) : [:],
                      target: isCall ? toolName.flatMap { ClaudeDirectApproval.target(toolName: $0, toolInput: toolInput) }
                                        .map(native) : nil,
                      command: toolName == "Bash" && (isCall || event == "PermissionRequest")
                        ? (toolInput["command"] as? String).map(native) : nil,
                      batchToolIDs: event == "PostToolBatch"
                        ? (toolInput["tool_use_ids"] as? [String]
                            ?? (toolInput["tool_uses"] as? [[String: Any]] ?? []).compactMap { $0["tool_use_id"] as? String })
                            .map(native) : [],
                      questionPrompts: isCall && toolName == "AskUserQuestion" ? questionPrompts(toolInput) : nil,
                      approvalDetails: approvalDetails(object["approval_details"]),
                      agent: Agent(object["agent_id"]), agentType: bounded(object["agent_type"] as? String))
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
        guard let call = record.toolUseID, let prompts = record.questionPrompts else { return nil }
        return AgentQuestion(session: identity, turn: turn, call: call, arrivedAt: at,
                             prompts: prompts, helperRequestID: record.helperRequestID)
    }

    private static func questionPrompts(_ toolInput: [String: Any]) -> [QuestionPrompt]? {
        guard let parsed = QuestionPrompt.parseCall(toolInput: toolInput),
              !parsed.prompts.isEmpty, parsed.count <= QuestionPrompt.maximumQuestions else { return nil }
        return parsed.prompts
    }

    private static func stringInput(_ input: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in input {
            guard let text = boundedText(value as? String, limit: maximumToolInput) else { continue }
            result[native(key)] = text
        }
        return result
    }

    /// `value` in Swift's own UTF-8 storage. `JSONSerialization` hands back bridged strings, and one
    /// holding text outside ASCII is read through an Objective-C call per UTF-16 unit, every time it
    /// is walked, compared or hashed.
    private static func native(_ value: String) -> String {
        var value = value
        value.makeContiguousUTF8()
        return value
    }

    private static func valid(_ value: String?) -> String? {
        guard let value = bounded(value), !value.isEmpty else { return nil }
        return value
    }

    private static func bounded(_ value: String?, limit: Int = maximumIdentifier) -> String? {
        guard let value = value.map(native), !value.isEmpty, value.utf8.count <= limit,
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
        guard let value = value.map(native), !value.isEmpty, value.utf8.count <= limit,
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
