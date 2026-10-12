import Foundation
import Testing
@testable import SteerCore

// ADR 0016's Open sequence: revalidate → (multiplexer only) focus and verify the pane → raise the host
// tab → verify. Every step is a fake on an explicit clock; nothing reads or drives a real terminal.

private struct Miss: Error, Equatable { let step: String }

/// Records each step in order and serves scripted results.
@MainActor
private final class Steps {
    var calls: [String] = []
    var failAt: String?
    var clock = 100.0

    func steps(pane: Bool) -> TerminalOpenSteps<String, Miss> {
        func step(_ name: String) -> Miss? {
            calls.append(name)
            return failAt == name ? Miss(step: name) : nil
        }
        return TerminalOpenSteps(
            now: { self.clock },
            revalidate: { preOpenAt in
                self.calls.append("revalidate@\(preOpenAt)")
                return self.failAt == "revalidate" ? .failure(Miss(step: "revalidate")) : .success("tab")
            },
            focusPane: pane ? { _ in step("focusPane") } : nil,
            verifyPane: pane ? { _ in step("verifyPane") } : nil,
            raise: { _ in step("raise") },
            verify: { _ in step("verify") })
    }
}

@MainActor @Test func aTerminalTabOpensThroughRevalidateRaiseAndVerify() async {
    let fake = Steps()
    let run = await TerminalOpenSequence.run(fake.steps(pane: false))
    #expect(run == .opened("tab", preOpenAt: 100))
    #expect(fake.calls == ["revalidate@100.0", "raise", "verify"])
}

@MainActor @Test func aMultiplexerPaneIsFocusedAndVerifiedBeforeItsHostTabIsRaised() async {
    let fake = Steps()
    let run = await TerminalOpenSequence.run(fake.steps(pane: true))
    #expect(run == .opened("tab", preOpenAt: 100))
    #expect(fake.calls == ["revalidate@100.0", "focusPane", "verifyPane", "raise", "verify"])
}

// Every command is sent once and never retried; a failed step stops the sequence there, keeps what
// already verified, and hands its typed failure to the fallback decision (ADR 0015).
@MainActor @Test func theFirstFailedStepStopsTheSequenceWithoutRetry() async {
    let expected: [(String, [String], TerminalOpenStep)] = [
        ("revalidate", ["revalidate@100.0"], .revalidate),
        ("focusPane", ["revalidate@100.0", "focusPane"], .focusPane),
        ("verifyPane", ["revalidate@100.0", "focusPane", "verifyPane"], .verifyPane),
        ("raise", ["revalidate@100.0", "focusPane", "verifyPane", "raise"], .raise),
        ("verify", ["revalidate@100.0", "focusPane", "verifyPane", "raise", "verify"], .verify),
    ]
    for (failAt, calls, step) in expected {
        let fake = Steps()
        fake.failAt = failAt
        let run = await TerminalOpenSequence.run(fake.steps(pane: true))
        #expect(run == .failed(Miss(step: failAt), at: step))
        #expect(fake.calls == calls)
    }
}

// MARK: - Ghostty title route through the sequence

private let title = "0199a1b2-c3d4-7e5f-8a9b-0c1d2..."
private let tab = GhosttyTarget(window_id: "w1", tab_id: "t1", terminal_id: "p1")

private func inventory(selected: GhosttyTarget? = nil, names: [String] = [title]) throws -> GhosttySnapshot {
    var object: [String: Any] = [
        "status": "ok", "front_window_id": "w1",
        "windows": [["id": "w1", "tabs": [["id": "t1", "terminals": names.enumerated().map { index, name in
            ["id": index == 0 ? "p1" : "p\(index + 1)", "name": name]
        }]]]],
    ]
    if let selected {
        object["selected"] = ["window_id": selected.window_id, "tab_id": selected.tab_id, "terminal_id": selected.terminal_id]
    }
    return try JSONDecoder().decode(GhosttySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

@MainActor @Test func ghosttyTitleOpenRunsTheSequenceAndSelectsOnce() async throws {
    var calls: [String] = []
    var inventories = [try inventory(), try inventory(selected: tab)]
    let run = await GhosttyTitleOpen.run(
        title: title, live: [title], running: true, sameWindowOnly: false, now: { 7 },
        snapshot: { calls.append("snapshot"); return inventories.removeFirst() },
        select: { target in calls.append("select \(target.tab_id)"); return "ok" })
    #expect(run == .opened(tab, preOpenAt: 7))
    #expect(calls == ["snapshot", "select t1", "snapshot"])
}

@MainActor @Test func ghosttyTitleOpenStopsAtTheFirstMissForTheFallback() async throws {
    // A split tab: no selection is sent.
    var calls: [String] = []
    let split = await GhosttyTitleOpen.run(
        title: title, live: [title], running: true, sameWindowOnly: false, now: { 7 },
        snapshot: { calls.append("snapshot"); return try? inventory(names: [title, "shell"]) },
        select: { _ in calls.append("select"); return "ok" })
    #expect(split == .failed(.fallBack(.unsupportedLayout, candidates: 1), at: .revalidate))
    #expect(calls == ["snapshot"])
    // A selection that did not verify falls back; Ghostty is already active.
    var inventories = [try inventory(), try inventory()]
    let unverified = await GhosttyTitleOpen.run(
        title: title, live: [title], running: true, sameWindowOnly: false, now: { 7 },
        snapshot: { inventories.removeFirst() }, select: { _ in "ok" })
    #expect(unverified == .failed(.fallBack(.notVerified, candidates: 1), at: .verify))
    // No reply to the selection: the host cannot be read.
    let silent = await GhosttyTitleOpen.run(
        title: title, live: [title], running: true, sameWindowOnly: false, now: { 7 },
        snapshot: { try? inventory() }, select: { _ in nil })
    #expect(silent == .failed(.unavailable(.hostUnreadable(.ghostty)), at: .raise))
    // Ghostty not running is an empty inventory and is not asked.
    var asked = false
    let notRunning = await GhosttyTitleOpen.run(
        title: title, live: [title], running: false, sameWindowOnly: false, now: { 7 },
        snapshot: { asked = true; return nil }, select: { _ in asked = true; return "ok" })
    #expect(notRunning == .failed(.fallBack(.noUniqueTarget, candidates: 0), at: .revalidate))
    #expect(!asked)
}
