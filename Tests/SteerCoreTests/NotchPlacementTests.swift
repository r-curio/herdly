import Foundation
import CoreGraphics
import Testing
@testable import SteerCore

private let builtIn = NotchDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32, housingWidth: 180, menuBarHeight: 32, isBuiltIn: true)
private let external = NotchDisplay(id: 2, frame: CGRect(x: 1512, y: 100, width: 2560, height: 1440), topInset: 0, housingWidth: 0, menuBarHeight: 25)

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

@Test func collapsedPanelIsTheHousingRowWithAWingOnEachSide() {
    let frame = NotchPlacement.frame(on: builtIn, expanded: false, rows: 3, extraRows: false)
    // Body 112 + 180 + 60 = 352, plus an 8-point ear on each side; exactly the housing height,
    // anchored to the top of the screen, with the gap centered over the housing.
    #expect(frame == CGRect(x: 756 - 90 - 112 - 8, y: 982 - 32, width: 368, height: 32))
    #expect(frame.maxY == builtIn.frame.maxY)
    let layout = NotchPlacement.strip(on: builtIn, expanded: false)
    #expect(layout == StripLayout(leading: 112, gap: 180, trailing: 60, height: 32))
    #expect(frame.minX + NotchPlacement.earRadius + layout.leading + layout.gap / 2 == builtIn.frame.midX)
}

@Test func nonNotchDisplayUsesACompactTopCenterStripInlineWithTheMenuBar() {
    // The strip is the menu bar row itself: as tall as the bar, anchored to the top edge.
    let collapsed = NotchPlacement.frame(on: external, expanded: false, rows: 0, extraRows: false)
    #expect(collapsed == CGRect(x: 1512 + 1280 - 108, y: 100 + 1440 - 25, width: 216, height: 25))
    #expect(NotchPlacement.strip(on: external, expanded: false) == StripLayout(leading: 140, gap: 0, trailing: 60, height: 25))
    let expanded = NotchPlacement.frame(on: external, expanded: true, contentHeight: 212.4)
    #expect(expanded == CGRect(x: 1512 + 1280 - 198, y: 100 + 1440 - 213, width: 396, height: 213))
}

@Test func displayWithoutAShownMenuBarPutsTheStripAtTheTopEdge() {
    // Under a full-screen app the menu bar is hidden, so the strip meets the screen's top edge.
    let hidden = NotchDisplay(id: 2, frame: external.frame, topInset: 0, housingWidth: 0, menuBarHeight: 0)
    let collapsed = NotchPlacement.frame(on: hidden, expanded: false, rows: 0, extraRows: false)
    // With no bar to match, the strip takes its own collapsed height.
    #expect(collapsed.maxY == hidden.frame.maxY)
    #expect(collapsed == CGRect(x: 1512 + 1280 - 108, y: 100 + 1440 - 40, width: 216, height: 40))
}

@Test func shownMenuBarHeightComesFromTheMenuBarWindowOnThatDisplay() {
    let builtInBar = CGRect(x: 0, y: 982 - 33, width: 1512, height: 33)
    let externalBar = CGRect(x: 1512, y: 100 + 1440 - 24, width: 2560, height: 24)
    #expect(NotchDisplay.shownMenuBarHeight(on: builtIn.frame, menuBars: [builtInBar, externalBar]) == 33)
    #expect(NotchDisplay.shownMenuBarHeight(on: external.frame, menuBars: [builtInBar, externalBar]) == 24)
    // A display whose menu bar is hidden has no bar window: zero, whatever visibleFrame reserves.
    #expect(NotchDisplay.shownMenuBarHeight(on: external.frame, menuBars: [builtInBar]) == 0)
    // A bar that is not flush with the top edge (sliding in) does not count.
    let sliding = CGRect(x: 1512, y: 100 + 1440 - 10, width: 2560, height: 24)
    #expect(NotchDisplay.shownMenuBarHeight(on: external.frame, menuBars: [sliding]) == 0)
}

@Test func stripTucksAboveAFullScreenDisplayUntilThePointerTouchesTheTopEdgeOrThePanelOpens() {
    let hidden = NotchDisplay(id: 2, frame: external.frame, topInset: 0, housingWidth: 0, menuBarHeight: 0)
    let away = CGPoint(x: 2000, y: 800)
    let atTop = CGPoint(x: 2000, y: hidden.frame.maxY - 1)
    #expect(NotchTuck.isTucked(display: hidden, pointer: away, interacting: false, open: false))
    #expect(!NotchTuck.isTucked(display: hidden, pointer: atTop, interacting: false, open: false))
    // Pinned to the edge the pointer reports exactly maxY.
    #expect(!NotchTuck.isTucked(display: hidden, pointer: CGPoint(x: 2000, y: hidden.frame.maxY), interacting: false, open: false))
    #expect(!NotchTuck.isTucked(display: hidden, pointer: away, interacting: true, open: false))
    // A spotlight, a hover expansion, or keyboard focus opens the panel and slides it in.
    #expect(!NotchTuck.isTucked(display: hidden, pointer: away, interacting: false, open: true))
    // The top edge of another display does not reveal this one.
    #expect(NotchTuck.isTucked(display: hidden, pointer: CGPoint(x: 700, y: 981), interacting: false, open: false))
    // An external monitor with a menu bar never tucks; neither does the built-in display, notch or not.
    #expect(!NotchTuck.isTucked(display: external, pointer: away, interacting: false, open: false))
    let builtInHidden = NotchDisplay(id: 1, frame: builtIn.frame, topInset: 0, menuBarHeight: 0, isBuiltIn: true)
    #expect(!NotchTuck.isTucked(display: builtInHidden, pointer: away, interacting: false, open: false))
    let frame = NotchPlacement.frame(on: hidden, expanded: false, rows: 0, extraRows: false)
    #expect(NotchTuck.tuckedFrame(frame).minY == hidden.frame.maxY)
}

@Test func expandedPanelGrowsDownwardFromTheSameTopEdgeAndIsCapped() {
    let frame = NotchPlacement.frame(on: builtIn, expanded: true, rows: 40, extraRows: false)
    #expect(frame.height == 480)
    #expect(frame.maxY == CGFloat(982))
    #expect(frame.width == 396)
    // The open panel's extra width is shared by both wings so the gap stays over the housing.
    let layout = NotchPlacement.strip(on: builtIn, expanded: true)
    #expect(layout == StripLayout(leading: 126, gap: 180, trailing: 74, height: 32))
    #expect(frame.minX + NotchPlacement.earRadius + layout.leading + layout.gap / 2 == builtIn.frame.midX)
    // A measured height smaller than a strip plus one row still leaves room for one row.
    #expect(NotchPlacement.frame(on: builtIn, expanded: true, contentHeight: 10).height == 56)
}

@Test func pointerOrKeyboardFocusCountsAsInteraction() {
    #expect(!NotchInteraction.isActive(pointerInside: false, keyboardFocus: false))
    #expect(NotchInteraction.isActive(pointerInside: true, keyboardFocus: false))
    #expect(NotchInteraction.isActive(pointerInside: false, keyboardFocus: true))
}

@Test func hoverHoldsThroughAShortGraceAfterThePointerLeaves() {
    var hover = HoverHold()
    func step(_ inside: Bool, _ now: Double) -> Bool { hover.update(pointerInside: inside, now: now) }
    #expect(step(false, 0) == false)
    #expect(step(true, 1) == true)
    #expect(step(false, 1.1) == true)
    #expect(step(false, 1.27) == true)
    #expect(step(false, 1.29) == false)
    // Re-entering within the grace keeps it held; a later leave restarts the grace.
    #expect(step(true, 2) == true)
    #expect(step(false, 2.2) == true)
    #expect(step(true, 2.3) == true)
    #expect(step(false, 3) == true)
    #expect(step(false, 3.19) == false)
}

@Test func spotlightShowsOneItemForThreeSecondsAndInteractionHoldsItWithoutExtendingIt() {
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 100, handoffAfter: 30)
    var queue = AttentionQueue()
    queue.apply(requests: [request], now: 100)
    var spotlight = Spotlight()
    spotlight.present(.request(request.identity), now: 100)
    let early = spotlight.update(interacting: false, now: 102.9)
    #expect(early == .request(request.identity))
    for now in stride(from: 103.0, through: 135.0, by: 1) {
        let held = spotlight.update(interacting: true, now: now)
        #expect(held == .request(request.identity))
        queue.expire(at: now)
    }
    #expect(queue.items.first?.kind == .handedBackRequest)
    #expect(queue.items.first?.request?.expiresAt == 130)
    // Interaction ends after the original three seconds: the spotlight closes at once.
    let after = spotlight.update(interacting: false, now: 136)
    #expect(after == nil)
    #expect(spotlight.item == nil)
}

@Test func spotlightClearsWithoutDismissingAndCanPresentAgain() {
    let completion = AttentionCompletion(source: .desktop, session: UUID(), turn: UUID(), arrivedAt: 5)
    var queue = AttentionQueue()
    queue.apply(completions: [completion], now: 5)
    var spotlight = Spotlight()
    spotlight.present(.completion(completion.id), now: 5)
    spotlight.clear()
    let cleared = spotlight.update(interacting: true, now: 6)
    #expect(cleared == nil)
    #expect(queue.items.count == 1)
    spotlight.present(.completion(completion.id), now: 7)
    let again = spotlight.update(interacting: false, now: 9.5)
    #expect(again == .completion(completion.id))
}

@Test func agentSpotlightUsesTheSameThreeSecondWindowAndQueueOverride() {
    let session = AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "session", surface: .cli)
    let item = AgentAttentionID.outcome(AgentTurnIdentity(session: session, turn: "turn"))
    var controller = NotchPresentationController()
    controller.present(item, now: 10)
    #expect(controller.update(interacting: false, now: 12.9) == .agentSpotlight(item))
    #expect(controller.update(interacting: false, now: 13) == .collapsed)

    controller.present(item, now: 20)
    controller.openQueue()
    #expect(controller.update(interacting: true, now: 21) == .queue)
}

@Test func spotlightOutranksPassiveInteractionUntilTheHeaderExplicitlyOpensTheQueue() {
    let session = UUID(), turn = UUID()
    let ids: [AttentionItemID] = [
        .completion(CompletionIdentity(source: .desktop, session: session, turn: turn)),
        .request(RequestIdentity(source: .cli, request: UUID())),
        .question(QuestionIdentity(source: .desktop, session: session, callID: "call"))
    ]
    for id in ids {
        #expect(NotchPresentationMode.resolve(spotlight: id, manualOpen: false, interacting: true) == .spotlight(id))
        #expect(NotchPresentationMode.resolve(spotlight: id, manualOpen: true, interacting: true) == .queue)
    }
    #expect(NotchPresentationMode.resolve(spotlight: nil, manualOpen: false, interacting: true) == .queue)
    #expect(NotchPresentationMode.resolve(spotlight: nil, manualOpen: false, interacting: false) == .collapsed)
}

@Test func presentationControllerCoversHeaderOverrideExpiryAndLaterOrdinaryHover() {
    let id = AttentionItemID.completion(CompletionIdentity(source: .desktop, session: UUID(), turn: UUID()))
    var controller = NotchPresentationController()
    controller.present(id, now: 10)
    #expect(controller.update(interacting: true, now: 14) == .spotlight(id))
    controller.openQueue()
    #expect(controller.update(interacting: true, now: 14.1) == .queue)
    #expect(controller.update(interacting: false, now: 14.2) == .collapsed)
    #expect(controller.update(interacting: true, now: 15) == .queue)
}

@Test func completionPreviewIsBoundedToFiveLinesAndSixHundredCharacters() {
    let lines = (1...7).map { "line \($0)" }.joined(separator: "\n")
    let linePreview = CompletionPreview(lines)
    #expect(linePreview?.text == "line 1\nline 2\nline 3\nline 4\nline 5…")
    #expect(linePreview?.truncated == true)

    let unicode = String(repeating: "🦌", count: 601)
    let characterPreview = CompletionPreview(unicode)
    #expect(characterPreview?.text.count == 600) // Ellipsis is included in the cap.
    #expect(characterPreview?.text.hasSuffix("…") == true)

    let exactFiveLines = [String(repeating: "a", count: 116), String(repeating: "b", count: 120),
                          String(repeating: "c", count: 120), String(repeating: "d", count: 120),
                          String(repeating: "e", count: 120), "omitted"].joined(separator: "\n")
    let exactLinePreview = CompletionPreview(exactFiveLines)
    #expect(exactLinePreview?.text.count == 600)
    #expect(exactLinePreview?.text.hasSuffix("…") == true)
    #expect(CompletionPreview("  \n ") == nil)
}

@Test func spotlightDetailsHaveStableCompleteAndPartialFieldOrdering() {
    let session = UUID(), turn = UUID(), requestID = UUID()
    let request = AttentionRequest(id: requestID, source: .cli, session: session, turn: turn, arrivedAt: 10,
                                   expiresAt: 40, details: ApprovalDetails(taskName: "Ship", project: "/repo",
                                       action: "Run", command: "swift test", reason: "Verify", longText: "full"))
    var queue = AttentionQueue(); queue.apply(requests: [request], now: 10)
    let item = queue.items[0]
    let details = SpotlightDetails.make(item: item, context: nil, response: nil) { "t\(Int($0))" }
    #expect(details.context.map(\.label) == ["task", "working directory", "action", "command", "reason",
                                             "full request", "deadline"])

    let completion = AttentionCompletion(source: .desktop, session: session, turn: turn, arrivedAt: 20)
    var completions = AttentionQueue(); completions.apply(completions: [completion], now: 20)
    let partial = SpotlightDetails.make(item: completions.items[0], context: nil,
                                        response: nil, timestamp: { _ in "time" })
    #expect(partial.context.isEmpty)
    #expect(partial.response == .unavailable("Response preview is unavailable."))

    let restored = AttentionCompletion(source: .desktop, session: session, turn: UUID(), arrivedAt: 21, uncertain: true)
    var restoredQueue = AttentionQueue(); restoredQueue.apply(completions: [restored], now: 21)
    let restoredDetails = SpotlightDetails.make(item: restoredQueue.items[0], context: nil,
                                                 response: nil, timestamp: { _ in "time" })
    #expect(restoredDetails.response == .unavailable("Response preview unavailable after restart."))
}

@Test func stripNamesTheTopPriorityItemAndCountsOnlyItemsThatNeedTheUser() {
    let session = UUID(uuidString: "01A0916C-337B-4C2E-9C1E-000000000001")!
    let running = AttentionRunning(source: .cli, session: session, turn: UUID(), arrivedAt: 1)
    var queue = AttentionQueue()
    queue.apply(running: [running], now: 1)
    var strip = StripSummary.make(items: queue.items, testPending: false)
    let first = StripSession(session: session, working: true, color: StripSummary.preferredColor(for: session))
    #expect(strip == StripSummary(subject: "session 01a0916c", working: true, toCheck: 0, sessions: [first], overflow: 0))

    let details = ApprovalDetails(taskName: "fix auth bug", project: "steer", action: "run", command: "swift test", reason: nil)
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 2, details: details)
    let completion = AttentionCompletion(source: .desktop, session: UUID(), turn: UUID(), arrivedAt: 3)
    queue.apply(requests: [request], completions: [completion], now: 3)
    strip = StripSummary.make(items: queue.items, testPending: true)
    #expect(strip.subject == "fix auth bug" && strip.working && strip.toCheck == 3)
    #expect(strip.sessions.count == 3 && strip.overflow == 0)

    #expect(StripSummary.make(items: [], testPending: false) == StripSummary(subject: "idle", working: false, toCheck: 0))
}

@Test func stripShowsAtMostThreeSessionsInDistinctColorsAndCountsTheRest() {
    var completions: [AttentionCompletion] = []
    for i in 1...5 {
        // Identifiers chosen so every session prefers the same color.
        let session = UUID(uuidString: "00000000-0000-4000-8000-00000000000\(i)")!
        completions.append(AttentionCompletion(source: .cli, session: session, turn: UUID(), arrivedAt: Double(i)))
    }
    var queue = AttentionQueue()
    queue.apply(requests: [], completions: completions, now: 5)
    let strip = StripSummary.make(items: queue.items, testPending: false)
    #expect(strip.sessions.count == StripSummary.maximumSprites)
    #expect(strip.overflow == 2)
    #expect(Set(strip.sessions.map(\.color)).count == 3)
    #expect(strip.sessions.allSatisfy { !$0.working })
    // The first shown session keeps its preferred color; later ones step to the next free one.
    #expect(strip.sessions[0].color == StripSummary.preferredColor(for: strip.sessions[0].session))
    #expect(StripSummary.make(items: [], testPending: false).sessions.isEmpty)
}

@Test func attentionCollapseStillNeverDismisses() {
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

@Test func stripCountsAQuestionAndStandsStillWhileTheSessionWaits() {
    let session = UUID(), turn = UUID()
    var queue = AttentionQueue()
    queue.apply(running: [AttentionRunning(source: .desktop, session: session, turn: turn, arrivedAt: 1)])
    queue.apply(questions: [AttentionQuestion(source: .desktop, session: session, turn: turn, callID: "call_1", arrivedAt: 2)])
    let strip = StripSummary.make(items: queue.items, testPending: false)
    #expect(strip.toCheck == 1)
    #expect(strip.working == false)
    #expect(strip.sessions == [StripSession(session: session, working: false, color: StripSummary.preferredColor(for: session))])
}

@Test func trailingWingWidensOnlyWhileAFiveHourReadingIsShown() {
    // Without a five-hour reading the strip is exactly as before.
    #expect(NotchPlacement.strip(on: builtIn, expanded: false, fiveHourShown: false) == StripLayout(leading: 112, gap: 180, trailing: 60, height: 32))
    // With one, the wing right of the housing grows to fit two readouts; the left wing does not move.
    let layout = NotchPlacement.strip(on: builtIn, expanded: false, fiveHourShown: true)
    #expect(layout == StripLayout(leading: 112, gap: 180, trailing: 112, height: 32))
    let frame = NotchPlacement.frame(on: builtIn, expanded: false, rows: 0, extraRows: false, fiveHourShown: true)
    #expect(frame == CGRect(x: 756 - 90 - 112 - 8, y: 982 - 32, width: 420, height: 32))
    #expect(frame.minX + NotchPlacement.earRadius + layout.leading + layout.gap / 2 == builtIn.frame.midX)
    // The wider body already exceeds the open width, so opening adds nothing to either wing.
    #expect(NotchPlacement.strip(on: builtIn, expanded: true, fiveHourShown: true) == StripLayout(leading: 112, gap: 180, trailing: 112, height: 32))
    #expect(NotchPlacement.frame(on: builtIn, expanded: true, contentHeight: 200, fiveHourShown: true).width == 420)
    // A display without a housing keeps the left wing at its full width and grows the body instead.
    #expect(NotchPlacement.strip(on: external, expanded: false, fiveHourShown: true) == StripLayout(leading: 112, gap: 0, trailing: 112, height: 25))
    #expect(NotchPlacement.frame(on: external, expanded: false, rows: 0, extraRows: false, fiveHourShown: true)
            == CGRect(x: 1512 + 1280 - 120, y: 100 + 1440 - 25, width: 240, height: 25))
}
