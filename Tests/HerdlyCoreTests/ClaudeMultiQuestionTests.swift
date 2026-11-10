import Foundation
import Testing
@testable import HerdlyCore

// #382: a Claude AskUserQuestion call with several questions is answered as one set.

private var threeQuestionInput: [String: Any] { [
    "questions": [
        ["header": "Format", "question": "Which format should the export use?",
         "options": [["label": "CSV"], ["label": "JSON lines"], ["label": "Markdown table"]]],
        ["header": "Scope", "question": "Which sessions should it include?", "multiSelect": true,
         "options": [["label": "Codex CLI"], ["label": "Claude"], ["label": "Codex app"]]],
        ["header": "Notify", "question": "Notify you when the export finishes?",
         "options": [["label": "Yes, in the notch"], ["label": "No"]]]
    ],
    "extra": "preserve"
] }

private func multiRequest(input: [String: Any] = threeQuestionInput, publishedAt: Double = 10,
                          expiresAt: Double = 40, eventDirectory: String = "/events") throws -> ClaudeQuestionRequest {
    let prompts = try #require(ClaudeQuestionAnswerPolicy.answerablePrompts(toolInput: input))
    return ClaudeQuestionRequest(requestID: "multi-1", installationID: "install-1", sourceScope: "/root",
                                 eventDirectory: eventDirectory, sessionID: "session-1", promptID: "prompt-1",
                                 toolUseID: "tool-1", publishedAt: publishedAt, expiresAt: expiresAt, prompts: prompts)
}

private func multiAnswer(for request: ClaudeQuestionRequest, _ entries: [ClaudeQuestionAnswerEntry],
                         sessionID: String? = nil, decidedAt: Double = 11) -> ClaudeQuestionAnswer {
    ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                         sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                         sessionID: sessionID ?? request.sessionID, promptID: request.promptID,
                         toolUseID: request.toolUseID, answers: entries, decidedAt: decidedAt)
}

private let completeSet: [ClaudeQuestionAnswerEntry] = [
    ClaudeQuestionAnswerEntry(kind: .option, answer: "JSON lines"),
    ClaudeQuestionAnswerEntry(kind: .multiSelect, answer: "Codex CLI, Claude"),
    ClaudeQuestionAnswerEntry(kind: .text, answer: "Only if it fails")
]

private func updatedAnswers(_ data: Data?) throws -> (answers: [String: String], input: [String: Any]) {
    let data = try #require(data)
    let output = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let hook = try #require(output["hookSpecificOutput"] as? [String: Any])
    #expect(hook["permissionDecision"] as? String == "allow")
    let updated = try #require(hook["updatedInput"] as? [String: Any])
    return (try #require(updated["answers"] as? [String: String]), updated)
}

@Test func helperPublishesOnlyCallsOfOneToFourReadableQuestions() throws {
    #expect(ClaudeQuestionAnswerPolicy.answerablePrompts(toolInput: threeQuestionInput)?.count == 3)
    let one = ["questions": [["question": "Ship?", "options": [["label": "Yes"]]]]]
    #expect(ClaudeQuestionAnswerPolicy.answerablePrompts(toolInput: one)?.count == 1)
    let question = ["question": "Q?", "options": [["label": "A"]]] as [String: Any]
    let five = ["questions": Array(repeating: question, count: 5)]
    #expect(ClaudeQuestionAnswerPolicy.answerablePrompts(toolInput: five) == nil)
    // One unreadable question makes the whole call Claude's own.
    var unreadable = threeQuestionInput
    unreadable["questions"] = [question, ["header": "No text", "options": [["label": "A"]]]]
    #expect(ClaudeQuestionAnswerPolicy.answerablePrompts(toolInput: unreadable) == nil)
    var secret = threeQuestionInput
    secret["questions"] = [question, ["question": "Token?", "isSecret": true]]
    #expect(ClaudeQuestionAnswerPolicy.answerablePrompts(toolInput: secret) == nil)
    #expect(ClaudeQuestionAnswerPolicy.answerablePrompts(toolInput: ["questions": [[String: Any]]()]) == nil)
}

@Test func completeAnswerSetEmitsEveryAnswerKeyedByQuestionText() throws {
    let request = try multiRequest()
    let answer = multiAnswer(for: request, completeSet)
    #expect(ClaudeQuestionAnswerPolicy.accepts(request: request, answer: answer))
    let (answers, updated) = try updatedAnswers(ClaudeQuestionAnswerPolicy.hookOutput(toolInput: threeQuestionInput,
                                                                                     request: request, answer: answer))
    #expect(answers == ["Which format should the export use?": "JSON lines",
                        "Which sessions should it include?": "Codex CLI, Claude",
                        "Notify you when the export finishes?": "Only if it fails"])
    #expect(updated["extra"] as? String == "preserve")
    #expect((updated["questions"] as? [[String: Any]])?.count == 3)
}

@Test func incompleteOrMismatchedAnswerSetsEmitNothing() throws {
    let request = try multiRequest()
    let partial = multiAnswer(for: request, Array(completeSet.prefix(2)))
    let extra = multiAnswer(for: request, completeSet + [ClaudeQuestionAnswerEntry(kind: .text, answer: "More")])
    // Answers in the wrong order no longer fit each question's own list.
    let reordered = multiAnswer(for: request, [completeSet[1], completeSet[0], completeSet[2]])
    let blank = multiAnswer(for: request, [completeSet[0], ClaudeQuestionAnswerEntry(kind: .text, answer: "  "), completeSet[2]])
    let notListed = multiAnswer(for: request, [ClaudeQuestionAnswerEntry(kind: .option, answer: "YAML"),
                                               completeSet[1], completeSet[2]])
    let singleOnMulti = multiAnswer(for: request, [completeSet[0], ClaudeQuestionAnswerEntry(kind: .option, answer: "Claude"),
                                                   completeSet[2]])
    let otherSession = multiAnswer(for: request, completeSet, sessionID: "session-2")
    for answer in [partial, extra, reordered, blank, notListed, singleOnMulti, otherSession] {
        #expect(!ClaudeQuestionAnswerPolicy.accepts(request: request, answer: answer))
        #expect(ClaudeQuestionAnswerPolicy.hookOutput(toolInput: threeQuestionInput, request: request, answer: answer) == nil)
    }
    // The tool input must still be the call the request was published for.
    var changed = threeQuestionInput
    changed["questions"] = Array((threeQuestionInput["questions"] as! [[String: Any]]).prefix(2))
    #expect(ClaudeQuestionAnswerPolicy.hookOutput(toolInput: changed, request: request,
                                                  answer: multiAnswer(for: request, completeSet)) == nil)
}

@Test func repeatedQuestionTextsLeaveTheCallToClaudeSinceOneKeyCannotCarryTwoAnswers() throws {
    let twin = ["question": "Which one?", "options": [["label": "A"], ["label": "B"]]] as [String: Any]
    let input: [String: Any] = ["questions": [twin, twin]]
    // The helper does not publish it, so the card is read-only rather than offering a Send that fails.
    #expect(ClaudeQuestionAnswerPolicy.answerablePrompts(toolInput: input) == nil)
    let prompts = try #require(QuestionPrompt.parseCall(toolInput: input)?.prompts)
    #expect(!ClaudeQuestionAnswerPolicy.answerable(prompts))
    let request = ClaudeQuestionRequest(requestID: "twin", installationID: "install-1", sourceScope: "/root",
                                        eventDirectory: "/events", sessionID: "session-1", promptID: "prompt-1",
                                        toolUseID: "tool-1", publishedAt: 10, expiresAt: 40, prompts: prompts)
    let answer = multiAnswer(for: request, [ClaudeQuestionAnswerEntry(kind: .option, answer: "A"),
                                            ClaudeQuestionAnswerEntry(kind: .option, answer: "B")])
    #expect(!ClaudeQuestionAnswerPolicy.accepts(request: request, answer: answer))
    #expect(ClaudeQuestionAnswerPolicy.hookOutput(toolInput: input, request: request, answer: answer) == nil)
}

@Test func singleAnswerRecordsStayReadableByEitherHelperVersion() throws {
    let request = try multiRequest(input: ["questions": [["question": "Ship?", "options": [["label": "Yes"]]]]])
    let single = ClaudeQuestionAnswer(requestID: request.requestID, installationID: request.installationID,
                                      sourceScope: request.sourceScope, eventDirectory: request.eventDirectory,
                                      sessionID: request.sessionID, promptID: request.promptID,
                                      toolUseID: request.toolUseID, kind: .option, answer: "Yes", decidedAt: 11)
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(single)) as? [String: Any])
    // A helper built before #382 reads `kind` and `answer` only.
    #expect(encoded["kind"] as? String == "option")
    #expect(encoded["answer"] as? String == "Yes")
    #expect(try JSONDecoder().decode(ClaudeQuestionAnswer.self, from: JSONEncoder().encode(single)) == single)
    // A record written by an app built before #382 decodes as a one-answer set.
    var legacy = encoded
    legacy["answers"] = nil
    let decoded = try JSONDecoder().decode(ClaudeQuestionAnswer.self,
                                           from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.answers == [ClaudeQuestionAnswerEntry(kind: .option, answer: "Yes")])

    // A set carries no single `answer`, so an older helper fails to decode it and sends nothing.
    let multi = multiAnswer(for: try multiRequest(), completeSet)
    let multiEncoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(multi)) as? [String: Any])
    #expect(multiEncoded["answer"] == nil && multiEncoded["kind"] == nil)
    #expect(try JSONDecoder().decode(ClaudeQuestionAnswer.self, from: JSONEncoder().encode(multi)) == multi)
    // Legacy fields that disagree with the set make the record unreadable rather than ambiguous.
    var conflicting = encoded
    conflicting["answer"] = "No"
    #expect((try? JSONDecoder().decode(ClaudeQuestionAnswer.self,
                                       from: JSONSerialization.data(withJSONObject: conflicting))) == nil)
}

@Test func helperAcceptsOneCompleteSetAndRefusesLateOrRepeatedSets() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-multi-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let request = try multiRequest(publishedAt: now - 0.05, expiresAt: now + 1,
                                   eventDirectory: directory.standardizedFileURL.path)
    #expect(ClaudeQuestionStore.publish(request, in: directory))
    #expect(ClaudeQuestionStore.pending(in: directory, installationID: "install-1", observingSince: now - 1,
                                        now: now).map(\.requestID) == [request.requestID])
    #expect(ClaudeQuestionStore.publish(ClaudeQuestionReceipt(requestID: request.requestID, installationID: "install-1",
                                                              sourceScope: "/root",
                                                              eventDirectory: request.eventDirectory,
                                                              receivedAt: now - 0.02, expiresAt: request.expiresAt),
                                        in: directory))
    let answer = multiAnswer(for: request, completeSet, decidedAt: now - 0.01)
    #expect(ClaudeQuestionStore.publish(answer, in: directory))
    // A second set for the same request never replaces the first.
    #expect(!ClaudeQuestionStore.publish(multiAnswer(for: request, completeSet, decidedAt: now), in: directory))
    let accepted = ClaudeQuestionHelper.awaitAnswer(for: request, in: directory, connectionTimeout: 0.2, answerTimeout: 0.2)
    #expect(accepted == answer)

    // A set decided after the window answers nothing.
    let lateDirectory = directory.appendingPathComponent("late", isDirectory: true)
    try FileManager.default.createDirectory(at: lateDirectory, withIntermediateDirectories: true)
    let late = try multiRequest(publishedAt: now - 0.05, expiresAt: now + 0.1,
                                eventDirectory: lateDirectory.standardizedFileURL.path)
    #expect(ClaudeQuestionStore.publish(late, in: lateDirectory))
    #expect(ClaudeQuestionStore.publish(ClaudeQuestionReceipt(requestID: late.requestID, installationID: "install-1",
                                                              sourceScope: "/root", eventDirectory: late.eventDirectory,
                                                              receivedAt: now - 0.02, expiresAt: late.expiresAt),
                                        in: lateDirectory))
    #expect(ClaudeQuestionStore.publish(multiAnswer(for: late, completeSet, decidedAt: now + 5), in: lateDirectory))
    #expect(ClaudeQuestionHelper.awaitAnswer(for: late, in: lateDirectory, connectionTimeout: 0.2, answerTimeout: 0.2) == nil)
}

// MARK: The card's step-through selection (`ClaudeQuestionCallSelection`)

private let cardPrompts = [
    QuestionPrompt(header: "Format", question: "Which format?", options: ["CSV", "JSON lines (Recommended)"]),
    QuestionPrompt(header: "Scope", question: "Which sessions?", options: ["Codex CLI", "Claude", "Codex app"],
                   multiSelect: true),
    QuestionPrompt(header: "Notify", question: "Notify you?", options: ["Yes", "No"])
]

@Test func pickingOnlySelectsAndNextKeepsTheAnswerWithoutSendingIt() {
    var card = ClaudeQuestionCallSelection(prompts: cardPrompts)
    #expect(card.current == 0)
    #expect(card.primary(viewed: 0) == .next(enabled: false))
    #expect(card.answers(prompts: cardPrompts) == nil)
    card = card.toggling(1, at: 0)
    #expect(card.primary(viewed: 0) == .next(enabled: true))
    #expect(card.answers(prompts: cardPrompts) == nil)
    card = card.advancing(from: 0)
    // Next only moves the card's default view on; the selection stays and nothing is sent.
    #expect(card.current == 1)
    #expect(card.selection(at: 0).options == [1])
    #expect(card.answers(prompts: cardPrompts) == nil)
    // Next from the last question has nowhere to go.
    #expect(card.advancing(from: 2) == card)
}

// #388: a Claude card is answered in any order, however the user reached each question.
@Test func everyQuestionIsAnswerableInAnyOrderWithoutNext() {
    var card = ClaudeQuestionCallSelection(prompts: cardPrompts)
    #expect((0..<3).allSatisfy(card.canSelect(question:)))
    #expect(!card.canSelect(question: 3) && !card.canSelect(question: -1))
    // Select Q1, view Q2 by the arrow (no Next), and tick Q2's options.
    card = card.toggling(1, at: 0)
    card = card.toggling(0, at: 1).toggling(1, at: 1)
    #expect(card.current == 0)
    #expect(card.selection(at: 1).options == [0, 1])
    // A question beyond the call changes nothing.
    #expect(card.toggling(0, at: 3) == card)
    #expect(card.primary(viewed: 2) == .send(enabled: false))
    card = card.typing("Only on failure", at: 2)
    #expect(card.primary(viewed: 2) == .send(enabled: true))
    #expect(card.answers(prompts: cardPrompts) == [
        ClaudeQuestionAnswerEntry(kind: .option, answer: "JSON lines (Recommended)"),
        ClaudeQuestionAnswerEntry(kind: .multiSelect, answer: "Codex CLI, Claude"),
        ClaudeQuestionAnswerEntry(kind: .text, answer: "Only on failure")
    ])
}

@Test func answeringBackwardsStillSendsInQuestionOrder() {
    let card = ClaudeQuestionCallSelection(prompts: cardPrompts)
        .toggling(1, at: 2).typing("All of them", at: 1).toggling(0, at: 0)
    #expect(card.answers(prompts: cardPrompts) == [
        ClaudeQuestionAnswerEntry(kind: .option, answer: "CSV"),
        ClaudeQuestionAnswerEntry(kind: .text, answer: "All of them"),
        ClaudeQuestionAnswerEntry(kind: .option, answer: "No")
    ])
}

@Test func sendStaysDisabledWhileAnyQuestionIsUnanswered() {
    let empty = ClaudeQuestionCallSelection(prompts: cardPrompts)
    let partials = [
        empty.toggling(0, at: 1).toggling(0, at: 2),             // Q1 missing
        empty.toggling(0, at: 0).toggling(0, at: 2),             // Q2 missing
        empty.toggling(0, at: 0).toggling(0, at: 1),             // Q3 missing
        empty.toggling(0, at: 0).typing("   ", at: 1).toggling(0, at: 2) // blank text is no answer
    ]
    for partial in partials {
        #expect(partial.primary(viewed: 2) == .send(enabled: false))
        #expect(partial.answers(prompts: cardPrompts) == nil)
    }
    // Send is only ever the last question's button; earlier ones offer Next, never Send.
    let complete = empty.toggling(0, at: 0).toggling(0, at: 1).toggling(0, at: 2)
    #expect(complete.primary(viewed: 0) == .next(enabled: true))
    #expect(complete.primary(viewed: 1) == .next(enabled: true))
    #expect(complete.primary(viewed: 2) == .send(enabled: true))
    // Next is enabled only while the viewed question has an answer; an unanswered one can still be
    // left by the arrows or the rail.
    #expect(empty.toggling(0, at: 2).primary(viewed: 0) == .next(enabled: false))
}

@Test func changingAnEarlierAnswerAfterLaterOnesKeepsTheRest() {
    var card = ClaudeQuestionCallSelection(prompts: cardPrompts)
        .toggling(0, at: 0).toggling(2, at: 1).toggling(0, at: 2)
    card = card.toggling(1, at: 0)
    #expect(card.answers(prompts: cardPrompts) == [
        ClaudeQuestionAnswerEntry(kind: .option, answer: "JSON lines (Recommended)"),
        ClaudeQuestionAnswerEntry(kind: .multiSelect, answer: "Codex app"),
        ClaudeQuestionAnswerEntry(kind: .option, answer: "Yes")
    ])
    // Emptying an earlier answer leaves a partial set, which is never sent.
    let emptied = card.toggling(2, at: 1)
    #expect(emptied.primary(viewed: 2) == .send(enabled: false))
    #expect(emptied.answers(prompts: cardPrompts) == nil)
    // A typed answer replaces options and vice versa, per question.
    let typed = card.typing("All of them", at: 1)
    #expect(typed.selection(at: 1).options.isEmpty)
    #expect(typed.answers(prompts: cardPrompts)?[1] == ClaudeQuestionAnswerEntry(kind: .text, answer: "All of them"))
}

@Test func theRailShowsEachQuestionsCurrentAnswer() {
    let card = ClaudeQuestionCallSelection(prompts: cardPrompts)
        .toggling(0, at: 1).toggling(1, at: 1).typing("Only on failure", at: 2)
    // No Next was pressed: the rail still shows what each question holds, and nothing for Q1.
    #expect(card.railAnswer(at: 0, labels: cardPrompts[0].options) == nil)
    #expect(card.railAnswer(at: 1, labels: cardPrompts[1].options) == .text("Codex CLI, Claude"))
    #expect(card.railAnswer(at: 2, labels: cardPrompts[2].options) == .text("Only on failure"))
    #expect(card.toggling(1, at: 0).railAnswer(at: 0, labels: cardPrompts[0].options) == .option(1))
    // A step that holds an answer is marked answered on the rail, whatever its position.
    let steps = QuestionSteps.make(cardPrompts, current: card.current, viewed: 2, currentStatus: nil,
                                   answeredWhenHeld: true) { card.railAnswer(at: $0, labels: cardPrompts[$0].options) }
    #expect(steps.steps.map(\.state) == [.upcoming, .answered, .current])
    #expect(steps.steps.map(\.summary) == [nil, "Codex CLI, Claude", "Only on failure"])
}

@Test func aSingleQuestionCallSendsAsBefore() {
    let prompt = [QuestionPrompt(header: nil, question: "Ship?", options: ["Yes", "No"])]
    let card = ClaudeQuestionCallSelection(prompts: prompt)
    #expect(card.primary(viewed: 0) == .send(enabled: false))
    let picked = card.toggling(0, at: 0)
    #expect(picked.primary(viewed: 0) == .send(enabled: true))
    #expect(picked.advancing(from: 0) == picked)
    #expect(picked.answers(prompts: prompt) == [ClaudeQuestionAnswerEntry(kind: .option, answer: "Yes")])
    // Answers checked against a different call's questions are refused.
    #expect(picked.answers(prompts: cardPrompts) == nil)
}
