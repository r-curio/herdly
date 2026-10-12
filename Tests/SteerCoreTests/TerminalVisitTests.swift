import Foundation
import Testing
@testable import SteerCore

// ADR 0016: one acknowledgment rule for every terminal host (verified Open, interval visit, five-second
// dwell). Every scan is a fixture on an explicit clock; nothing sleeps or reads a real terminal.

private typealias Scan = TerminalVisibilityScan<String>

private func completions(_ arrivals: [(String, Double)]) -> [TerminalCompletionCandidate<String>] {
    arrivals.map { TerminalCompletionCandidate(id: $0.0, arrivedAt: $0.1) }
}

// MARK: - Open

@Test func onlyAVerifiedOpenAcknowledgesCompletionsThatArrivedBeforeThePreOpenRead() {
    let queued = completions([("before", 99.999), ("atRead", 100), ("after", 100.5), ("invalid", .nan)])
    #expect(TerminalVisitAcknowledgment.afterOpen(queued, result: .opened, preOpenAt: 100) == ["before"])
    // A fallback raised the app without selecting anything: it never acknowledges (ADR 0015).
    for reason in [OpenFallbackReason.noUniqueTarget, .unsupportedLayout, .partialReach, .notVerified] {
        #expect(TerminalVisitAcknowledgment.afterOpen(queued, result: .fellBack(.ghostty, reason), preOpenAt: 100).isEmpty)
    }
    #expect(TerminalVisitAcknowledgment.afterOpen(queued, result: .unavailable(.sessionEnded), preOpenAt: 100).isEmpty)
    #expect(TerminalVisitAcknowledgment.afterOpen(queued, result: .opened, preOpenAt: .nan).isEmpty)
}

// MARK: - Manual visit

@Test func aManualVisitNeedsTheTargetHiddenInOneScanAndVisibleInTheNext() {
    let queued = completions([("early", 9), ("atPrevious", 10), ("duringInterval", 10.5)])
    func visit(_ previous: Scan?, _ current: Scan) -> Set<String> {
        TerminalVisitAcknowledgment.manualVisit(queued, target: "A", previous: previous, current: current)
    }
    let shown = Scan(takenAt: 12, reading: .visible("A"))
    // Another app in front, or another tab: only arrivals before the earlier scan are acknowledged.
    #expect(visit(Scan(takenAt: 10, reading: .nothing), shown) == ["early"])
    #expect(visit(Scan(takenAt: 10, reading: .visible("B")), shown) == ["early"])
    #expect(visit(Scan(takenAt: 10, reading: .unchecked("B")), shown) == ["early"])
    // Already in front, possibly in front, or not known: no visit was observed.
    #expect(visit(Scan(takenAt: 10, reading: .visible("A")), shown).isEmpty)
    #expect(visit(Scan(takenAt: 10, reading: .unchecked("A")), shown).isEmpty)
    #expect(visit(Scan(takenAt: 10, reading: .unknown), shown).isEmpty)
    #expect(visit(nil, shown).isEmpty)
    // The later scan must show the target itself.
    #expect(visit(Scan(takenAt: 10, reading: .nothing), Scan(takenAt: 12, reading: .visible("B"))).isEmpty)
    #expect(visit(Scan(takenAt: 10, reading: .nothing), Scan(takenAt: 12, reading: .unchecked("A"))).isEmpty)
    // Scans out of order, or a scan without a finite time.
    #expect(visit(Scan(takenAt: 12, reading: .nothing), Scan(takenAt: 10, reading: .visible("A"))).isEmpty)
    #expect(visit(Scan(takenAt: .nan, reading: .nothing), shown).isEmpty)
}

// MARK: - Dwell

@Test func dwellAcknowledgesAtExactlyFiveSecondsAfterArrivalAndNotJustBefore() {
    let queued = completions([("beforeRun", 9), ("atStart", 10), ("later", 11)])
    var dwell = TerminalDwell<String>()
    for at in [10.0, 12, 14] { dwell.observe(target: "A", visible: true, at: at) }
    #expect(dwell.acknowledged(queued, target: "A", at: 14).isEmpty)
    // 14.999 s: just under five seconds for the arrival at 10.
    dwell.observe(target: "A", visible: true, at: 14.999)
    #expect(dwell.acknowledged(queued, target: "A", at: 14.999).isEmpty)
    // Exactly five seconds.
    dwell.observe(target: "A", visible: true, at: 15)
    #expect(dwell.acknowledged(queued, target: "A", at: 15) == ["atStart"])
    dwell.observe(target: "A", visible: true, at: 16)
    #expect(dwell.acknowledged(queued, target: "A", at: 16) == ["atStart", "later"])
    // An arrival before the run began is left to a visit or dismissal.
    dwell.observe(target: "A", visible: true, at: 18)
    #expect(!dwell.acknowledged(queued, target: "A", at: 18).contains("beforeRun"))
    // Another target, or a time other than the latest scan.
    #expect(dwell.acknowledged(queued, target: "B", at: 18).isEmpty)
    #expect(dwell.acknowledged(queued, target: "A", at: 30).isEmpty)
}

@Test func aShortVisitNeverReachesTheDwell() {
    let queued = completions([("done", 10)])
    var dwell = TerminalDwell<String>()
    dwell.observe(target: "A", visible: true, at: 10)
    dwell.observe(target: "A", visible: true, at: 12)
    dwell.observe(target: "A", visible: true, at: 14)
    // Hidden at 14.5 (another app or tab), back at 16: the run restarts.
    dwell.observe(target: "A", visible: false, at: 14.5)
    dwell.observe(target: "A", visible: true, at: 16)
    for at in [16.0, 18, 20] {
        dwell.observe(target: "A", visible: true, at: at)
        #expect(dwell.acknowledged(queued, target: "A", at: at).isEmpty)
    }
    // A gap of more than five seconds between visible scans restarts it too; exactly five does not.
    var gap = TerminalDwell<String>()
    gap.observe(target: "A", visible: true, at: 10)
    gap.observe(target: "A", visible: true, at: 15)
    #expect(gap.since == 10)
    gap.observe(target: "A", visible: true, at: 20.001)
    #expect(gap.since == 20.001)
    // A different target restarts the run.
    gap.observe(target: "B", visible: true, at: 22)
    #expect(gap.target == "B")
    #expect(gap.since == 22)
}

@Test func dwellWorksForGhosttyTabTargets() {
    let tab = GhosttyTarget(window_id: "w", tab_id: "t", terminal_id: "p")
    var dwell = TerminalDwell<GhosttyTarget>()
    dwell.observe(target: tab, visible: true, at: 0)
    dwell.observe(target: tab, visible: true, at: 2)
    dwell.observe(target: tab, visible: true, at: 4)
    dwell.observe(target: tab, visible: true, at: 6)
    #expect(dwell.acknowledged(completions([("c", 1)]), target: tab, at: 6) == ["c"])
}

// MARK: - Tracker

@Test func theTrackerAcknowledgesAVisitAndADwellAcrossScans() {
    let queued = completions([("beforeSwitch", 1), ("whileVisible", 6.5)])
    var tracker = TerminalVisitTracker<String>()
    tracker.record(Scan(takenAt: 2, reading: .nothing))
    #expect(tracker.acknowledged(queued, target: "A").isEmpty)
    tracker.record(Scan(takenAt: 4, reading: .visible("A")))
    // The switch between 2 and 4 is a visit for what arrived before 2.
    #expect(tracker.acknowledged(queued, target: "A") == ["beforeSwitch"])
    #expect(tracker.acknowledged(queued, target: "B").isEmpty)
    for at in [6.0, 8, 10] {
        tracker.record(Scan(takenAt: at, reading: .visible("A")))
        #expect(tracker.acknowledged(queued, target: "A").isEmpty)
    }
    // 6.5 + 5 = 11.5: just under at 11.4, exactly at 11.5.
    tracker.record(Scan(takenAt: 11.4, reading: .visible("A")))
    #expect(tracker.acknowledged(queued, target: "A").isEmpty)
    tracker.record(Scan(takenAt: 11.5, reading: .visible("A")))
    #expect(tracker.acknowledged(queued, target: "A") == ["whileVisible"])
}

@Test func theTrackerRestartsOnAFailedOrUncheckedScan() {
    let queued = completions([("c", 3)])
    var tracker = TerminalVisitTracker<String>()
    tracker.record(Scan(takenAt: 2, reading: .visible("A")))
    tracker.record(Scan(takenAt: 4, reading: .visible("A")))
    tracker.record(Scan(takenAt: 6, reading: .unknown))
    tracker.record(Scan(takenAt: 8, reading: .visible("A")))
    tracker.record(Scan(takenAt: 10, reading: .visible("A")))
    // The run began again at 8, after the arrival at 3; and an unknown scan is no "hidden" for a visit.
    #expect(tracker.acknowledged(queued, target: "A").isEmpty)
    // An unchecked scan keeps the run only for its own candidate.
    var kept = TerminalVisitTracker<String>()
    kept.record(Scan(takenAt: 2, reading: .visible("A")))
    kept.record(Scan(takenAt: 4, reading: .unchecked("A")))
    kept.record(Scan(takenAt: 7, reading: .visible("A")))
    #expect(kept.acknowledged(completions([("d", 2)]), target: "A") == ["d"])
    var lost = TerminalVisitTracker<String>()
    lost.record(Scan(takenAt: 2, reading: .visible("A")))
    lost.record(Scan(takenAt: 4, reading: .unchecked("B")))
    lost.record(Scan(takenAt: 7, reading: .visible("A")))
    #expect(lost.dwell.since == 7)
    // The switch from B back to A is a visit for what arrived before 4, not for what arrived during it.
    #expect(lost.acknowledged(completions([("d", 2), ("e", 4.5)]), target: "A") == ["d"])
}

// ADR 0015 and 0016: an Open in flight restarts the run, and the interval spanning it is no visit, so a
// fallback that happened to raise the target's tab never acknowledges.
@Test func anOpenEndsTheRunAndIsNeverAVisit() {
    let queued = completions([("c", 1)])
    var tracker = TerminalVisitTracker<String>()
    tracker.record(Scan(takenAt: 2, reading: .nothing))
    tracker.reset(at: 3)
    tracker.record(Scan(takenAt: 4, reading: .visible("A")))
    #expect(tracker.acknowledged(queued, target: "A").isEmpty)
    // A check started before the Open and returning after it is ignored.
    var late = TerminalVisitTracker<String>()
    late.record(Scan(takenAt: 2, reading: .nothing))
    late.reset(at: 5)
    late.record(Scan(takenAt: 4, reading: .visible("A")))
    #expect(late.latest == nil)
    #expect(late.acknowledged(queued, target: "A").isEmpty)
}

// MARK: - Visible and when to check

private func ghostty(selected: GhosttyTarget?, front: String = "w1", status: String = "ok") throws -> GhosttySnapshot {
    var object: [String: Any] = [
        "status": status, "front_window_id": front,
        "windows": [["id": "w1", "tabs": [["id": "t1", "terminals": [["id": "p1", "name": "a"]]]]],
                    ["id": "w2", "tabs": [["id": "t2", "terminals": [["id": "p2", "name": "b"]]]]]],
    ]
    if let selected {
        object["selected"] = ["window_id": selected.window_id, "tab_id": selected.tab_id, "terminal_id": selected.terminal_id]
    }
    return try JSONDecoder().decode(GhosttySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func ghosttyIsVisibleOnlyWhenMacOSReportsItFrontmostAndItsFrontWindowShowsTheTab() throws {
    let tab = GhosttyTarget(window_id: "w1", tab_id: "t1", terminal_id: "p1")
    #expect(TerminalVisibility.ghostty(try ghostty(selected: tab), frontmost: .ghostty) == .visible(tab))
    // Ghostty's own answer is not enough: macOS reports another app frontmost.
    #expect(TerminalVisibility.ghostty(try ghostty(selected: tab), frontmost: nil) == .nothing)
    #expect(TerminalVisibility.ghostty(try ghostty(selected: tab), frontmost: .iTerm2) == .nothing)
    // Ghostty reports no selection while it is not frontmost.
    #expect(TerminalVisibility.ghostty(try ghostty(selected: nil), frontmost: .ghostty) == .nothing)
    // A selection outside the front window, an unreadable inventory, or none at all.
    let other = GhosttyTarget(window_id: "w2", tab_id: "t2", terminal_id: "p2")
    #expect(TerminalVisibility.ghostty(try ghostty(selected: other), frontmost: .ghostty) == .nothing)
    #expect(TerminalVisibility.ghostty(try ghostty(selected: tab, status: "unavailable"), frontmost: .ghostty) == .unknown)
    #expect(TerminalVisibility.ghostty(nil, frontmost: .ghostty) == .unknown)
}

@Test func aHostIsCheckedOnlyWhileFrontmostWithALiveBoundTargetAndNoCheckInFlight() {
    #expect(TerminalVisibility.shouldCheck(.ghostty, frontmost: .ghostty, holdsLiveBoundTarget: true, checkInFlight: false))
    #expect(!TerminalVisibility.shouldCheck(.ghostty, frontmost: nil, holdsLiveBoundTarget: true, checkInFlight: false))
    #expect(!TerminalVisibility.shouldCheck(.ghostty, frontmost: .wezTerm, holdsLiveBoundTarget: true, checkInFlight: false))
    #expect(!TerminalVisibility.shouldCheck(.ghostty, frontmost: .ghostty, holdsLiveBoundTarget: false, checkInFlight: false))
    #expect(!TerminalVisibility.shouldCheck(.ghostty, frontmost: .ghostty, holdsLiveBoundTarget: true, checkInFlight: true))
}
