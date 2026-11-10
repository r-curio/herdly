import Foundation

/// When each Claude subagent runs, from one hook directory's records (#404). The reader and retention
/// both decide a subagent's calls by it, so they never disagree on whether a call has ended.
///
/// A subagent's run starts with its `SubagentStart` and ends at its first `SubagentStop` at or after
/// that start, or at its session's end; a start while a run is open is a repeat. Once its parent turn has
/// ended (a `Stop` or `StopFailure` in the session, or a submit of another prompt, at or after the
/// start), an open run also ends at `ClaudeObservationReader.maximumSubagentAge`. The
/// same agent id may run again after its run ended. A call belongs to the run whose span holds its
/// capture time; a call before any start, or after a run ended and before the next, belongs to none.
struct ClaudeSubagentLifetimes {
    enum CallState: Equatable {
        /// No run of a subagent Herdly saw start holds the call, so nothing says whether it still runs.
        case unknown
        case running
        case ended
    }

    private struct Key: Hashable {
        let session: String
        let agent: String
    }

    private struct Start {
        let at: Double
        /// The prompt the subagent started in, nil when the record had none.
        let prompt: String?
    }

    private var starts: [Key: [Start]] = [:]
    private var stops: [Key: [Double]] = [:]
    private var sessionEnds: [String: [Double]] = [:]
    /// Each session's latest `Stop`/`StopFailure`.
    private var latestTurnEnds: [String: Double] = [:]
    /// Each session's prompt submits.
    private var submits: [String: [(at: Double, prompt: String)]] = [:]

    /// Takes one record, in any order. `agent` is the record's accepted `agent_id`, nil when it has none;
    /// `prompt` is its raw `prompt_id`, bounded here as the reader bounds it (`promptID`), so a malformed one
    /// counts as none on both sides.
    mutating func note(event: String, session: String, agent: String?, prompt rawPrompt: String?, at capturedAt: Double) {
        let prompt = ClaudeObservationReader.promptID(rawPrompt)
        if let agent, event == "SubagentStart" {
            starts[Key(session: session, agent: agent), default: []].append(Start(at: capturedAt, prompt: prompt))
        }
        if let agent, event == "SubagentStop" { stops[Key(session: session, agent: agent), default: []].append(capturedAt) }
        if ClaudeObservationReader.subagentsEndingEvents.contains(event) {
            sessionEnds[session, default: []].append(capturedAt)
        }
        if event == "UserPromptSubmit", let prompt { submits[session, default: []].append((capturedAt, prompt)) }
        ClaudeObservationReader.noteTurnEnd(event: event, session: session, at: capturedAt, in: &latestTurnEnds)
    }

    /// The run of `agent` in `session` whose span holds `at`: its start, and its stop or session end if any.
    func run(session: String, agent: String, holding at: Double) -> (startedAt: Double, endedAt: Double?)? {
        runStart(session: session, agent: agent, holding: at).map { ($0.start.at, $0.endedAt) }
    }

    private func runStart(session: String, agent: String, holding at: Double) -> (start: Start, endedAt: Double?)? {
        let key = Key(session: session, agent: agent)
        guard let all = starts[key]?.sorted(by: { $0.at < $1.at }) else { return nil }
        let stopTimes = stops[key] ?? []
        let endTimes = sessionEnds[session] ?? []
        var index = all.startIndex
        while index < all.endIndex {
            let start = all[index]
            guard at >= start.at else { return nil }
            let end = (stopTimes.filter { $0 >= start.at } + endTimes.filter { $0 >= start.at }).min()
            guard let end else { return (start, nil) }
            if at <= end { return (start, end) }
            guard let next = all.firstIndex(where: { $0.at > end }) else { return nil }
            index = next
        }
        return nil
    }

    /// The latest end of the parent turn of a run that started with `start`, nil while it has none: a
    /// `Stop`/`StopFailure` in the session, or a submit of another prompt, at or after the start. A repeated
    /// submit of the run's own prompt is not one.
    private func parentTurnEnd(session: String, start: Start) -> Double? {
        let stop = latestTurnEnds[session].flatMap { $0 >= start.at ? $0 : nil }
        let submit = start.prompt.flatMap { prompt in
            submits[session]?.filter { $0.at >= start.at && $0.prompt != prompt }.map(\.at).max()
        }
        return [stop, submit].compactMap { $0 }.max()
    }

    /// When the open run holding the call `agent` made at `at` reaches its age bound; nil when no open
    /// run holds it or its parent turn has not ended.
    func expiresAt(session: String, agent: String, at: Double) -> Double? {
        guard let run = runStart(session: session, agent: agent, holding: at), run.endedAt == nil else { return nil }
        return ClaudeObservationReader.subagentExpiresAt(startedAt: run.start.at,
                                                         latestTurnEndAt: parentTurnEnd(session: session, start: run.start))
    }

    /// Whether the call `agent` made at `at` is still running at `now`: `.ended` once its run stopped,
    /// its session ended, or it passed its age bound; `.unknown` when no run holds it.
    func call(session: String, agent: String, at: Double, now: Double) -> CallState {
        guard let run = runStart(session: session, agent: agent, holding: at) else { return .unknown }
        if run.endedAt != nil { return .ended }
        return ClaudeObservationReader.subagentIsListed(startedAt: run.start.at,
                                                        latestTurnEndAt: parentTurnEnd(session: session, start: run.start),
                                                        now: now) ? .running : .ended
    }
}
