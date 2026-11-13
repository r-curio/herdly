import Foundation

/// The tone a finished row's state words take (#418, Paper "R3 · State first"): the one exception to
/// the One Color Rule and D14 besides the "Failed" well and the usage rings. Only the state words carry
/// it; the pull request, repository and branch stay dim. Each holds at least 4.5:1 on black.
public enum WorkStatusTone: Equatable, Sendable {
    /// Checks failing, conflict.
    case red
    /// Uncommitted, not pushed.
    case amber
    /// Checks running.
    case gray
    /// Checks passed, merged.
    case green

    /// The sRGB value, 0xRRGGBB.
    public var hex: UInt32 {
        switch self {
        case .red: 0xF87171
        case .amber: 0xFBBF24
        case .gray: 0x8F8F8F
        case .green: 0x4ADE80
        }
    }

    /// The sRGB channels, 0 to 1.
    public var components: (red: Double, green: Double, blue: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}

extension WorkStatus {
    /// The state words' tone; nil for no verdict.
    public var tone: WorkStatusTone? {
        switch self {
        case .noVerdict: nil
        case .checksFailing, .conflict: .red
        case .uncommitted, .notPushed: .amber
        case .checksRunning: .gray
        case .checksPassed, .merged: .green
        }
    }
}

/// The place slot after a row's name (#418): the work status state first, then either the pull
/// request ("· checks failing · herdly#431") or the place in the display profile's format ("· not
/// pushed · herdly @ feat/usage"); without a verdict, the place as before ("· herdly @ main"). The
/// state never truncates: `detail` is the part that gives way. Presentation only; it orders, counts
/// and acknowledges nothing.
public struct RowPlace: Equatable, Sendable {
    /// The state words, drawn first in their tone; nil when the row shows no verdict.
    public let state: WorkStatus?
    /// The dim text after the state, or the whole place without one; it truncates first. Nil when
    /// there is nothing to show after the state.
    public let detail: String?
    /// What VoiceOver reads in the place's position: the state in words, then the pull request or
    /// the place. Colour is never the only signal.
    public let spoken: String

    public init(state: WorkStatus?, detail: String?, spoken: String) {
        self.state = state
        self.detail = detail
        self.spoken = spoken
    }

    /// The whole slot as one line, as the row draws it.
    public var text: String {
        "· " + [state?.words, detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// The row's place slot, or nil when it has nothing to show.
    /// - `label`: the turn's work status (`WorkStatusModel.finishedLabel`), nil without a verdict.
    /// - `place`: the place in the display profile's "After each name" format.
    /// - `note`: a row note keeps the slot while it shows (it is drawn instead), so no verdict is shown;
    ///   VoiceOver still reads the place before the note.
    ///
    /// Only a result row (recent or Earlier) shows a verdict. "Failed" and "Unreachable" keep the word
    /// slot and the verdict still shows here; a result whose status is unavailable ("Status unknown")
    /// and a waiting or status-unavailable Claude row show none.
    public static func make(_ item: AgentAttentionItem, label: WorkStatusLabel?, place: String?,
                            note: RowNote?) -> RowPlace? {
        guard note == nil, let label, let words = label.verdict.words, showsVerdict(item) else {
            return place.map { RowPlace(state: nil, detail: $0, spoken: $0) }
        }
        let state = label.verdict
        if let request = label.pullRequest {
            return RowPlace(state: state, detail: "\(request.name)#\(request.number)",
                            spoken: "\(words), pull request \(request.number) in \(request.name)")
        }
        return RowPlace(state: state, detail: place, spoken: [words, place].compactMap { $0 }.joined(separator: ", "))
    }

    /// Result rows whose status is known: "Failed" may sit beside a verdict, "Status unknown" may not.
    static func showsVerdict(_ item: AgentAttentionItem) -> Bool {
        guard item.kind == .outcome || item.kind == .earlierOutcome else { return false }
        return QueueRowPresentation.exception(item) != .statusUnknown
    }
}
