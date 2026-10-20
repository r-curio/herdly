import Foundation
import Testing
@testable import HerdlyCore

// ADR 0010: Codex question options relayed as herdr pane keys.

private let session = UUID(uuidString: "01A09D9B-7642-7B51-BCCE-9B66CFE5361F")!
private let turn = UUID(uuidString: "01A09DB7-0C51-7F33-9EBC-4E44F91DF22C")!
private let pane = "w1:p1"
private let target = HerdrPaneTarget(sessionID: session.uuidString.lowercased(), agent: .codex, paneID: pane)

private let twoOptions = QuestionPrompt(id: "q1", header: "Shape", question: "Which?", options: ["Flexible", "Same"])
private let threeOptions = QuestionPrompt(id: "q2", header: "Scope", question: "Scope?", options: ["Lookup", "Checkout", "Both"])

private func question(_ prompts: [QuestionPrompt] = [twoOptions], callID: String = "call_1") -> AttentionQuestion {
    AttentionQuestion(source: .cli, session: session, turn: turn, callID: callID, arrivedAt: 100, prompts: prompts)
}

private func pending(_ question: AttentionQuestion) -> ReminderReader.RolloutEvidence {
    var evidence = ReminderReader.RolloutEvidence()
    evidence.pendingQuestions = [question]
    return evidence
}

private func scan(status: HerdrAgentStatus = .blocked, paneID: String = pane) -> HerdrScanOutcome {
    let herdrPane = HerdrPane(paneID: paneID, tabID: "w1:t1", workspaceID: "w1", focused: false, agent: "codex",
                              agentStatus: status, agentSession: nil, terminalTitle: nil)
    return .available(HerdrScan(snapshot: HerdrSnapshot(version: "0.9.3", protocolVersion: 22, focusedWorkspaceID: "w1",
                                                        focusedTabID: "w1:t1", focusedPaneID: paneID,
                                                        tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", focused: true,
                                                                        paneCount: 1)],
                                                        panes: [herdrPane],
                                                        layouts: [HerdrLayout(tabID: "w1:t1", zoomed: false, paneIDs: [paneID])]),
                                integration: HerdrIntegrationReport(states: [.codex: .current(version: 8)]),
                                client: .success(HerdrAttachedClient(pid: 1, tty: "ttys001", serverPID: 2)),
                                serverStartedAt: 10))
}

private func check(_ question: AttentionQuestion, evidence: ReminderReader.RolloutEvidence? = nil,
                   binding: HerdrSessionBinding = .bound(target), outcome: HerdrScanOutcome? = scan(),
                   spentPane: String = pane) -> Result<HerdrPaneTarget, HerdrQuestionRelayUnavailable> {
    HerdrQuestionRelay.preSendCheck(question: question, evidence: evidence ?? pending(question), binding: binding,
                                    outcome: outcome, spentPane: spentPane)
}

private func daemonBook(callID: String = "call_1") -> AppServerQuestionBook {
    var book = AppServerQuestionBook()
    _ = book.apply(message: ["jsonrpc": "2.0", "id": 7, "method": "item/tool/requestUserInput",
                             "params": ["threadId": session.uuidString.lowercased(), "turnId": turn.uuidString.lowercased(),
                                        "itemId": callID,
                                        "questions": [["id": "q1", "header": "Shape", "question": "Which?",
                                                       "options": [["label": "Flexible"], ["label": "Same"]]]]]],
                   now: 100)
    return book
}

private func route(_ question: AttentionQuestion, book: AppServerQuestionBook = AppServerQuestionBook(),
                   daemonConnected: Bool = false, ledger: QuestionRelayLedger = QuestionRelayLedger(),
                   progress: QuestionAnswerProgress? = nil,
                   herdr: HerdrSessionBinding = .bound(target)) -> QuestionAnswerRoute {
    QuestionRelayRouting.route(for: question, book: book, daemonConnected: daemonConnected, ledger: ledger,
                               progress: progress, herdr: herdr)
}

private func started(_ question: AttentionQuestion, progress: QuestionAnswerProgress? = nil,
                     ledger: QuestionRelayLedger = QuestionRelayLedger(), index: Int = 0,
                     option: Int = 1) throws -> HerdrQuestionRelay.Start {
    try HerdrQuestionRelay.start(current: question, progress: progress ?? QuestionAnswerProgress(call: question.id),
                                 ledger: ledger, ghosttyEnabled: true, pane: pane, question: index, option: option).get()
}

// MARK: - Payload and eligibility

@Test func aClickBecomesOneDigitWithoutEnter() throws {
    let call = question()
    let start = try started(call, option: 1)
    #expect(start.key == "2")
    #expect(start.pane == pane)
    #expect(start.progress.phase == .sending)
    #expect(start.ledger.keyRoute(for: call.id) == .herdr(paneID: pane))
    #expect(start.ledger.hasSpent(call.id, question: 0))
    #expect(HerdrQuestionRelay.key(forOption: 7) == "8")
    #expect(HerdrQuestionRelay.key(forOption: 8) == nil)
    #expect(HerdrQuestionRelay.key(forOption: -1) == nil)
}

@Test func noKeyForASecretQuestion() {
    let secret = QuestionPrompt(header: "Token", question: "Paste it", options: ["a", "b"], isSecret: true)
    let call = question([secret])
    let result = HerdrQuestionRelay.start(current: call, progress: QuestionAnswerProgress(call: call.id),
                                          ledger: QuestionRelayLedger(), ghosttyEnabled: true, pane: pane,
                                          question: 0, option: 0)
    #expect(result == .failure(.policy(.notOfferable)))
    guard case .continueInCodex = QuestionAnswerProgress.offer(call, at: 0) else {
        Issue.record("a secret question must stay in Codex"); return
    }
}

@Test func isSecretIsParsedFromTheRolloutArguments() throws {
    let prompts = try #require(QuestionPrompt.parse(arguments: #"{"questions":[{"id":"t","question":"Key?","isSecret":true,"options":[{"label":"a"}]}]}"#))
    #expect(prompts.first?.isSecret == true)
    // Records written before the field existed decode as not secret.
    let legacy = #"{"options":["a"],"multiSelect":false,"truncated":false,"isOther":false,"optionsComplete":true}"#
    let decoded = try JSONDecoder().decode(QuestionPrompt.self, from: Data(legacy.utf8))
    #expect(decoded.isSecret == false)
}

@Test func noKeyForMoreThanEightOptions() throws {
    let nine = try #require(QuestionPrompt.parse(arguments: """
        {"questions":[{"question":"Pick","options":[\((1...9).map { #"{"label":"o\#($0)"}"# }.joined(separator: ","))]}]}
        """)).first!
    let call = question([nine])
    for option in [0, 8] {
        let result = HerdrQuestionRelay.start(current: call, progress: QuestionAnswerProgress(call: call.id),
                                              ledger: QuestionRelayLedger(), ghosttyEnabled: true, pane: pane,
                                              question: 0, option: option)
        #expect(result == .failure(.policy(.notOfferable)))
    }
}

@Test func noKeyWithoutAPaneOrWithGhosttyControlsOff() {
    let call = question()
    let fresh = QuestionAnswerProgress(call: call.id)
    #expect(HerdrQuestionRelay.start(current: call, progress: fresh, ledger: QuestionRelayLedger(), ghosttyEnabled: true,
                                     pane: nil, question: 0, option: 0) == .failure(.noPane))
    #expect(HerdrQuestionRelay.start(current: call, progress: fresh, ledger: QuestionRelayLedger(), ghosttyEnabled: false,
                                     pane: pane, question: 0, option: 0) == .failure(.policy(.ghosttyDisabled)))
}

// MARK: - Fresh check vetoes

@Test func freshCheckPassesOnlyForAPendingCallOnABlockedBoundPane() {
    #expect(check(question()) == .success(target))
}

@Test func rolloutOutputForTheCallVetoes() {
    let call = question()
    var evidence = ReminderReader.RolloutEvidence()
    evidence.answeredQuestions = [call.id]
    #expect(check(call, evidence: evidence) == .failure(.answeredInRollout))
}

@Test func anEndedTurnVetoes() {
    let call = question()
    for ended in [\ReminderReader.RolloutEvidence.completed, \.canceled] {
        var evidence = pending(call)
        evidence[keyPath: ended] = [TurnIdentity(session: session, turn: turn)]
        #expect(check(call, evidence: evidence) == .failure(.turnEnded))
    }
}

@Test func anUnreadableRolloutVetoes() {
    // Unreadable rollouts yield empty evidence, which is never "still pending".
    #expect(check(question(), evidence: ReminderReader.RolloutEvidence()) == .failure(.rolloutUnreadable))
}

@Test func anyAgentStatusButBlockedVetoes() {
    for status in [HerdrAgentStatus.idle, .working, .done, .unknown, .other("paused")] {
        #expect(check(question(), outcome: scan(status: status)) == .failure(.agentNotBlocked(status)))
    }
    // The pane missing from the fresh snapshot, or no snapshot at all.
    #expect(check(question(), outcome: scan(paneID: "w1:p9")) == .failure(.agentNotBlocked(nil)))
    #expect(check(question(), outcome: .unavailable(.timeout)) == .failure(.agentNotBlocked(nil)))
}

@Test func anUnavailableBindingVetoes() {
    #expect(check(question(), binding: .unavailable(.binding(.split))) == .failure(.binding(.binding(.split))))
    #expect(check(question(), binding: .unavailable(.herdr(.notRunning))) == .failure(.binding(.herdr(.notRunning))))
    #expect(check(question(), binding: .notInHerdr) == .failure(.leftHerdr))
    let moved = HerdrPaneTarget(sessionID: target.sessionID, agent: .codex, paneID: "w1:p2")
    #expect(check(question(), binding: .bound(moved), outcome: scan(paneID: "w1:p2")) == .failure(.paneChanged))
}

@Test func theRolloutVetoComesFirst() {
    // A manual answer is reported as such even when herdr is also unavailable.
    let call = question()
    var evidence = ReminderReader.RolloutEvidence()
    evidence.answeredQuestions = [call.id]
    #expect(check(call, evidence: evidence, binding: .unavailable(.notScanned)) == .failure(.answeredInRollout))
}

@Test func aVetoSendsNothingReleasesTheKeyAndKeepsTheTypedReason() throws {
    let call = question()
    let start = try started(call)
    let settled = HerdrQuestionRelay.settle(.vetoed(.agentNotBlocked(.working)), progress: start.progress,
                                            ledger: start.ledger, question: call, index: 0, option: 1, now: 200)
    #expect(settled.progress.phase == .failed(HerdrQuestionRelayUnavailable.agentNotBlocked(.working).message))
    #expect(settled.progress.picks.isEmpty)
    #expect(settled.ledger.keyRoute(for: call.id) == nil)
    #expect(settled.ledger.failure(for: call.id) == .agentNotBlocked(.working))
    // A failed card is never retried by a later click.
    let retry = HerdrQuestionRelay.start(current: call, progress: settled.progress, ledger: settled.ledger,
                                         ghosttyEnabled: true, pane: pane, question: 0, option: 1)
    #expect(retry == .failure(.policy(.notReady)))
}

// MARK: - Routes

@Test func theDaemonWinsWhenItHoldsTheCall() {
    let call = question()
    let book = daemonBook()
    guard case .daemon = route(call, book: book, daemonConnected: true) else {
        Issue.record("the daemon must win over herdr keys"); return
    }
    // Another call, or a disconnected daemon, leaves herdr keys.
    #expect(route(question(callID: "call_2"), book: book, daemonConnected: true) == .herdrRelay)
    #expect(route(call, book: book, daemonConnected: false) == .herdrRelay)
}

@Test func routeLockKeepsAKeyedCallOnHerdrKeysWhenTheDaemonArrives() throws {
    let call = question([twoOptions, threeOptions])
    let start = try started(call)
    let settled = HerdrQuestionRelay.settle(.delivered(.queued), progress: start.progress, ledger: start.ledger,
                                            question: call, index: 0, option: 1, now: 200)
    #expect(route(call, book: daemonBook(), daemonConnected: true, ledger: settled.ledger,
                  progress: settled.progress) == .herdrRelay)
    // Even when herdr is unavailable now, the call does not move routes; the send then fails closed.
    #expect(route(call, ledger: settled.ledger, progress: settled.progress, herdr: .unavailable(.notScanned)) == .herdrRelay)
    #expect(route(call, ledger: settled.ledger, progress: settled.progress, herdr: .notInHerdr) == .herdrRelay)
}

@Test func routeLockKeepsADaemonAnswerOffKeys() {
    let call = question([twoOptions, threeOptions])
    var book = daemonBook()
    // A drafted daemon answer, then the daemon disconnects: keys would hit the wrong question.
    let drafted = QuestionAnswerProgress(call: call.id).recordingDraft(question: 0, answer: .option(0))
    book.disconnect()
    #expect(route(call, book: book, daemonConnected: false, progress: drafted)
            == .relayUnavailable(.daemonAnswerInProgress))
    // A call answered through the daemon stays there.
    var answered = daemonBook()
    answered.markAnswered(answered.pendingRequests[0])
    #expect(route(call, book: answered, daemonConnected: true) == .daemonAnswered)
}

@Test func aCodexQuestionInAHostWithoutDigitsIsAnsweredInCodex() {
    // ADR 0017: Terminal.app types no question digits, because `do script`'s newline could answer the
    // next question. The daemon still wins; a session also bound in herdr is withheld too, since a herdr
    // key needs the title unique across the enabled hosts.
    let call = question()
    func terminalRoute(book: AppServerQuestionBook = AppServerQuestionBook(), daemonConnected: Bool = false,
                       herdr: HerdrSessionBinding = .notInHerdr) -> QuestionAnswerRoute {
        QuestionRelayRouting.route(for: call, book: book, daemonConnected: daemonConnected, ledger: QuestionRelayLedger(),
                                   progress: nil, herdr: herdr, terminalHost: .terminalApp)
    }
    #expect(terminalRoute() == .relayUnavailable(.noQuestionKeys(.terminalApp)))
    #expect(QuestionRelayRouting.route(for: call, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       terminalHost: .iTerm2) == .relayUnavailable(.noQuestionKeys(.iTerm2)))
    guard case .daemon = terminalRoute(book: daemonBook(), daemonConnected: true) else {
        Issue.record("the daemon must win"); return
    }
    // A herdr key needs the title unique across the enabled hosts too.
    #expect(terminalRoute(herdr: .bound(target)) == .relayUnavailable(.noQuestionKeys(.terminalApp)))
    #expect(HerdrQuestionRelayUnavailable.noQuestionKeys(.iTerm2).message == "Herdly can't type into iTerm2. Reply in the session.")
    #expect(HerdrQuestionRelayUnavailable.noQuestionKeys(.terminalApp).message == "Answer this in Codex.")
    #expect(HerdrPresentation.relayUnavailableLine(for: .noQuestionKeys(.terminalApp)) == "Answer this in Codex.")
    // Another host's digits never go to Ghostty: a host without digits says so, and WezTerm, whose digits
    // were proven live (#245), uses its own pane's relay.
    for host: TerminalHost in [.tmux, .zellij, .iTerm2, .terminalApp] {
        #expect(QuestionRelayRouting.route(for: call, book: AppServerQuestionBook(), daemonConnected: false,
                                           ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                           terminalHost: host) == .relayUnavailable(.noQuestionKeys(host)))
    }
    #expect(QuestionRelayRouting.route(for: call, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       terminalHost: .wezTerm) == .terminalRelay)
    // An enabled host that is unread or unreadable could hold the session: no Ghostty key.
    #expect(QuestionRelayRouting.route(for: call, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       unreadHost: .terminalApp) == .relayUnavailable(.otherHostUnreadable(.terminalApp)))
    // A Ghostty session keeps its own key relay.
    #expect(QuestionRelayRouting.route(for: call, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       terminalHost: .ghostty) == .ghosttyRelay)
}

@Test func sessionsRouteByTheirHerdrBinding() {
    let call = question()
    #expect(route(call, herdr: .notInHerdr) == .ghosttyRelay)
    #expect(route(call, herdr: .bound(target)) == .herdrRelay)
    #expect(route(call, herdr: .unavailable(.ghosttyControlsOff)) == .relayUnavailable(.binding(.ghosttyControlsOff)))
    let desktop = AttentionQuestion(source: .desktop, session: session, turn: turn, callID: "call_1", arrivedAt: 1,
                                    prompts: [twoOptions])
    #expect(route(desktop) == .desktopPick)
    // A Ghostty-keyed call stays on Ghostty keys.
    var ledger = QuestionRelayLedger()
    let spentGhostty = ledger.spend(call.id, question: 0, route: .ghostty)
    #expect(spentGhostty)
    #expect(route(call, book: daemonBook(), daemonConnected: true, ledger: ledger) == .ghosttyRelay)
    let movedToHerdr = ledger.spend(call.id, question: 1, route: .herdr(paneID: pane))
    #expect(!movedToHerdr)
}

// MARK: - Progress, delivery and no resend

@Test func multiQuestionCallsAdvanceOneDigitPerQuestion() throws {
    let call = question([twoOptions, threeOptions])
    let first = try started(call, option: 0)
    #expect(first.key == "1")
    let afterFirst = HerdrQuestionRelay.settle(.delivered(.queued), progress: first.progress, ledger: first.ledger,
                                               question: call, index: 0, option: 0, now: 200)
    #expect(afterFirst.progress.questionIndex == 1)
    #expect(afterFirst.progress.phase == .ready)
    // The first question cannot be keyed again, and the second takes its own digit.
    #expect(HerdrQuestionRelay.start(current: call, progress: afterFirst.progress, ledger: afterFirst.ledger,
                                     ghosttyEnabled: true, pane: pane, question: 0, option: 1)
            == .failure(.policy(.wrongQuestion)))
    let second = try started(call, progress: afterFirst.progress, ledger: afterFirst.ledger, index: 1, option: 2)
    #expect(second.key == "3")
    let done = HerdrQuestionRelay.settle(.delivered(.queued), progress: second.progress, ledger: second.ledger,
                                         question: call, index: 1, option: 2, now: 210)
    #expect(done.progress.phase == .sent(at: 210))
    #expect(done.progress.picks == [0: 0, 1: 2])
}

@Test func oneKeyPerCallAndQuestionIndex() {
    let call = question()
    var ledger = QuestionRelayLedger()
    let first = ledger.spend(call.id, question: 0, route: .herdr(paneID: pane))
    let again = ledger.spend(call.id, question: 0, route: .herdr(paneID: pane))
    #expect(first)
    #expect(!again)
    let result = HerdrQuestionRelay.start(current: call, progress: QuestionAnswerProgress(call: call.id), ledger: ledger,
                                          ghosttyEnabled: true, pane: pane, question: 0, option: 0)
    #expect(result == .failure(.alreadySent))
}

@Test func aPossibleWriteCountsAsSentAndIsNeverResent() throws {
    let call = question()
    for delivery in [HerdrKeyDelivery.possiblySent(.timeout), .possiblySent(.notRunning), .possiblySent(.malformedReply)] {
        let start = try started(call)
        let settled = HerdrQuestionRelay.settle(.delivered(delivery), progress: start.progress, ledger: start.ledger,
                                                question: call, index: 0, option: 1, now: 300)
        #expect(settled.progress.phase == .sent(at: 300))
        #expect(settled.ledger.hasSpent(call.id, question: 0))
        #expect(HerdrQuestionRelay.start(current: call, progress: settled.progress, ledger: settled.ledger,
                                         ghosttyEnabled: true, pane: pane, question: 0, option: 1)
                == .failure(.policy(.notReady)))
    }
}

@Test func deliveryClassificationTreatsAnyFailureAfterTheWriteAsSent() {
    #expect(HerdrKeyDelivery.classify(.success(.accepted(type: "ok")), writeAttempted: true) == .queued)
    #expect(HerdrKeyDelivery.classify(.failure(.timeout), writeAttempted: true) == .possiblySent(.timeout))
    #expect(HerdrKeyDelivery.classify(.failure(.notRunning), writeAttempted: true) == .possiblySent(.notRunning))
    #expect(HerdrKeyDelivery.classify(.failure(.malformedReply), writeAttempted: true) == .possiblySent(.malformedReply))
    #expect(HerdrKeyDelivery.classify(.success(.pong(version: "x", protocolVersion: 22)), writeAttempted: true)
            == .possiblySent(.malformedReply))
    // Before any write, or an explicit herdr refusal: nothing was sent.
    #expect(HerdrKeyDelivery.classify(.failure(.timeout), writeAttempted: false) == .notSent(.timeout))
    #expect(HerdrKeyDelivery.classify(.failure(.untrustedSocket), writeAttempted: false) == .notSent(.untrustedSocket))
    #expect(HerdrKeyDelivery.classify(.failure(.requestRefused(code: "pane_not_found")), writeAttempted: true)
            == .notSent(.requestRefused(code: "pane_not_found")))
}

@Test func aCertainNotSentFailsWithoutLockingTheRoute() throws {
    let call = question()
    let start = try started(call)
    let settled = HerdrQuestionRelay.settle(.delivered(.notSent(.notRunning)), progress: start.progress,
                                            ledger: start.ledger, question: call, index: 0, option: 1, now: 300)
    guard case .failed = settled.progress.phase else { Issue.record("expected failed"); return }
    #expect(settled.ledger.keyRoute(for: call.id) == nil)
    #expect(settled.ledger.failure(for: call.id) == .herdrRefused(.notRunning))
}

@Test func theLastAnswerBecomesUnconfirmedAtTenSecondsWithAnExplicitClock() throws {
    let call = question()
    let start = try started(call)
    let sent = HerdrQuestionRelay.settle(.delivered(.queued), progress: start.progress, ledger: start.ledger,
                                         question: call, index: 0, option: 1, now: 1_000).progress
    #expect(sent.expiring(at: 1_009.999).phase == .sent(at: 1_000))
    #expect(sent.expiring(at: 1_010).phase == .unconfirmed(sentAt: 1_000))
    // Unconfirmed is final: it offers no buttons and never resends.
    let unconfirmed = sent.expiring(at: 1_010)
    #expect(!unconfirmed.offersButtons)
    #expect(unconfirmed.expiring(at: 2_000) == unconfirmed)
}

@Test func pruningForgetsCallsNoLongerWaiting() {
    let call = question()
    var ledger = QuestionRelayLedger()
    _ = ledger.spend(call.id, question: 0, route: .herdr(paneID: pane))
    ledger.recordFailure(.turnEnded, for: question(callID: "call_2").id)
    ledger.prune(keeping: [])
    #expect(ledger == QuestionRelayLedger())
}

// MARK: - Open fallback (ADR 0015)

@Test func herdrFallbackOpenNeverEnablesOrTargetsTheKeyRelay() {
    // Each of these bindings makes Open raise Ghostty (and the card keep Open), yet the relay's
    // fresh check still refuses: a fallback never makes a pane, tab or app an input target.
    let switches = TerminalHostSwitches(enabled: [.ghostty, .herdr])
    let reasons: [HerdrSessionUnavailable] = [
        .binding(.split), .binding(.multipleClients(2)), .binding(.nonGhosttyClient),
        .binding(.duplicateTitles(["w1:p1", "w1:p2"])), .herdr(.wrongClientCount(2)),
    ]
    for reason in reasons {
        let binding = HerdrSessionBinding.unavailable(reason)
        let open = HerdrOpenFallback.resolve(.binding(reason), agent: .codex, clientWalks: [.reached(.ghostty)],
                                             switches: switches, isRunning: { _ in true })
        if case .fellBack(.ghostty, _)? = open {} else { Issue.record("\(reason) did not fall back: \(String(describing: open))") }
        #expect(open?.acknowledges == false)
        #expect(HerdrPresentation.openAvailability(binding: binding, ttySupport: .supported) == .available)
        #expect(check(question(), binding: binding) == .failure(.binding(reason)), "\(reason)")
    }
}
