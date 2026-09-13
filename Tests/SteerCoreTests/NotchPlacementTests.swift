import Foundation
import CoreGraphics
import Testing
@testable import SteerCore

private let builtIn = NotchDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32)
private let external = NotchDisplay(id: 2, frame: CGRect(x: 1512, y: 100, width: 2560, height: 1440), topInset: 0)

@Test func pointerDisplayIsChosenWhenNotInteracting() {
    let choice = NotchDisplaySelection.choose(displays: [builtIn, external], pointer: CGPoint(x: 2000, y: 500),
                                              current: builtIn.id, interacting: false)
    #expect(choice == external)
}

@Test func placementFreezesOnTheCurrentDisplayWhileInteracting() {
    let choice = NotchDisplaySelection.choose(displays: [builtIn, external], pointer: CGPoint(x: 2000, y: 500),
                                              current: builtIn.id, interacting: true)
    #expect(choice == builtIn)
}

@Test func disconnectedCurrentDisplayFallsBackToTheRuleEvenWhileInteracting() {
    let choice = NotchDisplaySelection.choose(displays: [external], pointer: CGPoint(x: 2000, y: 500),
                                              current: builtIn.id, interacting: true)
    #expect(choice == external)
}

@Test func pointerOffEveryDisplayKeepsTheCurrentThenUsesTheFirstDisplay() {
    let offscreen = CGPoint(x: -50, y: -50)
    #expect(NotchDisplaySelection.choose(displays: [builtIn, external], pointer: offscreen, current: external.id, interacting: false) == external)
    #expect(NotchDisplaySelection.choose(displays: [builtIn, external], pointer: offscreen, current: nil, interacting: false) == builtIn)
    #expect(NotchDisplaySelection.choose(displays: [], pointer: offscreen, current: builtIn.id, interacting: true) == nil)
}

@Test func collapsedPanelSitsBelowThePhysicalNotchAndCenteredOnTheDisplay() {
    let frame = NotchPlacement.frame(on: builtIn, expanded: false, rows: 3, extraRows: false)
    #expect(frame == CGRect(x: 651, y: 982 - 38 - 34, width: 210, height: 34))
}

@Test func nonNotchDisplayUsesACompactTopCenterPanel() {
    let collapsed = NotchPlacement.frame(on: external, expanded: false, rows: 0, extraRows: false)
    #expect(collapsed == CGRect(x: 1512 + 1280 - 105, y: 100 + 1440 - 12 - 34, width: 210, height: 34))
    let expanded = NotchPlacement.frame(on: external, expanded: true, rows: 2, extraRows: true)
    #expect(expanded == CGRect(x: 1512 + 1280 - 190, y: 100 + 1440 - 12 - 360, width: 380, height: 360))
}

@Test func expandedPanelHeightIsCappedForLongQueues() {
    let frame = NotchPlacement.frame(on: builtIn, expanded: true, rows: 40, extraRows: false)
    #expect(frame.height == 380)
    #expect(frame.maxY == CGFloat(944))
}

@Test func pointerOrKeyboardFocusCountsAsInteraction() {
    #expect(!NotchInteraction.isActive(pointerInside: false, keyboardFocus: false))
    #expect(NotchInteraction.isActive(pointerInside: true, keyboardFocus: false))
    #expect(NotchInteraction.isActive(pointerInside: false, keyboardFocus: true))
}

@Test func interactionKeepsACompletionOpenButNeverExtendsAnApprovalDeadline() {
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 100, handoffAfter: 30)
    var queue = AttentionQueue()
    queue.apply(requests: [request], now: 100)
    var popup = Attention()
    popup.enqueue()
    let shown = popup.update(codexForeground: false, hovering: false, now: 100)
    #expect(shown)

    // Pointer and keyboard interaction from 101 s to 135 s: the popup stays open the whole time.
    for now in stride(from: 101.0, through: 135.0, by: 1) {
        let interacting = NotchInteraction.isActive(pointerInside: now.truncatingRemainder(dividingBy: 2) == 0, keyboardFocus: now.truncatingRemainder(dividingBy: 2) == 1)
        _ = popup.update(codexForeground: false, hovering: interacting, now: now)
        queue.expire(at: now)
    }
    #expect(popup.expanded)
    #expect(queue.items.first?.kind == .handedBackRequest)
    #expect(queue.items.first?.request?.expiresAt == 130)

    // Once interaction ends, the three-second collapse resumes from the last expansion, not from now.
    _ = popup.update(codexForeground: false, hovering: false, now: 136)
    #expect(!popup.expanded && popup.pending)
}

@Test func escapeCollapsesWithoutDismissingAndTheItemCanReopen() {
    var popup = Attention()
    popup.enqueue()
    _ = popup.update(codexForeground: false, hovering: false, now: 10)
    popup.collapse()
    #expect(!popup.expanded && popup.pending && popup.presented)
    let replayed = popup.update(codexForeground: false, hovering: true, now: 11)
    #expect(!replayed && !popup.expanded)
    popup.expand(now: 12)
    #expect(popup.expanded)
}
