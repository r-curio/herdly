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

/// Every key that is not ⌘⏎ or ⌘⌫: bare Return, every letter, every digit, bare Delete.
private let undecidingKeys: [ApprovalCardKey] = [.returnKey, .delete]
    + "abcdefghijklmnopqrstuvwxyz".map(ApprovalCardKey.letter)
    + (0...9).map(ApprovalCardKey.digit)

@Test func onALiveDecidableCardWithTheKeyboardCommandReturnApprovesAndCommandDeleteDenies() throws {
    for source in [codexCLI, claude] {
        let live = try reading(source, readAt: 112, now: 112)
        #expect(live.decisionEnabled)
        #expect(action(.commandReturn, live) == .approve)
        #expect(action(.commandDelete, live) == .deny)
        #expect(action(.letter("o"), live) == .open)
    }
}

@Test func noKeyButCommandReturnOrCommandDeleteEverDecides() throws {
    let cards = [try reading(readAt: 112, now: 112), try reading(readAt: 129.5, now: 130),
                 try reading(readAt: 130, now: 130), try reading(codexDesktop, readAt: 112, now: 112, decidable: false)]
    for card in cards {
        for key in undecidingKeys {
            let result = action(key, card)
            #expect(result != .approve && result != .deny, "\(key) decided")
        }
    }
    // On a live card bare Return, A, D, Y, N, digits and bare Delete do nothing at all.
    let live = try reading(readAt: 112, now: 112)
    for key in [ApprovalCardKey.returnKey, .letter("a"), .letter("d"), .letter("y"), .letter("n"), .digit(1), .delete] {
        #expect(action(key, live) == .none)
        #expect(!action(key, live).consumesKey)
    }
}

@Test func pastTheDeadlineOrHandedBackOnlyOpenRemains() throws {
    // The card's clock reached the deadline before the hand-back is recorded, and once it is.
    for card in [try reading(readAt: 129.5, now: 130), try reading(readAt: 129.5, now: 200), try reading(readAt: 130, now: 130)] {
        #expect(!card.decisionEnabled)
        #expect(action(.commandReturn, card) == .none)
        #expect(action(.commandDelete, card) == .none)
        #expect(action(.letter("o"), card) == .open)
        #expect(action(.returnKey, card) == .open)
    }
    // One instant before the deadline the request is still decidable.
    #expect(action(.commandReturn, try reading(readAt: 129.9, now: 129.9)) == .approve)
}

@Test func aDesktopApprovalThatStaysNativeGetsNoDecisionKeys() throws {
    let native = try reading(codexDesktop, readAt: 112, now: 112, decidable: false)
    #expect(action(.commandReturn, native) == .none)
    #expect(action(.commandDelete, native) == .none)
    // Its one action is Open, by O or Return, as on a handed-back card.
    #expect(action(.letter("o"), native) == .open)
    #expect(action(.returnKey, native) == .open)
}

@Test func withoutTheKeyboardAnApprovalCardTakesNoKey() throws {
    // A spotlight before the hotkey or a click: ⌘⏎ typed in another app is never the card's.
    let live = try reading(readAt: 112, now: 112)
    let handedBack = try reading(readAt: 130, now: 130)
    for card in [live, handedBack] {
        for key in [ApprovalCardKey.commandReturn, .commandDelete] + undecidingKeys {
            #expect(action(key, card, focus: .withoutKeyboard) == .none)
        }
    }
}

@Test func keyboardFocusMovesNoApprovalDeadline() throws {
    // Reading a card with the keyboard changes nothing about its countdown (ADR 0020): the same
    // request read at the same instant has the same countdown, and it still expires at 130.
    let live = try reading(readAt: 112, now: 112)
    _ = action(.commandReturn, live)
    _ = action(.letter("o"), live)
    #expect(live.countdown == (try reading(readAt: 112, now: 112)).countdown)
    #expect(live.countdown?.label == "18s left")
    #expect(action(.commandReturn, try reading(readAt: 112, now: 130)) == .none)
}
