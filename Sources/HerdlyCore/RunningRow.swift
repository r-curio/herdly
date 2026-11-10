import Foundation

extension AgentSource {
    /// The agent's short name in row text: "Codex" or "Claude".
    public var displayName: String { self == .claude ? "Claude" : "Codex" }
}

extension AgentSessionIdentity {
    /// The agent surface a session runs on, as rows name it: "Codex CLI", "Codex Desktop", or
    /// "Claude Code" (every Claude session).
    public var sourceLabel: String {
        source == .claude ? "Claude Code" : (surface == .cli ? "Codex CLI" : "Codex Desktop")
    }
}

/// The one running row opened in place in the open queue (#319, F3). A running row is one line until
/// the user opens it; only one is open at a time, so opening another moves the open state to it and
/// a second click on the open row closes it. Escape closes an open row before it collapses the panel.
/// Presentation only: opening a row acknowledges nothing and selects no navigation target.
///
/// An opened row whose session has running subagents also carries the switcher's choice (#397, Paper
/// H2 "E · Switcher"): whose lines the details show, the session's or one subagent's. Every open
/// starts on the session, and closing the row forgets the choice.
public struct OpenRunningRow: Equatable, Sendable {
    /// Whose lines the opened row shows.
    public enum Shown: Hashable, Sendable {
        case session
        /// A running subagent, by its `SubagentActivity.id`.
        case subagent(String)
    }

    public private(set) var open: AgentAttentionID?
    public private(set) var shown: Shown = .session

    public init() {}

    public func isOpen(_ id: AgentAttentionID) -> Bool { open == id }

    /// Shows `choice` in the open row `row` and returns true. Ignored, returning false, when `row` is
    /// not the open row or the subagent is not one of its running subagents.
    @discardableResult
    public mutating func select(_ choice: Shown, in row: AgentAttentionItem) -> Bool {
        guard open == row.id else { return false }
        if case let .subagent(id) = choice, !(row.running?.subagents.contains { $0.id == id } ?? false) { return false }
        shown = choice
        return true
    }

    /// The subagent whose lines the open row shows, read from `row`'s current subagents; nil shows the
    /// session. A shown subagent that has finished reads nil at once, before `reconcile` runs.
    public func shownSubagent(in row: AgentAttentionItem) -> SubagentActivity? {
        guard open == row.id, case let .subagent(id) = shown else { return nil }
        return row.running?.subagents.first { $0.id == id }
    }

    /// Opens `row`, or closes it when it is already open, and returns true. Only a working row
    /// (`.running`) opens in place: a request opens as its own card, and a waiting turn and the other
    /// rows keep their body, so for them nothing changes and the result is false.
    @discardableResult
    public mutating func toggle(_ row: AgentAttentionItem) -> Bool {
        guard row.kind == .running else { return false }
        open = open == row.id ? nil : row.id
        shown = .session
        return true
    }

    /// Where keyboard focus goes inside an opened row once its subagents change (#397).
    public enum Focus: Hashable, Sendable {
        case well(Shown)
        /// The row's Open control, once the switcher itself has left.
        case open
    }

    /// Keyboard focus to move to when the running subagents become `running`, given the switcher well
    /// that last held focus: a finished subagent's well hands focus to "Session" while any well
    /// remains, or to Open when the last subagent finished and the switcher left, so focus stays in
    /// the row. Nil leaves focus where it is.
    public static func focusAfterSubagentsChange(lastFocused: Shown?, running: [String]) -> Focus? {
        guard case let .subagent(id)? = lastFocused, !running.contains(id) else { return nil }
        return running.isEmpty ? .open : .well(.session)
    }

    /// The switcher well to remember as last focused when its focus becomes `now`. A well that lost
    /// focus because its subagent finished stays remembered (SwiftUI can clear focus before the new
    /// subagent list arrives); one the user moved focus away from is forgotten.
    public static func rememberedFocus(previous: Shown?, now: Shown?, running: [String]) -> Shown? {
        if now == nil, case let .subagent(id)? = previous, !running.contains(id) { return previous }
        return now
    }

    public mutating func close() {
        open = nil
        shown = .session
    }

    /// Closes the open row and returns true; returns false with nothing open, so Escape goes on to
    /// collapse the panel.
    public mutating func escape() -> Bool {
        guard open != nil else { return false }
        close()
        return true
    }

    /// Closes the open row once it is no longer an on-screen working row: its turn left the queue or
    /// stopped working, or a closed "N working" fold hides it. It never reopens by itself. A shown
    /// subagent that is no longer running hands the details back to the session.
    public mutating func reconcile(visible rows: [AgentAttentionItem]) {
        guard let open else { return }
        guard let row = rows.first(where: { $0.id == open && $0.kind == .running }) else { return close() }
        if case .subagent = shown, shownSubagent(in: row) == nil { shown = .session }
    }
}

/// What an opened running row shows below its header line (#319, F3), one labelled line each:
/// "now", the latest action; "you", the last prompt; "where", the source and the terminal Herdly last
/// saw. A line with nothing to show is left out, except that "now" reads "Unknown" when neither an
/// action nor a prompt is known, so an opened row is never blank. Text that does not fit one line
/// (`lineLimit` characters, or more than one line) is shortened with "…" and keeps its full text
/// behind a disclosure, so a shortened command stays marked (D11). Presentation only.
public struct RunningRowDetails: Equatable, Sendable {
    /// Characters a line shows before it is shortened: about two lines of the 11pt mono value column
    /// at the standard panel width, so an opened row stays compact.
    public static let lineLimit = 80

    public struct Now: Equatable, Sendable {
        /// "$ <command>" for a shell command; otherwise the tool's name and its target.
        public let text: String
        /// The full action when `text` is shortened; nil when `text` already shows all of it.
        public let full: String?
        /// "Show full command" or "Show full action" while `full` is set.
        public let disclosureTitle: String?
        /// Neither an action nor a prompt is known; drawn dim.
        public let isUnknown: Bool

        public init(text: String, full: String?, disclosureTitle: String?, isUnknown: Bool) {
            self.text = text
            self.full = full
            self.disclosureTitle = disclosureTitle
            self.isUnknown = isUnknown
        }
    }

    public struct You: Equatable, Sendable {
        public let text: String
        /// The prompt as Herdly has it, when `text` shows less than that.
        public let full: String?
        /// "Show full prompt", or "Show more of prompt" when Herdly kept only the prompt's start.
        public let disclosureTitle: String?
        /// Herdly kept only the start of the prompt; the full prompt is in the agent.
        public let keptOnlyStart: Bool

        public init(text: String, full: String?, disclosureTitle: String?, keptOnlyStart: Bool) {
            self.text = text
            self.full = full
            self.disclosureTitle = disclosureTitle
            self.keptOnlyStart = keptOnlyStart
        }
    }

    public let now: Now?
    public let you: You?
    /// The "where" line: "Codex CLI", "Codex Desktop" or "Claude Code", then " · <terminal>" when known.
    public let place: String

    /// `host` is the terminal app or multiplexer whose inventory last showed the session, if any.
    public static func make(_ running: AgentRunning, host: TerminalHost?) -> RunningRowDetails {
        let source = running.identity.session.sourceLabel
        let you = prompt(running)
        var now = action(running)
        if now == nil && you == nil {
            now = Now(text: "Unknown", full: nil, disclosureTitle: nil, isUnknown: true)
        }
        return RunningRowDetails(now: now, you: you, place: source + (host.map { " · " + $0.displayName } ?? ""))
    }

    private static func action(_ running: AgentRunning) -> Now? {
        now(toolName: running.toolName, toolInput: running.toolInput)
    }

    /// The "now" line for one tool call, or nil without a tool name. A subagent's latest action
    /// (`SubagentActivity`) uses the same line.
    public static func now(toolName: String?, toolInput: [String: String]) -> Now? {
        guard let name = nonBlank(toolName) else { return nil }
        let action = toolName.flatMap { ToolAction(name: $0, input: toolInput) }
        if let action, action.isCommand {
            let line = shortened(action.fullText)
            return Now(text: "$ " + line.text, full: line.shortened ? action.fullText : nil,
                       disclosureTitle: line.shortened ? action.disclosureTitle : nil, isUnknown: false)
        }
        let full = action.map { "\(name) \($0.fullText)" } ?? name
        let line = shortened(full)
        return Now(text: line.text, full: line.shortened ? full : nil,
                   disclosureTitle: line.shortened ? (action?.disclosureTitle ?? "Show full action") : nil, isUnknown: false)
    }

    private static func prompt(_ running: AgentRunning) -> You? {
        guard let prompt = nonBlank(running.prompt) else { return nil }
        let line = shortened(prompt)
        let kept = running.promptShortened
        // Herdly's copy is only the prompt's start, so even an unshortened line is not all of it.
        let text = kept && !line.shortened ? line.text + "…" : line.text
        let opens = line.shortened || kept
        return You(text: text, full: opens ? prompt : nil,
                   disclosureTitle: opens ? (kept ? "Show more of prompt" : "Show full prompt") : nil, keptOnlyStart: kept)
    }

    /// The first line of trimmed text, cut to `lineLimit` characters, with "…" when anything was left out.
    static func shortened(_ value: String) -> (text: String, shortened: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: \.isNewline)
        let first = lines.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? trimmed
        let cut = String(first.prefix(lineLimit))
        let shortened = lines.count > 1 || first.count > lineLimit
        return (shortened ? cut + "…" : cut, shortened)
    }
}

/// What an opened running row shows for one of its running subagents (#397, Paper H2 "E · Switcher"),
/// in the same label/value lines as the session's: "now", its latest action ("Unknown" in dim while
/// none is known); "asked", the task it was given, when the source reports one; "role", when the source
/// names one; and "for", how long it has run, in the rows' age format. Presentation only.
public struct SubagentDetails: Equatable, Sendable {
    public struct Asked: Equatable, Sendable {
        public let text: String
        /// The whole task when `text` shows less of it.
        public let full: String?
        /// "Show full task" while `full` is set.
        public let disclosureTitle: String?
    }

    public let now: RunningRowDetails.Now
    public let asked: Asked?
    public let role: String?
    /// Time since the subagent started: "<1m", "4m", "2h", "3d".
    public let age: String

    public static func make(_ subagent: SubagentActivity, now: Double) -> SubagentDetails {
        let action = subagent.latestAction
            ?? RunningRowDetails.Now(text: "Unknown", full: nil, disclosureTitle: nil, isUnknown: true)
        let asked = nonBlank(subagent.asked).map { task -> Asked in
            let line = RunningRowDetails.shortened(task)
            return Asked(text: line.text, full: line.shortened ? task : nil,
                         disclosureTitle: line.shortened ? "Show full task" : nil)
        }
        return SubagentDetails(now: action, asked: asked, role: nonBlank(subagent.role),
                               age: QueueRowPresentation.age(since: subagent.startedAt, now: now))
    }
}

/// `text` trimmed of surrounding whitespace, or nil when nothing is left: a detail line with nothing
/// to show is left out.
private func nonBlank(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}
