import Foundation
import Testing
@testable import HerdlyCore

private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/claude", session: "s1", surface: .cli)
private let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s2", surface: .cli)
private let approvalID = AgentAttentionID.approval(AgentCallIdentity(session: claude, turn: "t1", call: "toolu_1"))
private let questionID = AgentAttentionID.question(AgentCallIdentity(session: codex, turn: "t2", call: "call_2"))
private let resultID = AgentAttentionID.outcome(AgentTurnIdentity(session: codex, turn: "t3"))

// MARK: - Where the hotkey puts the keyboard (#427)

@Test func theHotkeyPutsTheKeyboardInTheSpotlightCardThatIsShowing() {
    #expect(NotchKeyboardEntry.target(showing: .agentSpotlight(questionID)) == .card(questionID))
    #expect(NotchKeyboardEntry.target(showing: .agentSpotlight(approvalID)) == .card(approvalID))
}

@Test func theHotkeyKeepsAClickedCardRatherThanOpeningTheQueueOverIt() {
    #expect(NotchKeyboardEntry.target(showing: .clickedCard(approvalID)) == .card(approvalID))
}

@Test func withNoCardShowingTheHotkeyOpensTheQueue() {
    #expect(NotchKeyboardEntry.target(showing: .collapsed) == .queue)
    #expect(NotchKeyboardEntry.target(showing: .queue) == .queue)
}

// MARK: - Giving the keyboard back (#427)

@Test func theKeyboardGoesBackToTheAppThatHadItWhenTheHotkeyWasPressed() {
    var handBack = NotchKeyboardReturn<String>()
    handBack.enter(frontmost: "Ghostty")
    #expect(handBack.handBack(isRunning: { _ in true }, frontmost: "Ghostty", herdly: "Herdly") == .activate("Ghostty"))
}

@Test func whenThatAppHasQuitHerdlyActivatesNothingAndLeavesItToMacOS() {
    var handBack = NotchKeyboardReturn<String>()
    handBack.enter(frontmost: "Ghostty")
    #expect(handBack.handBack(isRunning: { $0 != "Ghostty" }, frontmost: nil, herdly: "Herdly") == .leaveToSystem)
}

@Test func withNoFrontmostAppAtEntryThereIsNothingToReturnTo() {
    var handBack = NotchKeyboardReturn<String>()
    handBack.enter(frontmost: nil)
    #expect(handBack.handBack(isRunning: { _ in true }, frontmost: "Herdly", herdly: "Herdly") == .leaveToSystem)
}

@Test func herdlyHavingTakenActivationStillHandsBackToTheRememberedApp() {
    var handBack = NotchKeyboardReturn<String>()
    handBack.enter(frontmost: "Ghostty")
    #expect(handBack.handBack(isRunning: { _ in true }, frontmost: "Herdly", herdly: "Herdly") == .activate("Ghostty"))
}

@Test func anAppBroughtForwardMeanwhileKeepsTheKeyboard() {
    // Return on a result row opened its session in Terminal; folding must not pull Ghostty back over it.
    var handBack = NotchKeyboardReturn<String>()
    handBack.enter(frontmost: "Ghostty")
    #expect(handBack.handBack(isRunning: { _ in true }, frontmost: "Terminal", herdly: "Herdly") == .reactivateFrontmost)
}

@Test func aClickedPanelHandsBackAsBeforeToTheAppStillInFront() {
    var handBack = NotchKeyboardReturn<String>()
    #expect(handBack.handBack(isRunning: { _ in true }, frontmost: "Ghostty", herdly: "Herdly") == .reactivateFrontmost)
}

@Test func theRememberedAppIsUsedOnceThenForgotten() {
    var handBack = NotchKeyboardReturn<String>()
    handBack.enter(frontmost: "Ghostty")
    _ = handBack.handBack(isRunning: { _ in true }, frontmost: "Ghostty", herdly: "Herdly")
    #expect(handBack.handBack(isRunning: { _ in true }, frontmost: "Ghostty", herdly: "Herdly") == .reactivateFrontmost)
}

@Test func focusLostToAnotherAppForgetsTheRememberedApp() {
    var handBack = NotchKeyboardReturn<String>()
    handBack.enter(frontmost: "Ghostty")
    handBack.forget()
    #expect(handBack.handBack(isRunning: { _ in true }, frontmost: "Ghostty", herdly: "Herdly") == .reactivateFrontmost)
}

@Test func theFootLineNamesTheSameAppTheHandBackReturnsToWithoutSpendingIt() {
    var handBack = NotchKeyboardReturn<String>()
    handBack.enter(frontmost: "Ghostty")
    #expect(handBack.target(isRunning: { _ in true }, frontmost: "Ghostty", herdly: "Herdly") == .activate("Ghostty"))
    #expect(handBack.target(isRunning: { _ in true }, frontmost: "Terminal", herdly: "Herdly") == .reactivateFrontmost)
    #expect(handBack.target(isRunning: { _ in false }, frontmost: nil, herdly: "Herdly") == .leaveToSystem)
    // Reading it spends nothing: the hand-back still returns to Ghostty.
    #expect(handBack.handBack(isRunning: { _ in true }, frontmost: "Ghostty", herdly: "Herdly") == .activate("Ghostty"))
}

@Test func theHotkeyEntersWhenTheKeyboardIsElsewhereAndHandsBackWhenItIsInTheNotch() {
    #expect(NotchKeyboardEntry.press(keyboardInNotch: false) == .enter)
    #expect(NotchKeyboardEntry.press(keyboardInNotch: true) == .handBack)
}

// MARK: - The hotkey's queue stays open while the keyboard is in it (Paper K "A · Hotkey")

@Test func aQueueOpenedByTheHotkeyStaysOpenWhileTheKeyboardIsInIt() {
    var controller = NotchPresentationController()
    controller.openQueueForKeyboard()
    // No pointer anywhere near, long after any hover grace.
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 1); #expect(result == .queue) }
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 600); #expect(result == .queue) }
    // Focus leaves (hotkey again, another app clicked): the queue folds.
    do { let result = controller.update(interacting: false, keyboardFocus: false, now: 601); #expect(result == .collapsed) }
    // And does not come back when focus returns some other way.
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 602); #expect(result == .collapsed) }
}

@Test func escapeOnTheHotkeysQueueCollapsesAndEndsTheHold() {
    var controller = NotchPresentationController()
    controller.openQueueForKeyboard()
    do { let result = controller.escape(); #expect(result == .collapse) }
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 1); #expect(result == .collapsed) }
}

@Test func aCardOpenedWithReturnFromTheHotkeysQueueIsHeldAndEscapeStepsBackToTheHeldQueue() {
    var controller = NotchPresentationController()
    controller.openQueueForKeyboard()
    controller.openCard(approvalID)
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 5, queued: [approvalID]); #expect(result == .clickedCard(approvalID)) }
    do { let result = controller.escape(); #expect(result == .backToQueue) }
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 6, queued: [approvalID]); #expect(result == .queue) }
}

@Test func aClickedQueueStillFoldsWhenThePointerLeavesDespiteKeyboardFocus() {
    // #376 is unchanged: focus from a click alone does not hold the queue.
    var controller = NotchPresentationController()
    controller.openQueue()
    do { let result = controller.update(interacting: true, keyboardFocus: true, now: 1); #expect(result == .queue) }
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 2); #expect(result == .collapsed) }
}

@Test func aFreshCardDoesNotReplaceTheHotkeysQueue() {
    var controller = NotchPresentationController()
    controller.openQueueForKeyboard()
    controller.present(questionID, now: 1, duration: .threeSeconds)
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 1, queued: [questionID]); #expect(result == .queue) }
}

@Test func keyboardFocusAloneIsNotInteractionSoItPausesNoCountdown() {
    // Approval and Claude question holds (ADR 0020) read the pointer only, and the hotkey's focus is
    // not interaction either, so no deadline moves because of it.
    #expect(!NotchInteraction.isActive(pointerInside: false, keyboardFocus: true))
}

// MARK: - The hotkey setting (Settings › Notch › Keyboard)

@Test func theHotkeyIsControlOptionSpaceAndOnByDefault() {
    let setting = NotchHotkeySetting.load(bool: { _ in nil }, string: { _ in nil })
    #expect(setting.enabled)
    #expect(setting.hotkey == .standard)
    #expect(setting.hotkey.keyCode == 49)
    #expect(setting.hotkey.title == "⌃⌥Space")
}

@Test func aChangedOrSwitchedOffHotkeyIsRememberedAcrossLaunches() {
    var flags: [String: Bool] = [:]
    var stored: [String: String] = [:]
    let custom = NotchHotkey(keyCode: 40, modifiers: [.command, .shift], keyName: "K")!
    NotchHotkeySetting(enabled: false, hotkey: custom).save(bool: { flags[$0] = $1 }, string: { stored[$0] = $1 })
    // The switch is a real Bool, as every other Herdly switch is.
    #expect(flags == ["notchHotkey.enabled": false])
    let loaded = NotchHotkeySetting.load(bool: { flags[$0] }, string: { stored[$0] })
    #expect(loaded == NotchHotkeySetting(enabled: false, hotkey: custom))
    #expect(loaded.hotkey.title == "⇧⌘K")
}

@Test func aShortcutNeedsControlOptionOrCommandSoPlainTypingIsNeverTaken() {
    #expect(NotchHotkey(keyCode: 18, modifiers: [], keyName: "1") == nil)
    #expect(NotchHotkey(keyCode: 18, modifiers: [.shift], keyName: "1") == nil)
    #expect(NotchHotkey(keyCode: 18, modifiers: [.option], keyName: "1") != nil)
}

@Test func anUnreadableSavedHotkeyFallsBackToTheStandardOne() {
    let stored = ["notchHotkey.keyCode": "x", "notchHotkey.modifiers": "0", "notchHotkey.keyName": "K"]
    #expect(NotchHotkeySetting.load(bool: { _ in true }, string: { stored[$0] }).hotkey == .standard)
    let noModifiers = ["notchHotkey.keyCode": "40", "notchHotkey.modifiers": "0", "notchHotkey.keyName": "K"]
    #expect(NotchHotkeySetting.load(bool: { _ in nil }, string: { noModifiers[$0] }).hotkey == .standard)
}

@Test func aTakenShortcutIsReportedAndTheNotchStaysClickOnly() {
    #expect(NotchHotkeyStatus.taken.problemLine == "Another app already uses this shortcut, so the notch opens only by click. Choose another.")
    #expect(NotchHotkeyStatus.failed(-50).problemLine != nil)
    #expect(NotchHotkeyStatus.registered.problemLine == nil)
    #expect(NotchHotkeyStatus.off.problemLine == nil)
}

// MARK: - Recording a new shortcut (Settings › Notch › Keyboard)

@Test func escapeAloneCancelsRecording() {
    #expect(NotchHotkeyRecording.decide(keyCode: NotchHotkey.escapeKeyCode, modifiers: [], keyName: "⎋") == .cancel)
}

@Test func aKeyWithControlOptionOrCommandIsRecorded() {
    let expected = NotchHotkey(keyCode: 40, modifiers: [.control, .option], keyName: "K")!
    #expect(NotchHotkeyRecording.decide(keyCode: 40, modifiers: [.control, .option], keyName: "K") == .shortcut(expected))
    // Escape with a modifier is a shortcut like any other key.
    let escape = NotchHotkey(keyCode: NotchHotkey.escapeKeyCode, modifiers: [.command], keyName: "⎋")!
    #expect(NotchHotkeyRecording.decide(keyCode: NotchHotkey.escapeKeyCode, modifiers: [.command], keyName: "⎋") == .shortcut(escape))
}

@Test func aKeyWithoutControlOptionOrCommandIsIgnoredAndRecordingGoesOn() {
    #expect(NotchHotkeyRecording.decide(keyCode: 40, modifiers: [], keyName: "K") == .ignore)
    #expect(NotchHotkeyRecording.decide(keyCode: 40, modifiers: [.shift], keyName: "K") == .ignore)
}
