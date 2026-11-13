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

private func row(_ kind: AgentAttentionKind, status: AgentOutcomeStatus? = .finished,
                 session: AgentSessionIdentity = codex) -> AgentAttentionItem {
    let outcome = status.map { AgentOutcome(session: session, turn: "t1", status: $0, arrivedAt: 100) }
    let id: AgentAttentionID = outcome.map { .outcome($0.identity) }
        ?? .running(AgentTurnIdentity(session: session, turn: "t1"))
    return AgentAttentionItem(id: id, kind: kind, session: session, arrivedAt: 100, approval: nil, question: nil,
                              outcome: outcome, running: nil, unavailableReason: nil)
}

@Test func aPullRequestVerdictReadsStateThenTheRepositoryAndNumber() throws {
    let place = try #require(RowPlace.make(row(.outcome), label: WorkStatusLabel(verdict: .checksFailing, pullRequest: pr431),
                                           place: "herdly @ feat/usage", note: nil))
    #expect(place.state == .checksFailing)
    #expect(place.detail == "herdly#431")
    #expect(place.text == "· checks failing · herdly#431")
    #expect(place.spoken == "checks failing, pull request 431 in herdly")
}

@Test func aVerdictWithoutAPullRequestReadsStateThenThePlaceInTheChosenFormat() throws {
    let notPushed = WorkStatusLabel(verdict: .notPushed)
    let full = try #require(RowPlace.make(row(.outcome), label: notPushed, place: "herdly @ feat/usage", note: nil))
    #expect(full.text == "· not pushed · herdly @ feat/usage")
    #expect(full.spoken == "not pushed, herdly @ feat/usage")
    #expect(RowPlace.make(row(.outcome), label: notPushed, place: "feat/usage", note: nil)?.text == "· not pushed · feat/usage")
    // A format that shows nothing leaves the state alone.
    let bare = try #require(RowPlace.make(row(.outcome), label: notPushed, place: nil, note: nil))
    #expect(bare.detail == nil)
    #expect(bare.text == "· not pushed")
    #expect(bare.spoken == "not pushed")
}

@Test func noVerdictKeepsTodaysPlaceExactly() throws {
    let today = try #require(RowPlace.make(row(.outcome), label: nil, place: "herdly @ main", note: nil))
    #expect(today == RowPlace(state: nil, detail: "herdly @ main", spoken: "herdly @ main"))
    #expect(today.text == "· herdly @ main")
    #expect(RowPlace.make(row(.outcome), label: nil, place: nil, note: nil) == nil)
}

@Test func everyStateReadsInItsLowercaseWordsAndTone() throws {
    let expected: [(WorkStatus, String, WorkStatusTone)] = [
        (.checksFailing, "checks failing", .red), (.conflict, "conflict", .red),
        (.uncommitted, "uncommitted", .amber), (.notPushed, "not pushed", .amber),
        (.checksRunning, "checks running", .gray),
        (.checksPassed, "checks passed", .green), (.merged, "merged", .green)
    ]
    for (verdict, words, tone) in expected {
        let place = try #require(RowPlace.make(row(.earlierOutcome), label: WorkStatusLabel(verdict: verdict, pullRequest: pr431),
                                               place: "herdly @ main", note: nil))
        #expect(place.text == "· \(words) · herdly#431")
        #expect(verdict.tone == tone)
    }
    #expect(WorkStatus.noVerdict.tone == nil)
}

@Test func aRowNoteKeepsThePlaceSlotSoNoVerdictShows() throws {
    let label = WorkStatusLabel(verdict: .checksPassed, pullRequest: pr431)
    for note in [RowNote.sending, .sentUnconfirmed, .replyNotDelivered(.codex)] {
        let place = try #require(RowPlace.make(row(.outcome), label: label, place: "herdly @ main", note: note))
        #expect(place.state == nil)
        // VoiceOver still reads the place before the note, as it did.
        #expect(place.spoken == "herdly @ main")
    }
}

@Test func failedAndUnreachableResultsKeepTheirWordAndStillShowTheVerdict() throws {
    let label = WorkStatusLabel(verdict: .conflict, pullRequest: pr431)
    let failed = row(.outcome, status: .failed)
    #expect(RowPlace.make(failed, label: label, place: "herdly @ main", note: nil)?.state == .conflict)
    #expect(QueueRowPresentation.exception(failed, target: .unreachable) == .unreachable)
    #expect(RowPlace.make(row(.outcome), label: label, place: "herdly @ main", note: nil)?.state == .conflict)
}

@Test func statusUnknownWaitingAndLiveRowsShowNoVerdict() {
    let label = WorkStatusLabel(verdict: .merged, pullRequest: pr431)
    for item in [row(.outcome, status: .unavailable), row(.earlierOutcome, status: .unavailable),
                 row(.waiting, status: nil, session: claude), row(.statusUnavailable, status: nil, session: claude),
                 row(.running, status: nil)] {
        #expect(RowPlace.make(item, label: label, place: "herdly @ main", note: nil)
            == RowPlace(state: nil, detail: "herdly @ main", spoken: "herdly @ main"))
    }
}

@Test func theSpokenHeadingReadsTheVerdictInWords() throws {
    let item = row(.outcome)
    let place = try #require(RowPlace.make(item, label: WorkStatusLabel(verdict: .checksFailing, pullRequest: pr431),
                                           place: "herdly @ main", note: nil))
    #expect(QueueRowPresentation.spokenHeading(item, name: "Fix sort", place: place.spoken, note: nil, countdown: nil)
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
    #expect(NotchStyle.stateTone(.red) == NotchStyle.stateRed)
    #expect(NotchStyle.stateTone(.green) == NotchStyle.stateGreen)
}

@MainActor @Test func theRepositoryOrBranchTruncatesBeforeTheState() {
    func width(_ place: RowPlace, proposed: CGFloat) -> CGFloat {
        NSHostingController(rootView: RowPlaceText(place: place)).sizeThatFits(in: CGSize(width: proposed, height: 100)).width
    }
    let long = "a-very-long-repository-name @ feat/a-much-longer-branch-name-than-fits"
    let place = RowPlace(state: .checksFailing, detail: long, spoken: "")
    let stateOnly = width(RowPlace(state: .checksFailing, detail: nil, spoken: ""), proposed: 1_000)
    let full = width(place, proposed: 1_000)
    #expect(full > stateOnly)
    // Narrower than the whole line (Standard's row leaves the place far less than this), and narrower
    // than the state alone: the detail gives way, the state never does.
    for proposed: CGFloat in [full - 40, 160, 60, 0] {
        #expect(width(place, proposed: proposed) >= stateOnly)
    }
    #expect(width(place, proposed: 160) <= max(160, stateOnly))
}
