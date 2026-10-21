import Foundation

/// The kind of display the notch sits on. Each kind keeps its own appearance choices because the
/// camera housing changes what fits in the strip.
public enum DisplayProfile: String, CaseIterable, Identifiable, Sendable {
    case macBookNotch
    case externalDisplay

    public var id: String { rawValue }

    public init(hasCameraHousing: Bool) {
        self = hasCameraHousing ? .macBookNotch : .externalDisplay
    }
}

/// What the strip's left wing shows.
public enum StripLeftWing: String, CaseIterable, Sendable {
    case spritesAndCount
    case countOnly
    case none
}

/// The one-line label between the wings. Only drawn where no camera housing covers that space.
public enum StripCenterLabel: String, CaseIterable, Sendable {
    case taskName
    case sessionName
    case off
}

public enum UsageDisplay: String, CaseIterable, Sendable {
    case compact
    /// Every weekly or seven-day readout, without the five-hour ones.
    case weeklyOnly
    case hidden
}

public enum QueueSort: String, CaseIterable, Sendable {
    /// Queue priority, oldest arrival first within each group.
    case needsAttention
    /// Live approvals and waiting questions stay first; every other row is newest event first.
    case lastUpdate
}

/// What follows each name in the open queue (D21): the repo folder and branch, or one of them.
public enum QueueLabelFormat: String, CaseIterable, Sendable {
    case repoAtBranch
    case repoOnly
    case branchOnly
}

public enum QueueGrouping: String, CaseIterable, Sendable {
    case none
    case state
    case agent
    case project
}

/// How much wider the open panel is than the collapsed strip. Standard is the instrument in DESIGN.md.
public enum PanelWidth: String, CaseIterable, Sendable {
    case standard
    case wide
    case extraWide

    /// Width opening adds to the collapsed body.
    public var growth: CGFloat {
        switch self {
        case .standard: 60
        case .wide: 160
        case .extraWide: 260
        }
    }

    /// Narrowest body the open panel gets.
    public var minimumBody: CGFloat {
        switch self {
        case .standard: 380
        case .wide: 480
        case .extraWide: 580
        }
    }
}

/// How long an unacknowledged outcome stays current before it is listed under "Earlier".
/// Moving is presentation decay only; it never acknowledges.
public enum EarlierDelay: String, CaseIterable, Sendable {
    case twoMinutes
    case fiveMinutes
    case tenMinutes
    case twentyMinutes
    case never

    /// Seconds after arrival, or nil when outcomes never move.
    public var seconds: Double? {
        switch self {
        case .twoMinutes: 2 * 60
        case .fiveMinutes: 5 * 60
        case .tenMinutes: 10 * 60
        case .twentyMinutes: 20 * 60
        case .never: nil
        }
    }
}

/// One display profile's strip and queue choices. The standard value is the instrument described in
/// DESIGN.md, so a user who changes nothing sees no difference.
public struct NotchAppearance: Equatable, Sendable {
    public var leftWing: StripLeftWing
    public var centerLabel: StripCenterLabel
    public var usage: UsageDisplay
    public var sprite: SpriteKind
    public var sort: QueueSort
    public var grouping: QueueGrouping
    public var earlier: EarlierDelay
    public var panelWidth: PanelWidth
    /// What follows each name in the open queue. The Settings menu for it is #324.
    public var labelFormat: QueueLabelFormat

    public static let standard = NotchAppearance(leftWing: .spritesAndCount, centerLabel: .taskName, usage: .compact,
                                                 sprite: .sheep, sort: .needsAttention, grouping: .none,
                                                 earlier: .fiveMinutes, panelWidth: .standard, labelFormat: .repoAtBranch)

    public init(leftWing: StripLeftWing, centerLabel: StripCenterLabel, usage: UsageDisplay,
                sprite: SpriteKind, sort: QueueSort, grouping: QueueGrouping, earlier: EarlierDelay,
                panelWidth: PanelWidth = .standard, labelFormat: QueueLabelFormat = .repoAtBranch) {
        self.leftWing = leftWing
        self.centerLabel = centerLabel
        self.usage = usage
        self.sprite = sprite
        self.sort = sort
        self.grouping = grouping
        self.earlier = earlier
        self.panelWidth = panelWidth
        self.labelFormat = labelFormat
    }

    /// The camera housing covers the centre of the strip, so the label is never drawn there.
    public func effectiveCenterLabel(on profile: DisplayProfile) -> StripCenterLabel {
        profile == .macBookNotch ? .off : centerLabel
    }

    /// Reads one profile through `value(key)`. A missing or unrecognised value keeps the standard choice.
    /// The retired `indicator` key (Sprite, Dot, Bar, Tint) is not read, so a profile saved with it
    /// shows the standard Sheep until the user picks another sprite.
    public static func load(profile: DisplayProfile, value: (String) -> String?) -> NotchAppearance {
        func read<T: RawRepresentable>(_ field: String, _ fallback: T) -> T where T.RawValue == String {
            value(key(profile, field)).flatMap(T.init(rawValue:)) ?? fallback
        }
        let standard = NotchAppearance.standard
        return NotchAppearance(leftWing: read("leftWing", standard.leftWing),
                               centerLabel: read("centerLabel", standard.centerLabel),
                               usage: read("usage", standard.usage),
                               sprite: read("sprite", standard.sprite),
                               sort: read("sort", standard.sort),
                               grouping: read("grouping", standard.grouping),
                               earlier: read("earlier", standard.earlier),
                               panelWidth: read("panelWidth", standard.panelWidth),
                               labelFormat: read("labelFormat", standard.labelFormat))
    }

    public func save(profile: DisplayProfile, write: (String, String) -> Void) {
        write(Self.key(profile, "leftWing"), leftWing.rawValue)
        write(Self.key(profile, "centerLabel"), centerLabel.rawValue)
        write(Self.key(profile, "usage"), usage.rawValue)
        write(Self.key(profile, "sprite"), sprite.rawValue)
        write(Self.key(profile, "sort"), sort.rawValue)
        write(Self.key(profile, "grouping"), grouping.rawValue)
        write(Self.key(profile, "earlier"), earlier.rawValue)
        write(Self.key(profile, "panelWidth"), panelWidth.rawValue)
        write(Self.key(profile, "labelFormat"), labelFormat.rawValue)
    }

    static func key(_ profile: DisplayProfile, _ field: String) -> String {
        "appearance.\(profile.rawValue).\(field)"
    }
}

/// A run of queue rows under one optional heading.
public struct QueueGroup: Equatable, Sendable {
    public let heading: String?
    /// The rows on screen; a folded section leaves out its later rows.
    public let items: [AgentAttentionItem]
    /// The kind section this group is, when the queue is split by kind (D13).
    public let section: QueueKindSection?
    /// Every row in the group, folded ones included; a kind section's heading shows it.
    public let count: Int
    /// Every Earlier result in the group, folded ones included, in queue order. The "Earlier"
    /// heading counts these and its "Dismiss all" dismisses exactly these.
    public let earlierIDs: [AgentAttentionID]
    /// Rows behind the group's "+N more" pill; zero when nothing is folded.
    public var folded: Int { count - items.count }

    /// `items` are the rows shown; `all`, when the group folds, is every row it holds.
    public init(heading: String?, items: [AgentAttentionItem], section: QueueKindSection? = nil,
                all: [AgentAttentionItem]? = nil) {
        let all = all ?? items
        self.heading = heading
        self.items = items
        self.section = section
        self.count = max(items.count, all.count)
        self.earlierIDs = all.filter { $0.kind == .earlierOutcome }.map(\.id)
    }
}

/// The open queue's kind sections when it is not grouped (D13): live approvals, waiting questions,
/// and everything else that needs the user. Each heading says the kind, so rows carry no kind word.
/// `working` heads the running rows only when nothing needs the user (#319, F1); otherwise they sit
/// behind the "N working" fold, which names them. It never folds behind "+N more".
public enum QueueKindSection: String, CaseIterable, Hashable, Sendable {
    case approve
    case answer
    case check
    case working

    public var heading: String {
        switch self {
        case .approve: "Approve"
        case .answer: "Answer"
        case .check: "Check"
        case .working: "Working"
        }
    }

    /// The section a row that needs the user belongs in, or nil for a running row, which sits in the
    /// working fold or, with nothing above it, the Working section.
    public init?(_ kind: AgentAttentionKind) {
        switch kind {
        case .actionableApproval: self = .approve
        case .question: self = .answer
        case .handedBackApproval, .waiting, .outcome, .earlierOutcome, .statusUnavailable: self = .check
        case .running: return nil
        }
    }
}

/// How many rows each kind section shows before its "+N more" pill (D13). The open queue has a
/// budget of `lineBudget` lines below the strip; every live approval spends one and never folds.
/// When the remaining rows all fit, nothing folds. Otherwise each later section, in order, shows at
/// most `rowsBeforeFold` rows and spends one line on its pill, while leaving each section after it
/// room for one row and a pill; the last section takes what budget is left. Every section keeps at
/// least one row, and a section never folds a single row. Headings are not counted. Presentation
/// only: no count, deadline, or order changes.
public enum QueueFold {
    public static let lineBudget = 11
    public static let rowsBeforeFold = 3

    /// Rows shown per section, for sections of `sections` rows following `approvals` live approvals.
    public static func shownRows(approvals: Int, sections: [Int], budget: Int = lineBudget) -> [Int] {
        var linesLeft = budget - approvals
        guard sections.reduce(0, +) > linesLeft else { return sections }
        // The fewest lines a section can take: all of one or two rows, or one row and its pill.
        func fewest(_ rows: Int) -> Int { min(rows, 2) }
        return sections.indices.map { index in
            let rows = sections[index]
            let isLast = index == sections.count - 1
            let reservedForLater = sections[(index + 1)...].map(fewest).reduce(0, +)
            let allowed = max(fewest(rows), linesLeft - reservedForLater)
            let cap = isLast ? rows : rowsBeforeFold
            var shown = rows
            if rows > min(cap, allowed) {
                shown = max(1, min(cap, allowed - 1))
                if rows - shown == 1 { shown = rows }
            }
            linesLeft -= shown + (shown < rows ? 1 : 0)
            return shown
        }
    }
}

public enum QueueGroups {
    /// Splits already-ordered rows into headed groups. Groups appear in the order of their first row,
    /// so the group holding the highest-priority item leads, and rows keep their order inside a group.
    /// `project` returns a session's working folder when known.
    public static func make(_ items: [AgentAttentionItem], grouping: QueueGrouping,
                            project: (AgentAttentionItem) -> String?) -> [QueueGroup] {
        guard grouping != .none else { return items.isEmpty ? [] : [QueueGroup(heading: nil, items: items)] }
        var order: [String] = []
        var members: [String: [AgentAttentionItem]] = [:]
        for item in items {
            let heading = heading(for: item, grouping: grouping, project: project)
            if members[heading] == nil { order.append(heading) }
            members[heading, default: []].append(item)
        }
        return order.map { QueueGroup(heading: $0, items: members[$0] ?? []) }
    }

    private static func heading(for item: AgentAttentionItem, grouping: QueueGrouping,
                                project: (AgentAttentionItem) -> String?) -> String {
        switch grouping {
        case .none:
            return ""
        case .state:
            switch item.kind {
            case .outcome, .earlierOutcome: return "Done"
            case .running: return "Working"
            case .actionableApproval, .question, .handedBackApproval, .waiting, .statusUnavailable: return "Needs you"
            }
        case .agent:
            return item.session.source == .codex ? "Codex" : "Claude"
        case .project:
            guard let folder = project(item)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                  let name = folder.split(separator: "/").last, !name.isEmpty else { return "Other" }
            return String(name)
        }
    }
}

/// The open queue split for reading: rows that need the user first, then the working rows. While
/// anything needs the user, the working rows sit behind one "N working" fold so they cannot crowd
/// out a request. The split follows the to-check badge: every row except a running one needs the
/// user. It changes presentation only, never the order inside either part, a count, or a deadline.
public struct QueueSections: Equatable, Sendable {
    public let attention: [QueueGroup]
    public let working: [QueueGroup]
    public let workingCount: Int

    /// Working rows fold only when something above them needs the user; otherwise they are the queue.
    public var foldsWorking: Bool { !attention.isEmpty && workingCount > 0 }
    /// No rows at all.
    public var isEmpty: Bool { attention.isEmpty && working.isEmpty }

    /// The rows the keyboard selection steps through, in reading order. Rows in a closed working
    /// fold are not on screen and are skipped.
    public func selectableRows(workingOpen: Bool) -> [AgentAttentionID] {
        selectableItems(workingOpen: workingOpen).map(\.id)
    }

    /// The on-screen rows themselves, in the same order as `selectableRows`.
    public func selectableItems(workingOpen: Bool) -> [AgentAttentionItem] {
        let working = foldsWorking && !workingOpen ? [] : self.working
        return (attention + working).flatMap(\.items)
    }

    /// Splits already-ordered rows. With `kindSections` and no grouping (the open queue), rows that
    /// need the user sit under Approve, Answer, and Check headings with their counts, an empty section
    /// leaves no heading, and later sections fold behind "+N more" (`QueueFold`) unless named in
    /// `openSections`. With nothing needing the user, the running rows sit unfolded under a "Working"
    /// heading with their count (#319, F1). A card passes no `kindSections` and stays one unheaded row.
    /// Folded working rows drop the State grouping's "Working" heading, since the fold already names
    /// them; Agent and Project headings stay inside the fold.
    public static func make(_ items: [AgentAttentionItem], grouping: QueueGrouping,
                            project: (AgentAttentionItem) -> String?, kindSections: Bool = false,
                            openSections: Set<QueueKindSection> = []) -> QueueSections {
        let needsUser = items.filter { $0.kind != .running }
        let running = items.filter { $0.kind == .running }
        let folds = !needsUser.isEmpty && !running.isEmpty
        let attention = kindSections && grouping == .none
            ? sectionsByKind(needsUser, open: openSections)
            : QueueGroups.make(needsUser, grouping: grouping, project: project)
        let workingGrouping: QueueGrouping = folds && grouping == .state ? .none : grouping
        let working = kindSections && grouping == .none && !folds && !running.isEmpty
            ? [QueueGroup(heading: QueueKindSection.working.heading, items: running, section: .working)]
            : QueueGroups.make(running, grouping: workingGrouping, project: project)
        return QueueSections(attention: attention, working: working, workingCount: running.count)
    }

    /// One kind section's rows before folding.
    private struct KindRows {
        let section: QueueKindSection
        let rows: [AgentAttentionItem]
    }

    private static func sectionsByKind(_ items: [AgentAttentionItem], open: Set<QueueKindSection>) -> [QueueGroup] {
        let sections = QueueKindSection.allCases
            .map { section in KindRows(section: section, rows: items.filter { QueueKindSection($0.kind) == section }) }
            .filter { !$0.rows.isEmpty }
        let approvalCount = sections.first { $0.section == .approve }?.rows.count ?? 0
        let foldable = sections.filter { $0.section != .approve }
        let shownPerFoldable = QueueFold.shownRows(approvals: approvalCount, sections: foldable.map(\.rows.count))
        return sections.map { kind in
            let foldableIndex = foldable.firstIndex { $0.section == kind.section }
            let shown = kind.section == .approve || open.contains(kind.section)
                ? kind.rows.count : foldableIndex.map { shownPerFoldable[$0] } ?? kind.rows.count
            return QueueGroup(heading: kind.section.heading, items: Array(kind.rows.prefix(shown)),
                              section: kind.section, all: kind.rows)
        }
    }
}
