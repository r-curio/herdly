import Foundation

/// The tone a finished row's state words take (#418, Paper "R3 · State first"): the one exception to
/// the One Color Rule and D14 besides the "Failed" well and the usage rings. Only the state words carry
/// it; the pull request, repository and branch stay dim. Each holds at least 4.5:1 on black.
///
/// The values live here, as plain sRGB numbers, rather than in `NotchStyle`: there is then one copy,
/// HerdlyCore stays free of AppKit and SwiftUI, and the contrast rule can be tested on the exact values.
/// `NotchStyle`'s four state tokens are built from them.
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
/// pushed · herdly @ feat/usage"); without a verdict, the place as before ("· herdly @ main"). A quiet
/// working row (#419) ends with the word "quiet" after its place ("· herdly @ docs/notes · quiet"). The
/// state and the quiet word never truncate: `detail` is the part that gives way. Presentation only; it
/// orders, counts and acknowledges nothing.
public struct RowPlaceLine: Equatable, Sendable {
    /// The tone "quiet" is drawn in: the state amber of a finished row's "uncommitted" (#419, Q1).
    public static let quietTone = WorkStatusTone.amber
    /// The quiet word, drawn last in `quietTone`.
    public static let quietWord = "quiet"

    /// The work status drawn first, in its tone; nil when the row shows no verdict.
    public let label: WorkStatusLabel?
    /// The dim text after the state ("herdly#431", or the place), or the whole place without one; it
    /// truncates first. Nil when there is nothing after the state.
    public let detail: String?
    /// The working row has gone quiet (`QuietRule`): "quiet" follows the place.
    public let quiet: Bool

    /// Nil when there is neither a verdict, a place, nor the quiet word to show. A label with a pull
    /// request shows the pull request in place of `place`.
    public init?(label: WorkStatusLabel?, place: String?, quiet: Bool) {
        let detail = label?.pullRequest.map { "\($0.name)#\($0.number)" } ?? place
        guard label != nil || detail != nil || quiet else { return nil }
        self.label = label
        self.detail = detail
        self.quiet = quiet
    }

    /// The dim separator drawn before "quiet": " · " after a state or place, "· " when the word is alone.
    public var quietLead: String { label == nil && detail == nil ? "· " : " · " }

    /// The whole slot as one line, as the row draws it.
    public var text: String {
        "· " + [label?.words, detail, quiet ? Self.quietWord : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// What VoiceOver reads in the place's position: the state in words, then the pull request ("checks
    /// failing, pull request 431 in herdly") or the place, then "quiet". Colour is never the only signal.
    public var spoken: String {
        let quietWord = quiet ? Self.quietWord : nil
        if let label, let request = label.pullRequest {
            return ["\(label.words), pull request \(request.number) in \(request.name)", quietWord]
                .compactMap { $0 }.joined(separator: ", ")
        }
        return [label?.words, detail, quietWord].compactMap { $0 }.joined(separator: ", ")
    }

    /// The row's place slot, or nil when it has nothing to show.
    /// - `label`: the turn's work status (`WorkStatusModel.finishedLabel`), nil without a verdict.
    /// - `place`: the place in the display profile's "After each name" format.
    /// - `note`: a row note keeps the slot while it shows (it is drawn instead), so no verdict or quiet
    ///   word is drawn; VoiceOver still reads the place, and "quiet", before the note.
    /// - `quiet`: whether the row is quiet now (`AgentAttentionItem.isQuiet(at:)`); only a working row
    ///   reads it.
    ///
    /// Only a result row (recent or Earlier) shows a verdict. "Failed" and "Unreachable" keep the word
    /// slot and the verdict still shows here; a result whose status is unavailable ("Status unknown")
    /// and a waiting or status-unavailable Claude row show none.
    public static func make(_ item: AgentAttentionItem, label: WorkStatusLabel?, place: String?,
                            note: RowNote?, quiet: Bool) -> RowPlaceLine? {
        let shown = note == nil && showsVerdict(item) ? label : nil
        // Kept with a note too: the note takes the visual slot, but VoiceOver still reads "quiet" (#419).
        return RowPlaceLine(label: shown, place: place, quiet: quiet && item.kind == .running)
    }

    /// Result rows whose status is known: "Failed" may sit beside a verdict, "Status unknown" may not.
    static func showsVerdict(_ item: AgentAttentionItem) -> Bool {
        guard item.kind == .outcome || item.kind == .earlierOutcome else { return false }
        return QueueRowPresentation.exception(item) != .statusUnknown
    }
}
