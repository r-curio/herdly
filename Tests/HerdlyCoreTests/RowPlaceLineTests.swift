import AppKit
import Foundation
import SwiftUI
import Testing
@testable import HerdlyApp
@testable import HerdlyCore

// The place slot of a finished row (#418; Paper "R3 · State first · Chosen 2026-11-13").

private let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "3f9a2c1e-0000-4000-8000-000000000001", surface: .cli)
private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/Users/u/.claude", session: "abcdef12-3456", surface: .cli)
private let pr431 = WorkPullRequest(repository: "r-curio/herdly", number: 431)

private func label(_ verdict: WorkStatus, _ pullRequest: WorkPullRequest? = nil) throws -> WorkStatusLabel {
    try #require(WorkStatusLabel(verdict: verdict, pullRequest: pullRequest))
}

private func row(_ kind: AgentAttentionKind, status: AgentOutcomeStatus? = .finished,
                 session: AgentSessionIdentity = codex) -> AgentAttentionItem {
    let outcome = status.map { AgentOutcome(session: session, turn: "t1", status: $0, arrivedAt: 100) }
    let id: AgentAttentionID = outcome.map { .outcome($0.identity) }
        ?? .running(AgentTurnIdentity(session: session, turn: "t1"))
    return AgentAttentionItem(id: id, kind: kind, session: session, arrivedAt: 100, approval: nil, question: nil,
                              outcome: outcome, running: nil, unavailableReason: nil)
}

@Test func aPullRequestVerdictReadsStateThenTheRepositoryAndNumber() throws {
    let line = try #require(RowPlaceLine.make(row(.outcome), label: label(.checksFailing, pr431),
                                              place: "herdly @ feat/usage", note: nil))
    #expect(line.label?.verdict == .checksFailing)
    #expect(line.detail == "herdly#431")
    #expect(line.text == "· checks failing · herdly#431")
    #expect(line.spoken == "checks failing, pull request 431 in herdly")
}

@Test func aVerdictWithoutAPullRequestReadsStateThenThePlaceInTheChosenFormat() throws {
    let notPushed = try label(.notPushed)
    let full = try #require(RowPlaceLine.make(row(.outcome), label: notPushed, place: "herdly @ feat/usage", note: nil))
    #expect(full.text == "· not pushed · herdly @ feat/usage")
    #expect(full.spoken == "not pushed, herdly @ feat/usage")
    #expect(RowPlaceLine.make(row(.outcome), label: notPushed, place: "feat/usage", note: nil)?.text == "· not pushed · feat/usage")
    // A format that shows nothing leaves the state alone.
    let bare = try #require(RowPlaceLine.make(row(.outcome), label: notPushed, place: nil, note: nil))
    #expect(bare.detail == nil)
    #expect(bare.text == "· not pushed")
    #expect(bare.spoken == "not pushed")
}

@Test func noVerdictKeepsTodaysPlaceExactly() throws {
    let today = try #require(RowPlaceLine.make(row(.outcome), label: nil, place: "herdly @ main", note: nil))
    #expect(today == RowPlaceLine(label: nil, place: "herdly @ main"))
    #expect(today.label == nil)
    #expect(today.text == "· herdly @ main")
    #expect(today.spoken == "herdly @ main")
    #expect(RowPlaceLine.make(row(.outcome), label: nil, place: nil, note: nil) == nil)
}

@Test func noVerdictHasNoLabelSoALineHasOneFormOfNoVerdict() {
    #expect(WorkStatusLabel(verdict: .noVerdict) == nil)
    #expect(WorkStatusLabel(verdict: .noVerdict, pullRequest: pr431) == nil)
    #expect(RowPlaceLine(label: nil, place: nil) == nil)
}

@Test func everyStateReadsInItsLowercaseWordsAndTone() throws {
    let expected: [(WorkStatus, String, WorkStatusTone)] = [
        (.checksFailing, "checks failing", .red), (.conflict, "conflict", .red),
        (.uncommitted, "uncommitted", .amber), (.notPushed, "not pushed", .amber),
        (.checksRunning, "checks running", .gray),
        (.checksPassed, "checks passed", .green), (.merged, "merged", .green)
    ]
    for (verdict, words, tone) in expected {
        let state = try label(verdict, pr431)
        let line = try #require(RowPlaceLine.make(row(.earlierOutcome), label: state, place: "herdly @ main", note: nil))
        #expect(line.text == "· \(words) · herdly#431")
        #expect(state.words == words)
        #expect(state.tone == tone)
    }
}

@Test func aRowNoteKeepsThePlaceSlotSoNoVerdictShows() throws {
    let passed = try label(.checksPassed, pr431)
    for note in [RowNote.sending, .sentUnconfirmed, .replyNotDelivered(.codex)] {
        let line = try #require(RowPlaceLine.make(row(.outcome), label: passed, place: "herdly @ main", note: note))
        #expect(line.label == nil)
        // VoiceOver still reads the place before the note, as it did.
        #expect(line.spoken == "herdly @ main")
    }
}

@Test func failedAndUnreachableResultsKeepTheirWordAndStillShowTheVerdict() throws {
    let conflict = try label(.conflict, pr431)
    let failed = row(.outcome, status: .failed)
    #expect(RowPlaceLine.make(failed, label: conflict, place: "herdly @ main", note: nil)?.label == conflict)
    #expect(QueueRowPresentation.exception(failed, target: .unreachable) == .unreachable)
    #expect(RowPlaceLine.make(row(.outcome), label: conflict, place: "herdly @ main", note: nil)?.label == conflict)
}

@Test func statusUnknownWaitingAndLiveRowsShowNoVerdict() throws {
    let merged = try label(.merged, pr431)
    for item in [row(.outcome, status: .unavailable), row(.earlierOutcome, status: .unavailable),
                 row(.waiting, status: nil, session: claude), row(.statusUnavailable, status: nil, session: claude),
                 row(.running, status: nil)] {
        #expect(RowPlaceLine.make(item, label: merged, place: "herdly @ main", note: nil)
            == RowPlaceLine(label: nil, place: "herdly @ main"))
    }
}

@Test func theSpokenHeadingReadsTheVerdictInWords() throws {
    let item = row(.outcome)
    let line = try #require(RowPlaceLine.make(item, label: label(.checksFailing, pr431), place: "herdly @ main", note: nil))
    #expect(QueueRowPresentation.spokenHeading(item, name: "Fix sort", place: line.spoken, note: nil, countdown: nil)
        == "Fix sort, checks failing, pull request 431 in herdly, Codex finished")
}

/// WCAG 2 contrast of an sRGB colour on black.
private func contrastOnBlack(_ color: Color) throws -> Double {
    let srgb = try #require(NSColor(color).usingColorSpace(.sRGB))
    func linear(_ c: CGFloat) -> Double {
        let c = Double(c)
        return c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let luminance = 0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent) + 0.0722 * linear(srgb.blueComponent)
    return (luminance + 0.05) / 0.05
}

@Test func theFourStateTonesAreThePaperValuesAndReadOnBlack() throws {
    // Paper R3's exact values.
    #expect(WorkStatusTone.red.hex == 0xF87171)
    #expect(WorkStatusTone.amber.hex == 0xFBBF24)
    #expect(WorkStatusTone.gray.hex == 0x8F8F8F)
    #expect(WorkStatusTone.green.hex == 0x4ADE80)
    for token in [NotchStyle.stateRed, NotchStyle.stateAmber, NotchStyle.stateGray, NotchStyle.stateGreen] {
        #expect(try contrastOnBlack(token) >= 4.5)
    }
    #expect(NotchStyle.stateColor(.red) == NotchStyle.stateRed)
    #expect(NotchStyle.stateColor(.amber) == NotchStyle.stateAmber)
    #expect(NotchStyle.stateColor(.gray) == NotchStyle.stateGray)
    #expect(NotchStyle.stateColor(.green) == NotchStyle.stateGreen)
}

// MARK: - Layout: what truncates

private let longName = "Refactor the session discovery pipeline for herdr and tmux"
private let longPlace = "a-very-long-repository-name @ feat/a-much-longer-branch-name-than-fits"

@MainActor private func fittedWidth<V: View>(_ view: V, proposed: CGFloat) -> CGFloat {
    NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: proposed, height: 200)).width
}

/// A result row's header line as `headerLine` lays it out: the sprite slot, the name and place, an
/// optional word, then the 36pt age lane, at 8pt gaps.
private struct HeaderLineProbe: View {
    let name: String
    let place: RowPlaceLine?
    let word: RowException?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: Sprite.slotGap) {
                Color.clear.frame(width: Sprite.slotWidth, height: Sprite.slotHeight)
                RowHeaderNamePlace(name: name, note: nil, place: place)
            }
            if let word { ExceptionWord(exception: word) }
            Text("59m").font(NotchStyle.mono(11)).lineLimit(1).fixedSize().frame(minWidth: 36, alignment: .trailing)
        }
    }
}

@MainActor @Test func theRepositoryOrBranchTruncatesBeforeTheState() {
    let line = RowPlaceLine(label: WorkStatusLabel(verdict: .checksFailing), place: longPlace)
    let stateOnly = fittedWidth(RowPlaceLineText(line: RowPlaceLine(label: WorkStatusLabel(verdict: .checksFailing), place: nil)!),
                                proposed: 1_000)
    for proposed: CGFloat in [400, 160, 60, 0] {
        #expect(fittedWidth(RowPlaceLineText(line: line!), proposed: proposed) >= stateOnly)
    }
}

@MainActor @Test func aLongNameAndPlaceNeverPushTheStateOrWordPastTheRow() throws {
    // The header's width at each panel width: the body less the 16pt insets and a result row's 30pt
    // Dismiss lane.
    let widths = PanelWidth.allCases.map { $0.minimumBody - 32 - 30 }
    let lines = [try #require(RowPlaceLine(label: WorkStatusLabel(verdict: .checksFailing), place: longPlace)),
                 try #require(RowPlaceLine(label: WorkStatusLabel(verdict: .checksRunning, pullRequest: pr431), place: longPlace))]
    for width in widths {
        for line in lines {
            for word in [nil, RowException.failed, .unreachable] {
                let probe = HeaderLineProbe(name: longName, place: line, word: word)
                #expect(fittedWidth(probe, proposed: width) <= width, "overflows at \(width) with \(String(describing: word))")
                // Nothing in the line is fixed but the state, the word and the age, so a line that fits
                // with the state whole has cut the name or place instead.
                let unconstrained = fittedWidth(probe, proposed: 10_000)
                #expect(unconstrained > width)
            }
        }
    }
}

@MainActor @Test func aNameTooLongForTheRowTruncatesRatherThanTheState() {
    // Even with no room left for any of the place's detail, the state words stay whole: the header
    // reserves their width and the name gives way.
    let line = RowPlaceLine(label: WorkStatusLabel(verdict: .checksFailing), place: longPlace)!
    let stateOnly = fittedWidth(RowPlaceLineText(line: RowPlaceLine(label: WorkStatusLabel(verdict: .checksFailing), place: nil)!),
                                proposed: 1_000)
    let header = RowHeaderNamePlace(name: longName, note: nil, place: line)
    for tight: CGFloat in [220, 160] {
        #expect(fittedWidth(header, proposed: tight) <= tight)
    }
    // Squeezed to nothing, the header keeps the whole state: the name and the detail collapse first.
    #expect(fittedWidth(header, proposed: 0) >= stateOnly)
}

// MARK: A quiet working row (#419; Paper "Q1 · Coloured word · Chosen 2026-11-13")

@Test func aQuietWorkingRowReadsQuietAfterItsPlace() throws {
    let running = row(.running, status: nil)
    let line = try #require(RowPlaceLine.make(running, label: nil, place: "herdly @ docs/notes", note: nil, quiet: true))
    #expect(line.quiet)
    #expect(line.label == nil)
    #expect(line.detail == "herdly @ docs/notes")
    #expect(line.text == "· herdly @ docs/notes · quiet")
    #expect(line.spoken == "herdly @ docs/notes, quiet")
    // With no place known, the word alone.
    let bare = try #require(RowPlaceLine.make(running, label: nil, place: nil, note: nil, quiet: true))
    #expect(bare.text == "· quiet")
    #expect(bare.spoken == "quiet")
    // Not quiet: the place as before.
    #expect(RowPlaceLine.make(running, label: nil, place: "herdly @ docs/notes", note: nil, quiet: false)?.text
        == "· herdly @ docs/notes")
}

@Test func onlyAWorkingRowWithoutANoteReadsQuiet() throws {
    for kind in [AgentAttentionKind.outcome, .earlierOutcome, .waiting, .statusUnavailable] {
        #expect(RowPlaceLine.make(row(kind), label: nil, place: "herdly @ main", note: nil, quiet: true)?.quiet == false)
    }
    #expect(RowPlaceLine.make(row(.running, status: nil), label: nil, place: "herdly @ main", note: .sending, quiet: true)?.quiet == false)
}

@Test func theQuietWordIsDrawnInTheAmberStateTone() {
    #expect(RowPlaceLine.quietTone == .amber)
    #expect(NotchStyle.stateColor(RowPlaceLine.quietTone) == NotchStyle.stateAmber)
}
