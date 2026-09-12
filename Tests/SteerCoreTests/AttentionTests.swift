import Testing
@testable import SteerCore

@Test func completionSurvivesVisibilityAndRestarts() {
    var item = Attention()
    item.enqueue()
    let whileInCodex = item.update(codexForeground: true, hovering: false, now: 0)
    #expect(!whileInCodex)
    #expect(item.pending && !item.presented)
    let firstPresentation = item.update(codexForeground: false, hovering: false, now: 10)
    #expect(firstPresentation)
    #expect(item.expanded)
    let whileHovering = item.update(codexForeground: false, hovering: true, now: 14)
    #expect(!whileHovering)
    #expect(item.expanded)
    _ = item.update(codexForeground: false, hovering: false, now: 14)
    #expect(!item.expanded && item.pending)
    item.expand(now: 20)
    _ = item.update(codexForeground: true, hovering: true, now: 21)
    #expect(!item.expanded && item.pending)
    let afterReturning = item.update(codexForeground: false, hovering: false, now: 22)
    #expect(!afterReturning)
    _ = item.update(codexForeground: nil, hovering: false, now: 23)
    #expect(item.pending && item.presented)
    var restored = Attention(restored: item.pending)
    let afterRestart = restored.update(codexForeground: false, hovering: false, now: 30)
    #expect(!afterRestart)
    #expect(restored.pending && !restored.expanded)
    restored.dismiss()
    #expect(!restored.pending)
    restored.enqueue()
    let nextCompletion = restored.update(codexForeground: false, hovering: false, now: 40)
    #expect(nextCompletion)
}

@Test func unknownActivationKeepsNewCompletionAvailable() {
    var item = Attention()
    item.enqueue()
    let shown = item.update(codexForeground: nil, hovering: false, now: 0)
    #expect(shown && item.pending)
    _ = item.update(codexForeground: nil, hovering: false, now: 3)
    #expect(!item.expanded && item.pending)
}

@Test func laterCompletionPresentsAgainWithoutChangingAcknowledgment() {
    var item = Attention()
    item.enqueue()
    let first = item.update(codexForeground: false, hovering: false, now: 10)
    #expect(first)
    item.enqueue()
    let later = item.update(codexForeground: false, hovering: false, now: 11)
    #expect(later)
    _ = item.update(codexForeground: false, hovering: false, now: 14.1)
    #expect(!item.expanded && item.pending)
}

@Test func cliPresentationWaitsForVerifiedGhosttyFocus() {
    #expect(!CompletionVisibility.allows(source: .cli, codexForeground: false, ghosttyFocus: .checking))
    #expect(!CompletionVisibility.allows(source: .cli, codexForeground: false, ghosttyFocus: .unknown))
    #expect(!CompletionVisibility.allows(source: .cli, codexForeground: false, ghosttyFocus: .focused))
    #expect(CompletionVisibility.allows(source: .cli, codexForeground: false, ghosttyFocus: .away))
    #expect(CompletionVisibility.allows(source: .desktop, codexForeground: nil, ghosttyFocus: .unknown))
    #expect(!CompletionVisibility.allows(source: .desktop, codexForeground: true, ghosttyFocus: .disabled))
}

@Test func cliThreeSecondTimerStartsAfterFocusGateOpens() {
    var presentation = Attention()
    presentation.enqueue()
    let blocked = !CompletionVisibility.allows(source: .cli, codexForeground: false, ghosttyFocus: .checking)
    let blockedResult = presentation.update(codexForeground: blocked, hovering: false, now: 10)
    #expect(!blockedResult)
    #expect(!presentation.presented)

    let allowed = CompletionVisibility.allows(source: .cli, codexForeground: false, ghosttyFocus: .away)
    let shown = presentation.update(codexForeground: !allowed, hovering: false, now: 20)
    #expect(shown)
    _ = presentation.update(codexForeground: false, hovering: false, now: 23.1)
    #expect(!presentation.expanded && presentation.pending)
}

@Test func mutedCompletionDoesNotSignalSoundAndReopeningDoesNotReplay() {
    var presentation = Attention()
    presentation.enqueue()
    let first = presentation.update(codexForeground: false, hovering: false, now: 10)
    #expect(!CompletionSound.shouldPlay(firstPresentation: first, muted: true))
    #expect(CompletionSound.shouldPlay(firstPresentation: first, muted: false))

    presentation.expand(now: 11)
    let reopened = presentation.update(codexForeground: false, hovering: false, now: 12)
    #expect(!CompletionSound.shouldPlay(firstPresentation: reopened, muted: false))
    let switched = presentation.update(codexForeground: true, hovering: false, now: 13)
    #expect(!CompletionSound.shouldPlay(firstPresentation: switched, muted: false))
}
