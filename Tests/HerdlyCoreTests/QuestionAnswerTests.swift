import Foundation
import Testing
@testable import HerdlyCore

private func question(source: AttentionSource = .cli, prompts: [QuestionPrompt], count: Int? = nil,
                      session: UUID = UUID(), turn: UUID = UUID()) -> AttentionQuestion {
    AttentionQuestion(source: source, session: session, turn: turn, callID: "call_1", arrivedAt: 100,
                      prompts: prompts, questionCount: count)
}

private let twoOptions = QuestionPrompt(header: "Shape", question: "Which?", options: ["Flexible", "Same"])
private let threeOptions = QuestionPrompt(header: "Release", question: "Scope?", options: ["Lookup", "Checkout", "Both"])

@Test func offerListsDigitsOnlyForACompleteOptionQuestion() {
    #expect(QuestionAnswerProgress.offer(question(prompts: [twoOptions]), at: 0) == .options(["Flexible", "Same"]))
    #expect(QuestionAnswerProgress.offer(question(prompts: [twoOptions, threeOptions]), at: 1) == .options(["Lookup", "Checkout", "Both"]))
}

@Test func questionsHerdlyCannotNumberExactlyStayInCodex() {
    let free = QuestionPrompt(header: "Name", question: "Call it?", options: [])
    let incomplete = QuestionPrompt(header: "H", question: "Q", options: ["a", "b"], truncated: true, optionsComplete: false)
    let unreadable = question(prompts: [])
    let beyond = question(prompts: [twoOptions], count: 3)
    for (label, offer) in [
        ("free text", QuestionAnswerProgress.offer(question(prompts: [free]), at: 0)),
        ("incomplete", QuestionAnswerProgress.offer(question(prompts: [incomplete]), at: 0)),
        ("unreadable", QuestionAnswerProgress.offer(unreadable, at: 0)),
        ("beyond the parsed questions", QuestionAnswerProgress.offer(beyond, at: 1)),
        ("negative index", QuestionAnswerProgress.offer(question(prompts: [twoOptions]), at: -1))
    ] {
        guard case .continueInCodex = offer else { Issue.record("\(label) should stay in Codex"); continue }
    }
}

@Test func otherQuestionsOfferOnlyTheListedOptions() {
    let other = QuestionPrompt(header: "H", question: "Q", options: ["a", "b"], isOther: true)
    #expect(QuestionAnswerProgress.offer(question(prompts: [other]), at: 0) == .options(["a", "b"]))
    let call = question(prompts: [other])
    let progress = QuestionAnswerProgress(call: call.id)
    #expect(QuestionAnswerPolicy.rejection(for: call, ghosttyEnabled: true, progress: progress, question: 0, option: 2) == .optionOutOfRange)
    #expect(QuestionAnswerPolicy.rejection(for: call, ghosttyEnabled: true, progress: progress, question: 0, option: 1) == nil)
}

@Test func policyAcceptsOnlyAPendingCLIQuestionWithGhosttyEnabledAndReadyProgress() {
    let cli = question(prompts: [twoOptions, threeOptions])
    let fresh = QuestionAnswerProgress(call: cli.id)
    #expect(QuestionAnswerPolicy.rejection(for: cli, ghosttyEnabled: true, progress: fresh, question: 0, option: 1) == nil)
    #expect(QuestionAnswerPolicy.rejection(for: nil, ghosttyEnabled: true, progress: fresh, question: 0, option: 1) == .notInQueue)
    let otherCall = AttentionQuestion(source: .cli, session: cli.session, turn: cli.turn, callID: "call_2", arrivedAt: 1, prompts: [twoOptions])
    #expect(QuestionAnswerPolicy.rejection(for: otherCall, ghosttyEnabled: true, progress: fresh, question: 0, option: 1) == .notInQueue)
    let desktop = cli.with(source: .desktop)
    #expect(QuestionAnswerPolicy.rejection(for: desktop, ghosttyEnabled: true, progress: QuestionAnswerProgress(call: desktop.id), question: 0, option: 1) == .notCLI)
    #expect(QuestionAnswerPolicy.rejection(for: cli, ghosttyEnabled: false, progress: fresh, question: 0, option: 1) == .ghosttyDisabled)
    #expect(QuestionAnswerPolicy.rejection(for: cli, ghosttyEnabled: true, progress: fresh, question: 1, option: 1) == .wrongQuestion)
    #expect(QuestionAnswerPolicy.rejection(for: cli, ghosttyEnabled: true, progress: fresh, question: 0, option: 2) == .optionOutOfRange)
    #expect(QuestionAnswerPolicy.rejection(for: cli, ghosttyEnabled: true, progress: fresh, question: 0, option: -1) == .optionOutOfRange)
    let free = question(prompts: [QuestionPrompt(header: nil, question: "Q", options: [])])
    #expect(QuestionAnswerPolicy.rejection(for: free, ghosttyEnabled: true, progress: QuestionAnswerProgress(call: free.id), question: 0, option: 0) == .notOfferable)
    // Nine options are the most one digit can name; eight is Herdly's cap anyway.
    let eight = question(prompts: [QuestionPrompt(header: nil, question: "Q", options: (1...8).map(String.init))])
    #expect(QuestionAnswerPolicy.rejection(for: eight, ghosttyEnabled: true, progress: QuestionAnswerProgress(call: eight.id), question: 0, option: 7) == nil)
    #expect(QuestionAnswerPolicy.key(forOption: 7) == "8")
    #expect(QuestionAnswerPolicy.key(forOption: 0) == "1")
    // Every non-ready phase refuses, and so does a repeated pick for the same question.
    let sending = fresh.startingSend(question: 0, option: 1)
    #expect(QuestionAnswerPolicy.rejection(for: cli, ghosttyEnabled: true, progress: sending, question: 0, option: 1) == .notReady)
    let failed = sending.recordingFailure("nope")
    #expect(QuestionAnswerPolicy.rejection(for: cli, ghosttyEnabled: true, progress: failed, question: 0, option: 1) == .notReady)
    let last = QuestionAnswerProgress(call: cli.id).startingSend(question: 0, option: 0)
        .recordingSent(question: 0, option: 0, of: question(prompts: [twoOptions], session: cli.session), at: 5)
    #expect(QuestionAnswerPolicy.rejection(for: cli, ghosttyEnabled: true, progress: last, question: 0, option: 1) == .notReady)
    #expect(QuestionAnswerPolicy.rejection(for: cli, ghosttyEnabled: true, progress: last.expiring(at: 20), question: 0, option: 1) == .notReady)
}

@Test func sendingANonLastQuestionAdvancesAndStaysReady() {
    let call = question(prompts: [twoOptions, threeOptions])
    let progress = QuestionAnswerProgress(call: call.id)
    let sending = progress.startingSend(question: 0, option: 1)
    #expect(sending.phase == .sending)
    #expect(!sending.offersButtons)
    let advanced = sending.recordingSent(question: 0, option: 1, of: call, at: 10)
    #expect(advanced.questionIndex == 1)
    #expect(advanced.phase == .ready)
    #expect(advanced.picks == [0: 1])
    #expect(QuestionAnswerPolicy.rejection(for: call, ghosttyEnabled: true, progress: advanced, question: 1, option: 2) == nil)
    #expect(QuestionAnswerPolicy.rejection(for: call, ghosttyEnabled: true, progress: advanced, question: 0, option: 0) == .wrongQuestion)
    // A call with more questions than Herdly parsed still advances past the last parsed one, into Codex.
    let capped = question(prompts: [twoOptions], count: 2)
    let beyond = QuestionAnswerProgress(call: capped.id).startingSend(question: 0, option: 0).recordingSent(question: 0, option: 0, of: capped, at: 1)
    #expect(beyond.questionIndex == 1 && beyond.phase == .ready)
    guard case .continueInCodex = QuestionAnswerProgress.offer(capped, at: beyond.questionIndex) else { Issue.record("beyond the cap"); return }
}

@Test func sendingTheLastQuestionWaitsThenBecomesUnconfirmedAfterTenSeconds() {
    let call = question(prompts: [twoOptions])
    let sent = QuestionAnswerProgress(call: call.id).startingSend(question: 0, option: 0).recordingSent(question: 0, option: 0, of: call, at: 100)
    #expect(sent.phase == .sent(at: 100))
    #expect(sent.expiring(at: 109.9).phase == .sent(at: 100))
    let expired = sent.expiring(at: 110)
    #expect(expired.phase == .unconfirmed(sentAt: 100))
    #expect(expired.expiring(at: 500) == expired)
    #expect(expired.startingSend(question: 0, option: 1) == expired)
    #expect(expired.recordingSent(question: 0, option: 1, of: call, at: 600) == expired)
}

@Test func failureRecordsTheReasonAndNeverRetries() {
    let call = question(prompts: [twoOptions])
    let failed = QuestionAnswerProgress(call: call.id).startingSend(question: 0, option: 0).recordingFailure("Ghostty refused")
    #expect(failed.phase == .failed("Ghostty refused"))
    #expect(failed.picks.isEmpty)
    #expect(failed.startingSend(question: 0, option: 0) == failed)
    #expect(failed.recordingSent(question: 0, option: 0, of: call, at: 1) == failed)
    // A failure can only follow a send in flight.
    #expect(QuestionAnswerProgress(call: call.id).recordingFailure("x").phase == .ready)
}

@Test func guardRefusesAnAnsweredCallAnEndedTurnAndUnreadableEvidence() {
    let call = question(prompts: [twoOptions])
    var pending = ReminderReader.RolloutEvidence()
    pending.pendingQuestions = [call.with(source: .desktop)]
    #expect(QuestionAnswerGuard.stillPending(call, in: pending))
    var answered = ReminderReader.RolloutEvidence()
    answered.answeredQuestions = [call.with(source: .desktop).id]
    #expect(!QuestionAnswerGuard.stillPending(call, in: answered))
    for kind in ["completed", "canceled"] {
        var ended = pending
        if kind == "completed" { ended.completed = [TurnIdentity(session: call.session, turn: call.turn)] }
        else { ended.canceled = [TurnIdentity(session: call.session, turn: call.turn)] }
        #expect(!QuestionAnswerGuard.stillPending(call, in: ended), Comment(rawValue: kind))
    }
    #expect(!QuestionAnswerGuard.stillPending(call, in: ReminderReader.RolloutEvidence()))
    var otherCall = ReminderReader.RolloutEvidence()
    otherCall.pendingQuestions = [AttentionQuestion(session: call.session, turn: call.turn, callID: "call_9", arrivedAt: 1)]
    #expect(!QuestionAnswerGuard.stillPending(call, in: otherCall))
    var otherTurn = ReminderReader.RolloutEvidence()
    otherTurn.pendingQuestions = [AttentionQuestion(session: call.session, turn: UUID(), callID: call.callID, arrivedAt: 1)]
    #expect(!QuestionAnswerGuard.stillPending(call, in: otherTurn))
}

@Test func desktopPickIsRecordedWithoutSendingAnything() {
    let call = question(source: .desktop, prompts: [twoOptions])
    let picked = QuestionAnswerProgress(call: call.id).pickingInCodex(question: 0, option: 1)
    #expect(picked.phase == .pickedInCodex(option: 1))
    #expect(picked.picks == [0: 1])
    #expect(!picked.offersButtons)
    #expect(QuestionAnswerPolicy.rejection(for: call, ghosttyEnabled: true, progress: picked, question: 0, option: 1) == .notCLI)
    #expect(QuestionAnswerProgress(call: call.id).pickingInCodex(question: 1, option: 0).phase == .ready)
}
