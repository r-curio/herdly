import CoreGraphics

/// One usage window's share used, as the strip's rings draw and print it.
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

/// One source's usage ring in the strip's right wing (D35), drawn left to right in the order `make`
/// returns: the outer ring is the weekly (Claude: seven-day) window, the inner ring the five-hour one.
/// "Unknown" stays distinct from 0%: an unknown window carries no share at all.
public struct UsageStripReadout: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case codex, claude }

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
    /// The inner ring; nil draws no inner ring at all (not an empty track): the window is not
    /// reported, or the strip shows weekly windows only.
    public let fiveHour: UsageShare?
    /// The outer ring's fill; nil while the window is unknown.
    public let weekly: UsageShare?
    /// False only for Claude reporting no seven-day window, which then draws no outer ring. Codex's
    /// outer track is always there, empty while its weekly window is unknown.
    public let hasOuterRing: Bool
    /// What VoiceOver calls the outer window: "seven-day" for Claude, "weekly" for Codex and for
    /// either source while the strip shows weekly windows only.
    public let weeklyName: String

    public init(source: Source, fiveHour: UsageShare?, weekly: UsageShare?, hasOuterRing: Bool = true,
                weeklyName: String = "weekly") {
        self.source = source
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.hasOuterRing = hasOuterRing
        self.weeklyName = weeklyName
    }

    /// No current reading at all: the empty outer track carries a dim "—", collapsed and open.
    public var isUnknown: Bool { fiveHour == nil && weekly == nil }

    /// The open strip's numbers after the ring: five-hour, a dim slash, week, one trailing percent
    /// ("61/18%"); one window alone is just that number ("58%"); an unknown window is a dim "—",
    /// and the percent follows the last known figure.
    public var openText: [TextRun] {
        var figures: [UsageShare?] = []
        if fiveHour != nil { figures.append(fiveHour) }
        if hasOuterRing { figures.append(weekly) }
        let lastKnown = figures.lastIndex { $0 != nil }
        var runs: [TextRun] = []
        for (index, share) in figures.enumerated() {
            if index > 0 { runs.append(TextRun("/", dim: true)) }
            if let share {
                runs.append(TextRun(share.figure + (index == lastKnown ? "%" : "")))
            } else {
                runs.append(TextRun("—", dim: true))
            }
        }
        return runs
    }

    /// Characters the open numbers can take whatever the values: each known figure is reserved
    /// three digits ("100"), so the wing does not move as the numbers change.
    var reservedOpenCharacters: Int {
        var figures: [UsageShare?] = []
        if fiveHour != nil { figures.append(fiveHour) }
        if hasOuterRing { figures.append(weekly) }
        let known = figures.filter { $0 != nil }.count
        return known * 3 + (figures.count - known) + max(0, figures.count - 1) + (known > 0 ? 1 : 0)
    }

    /// What VoiceOver says for this source in the strip label, one phrase per window, e.g.
    /// "Claude five-hour limit 62% used"; the wording predates the rings and is kept.
    public var spokenLabels: [String] {
        let name = source == .claude ? "Claude" : "Codex"
        var labels: [String] = []
        if let fiveHour { labels.append("\(name) five-hour limit \(fiveHour.percentText) used") }
        if hasOuterRing {
            labels.append("\(name) \(weeklyName) limit " + (weekly.map { "\($0.percentText) used" } ?? "unknown"))
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
        var readouts: [UsageStripReadout] = []
        let claudeFive = fiveHour ? claude?.fiveHour.map { UsageShare(usedPercent: $0.usedPercentage) } : nil
        let claudeSeven = claude?.sevenDay.map { UsageShare(usedPercent: $0.usedPercentage) }
        if claudeFive != nil || claudeSeven != nil {
            readouts.append(UsageStripReadout(source: .claude, fiveHour: claudeFive, weekly: claudeSeven,
                                              hasOuterRing: claudeSeven != nil,
                                              weeklyName: fiveHour ? "seven-day" : "weekly"))
        }
        readouts.append(UsageStripReadout(source: .codex,
                                          fiveHour: fiveHour ? codex?.fiveHour.map { UsageShare(usedPercent: $0.usedPercent) } : nil,
                                          weekly: codex?.weekly.map { UsageShare(usedPercent: $0.usedPercent) }))
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

    /// The open wing: each ring followed by its numbers, room reserved for "100" per figure. Pass it
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
