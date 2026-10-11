import Testing
@testable import SteerCore

private let player = QuestionPrompt(header: "Player", question: "Who plays?", options: ["Casual", "Enthusiast"])
private let purpose = QuestionPrompt(header: "Purpose", question: "What for?", options: ["Portfolio", "User test", "Product"])
private let unnamed = QuestionPrompt(header: "  ", question: "Anything else?", options: [])

@Test func stepsMarkEarlierQuestionsAnsweredAndNameTheCurrentOne() {
    let steps = QuestionSteps.make([player, purpose, unnamed], current: 1) { $0 == 0 ? .option(0) : nil }
    #expect(steps.steps.map(\.label) == ["Player", "Purpose", "Question 3"])
    #expect(steps.steps.map(\.state) == [.answered, .current, .upcoming])
    #expect(steps.answered == [QuestionSteps.Answered(label: "Player", answer: "Casual")])
}

@Test func answeredLinesShowTypedTextAndNeverInventAnAnswer() {
    let steps = QuestionSteps.make([unnamed, player, purpose], current: 2) { index in
        switch index {
        case 0: .text("Ship it")
        default: nil
        }
    }
    // Question 2 is behind the card but Steer holds no answer for it: marked answered, no line.
    #expect(steps.steps.map(\.state) == [.answered, .answered, .current])
    #expect(steps.answered == [QuestionSteps.Answered(label: "Question 1", answer: "Ship it")])
}

@Test func anOptionBeyondTheListIsNamedByPosition() {
    let steps = QuestionSteps.make([player, purpose], current: 1) { _ in .option(5) }
    #expect(steps.answered == [QuestionSteps.Answered(label: "Player", answer: "Option 6")])
}

@Test func theCurrentIndexIsClampedAndAnswersAtOrAfterItAreNotShown() {
    let past = QuestionSteps.make([player, purpose], current: 9) { _ in .option(1) }
    #expect(past.steps.map(\.state) == [.answered, .current])
    #expect(past.answered.map(\.label) == ["Player"])
    let before = QuestionSteps.make([player, purpose], current: -3) { _ in .option(1) }
    #expect(before.steps.map(\.state) == [.current, .upcoming])
    #expect(before.answered.isEmpty)
    #expect(QuestionSteps.make([], current: 0) { _ in nil } == QuestionSteps(steps: [], answered: []))
}

@Test func theReadOnlySentenceCountsTheQuestions() {
    #expect(QuestionSteps.answerElsewhere(count: 3, agent: "Claude") == "Claude is asking 3 questions. Answer them in Claude.")
    #expect(QuestionSteps.answerElsewhere(count: 1, agent: "Codex") == "Codex is asking a question. Answer it in Codex.")
}
