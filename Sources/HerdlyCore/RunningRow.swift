import Foundation

/// The one running row opened in place in the open queue (#319, F3). A running row is one line until
/// the user opens it; only one is open at a time, so opening another moves the open state to it and
/// a second click on the open row closes it. Escape closes an open row before it collapses the panel.
/// Presentation only: opening a row acknowledges nothing and selects no navigation target.
public struct OpenRunningRow: Equatable, Sendable {
    public private(set) var open: AgentAttentionID?

    public init() {}

    public func isOpen(_ id: AgentAttentionID) -> Bool { open == id }

    /// Opens `row`, or closes it when it is already open. Only a working row (`.running`) opens in
    /// place: a request opens as its own card, and a waiting turn and the other rows keep their body.
    public mutating func toggle(_ row: AgentAttentionItem) {
        guard row.kind == .running else { return }
        open = open == row.id ? nil : row.id
    }

    public mutating func close() { open = nil }

    /// Closes the open row and returns true; returns false with nothing open, so Escape goes on to
    /// collapse the panel.
    public mutating func escape() -> Bool {
        guard open != nil else { return false }
        open = nil
        return true
    }

    /// Closes the open row once it is no longer an on-screen working row: its turn left the queue or
    /// stopped working, or a closed "N working" fold hides it. It never reopens by itself.
    public mutating func reconcile(visible rows: [AgentAttentionItem]) {
        if let open, !rows.contains(where: { $0.id == open && $0.kind == .running }) { self.open = nil }
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
        let session = running.identity.session
        let source = session.source == .claude ? "Claude Code" : (session.surface == .cli ? "Codex CLI" : "Codex Desktop")
        let you = prompt(running)
        var now = action(running)
        if now == nil && you == nil {
            now = Now(text: "Unknown", full: nil, disclosureTitle: nil, isUnknown: true)
        }
        return RunningRowDetails(now: now, you: you, place: source + (host.map { " · " + $0.displayName } ?? ""))
    }

    private static func action(_ running: AgentRunning) -> Now? {
        guard let name = running.toolName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let action = running.action
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
        guard let prompt = running.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return nil }
        let line = shortened(prompt)
        let kept = running.promptShortened
        // Herdly's copy is only the prompt's start, so even an unshortened line is not all of it.
        let text = kept && !line.shortened ? line.text + "…" : line.text
        let opens = line.shortened || kept
        return You(text: text, full: opens ? prompt : nil,
                   disclosureTitle: opens ? (kept ? "Show more of prompt" : "Show full prompt") : nil, keptOnlyStart: kept)
    }

    /// The first line of trimmed text, cut to `lineLimit` characters, with "…" when anything was left out.
    private static func shortened(_ value: String) -> (text: String, shortened: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: \.isNewline)
        let first = lines.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? trimmed
        let cut = String(first.prefix(lineLimit))
        let shortened = lines.count > 1 || first.count > lineLimit
        return (shortened ? cut + "…" : cut, shortened)
    }
}
