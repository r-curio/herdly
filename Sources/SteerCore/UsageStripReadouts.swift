import CoreGraphics

/// One usage bar in the strip's right wing, drawn left to right in the order `make` returns.
public struct UsageStripReadout: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case codex, claude }

    public let source: Source
    /// Dim label ahead of the bar ("5h", "7d"); Codex's weekly readout has none.
    public let caption: String?
    /// Share used, 0 to 100, or nil while the window is unknown (Codex's weekly readout only).
    public let usedPercent: Double?
    public let percentText: String?

    public init(source: Source, caption: String?, usedPercent: Double?, percentText: String?) {
        self.source = source
        self.caption = caption
        self.usedPercent = usedPercent
        self.percentText = percentText
    }

    /// What VoiceOver says for this bar in the strip label, e.g. "Claude five-hour limit 62% used".
    public var spokenLabel: String {
        let name = source == .claude ? "Claude" : "Codex"
        let window = switch caption {
        case "5h": "five-hour"
        case "7d": "seven-day"
        default: "weekly"
        }
        return "\(name) \(window) limit " + (percentText.map { "\($0) used" } ?? "unknown")
    }
}

/// Which usage bars the strip shows and how wide their wing must be. Claude's current five-hour and
/// seven-day windows come first, then Codex's five-hour window while it reports one, then Codex's
/// weekly readout, which is always present (a dash while unknown). Pass readings already filtered
/// to the present (`current(now:)`) so the bars and the wing width agree. With `fiveHour` false
/// both five-hour readouts are left out and the wing narrows to match.
public enum UsageStripReadouts {
    /// A captioned readout at 11pt mono, its 8pt trailing pad included, with room for "100%".
    public static let captionedReadoutWidth: CGFloat = 62
    /// Extra space between the Claude group and the Codex group (on top of the 8pt pad).
    public static let groupGap: CGFloat = 4

    public static func make(codex: CodexUsageReading?, claude: ClaudeUsageReading?,
                            fiveHour: Bool = true) -> [UsageStripReadout] {
        var readouts: [UsageStripReadout] = []
        if fiveHour, let window = claude?.fiveHour {
            readouts.append(UsageStripReadout(source: .claude, caption: "5h", usedPercent: window.usedPercentage, percentText: window.percentText))
        }
        if let window = claude?.sevenDay {
            readouts.append(UsageStripReadout(source: .claude, caption: "7d", usedPercent: window.usedPercentage, percentText: window.percentText))
        }
        if fiveHour, let window = codex?.fiveHour {
            readouts.append(UsageStripReadout(source: .codex, caption: "5h", usedPercent: window.usedPercent, percentText: window.percentText))
        }
        let weekly = codex?.weekly
        readouts.append(UsageStripReadout(source: .codex, caption: nil, usedPercent: weekly?.usedPercent, percentText: weekly?.percentText))
        return readouts
    }

    /// Width of the wing right of the housing for these readouts. Codex's own readouts keep their
    /// established widths (60pt weekly, 52pt more for five-hour); each Claude readout adds a full
    /// captioned width, plus the gap that sets the two groups apart.
    public static func wingWidth(_ readouts: [UsageStripReadout]) -> CGFloat {
        let codexFiveHour = readouts.contains { $0.source == .codex && $0.caption != nil }
        let claude = readouts.filter { $0.source == .claude }.count
        return NotchPlacement.trailingWing
            + (codexFiveHour ? NotchPlacement.readoutWidth : 0)
            + CGFloat(claude) * captionedReadoutWidth
            + (claude > 0 ? groupGap : 0)
    }
}
