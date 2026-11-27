import Foundation
import CoreGraphics
import Testing
@testable import HerdlyCore

private let builtIn = NotchDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32, housingWidth: 180, menuBarHeight: 32, isBuiltIn: true,
                                    persistentID: "BUILT-IN-UUID", name: "Built-in Retina Display")
private let external = NotchDisplay(id: 2, frame: CGRect(x: 1512, y: 100, width: 2560, height: 1440), topInset: 0, housingWidth: 0, menuBarHeight: 25,
                                    persistentID: "EXTERNAL-UUID", name: "DELL U2720Q")

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

private let pinnedExternal = NotchDisplayPreference.pinned(NotchDisplayPin(id: "EXTERNAL-UUID", name: "DELL U2720Q"))
private let secondExternal = NotchDisplay(id: 3, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), topInset: 0, menuBarHeight: 25,
                                          persistentID: "SECOND-UUID", name: "DELL U2720Q")

@Test func pinnedDisplayIsChosenWhereverThePointerIs() {
    let onBuiltIn = CGPoint(x: 700, y: 500)
    #expect(NotchDisplaySelection.choose(displays: [builtIn, external], pointer: onBuiltIn, current: builtIn.id,
                                         interacting: false, preference: pinnedExternal) == external)
    #expect(NotchDisplaySelection.choose(displays: [builtIn, external], pointer: CGPoint(x: -50, y: -50), current: nil,
                                         interacting: false, preference: pinnedExternal) == external)
}

@Test func missingPinnedDisplayFallsBackToTheBuiltInDisplayAndReturnsWhenItReconnects() {
    // The pointer is on another external display; the fallback is still the built-in display.
    let onSecond = CGPoint(x: -900, y: 500)
    #expect(NotchDisplaySelection.choose(displays: [builtIn, secondExternal], pointer: onSecond, current: external.id,
                                         interacting: false, preference: pinnedExternal) == builtIn)
    // Reconnected, the pinned display is chosen again without the user re-pinning it.
    #expect(NotchDisplaySelection.choose(displays: [builtIn, secondExternal, external], pointer: onSecond, current: builtIn.id,
                                         interacting: false, preference: pinnedExternal) == external)
}

@Test func missingPinnedDisplayWithNoBuiltInDisplayFollowsThePointer() {
    let onSecond = CGPoint(x: -900, y: 500)
    #expect(NotchDisplaySelection.choose(displays: [secondExternal], pointer: onSecond, current: nil,
                                         interacting: false, preference: pinnedExternal) == secondExternal)
    // A pin to the built-in display itself, with the lid closed, also falls through to the pointer rule.
    let pinnedBuiltIn = NotchDisplayPreference.pinned(NotchDisplayPin(id: "BUILT-IN-UUID", name: "Built-in Retina Display"))
    #expect(NotchDisplaySelection.choose(displays: [external, secondExternal], pointer: onSecond, current: nil,
                                         interacting: false, preference: pinnedBuiltIn) == secondExternal)
}

@Test func interactionKeepsTheCurrentDisplayWhenThePinnedDisplayReconnects() {
    #expect(NotchDisplaySelection.choose(displays: [builtIn, external], pointer: CGPoint(x: 700, y: 500), current: builtIn.id,
                                         interacting: true, preference: pinnedExternal) == builtIn)
    // Once interaction ends the pin applies again.
    #expect(NotchDisplaySelection.choose(displays: [builtIn, external], pointer: CGPoint(x: 700, y: 500), current: builtIn.id,
                                         interacting: false, preference: pinnedExternal) == external)
}

@Test func storedPreferenceWithoutAnIdentifierFollowsThePointer() {
    #expect(NotchDisplayPreference.restored(id: nil, name: "DELL U2720Q") == .followPointer)
    #expect(NotchDisplayPreference.restored(id: "", name: "DELL U2720Q") == .followPointer)
    #expect(NotchDisplayPreference.restored(id: "EXTERNAL-UUID", name: "DELL U2720Q") == pinnedExternal)
    #expect(NotchDisplayPreference.restored(id: "EXTERNAL-UUID", name: nil)
            == .pinned(NotchDisplayPin(id: "EXTERNAL-UUID", name: "Pinned display")))
}

@Test func displayChoicesNumberTwinsAndKeepADisconnectedPinVisible() {
    let choices = NotchDisplayChoices(displays: [builtIn, external, secondExternal], preference: .followPointer)
    // Follow pointer first, then left to right; two monitors of one model are numbered in that order.
    #expect(choices.options.map(\.label) == ["Follow pointer", "DELL U2720Q (1)", "Built-in Retina Display", "DELL U2720Q (2)"])
    #expect(choices.options[1].preference.pin?.id == "SECOND-UUID")
    #expect(choices.selected == choices.options[0])

    // A display the system gives no UUID cannot be pinned, so it is not offered.
    let anonymous = NotchDisplay(id: 9, frame: CGRect(x: 5000, y: 0, width: 800, height: 600), topInset: 0, name: "Projector")
    let disconnected = NotchDisplayChoices(displays: [builtIn, anonymous], preference: pinnedExternal)
    #expect(disconnected.options.map(\.label) == ["Follow pointer", "Built-in Retina Display", "DELL U2720Q (not connected)"])
    #expect(disconnected.selected == disconnected.options.last)
    #expect(disconnected.selected.preference == pinnedExternal)

    // A display that reports no name is labeled by kind rather than left blank.
    let unnamed = NotchDisplay(id: 1, frame: builtIn.frame, topInset: 32, isBuiltIn: true, persistentID: "BUILT-IN-UUID")
    #expect(NotchDisplayChoices(displays: [unnamed], preference: .followPointer).options.map(\.label)
            == ["Follow pointer", "Built-in display"])
}

@Test func displayChoicesCheckAndDescribeThePinnedDisplayByItsCurrentLabel() {
    // A stored name that has gone out of date still checks the right display, and the detail line
    // names it the way the picker does.
    let renamed = NotchDisplayPreference.pinned(NotchDisplayPin(id: "EXTERNAL-UUID", name: "Old name"))
    let connected = NotchDisplayChoices(displays: [builtIn, external], preference: renamed)
    #expect(connected.options.count == 3)
    #expect(connected.selected.label == "DELL U2720Q")
    #expect(connected.detail == "Stays on DELL U2720Q.")
    // Twins that swap places keep the pin on the same monitor, under its new number.
    let pinnedSecond = NotchDisplayPreference.pinned(NotchDisplayPin(id: "SECOND-UUID", name: "DELL U2720Q (1)"))
    let movedRight = NotchDisplay(id: 3, frame: CGRect(x: 5000, y: 0, width: 1920, height: 1080), topInset: 0, menuBarHeight: 25,
                                  persistentID: "SECOND-UUID", name: "DELL U2720Q")
    let swapped = NotchDisplayChoices(displays: [builtIn, external, movedRight], preference: pinnedSecond)
    #expect(swapped.selected.preference.pin?.id == "SECOND-UUID")
    #expect(swapped.selected.label == "DELL U2720Q (2)")
    #expect(swapped.detail == "Stays on DELL U2720Q (2).")
}

@Test func displayDetailDescribesWhereTheNotchIsShown() {
    #expect(NotchDisplayChoices(displays: [builtIn, external], preference: .followPointer).detail
            == "Follows the pointer to the display you're using.")
    #expect(NotchDisplayChoices(displays: [builtIn, external], preference: pinnedExternal).detail == "Stays on DELL U2720Q.")
    #expect(NotchDisplayChoices(displays: [builtIn], preference: pinnedExternal).detail
            == "DELL U2720Q isn't connected. Showing on the built-in display.")
    #expect(NotchDisplayChoices(displays: [secondExternal], preference: pinnedExternal).detail
            == "DELL U2720Q isn't connected. Following the pointer.")
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
    // Opening adds its growth to the 352pt collapsed body: 412pt plus the two ears.
    #expect(frame.width == 428)
    // The open panel's extra width is shared by both wings so the gap stays over the housing.
    let layout = NotchPlacement.strip(on: builtIn, expanded: true)
    #expect(layout == StripLayout(leading: 142, gap: 180, trailing: 90, height: 32))
    #expect(frame.minX + NotchPlacement.earRadius + layout.leading + layout.gap / 2 == builtIn.frame.midX)
    // A measured height smaller than a strip plus one row still leaves room for one row.
    #expect(NotchPlacement.frame(on: builtIn, expanded: true, contentHeight: 10).height == 56)
}

@Test func thePointerCountsAsInteractionAndAClickAloneDoesNotHoldThePanel() {
    #expect(!NotchInteraction.isActive(pointerInside: false, keyboardFocus: false))
    #expect(NotchInteraction.isActive(pointerInside: true, keyboardFocus: false))
    #expect(NotchInteraction.isActive(pointerInside: true, keyboardFocus: true))
    // A click's focus alone lets the panel fold once the pointer leaves (#376).
    #expect(!NotchInteraction.isActive(pointerInside: false, keyboardFocus: true))
}

@Test func focusHoldsThePanelOnlyForADraftOrVoiceOver() {
    #expect(NotchInteraction.isActive(pointerInside: false, keyboardFocus: true, draftInProgress: true))
    #expect(NotchInteraction.isActive(pointerInside: false, keyboardFocus: true, voiceOverRunning: true))
    // Neither holds without focus: a draft left behind by a click elsewhere, or VoiceOver elsewhere.
    #expect(!NotchInteraction.isActive(pointerInside: false, keyboardFocus: false, draftInProgress: true))
    #expect(!NotchInteraction.isActive(pointerInside: false, keyboardFocus: false, voiceOverRunning: true))
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
    // The three seconds start over from the last interaction (135), not from presentation.
    #expect(spotlight.update(interacting: false, now: 137.999) == .request(request.identity))
    let after = spotlight.update(interacting: false, now: 138)
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
    #expect(controller.agentSpotlightIsActive(interacting: false, now: 12.9))
    #expect(!controller.agentSpotlightIsActive(interacting: false, now: 13))
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

@Test func spotlightDetailsReadARequestAsAskCommandAndPlace() {
    let session = UUID(), turn = UUID(), requestID = UUID()
    let request = AttentionRequest(id: requestID, source: .cli, session: session, turn: turn, arrivedAt: 10,
                                   expiresAt: 40, details: ApprovalDetails(taskName: "Ship", project: "/Users/me/repo",
                                       action: "Run", command: "swift test", reason: "Verify", longText: "full"))
    var queue = AttentionQueue(); queue.apply(requests: [request], now: 10)
    let details = SpotlightDetails.make(item: queue.items[0], context: nil, response: nil, home: "/Users/me")
    let card = details.request
    #expect(card?.ask == "Verify")
    #expect(card?.action == "Run")
    #expect(card?.command == "swift test")
    #expect(card?.task == "Ship")
    #expect(card?.directory?.display == "~/repo")
    #expect(card?.directory?.full == "/Users/me/repo")
    #expect(card?.fullRequest == "full")  // Not JSON: Herdly cannot prove the card already shows it.
    #expect(card?.arrivedAt == 10 && card?.expiresAt == 40)
    #expect(details.directory == nil)

    let completion = AttentionCompletion(source: .desktop, session: session, turn: turn, arrivedAt: 20)
    var completions = AttentionQueue(); completions.apply(completions: [completion], now: 20)
    let partial = SpotlightDetails.make(item: completions.items[0], context: nil, response: nil)
    #expect(partial.request == nil && partial.directory == nil)
    #expect(partial.response == .unavailable("Response preview is unavailable."))
    let located = SpotlightDetails.make(item: completions.items[0], context: SpotlightRecordContext(workingDirectory: "/Users/me"),
                                        response: nil, home: "/Users/me/")
    #expect(located.directory?.display == "~")

    let restored = AttentionCompletion(source: .desktop, session: session, turn: UUID(), arrivedAt: 21, uncertain: true)
    var restoredQueue = AttentionQueue(); restoredQueue.apply(completions: [restored], now: 21)
    let restoredDetails = SpotlightDetails.make(item: restoredQueue.items[0], context: nil, response: nil)
    #expect(restoredDetails.response == .unavailable("Response preview unavailable after restart."))
}

@Test func spotlightRequestHidesATaskOnlyWhenTheSessionLabelNamesIt() {
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 0, expiresAt: 30,
                                   details: ApprovalDetails(taskName: "test", action: "Bash", command: "swift test"))
    var queue = AttentionQueue(); queue.apply(requests: [request], now: 0)
    let card = SpotlightDetails.make(item: queue.items[0], context: nil, response: nil).request
    #expect(card?.task(besidesSessionName: "test") == nil)
    // A task inside a longer name, a name that only ends with it, or an unnamed session still shows it.
    #expect(card?.task(besidesSessionName: "latest docs") == "test")
    #expect(card?.task(besidesSessionName: "foo · test") == "test")
    #expect(card?.task(besidesSessionName: "test runner") == "test")
    #expect(card?.task(besidesSessionName: nil) == "test")
}

@Test func spotlightRequestLiftsTheAskAndHidesARawRequestItAlreadyShows() {
    func card(reason: String? = nil, command: String? = "git fetch origin", long: String?) -> SpotlightRequest? {
        let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 0, expiresAt: 30,
                                       details: ApprovalDetails(project: "/Users/mesa/x", action: "Bash", command: command,
                                                                reason: reason, longText: long))
        var queue = AttentionQueue(); queue.apply(requests: [request], now: 0)
        return SpotlightDetails.make(item: queue.items[0], context: nil, response: nil, home: "/Users/me").request
    }
    // A command Codex sent as a list is not what the card shows: the raw request stays reachable.
    #expect(card(command: nil, long: #"{"command":["git","fetch"]}"#)?.fullRequest == #"{"command":["git","fetch"]}"#)
    #expect(card(command: nil, long: #"{"description":["a"]}"#)?.fullRequest != nil)
    let covered = #"{"command":"git fetch origin","description":"  Allow fetching remote main?  "}"#
    #expect(card(long: covered)?.ask == "Allow fetching remote main?")
    #expect(card(long: covered)?.fullRequest == nil)
    // A prefix that is not a whole path component is not the home folder.
    #expect(card(long: covered)?.directory?.display == "/Users/mesa/x")
    #expect(card(long: #"{"justification":"Needs network"}"#)?.ask == "Needs network")

    // Codex's own reason outranks the lifted sentence, so a differing description is still shown in full.
    let differing = card(reason: "Update checkout", long: covered)
    #expect(differing?.ask == "Update checkout")
    #expect(differing?.fullRequest == covered)
    // Extra keys, a different command, or no ask at all keep the raw request.
    #expect(card(long: #"{"command":"git fetch origin","timeout_ms":5000}"#)?.fullRequest != nil)
    #expect(card(long: #"{"command":"rm -rf build"}"#)?.fullRequest != nil)
    let bare = card(command: nil, long: #"{"description":"   "}"#)
    #expect(bare?.ask == nil && bare?.command == nil && bare?.fullRequest != nil)
    #expect(card(long: nil)?.fullRequest == nil)
}

@Test func spotlightElapsedTimeIsCompactAndNeverNegative() {
    #expect(SpotlightRequest.elapsed(since: 100, now: 50) == "just now")
    #expect(SpotlightRequest.elapsed(since: 0, now: 59) == "just now")
    #expect(SpotlightRequest.elapsed(since: 0, now: 60) == "1m ago")
    #expect(SpotlightRequest.elapsed(since: 0, now: 3_599) == "59m ago")
    #expect(SpotlightRequest.elapsed(since: 0, now: 3_600) == "1h ago")
    #expect(SpotlightRequest.elapsed(since: 0, now: 86_400 * 3) == "3d ago")
}

@Test func stripNamesTheTopPriorityItemAndCountsOnlyItemsThatNeedTheUser() {
    let session = UUID(uuidString: "01A0916C-337B-4C2E-9C1E-000000000001")!
    let running = AttentionRunning(source: .cli, session: session, turn: UUID(), arrivedAt: 1)
    var queue = AttentionQueue()
    queue.apply(running: [running], now: 1)
    var strip = StripSummary.make(items: queue.items, testPending: false)
    let first = StripSession(session: session, working: true, color: StripSummary.preferredColor(for: session))
    #expect(strip == StripSummary(subject: "session 01a0916c", working: true, toCheck: 0, sessions: [first]))

    let details = ApprovalDetails(taskName: "fix auth bug", project: "herdly", action: "run", command: "swift test", reason: nil)
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 2, details: details)
    let completion = AttentionCompletion(source: .desktop, session: UUID(), turn: UUID(), arrivedAt: 3)
    queue.apply(requests: [request], completions: [completion], now: 3)
    strip = StripSummary.make(items: queue.items, testPending: true)
    #expect(strip.subject == "fix auth bug" && strip.working && strip.toCheck == 3)
    #expect(strip.sessions.count == 3)

    #expect(StripSummary.make(items: [], testPending: false) == StripSummary(subject: "idle", working: false, toCheck: 0))
}

@Test func emptyQueueNamesConnectedSourcesAndClaimsNoGapBeforeBothSetupsAreChecked() {
    let both = EmptyQueueReading.make(codexConnected: true, claudeConnected: true)
    #expect(both == .nothingRunning(listening: [.codex, .claude]))
    #expect(both.title == "Nothing running" && both.sentence == "Listening for Codex and Claude.")
    #expect(EmptyQueueReading.make(codexConnected: false, claudeConnected: true).sentence == "Listening for Claude.")
    #expect(EmptyQueueReading.make(codexConnected: true, claudeConnected: nil).sentence == "Listening for Codex.")

    // A pending check never reads as a missing connection, even when the other setup is absent.
    for pending in [EmptyQueueReading.make(codexConnected: nil, claudeConnected: nil),
                    EmptyQueueReading.make(codexConnected: false, claudeConnected: nil),
                    EmptyQueueReading.make(codexConnected: nil, claudeConnected: false)] {
        #expect(pending == .nothingRunning(listening: []))
        #expect(pending.title == "Nothing running" && pending.sentence == nil)
    }

    let neither = EmptyQueueReading.make(codexConnected: false, claudeConnected: false)
    #expect(neither == .notConnected && neither.title == "Not connected")
    #expect(neither.sentence == "Codex and Claude aren’t reporting to Herdly yet.")
}

@Test func stripShowsAtMostThreeSessionsInDistinctColors() {
    var completions: [AttentionCompletion] = []
    for i in 1...5 {
        // Identifiers chosen so every session prefers the same color.
        let session = UUID(uuidString: "00000000-0000-4000-8000-00000000000\(i)")!
        completions.append(AttentionCompletion(source: .cli, session: session, turn: UUID(), arrivedAt: Double(i)))
    }
    var queue = AttentionQueue()
    queue.apply(requests: [], completions: completions, now: 5)
    let strip = StripSummary.make(items: queue.items, testPending: false)
    // Sessions beyond three appear only in the open queue (D2, #318).
    #expect(strip.sessions.count == StripSummary.maximumSprites)
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

@Test func trailingWingWidensForTheUsageReadoutsShown() {
    // With only the weekly reading the strip is exactly as before.
    #expect(NotchPlacement.strip(on: builtIn, expanded: false, wing: NotchPlacement.trailingWing) == StripLayout(leading: 112, gap: 180, trailing: 60, height: 32))
    // With a second readout, the wing right of the housing grows to fit two readouts; the left wing does not move.
    let layout = NotchPlacement.strip(on: builtIn, expanded: false, wing: 112)
    #expect(layout == StripLayout(leading: 112, gap: 180, trailing: 112, height: 32))
    let frame = NotchPlacement.frame(on: builtIn, expanded: false, rows: 0, extraRows: false, wing: 112)
    #expect(frame == CGRect(x: 756 - 90 - 112 - 8, y: 982 - 32, width: 420, height: 32))
    #expect(frame.minX + NotchPlacement.earRadius + layout.leading + layout.gap / 2 == builtIn.frame.midX)
    // The wider body already exceeds the open width's floor, and opening still widens it, half to each wing.
    #expect(NotchPlacement.strip(on: builtIn, expanded: true, wing: 112) == StripLayout(leading: 142, gap: 180, trailing: 142, height: 32))
    #expect(NotchPlacement.frame(on: builtIn, expanded: true, contentHeight: 200, wing: 112).width == 480)
    // A display without a housing keeps the left wing at its full width and grows the body instead.
    #expect(NotchPlacement.strip(on: external, expanded: false, wing: 112) == StripLayout(leading: 112, gap: 0, trailing: 112, height: 25))
    #expect(NotchPlacement.frame(on: external, expanded: false, rows: 0, extraRows: false, wing: 112)
            == CGRect(x: 1512 + 1280 - 120, y: 100 + 1440 - 25, width: 240, height: 25))
    // A wider wing grows the body to the right; the left wing and housing center stay put.
    let wide = NotchPlacement.strip(on: builtIn, expanded: false, wing: 240)
    #expect(wide == StripLayout(leading: 112, gap: 180, trailing: 240, height: 32))
    let four = NotchPlacement.frame(on: builtIn, expanded: false, rows: 0, extraRows: false, wing: 240)
    let two = NotchPlacement.frame(on: builtIn, expanded: false, rows: 0, extraRows: false, wing: 112)
    #expect(four.width - two.width == 128)
    #expect(four.minX == two.minX)
    // Even with every readout shown, opening widens the panel by the same growth.
    let fourOpen = NotchPlacement.frame(on: builtIn, expanded: true, contentHeight: 200, wing: 240)
    #expect(fourOpen.width - four.width == NotchPlacement.expandedGrowth)
    #expect(fourOpen.midX == four.midX)
    #expect(NotchPlacement.strip(on: external, expanded: false, wing: 240) == StripLayout(leading: 112, gap: 0, trailing: 240, height: 25))
    // A wing narrower than the weekly readout's lays out as that readout's.
    #expect(NotchPlacement.strip(on: builtIn, expanded: false, wing: 0) == StripLayout(leading: 112, gap: 180, trailing: 60, height: 32))
}

private let bothCodex = CodexUsageReading(weekly: CodexUsageWindow(usedPercent: 58, resetsAt: 1_000),
                                          fiveHour: CodexUsageWindow(usedPercent: 36, resetsAt: 1_000))
private let bothClaude = ClaudeUsageReading(sourceScope: "/a", sessionID: "00000000-0000-4000-8000-000000000001",
                                            fiveHour: ClaudeUsageWindow(usedPercentage: 61, resetsAt: 1_000),
                                            sevenDay: ClaudeUsageWindow(usedPercentage: 18, resetsAt: 1_000), observedAt: 1)

private let weeklyOnly = UsageWindows(fiveHour: false, weekly: true)
private let fiveHourOnly = UsageWindows(fiveHour: true, weekly: false)
private let off = UsageWindows(fiveHour: false, weekly: false)

private func runs(_ readout: UsageStripReadout) -> String {
    readout.openText.map { $0.dim ? "[\($0.text)]" : $0.text }.joined()
}

@Test func usageStripShowsOneRingPerSourceClaudeFirst() {
    let rings = UsageStripReadouts.make(codex: bothCodex, claude: bothClaude)
    #expect(rings == [UsageStripReadout(source: .claude, fiveHour: .known(UsageShare(usedPercent: 61)),
                                        weekly: .known(UsageShare(usedPercent: 18)), weeklyWindow: .sevenDay),
                      UsageStripReadout(source: .codex, fiveHour: .known(UsageShare(usedPercent: 36)),
                                        weekly: .known(UsageShare(usedPercent: 58)), weeklyWindow: .weekly)])
    // Open: five-hour, a dim slash, week, one trailing percent.
    #expect(rings.map(runs) == ["61[/]18%", "36[/]58%"])
    // VoiceOver keeps today's wording, both windows per source, in today's order.
    #expect(rings.flatMap(\.spokenLabels) == ["Claude five-hour limit 61% used", "Claude seven-day limit 18% used",
                                              "Codex five-hour limit 36% used", "Codex weekly limit 58% used"])
    // Only Codex reporting: one ring.
    #expect(UsageStripReadouts.make(codex: bothCodex, claude: nil).map(\.source) == [.codex])
}

@Test func usageRingFillsClampAndUnknownIsNeverZero() {
    #expect(UsageShare(usedPercent: 0).fraction == 0)
    #expect(UsageShare(usedPercent: 50).fraction == 0.5)
    #expect(UsageShare(usedPercent: 100).fraction == 1)
    #expect(UsageShare(usedPercent: 140).fraction == 1)
    #expect(UsageShare(usedPercent: 140).percentText == "100%")
    #expect(UsageShare(usedPercent: -3).fraction == 0)
    // The windows' own percent text is the same clamp and format.
    #expect(CodexUsageWindow(usedPercent: 140, resetsAt: 1).percentText == "100%")
    #expect(ClaudeUsageWindow(usedPercentage: 61.6, resetsAt: 1).percentText == "62%")
    // A 0% reading is a known window with an empty fill, not the unknown dash.
    let zero = UsageStripReadouts.make(codex: CodexUsageReading(weekly: CodexUsageWindow(usedPercent: 0, resetsAt: 1_000), fiveHour: nil), claude: nil)
    #expect(zero.map(\.showsDash) == [false])
    #expect(zero.map(runs) == ["0%"])
    // With no reading Codex's ring is still there: an empty outer track and a dim dash.
    let none = UsageStripReadouts.make(codex: nil, claude: nil)
    #expect(none == [UsageStripReadout(source: .codex, fiveHour: .notReported, weekly: .unknown, weeklyWindow: .weekly)])
    #expect(none[0].showsDash)
    #expect(none.map(runs) == ["[—]"])
    #expect(none.flatMap(\.spokenLabels) == ["Codex weekly limit unknown"])
    // A five-hour reading with the week unknown: a dim dash for the week, still one trailing percent.
    let weekUnknown = UsageStripReadouts.make(codex: CodexUsageReading(weekly: nil, fiveHour: CodexUsageWindow(usedPercent: 40, resetsAt: 1_000)),
                                              claude: nil)
    #expect(weekUnknown.map(runs) == ["40[/][—]%"])
    // Collapsed, the empty outer track still carries the dash, so the unknown week never reads as 0%.
    #expect(weekUnknown[0].showsDash)
    // A window that is not reported is no ring, so it needs no dash.
    let weeklyPlan = UsageStripReadouts.make(codex: CodexUsageReading(weekly: CodexUsageWindow(usedPercent: 0, resetsAt: 1_000), fiveHour: nil),
                                             claude: nil)
    #expect(weeklyPlan[0].showsDash == false)
}

@Test func usageRingLeavesOutWindowsThatAreNotReported() {
    // Some Codex plans report only the week: no inner ring at all, and just that number open.
    let weeklyPlan = UsageStripReadouts.make(codex: CodexUsageReading(weekly: CodexUsageWindow(usedPercent: 58, resetsAt: 1_000), fiveHour: nil), claude: nil)
    #expect(weeklyPlan[0].fiveHour == .notReported && weeklyPlan[0].weekly == .known(UsageShare(usedPercent: 58)))
    #expect(weeklyPlan.map(runs) == ["58%"])
    // Claude reporting only its five-hour window: an inner ring and no outer one.
    let fiveOnly = ClaudeUsageReading(sourceScope: "/a", sessionID: nil, fiveHour: ClaudeUsageWindow(usedPercentage: 7, resetsAt: 1_000),
                                      sevenDay: nil, observedAt: 1)
    let claude = UsageStripReadouts.make(codex: nil, claude: fiveOnly)[0]
    #expect(claude.source == .claude && claude.weekly == .notReported && claude.fiveHour == .known(UsageShare(usedPercent: 7)))
    #expect(runs(claude) == "7%")
    #expect(claude.spokenLabels == ["Claude five-hour limit 7% used"])
}

@Test func weeklyOnlyUsageDropsEveryInnerRing() {
    let weekly = UsageStripReadouts.make(codex: bothCodex, claude: bothClaude, claudeWindows: weeklyOnly, codexWindows: weeklyOnly)
    #expect(weekly.map(\.fiveHour) == [.notReported, .notReported])
    #expect(weekly.map(\.weeklyWindow) == [.weekly, .weekly])
    #expect(weekly.map(runs) == ["18%", "58%"])
    #expect(weekly.flatMap(\.spokenLabels) == ["Claude weekly limit 18% used", "Codex weekly limit 58% used"])
    // A Claude reading with only a five-hour window has nothing left to show.
    let fiveOnly = ClaudeUsageReading(sourceScope: "/a", sessionID: nil, fiveHour: ClaudeUsageWindow(usedPercentage: 7, resetsAt: 1_000),
                                      sevenDay: nil, observedAt: 1)
    #expect(UsageStripReadouts.make(codex: nil, claude: fiveOnly, claudeWindows: weeklyOnly, codexWindows: weeklyOnly).map(\.source) == [.codex])
    #expect(UsageStripReadouts.make(codex: nil, claude: nil, claudeWindows: weeklyOnly, codexWindows: weeklyOnly).flatMap(\.spokenLabels) == ["Codex weekly limit unknown"])
}

@Test func eachAgentsRingDrawsOnlyItsChosenWindows() {
    // Claude weekly only beside Codex both: Claude's outer ring alone, called weekly; Codex unchanged.
    let mixed = UsageStripReadouts.make(codex: bothCodex, claude: bothClaude, claudeWindows: weeklyOnly)
    #expect(mixed.map(runs) == ["18%", "36[/]58%"])
    #expect(mixed[0].fiveHour == .notReported && mixed[0].weeklyWindow == .weekly)
    #expect(mixed.flatMap(\.spokenLabels) == ["Claude weekly limit 18% used",
                                               "Codex five-hour limit 36% used", "Codex weekly limit 58% used"])
    // Five-hour only: the inner ring alone, keeping "seven-day" out of it.
    let fiveOnly = UsageStripReadouts.make(codex: bothCodex, claude: bothClaude,
                                           claudeWindows: fiveHourOnly, codexWindows: fiveHourOnly)
    #expect(fiveOnly.map(\.weekly) == [.notReported, .notReported])
    #expect(fiveOnly.map(runs) == ["61%", "36%"])
    #expect(fiveOnly.flatMap(\.spokenLabels) == ["Claude five-hour limit 61% used", "Codex five-hour limit 36% used"])
    // Neither: that agent has no ring at all, Codex included.
    #expect(UsageStripReadouts.make(codex: bothCodex, claude: bothClaude, claudeWindows: off).map(\.source) == [.codex])
    #expect(UsageStripReadouts.make(codex: bothCodex, claude: bothClaude, codexWindows: off).map(\.source) == [.claude])
    #expect(UsageStripReadouts.make(codex: nil, claude: nil, claudeWindows: off, codexWindows: off).isEmpty)
    // Codex's five-hour window chosen alone before any reading: an empty inner track and a dash, never 0%.
    let unread = UsageStripReadouts.make(codex: nil, claude: nil, codexWindows: fiveHourOnly)
    #expect(unread == [UsageStripReadout(source: .codex, fiveHour: .unknown, weekly: .notReported, weeklyWindow: .weekly)])
    #expect(unread[0].showsDash && unread.map(runs) == ["[—]"])
}

@Test func codexFiveHourBoxFollowsWhetherThePlanHasTheLimit() {
    let weeklyPlan = CodexUsageReading(weekly: CodexUsageWindow(usedPercent: 58, resetsAt: 1_000), fiveHour: nil)
    // Before any reading, and with both windows reported, the plan is taken to have the limit.
    #expect(CodexUsageReading.hasFiveHourLimit(nil))
    #expect(CodexUsageReading.hasFiveHourLimit(bothCodex))
    // A five-hour reading with the week missing says nothing against the limit.
    #expect(CodexUsageReading.hasFiveHourLimit(CodexUsageReading(weekly: nil, fiveHour: CodexUsageWindow(usedPercent: 4, resetsAt: 1_000))))
    // Weekly with no five-hour window: no limit, so the shown windows drop it and keep the choice.
    #expect(!CodexUsageReading.hasFiveHourLimit(weeklyPlan))
    #expect(UsageWindows.both.shown(fiveHourAvailable: false) == weeklyOnly)
    #expect(fiveHourOnly.shown(fiveHourAvailable: false) == off)
    #expect(UsageWindows.both.shown(fiveHourAvailable: true) == .both)
    // Chosen alone on such a plan, Codex shows no ring.
    #expect(UsageStripReadouts.make(codex: weeklyPlan, claude: nil,
                                    codexWindows: fiveHourOnly.shown(fiveHourAvailable: false)).isEmpty)
}

@Test func collapsedUsageWingIsTheMinimumWhateverTheSourcesReport() {
    let both = UsageStripReadouts.make(codex: bothCodex, claude: bothClaude)
    #expect(UsageStripReadouts.collapsedWingWidth(both) == NotchPlacement.trailingWing) // 18 + 8 + 18 + 8 inset
    #expect(UsageStripReadouts.collapsedWingWidth(UsageStripReadouts.make(codex: bothCodex, claude: nil)) == NotchPlacement.trailingWing)
    #expect(UsageStripReadouts.collapsedWingWidth(UsageStripReadouts.make(codex: nil, claude: nil)) == NotchPlacement.trailingWing)
    #expect(UsageStripReadouts.collapsedWingWidth([]) == NotchPlacement.trailingWing) // Both agents off
    #expect(UsageStripReadouts.collapsedWingWidth(UsageStripReadouts.make(codex: bothCodex, claude: bothClaude,
                                                                          claudeWindows: off, codexWindows: off)) == NotchPlacement.trailingWing)
    // A dash beside another ring is the one case that needs more: 18 + 8 + 18 + 5 + 6.8 + 8.
    #expect(UsageStripReadouts.collapsedWingWidth(UsageStripReadouts.make(codex: nil, claude: bothClaude)) == 64)
    let weekUnknown = CodexUsageReading(weekly: nil, fiveHour: CodexUsageWindow(usedPercent: 40, resetsAt: 1_000))
    #expect(UsageStripReadouts.collapsedWingWidth(UsageStripReadouts.make(codex: weekUnknown, claude: bothClaude)) == 64)
    // A dash beside no other ring fits the minimum.
    #expect(UsageStripReadouts.collapsedWingWidth(UsageStripReadouts.make(codex: weekUnknown, claude: nil)) == NotchPlacement.trailingWing)
    #expect(UsageStripReadouts.wingWidth(both, expanded: false) == NotchPlacement.trailingWing)
}

@Test func openUsageWingFitsEveryRingsNumbers() {
    // Each ring, 5pt, "99/99%" reserved at 6.8pt a glyph; 12pt between sources; the 8pt inset.
    let both = UsageStripReadouts.make(codex: bothCodex, claude: bothClaude)
    #expect(UsageStripReadouts.openWingWidth(both) == 148) // 2 × (18 + 5 + 40.8) + 12 + 8
    #expect(UsageStripReadouts.wingWidth(both, expanded: true) == 148)
    #expect(UsageStripReadouts.openWingWidth(UsageStripReadouts.make(codex: bothCodex, claude: nil)) == 72)
    // Weekly only: one "99%" per ring.
    #expect(UsageStripReadouts.openWingWidth(UsageStripReadouts.make(codex: bothCodex, claude: bothClaude, claudeWindows: weeklyOnly, codexWindows: weeklyOnly)) == 107)
    // Mixed: Claude "99%" beside Codex "99/99%": (18 + 5 + 20.4) + 12 + (18 + 5 + 40.8) + 8.
    #expect(UsageStripReadouts.openWingWidth(UsageStripReadouts.make(codex: bothCodex, claude: bothClaude,
                                                                     claudeWindows: weeklyOnly)) == 128)
    // One agent off: only the other's ring and numbers.
    #expect(UsageStripReadouts.openWingWidth(UsageStripReadouts.make(codex: bothCodex, claude: bothClaude,
                                                                     codexWindows: off)) == 72)
    #expect(UsageStripReadouts.openWingWidth([]) == NotchPlacement.trailingWing)
    // Single digits keep the two-digit room, so the panel holds still as the numbers change.
    let low = UsageStripReadouts.make(codex: CodexUsageReading(weekly: CodexUsageWindow(usedPercent: 1, resetsAt: 1_000),
                                                               fiveHour: CodexUsageWindow(usedPercent: 2, resetsAt: 1_000)), claude: nil)
    #expect(UsageStripReadouts.openWingWidth(low) == 72)
    // A spent window's "100" takes one glyph more.
    let spent = UsageStripReadouts.make(codex: CodexUsageReading(weekly: CodexUsageWindow(usedPercent: 30, resetsAt: 1_000),
                                                                 fiveHour: CodexUsageWindow(usedPercent: 100, resetsAt: 1_000)), claude: nil)
    #expect(UsageStripReadouts.openWingWidth(spent) == 79) // 18 + 5 + 7 × 6.8 + 8
    // The unknown week is one dash: "40/—%".
    let weekUnknown = UsageStripReadouts.make(codex: CodexUsageReading(weekly: nil, fiveHour: CodexUsageWindow(usedPercent: 40, resetsAt: 1_000)),
                                              claude: nil)
    #expect(UsageStripReadouts.openWingWidth(weekUnknown) == 65) // 18 + 5 + 5 × 6.8 + 8
    // An unknown ring and Hidden keep the minimum.
    #expect(UsageStripReadouts.openWingWidth(UsageStripReadouts.make(codex: nil, claude: nil)) == NotchPlacement.trailingWing)
    #expect(UsageStripReadouts.openWingWidth([]) == NotchPlacement.trailingWing)
}

@Test func openUsageWingKeepsTheHousingCentredAndGrowsBothWings() {
    let both = UsageStripReadouts.make(codex: bothCodex, claude: bothClaude)
    let collapsed = UsageStripReadouts.wingWidth(both, expanded: false)
    let open = UsageStripReadouts.wingWidth(both, expanded: true)
    for width in PanelWidth.allCases {
        let layout = NotchPlacement.strip(on: builtIn, expanded: true, wing: open, width: width)
        let frame = NotchPlacement.frame(on: builtIn, expanded: true, contentHeight: 200, wing: open, width: width)
        // The numbers fit inside the content inset, and the left wing gains at least the usual growth.
        #expect(layout.trailing >= open)
        #expect(layout.leading >= NotchPlacement.leadingWing + NotchPlacement.expandedGrowth / 2)
        #expect(layout.trailing - open == layout.leading - NotchPlacement.leadingWing)
        #expect(frame.minX + NotchPlacement.earRadius + layout.leading + layout.gap / 2 == builtIn.frame.midX)
        let externalLayout = NotchPlacement.strip(on: external, expanded: true, wing: open, width: width)
        let externalFrame = NotchPlacement.frame(on: external, expanded: true, contentHeight: 200, wing: open, width: width)
        #expect(externalLayout.trailing == open)
        #expect(externalLayout.leading >= NotchPlacement.leadingWing)
        #expect(externalFrame.midX == external.frame.midX)
    }
    // Standard on the MacBook notch: 180 + 112 + 148 + 60 growth, split evenly.
    #expect(NotchPlacement.strip(on: builtIn, expanded: true, wing: open) == StripLayout(leading: 142, gap: 180, trailing: 178, height: 32))
    #expect(NotchPlacement.strip(on: builtIn, expanded: false, wing: collapsed) == StripLayout(leading: 112, gap: 180, trailing: 60, height: 32))
}

@Test func centerLabelWidensOnlyAStripWithoutAHousing() {
    let label = NotchPlacement.centerLabelWidth

    #expect(NotchPlacement.strip(on: external, expanded: false, centerLabel: label)
        == StripLayout(leading: 112, gap: 160, trailing: 60, height: 25))
    #expect(NotchPlacement.strip(on: builtIn, expanded: false, centerLabel: label)
        == NotchPlacement.strip(on: builtIn, expanded: false))
    let framed = NotchPlacement.frame(on: external, expanded: false, rows: 0, extraRows: false, centerLabel: label)
    #expect(framed.width == 332 + 2 * NotchPlacement.earRadius && framed.midX == external.frame.midX)
}

@Test func panelWidthWidensOnlyTheOpenPanelAndKeepsTheHousingCentered() {
    // Collapsed body: housing 180 + wings 112 + 112 = 404.
    let collapsed = NotchPlacement.frame(on: builtIn, expanded: false, rows: 0, extraRows: false, wing: 112)
    for (width, body) in [(PanelWidth.standard, 464.0), (.wide, 564), (.extraWide, 664)] {
        #expect(NotchPlacement.bodyWidth(on: builtIn, expanded: false, wing: 112, width: width) == 404)
        #expect(NotchPlacement.bodyWidth(on: builtIn, expanded: true, wing: 112, width: width) == CGFloat(body))
        let open = NotchPlacement.frame(on: builtIn, expanded: true, contentHeight: 200, wing: 112, width: width)
        #expect(open.width == CGFloat(body) + 2 * NotchPlacement.earRadius)
        #expect(open.midX == collapsed.midX)
        let layout = NotchPlacement.strip(on: builtIn, expanded: true, wing: 112, width: width)
        #expect(layout.leading == layout.trailing)
    }
    // A narrow strip still reaches each width's floor.
    let bare = NotchDisplay(id: 3, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), topInset: 0, housingWidth: 0,
                            menuBarHeight: 25, isBuiltIn: false)
    #expect(NotchPlacement.bodyWidth(on: bare, expanded: true, width: .standard) == 380)
    #expect(NotchPlacement.bodyWidth(on: bare, expanded: true, width: .wide) == 480)
    #expect(NotchPlacement.bodyWidth(on: bare, expanded: true, width: .extraWide) == 580)
}

@Test func widePanelNeverRunsPastTheDisplayMarginsOrBelowStandard() {
    let narrow = NotchDisplay(id: 4, frame: CGRect(x: 0, y: 0, width: 600, height: 800), topInset: 0, housingWidth: 0,
                              menuBarHeight: 25, isBuiltIn: false)
    // Room: 600 - 2 * (8 + 16) = 552.
    #expect(NotchPlacement.bodyWidth(on: narrow, expanded: true, width: .extraWide) == 552)
    #expect(NotchPlacement.bodyWidth(on: narrow, expanded: true, width: .wide) == 480)
    let tiny = NotchDisplay(id: 5, frame: CGRect(x: 0, y: 0, width: 400, height: 600), topInset: 0, housingWidth: 0,
                            menuBarHeight: 25, isBuiltIn: false)
    #expect(NotchPlacement.bodyWidth(on: tiny, expanded: true, width: .extraWide)
            == NotchPlacement.bodyWidth(on: tiny, expanded: true, width: .standard))
}

@Test func pointerPushedAgainstTheTopEdgeCountsAsOverThePanel() {
    // The built-in strip measured live: Cocoa y 950–982, and the pinned pointer reports y 982.
    let strip = CGRect(x: 543, y: 950, width: 421, height: 32)

    #expect(!strip.contains(CGPoint(x: 750, y: 982)))
    #expect(NotchHover.pointerTouchesTopEdge(of: strip, pointer: CGPoint(x: 750, y: 982)))
    #expect(NotchHover.pointerTouchesTopEdge(of: strip, pointer: CGPoint(x: 543, y: 982)))
    #expect(!NotchHover.pointerTouchesTopEdge(of: strip, pointer: CGPoint(x: 964, y: 982)))
    #expect(!NotchHover.pointerTouchesTopEdge(of: strip, pointer: CGPoint(x: 400, y: 982)))
    #expect(!NotchHover.pointerTouchesTopEdge(of: strip, pointer: CGPoint(x: 750, y: 981)))
    #expect(!NotchHover.pointerTouchesTopEdge(of: .zero, pointer: .zero))
}

@Test func panelMovedByTheWindowServerIsPutBackWhenTheTargetIsUnchanged() {
    let strip = NotchPlacement.frame(on: builtIn, expanded: false, rows: 0, extraRows: false)
    // After the display sleeps and wakes, the panel sits mid-screen while the computed frame is the same.
    let midScreen = strip.offsetBy(dx: 0, dy: -400)

    #expect(NotchFrameSync.action(target: strip, lastTarget: strip, actual: midScreen, animating: false) == .restoreDrifted)
    #expect(NotchFrameSync.action(target: strip, lastTarget: strip, actual: strip.offsetBy(dx: 300, dy: 0), animating: false) == .restoreDrifted)
    #expect(NotchFrameSync.action(target: strip, lastTarget: strip, actual: strip, animating: false) == .none)
}

@Test func frameSyncIgnoresRoundingAndRunningAnimationsButFollowsANewTarget() {
    let strip = NotchPlacement.frame(on: builtIn, expanded: false, rows: 0, extraRows: false)
    let open = NotchPlacement.frame(on: builtIn, expanded: true, rows: 3, extraRows: false)

    // Backing-store rounding of a half-point origin is not drift.
    #expect(NotchFrameSync.action(target: strip, lastTarget: strip, actual: strip.offsetBy(dx: 0.5, dy: -0.5), animating: false) == .none)
    // Mid-animation the panel is between frames; that is not drift either.
    #expect(NotchFrameSync.action(target: open, lastTarget: open, actual: strip, animating: true) == .none)
    // A changed target always moves, animating or not.
    #expect(NotchFrameSync.action(target: open, lastTarget: strip, actual: strip, animating: true) == .moveToNewTarget)
    #expect(NotchFrameSync.action(target: open, lastTarget: strip, actual: strip, animating: false) == .moveToNewTarget)
}

@Test func openingPanelWaitsForItsMeasuredHeightInsteadOfGrowingToTheEstimate() {
    // A measurement always wins, even one that arrives at once.
    #expect(NotchOpenHeight.choose(measured: 212, waitingSince: 10, now: 10) == .measured(212))
    #expect(NotchOpenHeight.choose(measured: 212, waitingSince: 10, now: 30) == .measured(212))
    // Without one the panel holds, so it never opens to the taller estimate and shrinks back.
    #expect(NotchOpenHeight.choose(measured: 0, waitingSince: 10, now: 10) == .awaitingMeasurement)
    #expect(NotchOpenHeight.choose(measured: 0, waitingSince: 10, now: 10 + NotchOpenHeight.grace - 0.01) == .awaitingMeasurement)
    // A measurement that never comes cannot keep the panel closed.
    #expect(NotchOpenHeight.choose(measured: 0, waitingSince: 10, now: 10 + NotchOpenHeight.grace) == .estimate)
}

// MARK: - Strip left wing (D2, D3, D22; #318)

private func wingSession(_ index: Int) -> AgentSessionIdentity {
    AgentSessionIdentity(source: .claude, sourceScope: "root", session: "session-\(index)", surface: .cli)
}

/// A strip whose queue holds one completion per session, with the listed sessions also working.
private func wingStrip(sessions count: Int, working: Set<Int> = []) -> AgentStripSummary {
    var queue = AgentAttentionQueue()
    for index in 0..<count {
        if working.contains(index) {
            queue.apply(.running(AgentRunning(session: wingSession(index), turn: "run-\(index)", arrivedAt: Double(index))))
        } else {
            queue.apply(.outcome(AgentOutcome(session: wingSession(index), turn: "done-\(index)", status: .finished,
                                              arrivedAt: Double(index))))
        }
    }
    return AgentStripSummary.make(items: queue.items(at: Double(count)), now: Double(count))
}

@Test func collapsedWingShowsUpToThreeSpritesAndABareCount() {
    let empty = StripWing.make(summary: wingStrip(sessions: 0), leftWing: .spritesAndCount, expanded: false)
    #expect(empty.sprites == [.unlit] && empty.badge == nil)

    let one = StripWing.make(summary: wingStrip(sessions: 1), leftWing: .spritesAndCount, expanded: false)
    #expect(one.sprites.map(\.identity) == [wingSession(0)] && one.badge == .count(1))

    let three = StripWing.make(summary: wingStrip(sessions: 3), leftWing: .spritesAndCount, expanded: false)
    #expect(three.sprites.map(\.identity) == [wingSession(0), wingSession(1), wingSession(2)] && three.badge == .count(3))

    // Nine sessions still draw exactly three sprites; the rest appear only in the open queue, and
    // nothing on the strip counts them.
    let nineSummary = wingStrip(sessions: 9)
    let nine = StripWing.make(summary: nineSummary, leftWing: .spritesAndCount, expanded: false)
    #expect(nine.sprites.count == 3)
    #expect(nine.sprites.map(\.identity) == [wingSession(0), wingSession(1), wingSession(2)])
    #expect(nine.badge == .count(9) && nineSummary.toCheck == 9)
}

@Test func openWingShowsOneSpriteAndNamesTheBadge() {
    let empty = StripWing.make(summary: wingStrip(sessions: 0), leftWing: .spritesAndCount, expanded: true)
    #expect(empty.sprites == [.unlit] && empty.badge == nil)

    let one = StripWing.make(summary: wingStrip(sessions: 1), leftWing: .spritesAndCount, expanded: true)
    #expect(one.sprites.map(\.identity) == [wingSession(0)] && one.badge == .named(1))

    let three = StripWing.make(summary: wingStrip(sessions: 3), leftWing: .spritesAndCount, expanded: true)
    #expect(three.sprites.map(\.identity) == [wingSession(0)] && three.badge == .named(3))

    let nine = StripWing.make(summary: wingStrip(sessions: 9), leftWing: .spritesAndCount, expanded: true)
    #expect(nine.sprites.map(\.identity) == [wingSession(0)] && nine.badge == .named(9))
}

@Test func openWingStepsTheFirstWorkingSessionsSprite() {
    // Completions outrank running work, so the working session is not first in priority order.
    let summary = wingStrip(sessions: 3, working: [1, 2])
    #expect(summary.sessions.first?.working == false)
    let open = StripWing.make(summary: summary, leftWing: .spritesAndCount, expanded: true)
    #expect(open.sprites.count == 1)
    guard case .session(let sprite) = open.sprites.first else { Issue.record("expected a session sprite"); return }
    #expect(sprite.working && sprite.session == wingSession(1))
    #expect(open.badge == .named(1))
    // A working session among the shown three keeps the color it has on the strip.
    #expect(sprite.color == summary.sessions[1].color)

    // The only working session ranks below the three collapsed sprites: collapsed it is not drawn,
    // open its sprite still steps.
    let deep = wingStrip(sessions: 9, working: [6])
    let deepCollapsed = StripWing.make(summary: deep, leftWing: .spritesAndCount, expanded: false)
    #expect(deepCollapsed.sprites.count == 3 && !deepCollapsed.sprites.map(\.identity).contains(wingSession(6)))
    let deepOpen = StripWing.make(summary: deep, leftWing: .spritesAndCount, expanded: true)
    #expect(deepOpen.sprites.map(\.identity) == [wingSession(6)] && deepOpen.badge == .named(8))
    // Its color matches its queue row: a session not on the strip takes its preferred color.
    if case .session(let session) = deepOpen.sprites.first {
        #expect(session.working && session.color == AgentStripSummary.preferredColor(for: wingSession(6)))
    } else { Issue.record("expected a session sprite") }

    // Only working sessions: nothing to check, so no badge, and the sprite still steps.
    let busy = StripWing.make(summary: wingStrip(sessions: 2, working: [0, 1]), leftWing: .spritesAndCount, expanded: true)
    #expect(busy.badge == nil && busy.sprites.count == 1)
    if case .session(let session) = busy.sprites.first { #expect(session.working) } else { Issue.record("expected a sprite") }
}

@Test func countOnlyWingKeepsOneSteppingSpriteAndNamesTheBadgeWhenOpen() {
    let idle = wingStrip(sessions: 3)
    #expect(StripWing.make(summary: idle, leftWing: .countOnly, expanded: false) == StripWing(sprites: [], badge: .count(3)))
    #expect(StripWing.make(summary: idle, leftWing: .countOnly, expanded: true) == StripWing(sprites: [], badge: .named(3)))
    #expect(StripWing.make(summary: wingStrip(sessions: 0), leftWing: .countOnly, expanded: true) == StripWing(sprites: [], badge: nil))

    let busy = wingStrip(sessions: 9, working: [4])
    for expanded in [false, true] {
        let wing = StripWing.make(summary: busy, leftWing: .countOnly, expanded: expanded)
        #expect(wing.sprites.map(\.identity) == [wingSession(4)])
        #expect(wing.badge == (expanded ? .named(8) : .count(8)))
    }
}

@Test func noneWingIsEmptyAndHasNoBadge() {
    for expanded in [false, true] {
        for count in [0, 1, 3, 9] {
            let wing = StripWing.make(summary: wingStrip(sessions: count, working: [0]), leftWing: .none, expanded: expanded)
            #expect(wing == StripWing(sprites: [], badge: nil))
        }
    }
}

@Test func badgeTextIsTheBareCountCollapsedAndNamedOpen() {
    #expect(StripWing.Badge.count(3).text == "3")
    #expect(StripWing.Badge.named(3).text == "3 to check")
    #expect(StripWing.Badge.named(12).text == "12 to check")
}

@Test func stripSpokenLabelNamesNoSessionCount() {
    let readouts = ["Codex weekly 40 percent used"]
    let nine = wingStrip(sessions: 9, working: [4])
    let label = nine.spokenLabel(emptyQueueTitle: "Nothing running", readouts: readouts)
    #expect(label == "\(nine.subject), working, 8 to check, Codex weekly 40 percent used")
    #expect(!label.contains("sessions"))

    let busy = wingStrip(sessions: 2, working: [0, 1])
    #expect(busy.spokenLabel(emptyQueueTitle: "Nothing running", readouts: []) == "\(busy.subject), working")

    let idle = wingStrip(sessions: 1)
    #expect(idle.spokenLabel(emptyQueueTitle: "Nothing running", readouts: []) == "\(idle.subject), 1 to check")

    let empty = wingStrip(sessions: 0)
    #expect(empty.spokenLabel(emptyQueueTitle: "Not connected", readouts: readouts)
        == "Not connected, Codex weekly 40 percent used")
}
