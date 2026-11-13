import Foundation
import Testing
@testable import HerdlyCore

// #439, Paper K "B · Approval keys": Approve is ⌘⏎ and Deny is ⌘⌫, O opens, on an approval card with
// deliberate keyboard focus. A request received at 100 has its 30-second deadline at 130.

private let codexCLI = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s2", surface: .cli)
private let codexDesktop = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s3", surface: .desktop)
private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/claude", session: "s1", surface: .cli)

/// The card as drawn at `now` from the queue read at `readAt`; `decidable` is the app's source check.
private func reading(_ session: AgentSessionIdentity = codexCLI, readAt: Double, now: Double,
                     decidable: Bool = true) throws -> ApprovalCardReading {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: session, turn: "t1", call: "c1", arrivedAt: 100)), now: 100)
    let row = try #require(queue.items(at: readAt).first)
    return try #require(ApprovalCardReading(row, decidable: decidable, now: now))
}

private func action(_ key: ApprovalCardKey, _ card: ApprovalCardReading,
                    focus: ApprovalCardFocus = .keyboard) -> ApprovalCardAction {
    ApprovalCardKeys.action(for: key, card: card, focus: focus)
}

/// Every key the table can be handed that is not ⌘⏎ or ⌘⌫. The panel hands an approval card nothing
/// else: digits, other letters and bare Delete never reach the table and go on to macOS.
private let undecidingKeys = ApprovalCardKey.allCases.filter { $0 != .commandReturn && $0 != .commandDelete }

@Test func onALiveDecidableCardWithTheKeyboardCommandReturnApprovesAndCommandDeleteDenies() throws {
    for source in [codexCLI, claude] {
        let live = try reading(source, readAt: 112, now: 112)
        #expect(live.decisionEnabled)
        #expect(action(.commandReturn, live) == .approve)
        #expect(action(.commandDelete, live) == .deny)
        #expect(action(.open, live) == .open)
    }
    // Each decides exactly what its button does: Approve is allow-once, and Open decides nothing.
    #expect(ApprovalCardAction.approve.decision == .allowOnce)
    #expect(ApprovalCardAction.deny.decision == .deny)
    #expect(ApprovalCardAction.open.decision == nil && ApprovalCardAction.none.decision == nil)
}

@Test func noKeyButCommandReturnOrCommandDeleteEverDecides() throws {
    let cards = [try reading(readAt: 112, now: 112), try reading(readAt: 129.5, now: 130),
                 try reading(readAt: 130, now: 130), try reading(codexDesktop, readAt: 112, now: 112, decidable: false)]
    for card in cards {
        for key in undecidingKeys {
            #expect(action(key, card).decision == nil, "\(key) decided")
        }
    }
    // On a live card a bare Return does nothing at all and goes on to macOS.
    let live = try reading(readAt: 112, now: 112)
    #expect(action(.returnKey, live) == .none)
    #expect(!action(.returnKey, live).consumesKey)
}

@Test func pastTheDeadlineOrHandedBackOnlyOpenRemains() throws {
    // The card's clock reached the deadline before the hand-back is recorded, and once it is.
    for card in [try reading(readAt: 129.5, now: 130), try reading(readAt: 129.5, now: 200), try reading(readAt: 130, now: 130)] {
        #expect(!card.decisionEnabled)
        #expect(action(.commandReturn, card) == .none)
        #expect(action(.commandDelete, card) == .none)
        #expect(action(.open, card) == .open)
        #expect(action(.returnKey, card) == .open)
    }
}

@Test func aDesktopApprovalThatStaysNativeGetsNoDecisionKeys() throws {
    let native = try reading(codexDesktop, readAt: 112, now: 112, decidable: false)
    #expect(action(.commandReturn, native) == .none)
    #expect(action(.commandDelete, native) == .none)
    // Its one action is Open, by O or Return, as on a handed-back card.
    #expect(action(.open, native) == .open)
    #expect(action(.returnKey, native) == .open)
}

@Test func withoutTheKeyboardAnApprovalCardTakesNoKey() throws {
    // A spotlight before the hotkey or a click: ⌘⏎ typed in another app is never the card's.
    let live = try reading(readAt: 112, now: 112)
    let handedBack = try reading(readAt: 130, now: 130)
    for card in [live, handedBack] {
        for key in ApprovalCardKey.allCases {
            #expect(action(key, card, focus: .withoutKeyboard) == .none)
        }
    }
}

@Test func aFocusedCardStopsDecidingAtTheRequestsUnheldThirtySecondDeadline() throws {
    // Keyboard focus holds nothing (ADR 0020): a request received at 100 and read with the keyboard
    // at 112 approves until its own deadline at 130, and not from then on.
    #expect(try reading(readAt: 112, now: 112).countdown?.label == "18s left")
    #expect(action(.commandReturn, try reading(readAt: 112, now: 129.9)) == .approve)
    #expect(action(.commandReturn, try reading(readAt: 112, now: 130)) == .none)
    #expect(action(.commandDelete, try reading(readAt: 112, now: 130)) == .none)
}
