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

    public static let standard = NotchAppearance(leftWing: .spritesAndCount, centerLabel: .taskName, usage: .compact,
                                                 sprite: .sheep, sort: .needsAttention, grouping: .none,
                                                 earlier: .fiveMinutes, panelWidth: .standard)

    public init(leftWing: StripLeftWing, centerLabel: StripCenterLabel, usage: UsageDisplay,
                sprite: SpriteKind, sort: QueueSort, grouping: QueueGrouping, earlier: EarlierDelay,
                panelWidth: PanelWidth = .standard) {
        self.leftWing = leftWing
        self.centerLabel = centerLabel
        self.usage = usage
        self.sprite = sprite
        self.sort = sort
        self.grouping = grouping
        self.earlier = earlier
        self.panelWidth = panelWidth
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
                               panelWidth: read("panelWidth", standard.panelWidth))
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
    }

    static func key(_ profile: DisplayProfile, _ field: String) -> String {
        "appearance.\(profile.rawValue).\(field)"
    }
}

/// A run of queue rows under one optional heading.
public struct QueueGroup: Equatable, Sendable {
    public let heading: String?
    public let items: [AgentAttentionItem]
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
        let working = foldsWorking && !workingOpen ? [] : self.working
        return (attention + working).flatMap(\.items).map(\.id)
    }

    /// Splits already-ordered rows. While folding, ungrouped requests gain a "Needs you" heading and
    /// folded working rows drop the State grouping's "Working" heading, since the fold already names
    /// them; Agent and Project headings stay inside the fold.
    public static func make(_ items: [AgentAttentionItem], grouping: QueueGrouping,
                            project: (AgentAttentionItem) -> String?) -> QueueSections {
        let needsUser = items.filter { $0.kind != .running }
        let running = items.filter { $0.kind == .running }
        let folds = !needsUser.isEmpty && !running.isEmpty
        var attention = QueueGroups.make(needsUser, grouping: grouping, project: project)
        if folds && grouping == .none {
            // Without grouping, one heading still separates the requests from the fold below them.
            attention = [QueueGroup(heading: "Needs you", items: needsUser)]
        }
        let workingGrouping: QueueGrouping = folds && grouping == .state ? .none : grouping
        return QueueSections(attention: attention,
                             working: QueueGroups.make(running, grouping: workingGrouping, project: project),
                             workingCount: running.count)
    }
}
