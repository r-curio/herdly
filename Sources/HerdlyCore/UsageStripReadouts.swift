import CoreGraphics

/// One usage window's share used, as the strip's rings draw and print it; Codex's and Claude's
/// windows format their percent through it too.
public struct UsageShare: Equatable, Sendable {
    /// As reported; values outside 0 to 100 are clamped by `fraction` and `figure`, never here.
    public let usedPercent: Double

    public init(usedPercent: Double) {
        self.usedPercent = usedPercent
    }

    /// Length of the ring's fill, 0 to 1; a reading above 100% closes the ring and no more.
    public var fraction: Double { min(100, max(0, usedPercent)) / 100 }
    /// The whole percent without its sign ("61"), as the open strip prints it.
    public var figure: String { "\(Int(min(100, max(0, usedPercent)).rounded()))" }
    public var percentText: String { figure + "%" }
}

/// One usage window as a ring shows it. A window that is not reported draws no ring at all; an
/// unknown one draws an empty track and never reads as 0%.
public enum UsageWindowState: Equatable, Sendable {
    case notReported
    case unknown
    case known(UsageShare)

    /// The share to fill, nil for an empty track or no ring.
    public var share: UsageShare? {
        if case .known(let share) = self { share } else { nil }
    }

    var isShown: Bool { self != .notReported }
}

/// One source's usage ring in the strip's right wing (D35), drawn left to right in the order `make`
/// returns: the outer ring is the weekly (Claude: seven-day) window, the inner ring the five-hour one.
public struct UsageStripReadout: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case codex, claude }

    /// What the outer window is called in the strip's spoken label. Claude's is "seven-day" beside
    /// its five-hour window and "weekly" while the strip shows weekly windows only; Codex's is
    /// always "weekly".
    public enum WeeklyWindow: Equatable, Sendable {
        case sevenDay, weekly

        var spokenName: String { self == .sevenDay ? "seven-day" : "weekly" }
    }

    /// One run of the open strip's numbers; `dim` runs are the slash and the unknown dash.
    public struct TextRun: Equatable, Sendable {
        public let text: String
        public let dim: Bool

        public init(_ text: String, dim: Bool = false) {
            self.text = text
            self.dim = dim
        }
    }

    public let source: Source
    /// The inner ring: not reported (no inner ring, not an empty track) or known.
    public let fiveHour: UsageWindowState
    /// The outer ring. Codex's is always shown, unknown before its first reading; Claude's is not
    /// reported while its reading has no current seven-day window.
    public let weekly: UsageWindowState
    public let weeklyWindow: WeeklyWindow

    public init(source: Source, fiveHour: UsageWindowState, weekly: UsageWindowState, weeklyWindow: WeeklyWindow) {
        self.source = source
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.weeklyWindow = weeklyWindow
    }

    /// No current reading at all: the empty outer track carries a dim "—", collapsed and open.
    public var isUnknown: Bool { fiveHour.share == nil && weekly.share == nil }

    /// The windows the ring shows, five-hour first, in the order the open numbers print them.
    private var shownWindows: [UsageWindowState] { [fiveHour, weekly].filter(\.isShown) }

    /// The open strip's numbers after the ring: five-hour, a dim slash, week, one trailing percent
    /// ("61/18%"); one window alone is just that number ("58%"); an unknown window is a dim "—"
    /// ("40/—%", or "—" alone with nothing known).
    public var openText: [TextRun] {
        var runs: [TextRun] = []
        for (index, window) in shownWindows.enumerated() {
            if index > 0 { runs.append(TextRun("/", dim: true)) }
            runs.append(window.share.map { TextRun($0.figure) } ?? TextRun("—", dim: true))
        }
        guard !isUnknown, let last = runs.last else { return runs }
        if last.dim { runs.append(TextRun("%")) } else { runs[runs.count - 1] = TextRun(last.text + "%") }
        return runs
    }

    /// Glyphs the open numbers are given: two digits per known figure whatever the value, so the
    /// wing holds still as the numbers change, and three while a window reads 100%.
    var reservedOpenCharacters: Int {
        let figures = shownWindows.reduce(0) { $0 + ($1.share.map { max(2, $0.figure.count) } ?? 1) }
        return figures + max(0, shownWindows.count - 1) + (isUnknown ? 0 : 1)
    }

    /// What VoiceOver says for this source in the strip label, one phrase per window, e.g.
    /// "Claude five-hour limit 62% used"; the wording predates the rings and is kept.
    public var spokenLabels: [String] {
        let name = source == .claude ? "Claude" : "Codex"
        var labels: [String] = []
        if let fiveHour = fiveHour.share { labels.append("\(name) five-hour limit \(fiveHour.percentText) used") }
        if weekly.isShown {
            labels.append("\(name) \(weeklyWindow.spokenName) limit " + (weekly.share.map { "\($0.percentText) used" } ?? "unknown"))
        }
        return labels
    }
}

/// Which usage rings the strip shows and how wide their wing must be (D35). Claude's ring comes
/// first while its newest reading has a current window, then Codex's, which is always present (an
/// empty track and a dash while unknown). Pass readings already filtered to the present
/// (`current(now:)`) so the rings and the wing width agree. With `fiveHour` false every inner ring
/// is left out, and Claude's ring only appears for its seven-day window.
public enum UsageStripReadouts {
    /// The ring's square.
    public static let ringSize: CGFloat = 18
    /// Each window's stroke, centred on radius 7.5 (outer, weekly) and 4 (inner, five-hour).
    public static let ringLineWidth: CGFloat = 2
    public static let outerRingDiameter: CGFloat = 15
    public static let innerRingDiameter: CGFloat = 8
    /// Between rings collapsed.
    public static let collapsedRingGap: CGFloat = 8
    /// Between one source's numbers and the next source's ring, open.
    public static let openGroupGap: CGFloat = 12
    /// Between a ring and its numbers or its dash.
    public static let textGap: CGFloat = 5
    /// One glyph of the 11pt system monospaced face (digits, slash, percent and dash alike).
    public static let glyphWidth: CGFloat = 6.8
    /// The strip's content inset on the wing's outer side, part of the wing's width.
    public static let contentInset: CGFloat = 8

    public static func make(codex: CodexUsageReading?, claude: ClaudeUsageReading?,
                            fiveHour: Bool = true) -> [UsageStripReadout] {
        func state(_ percent: Double?) -> UsageWindowState {
            percent.map { .known(UsageShare(usedPercent: $0)) } ?? .notReported
        }
        var readouts: [UsageStripReadout] = []
        let claudeFive = state(fiveHour ? claude?.fiveHour?.usedPercentage : nil)
        let claudeSeven = state(claude?.sevenDay?.usedPercentage)
        if claudeFive.isShown || claudeSeven.isShown {
            readouts.append(UsageStripReadout(source: .claude, fiveHour: claudeFive, weekly: claudeSeven,
                                              weeklyWindow: fiveHour ? .sevenDay : .weekly))
        }
        let codexWeekly = codex?.weekly.map { UsageWindowState.known(UsageShare(usedPercent: $0.usedPercent)) } ?? .unknown
        readouts.append(UsageStripReadout(source: .codex, fiveHour: state(fiveHour ? codex?.fiveHour?.usedPercent : nil),
                                          weekly: codexWeekly, weeklyWindow: .weekly))
        return readouts
    }

    /// The collapsed wing: rings only, which fit the 60pt minimum (`NotchPlacement.trailingWing`).
    /// Only Codex's unknown dash beside Claude's ring needs a few points more, so it never clips.
    public static func collapsedWingWidth(_ readouts: [UsageStripReadout]) -> CGFloat {
        guard !readouts.isEmpty else { return NotchPlacement.trailingWing }
        let rings = CGFloat(readouts.count) * ringSize + CGFloat(readouts.count - 1) * collapsedRingGap
        let dashes = readouts.reduce(CGFloat(0)) { $0 + ($1.isUnknown ? textGap + glyphWidth : 0) }
        return max(NotchPlacement.trailingWing, (rings + dashes + contentInset).rounded(.up))
    }

    /// The open wing: each ring followed by its numbers, two digits reserved per figure (three while
    /// a window reads 100%). Pass it
    /// as the placement's wing while the panel is open; the open growth then still adds to both wings.
    public static func openWingWidth(_ readouts: [UsageStripReadout]) -> CGFloat {
        guard !readouts.isEmpty else { return NotchPlacement.trailingWing }
        let groups = readouts.reduce(CGFloat(0)) {
            $0 + ringSize + textGap + CGFloat($1.reservedOpenCharacters) * glyphWidth
        }
        let width = groups + CGFloat(readouts.count - 1) * openGroupGap + contentInset
        return max(NotchPlacement.trailingWing, width.rounded(.up))
    }

    /// The wing for the panel's state.
    public static func wingWidth(_ readouts: [UsageStripReadout], expanded: Bool) -> CGFloat {
        expanded ? openWingWidth(readouts) : collapsedWingWidth(readouts)
    }
}
