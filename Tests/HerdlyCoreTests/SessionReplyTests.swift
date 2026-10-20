import Foundation
import Testing
@testable import HerdlyCore

// A reply typed on a completion card starts a new turn on that exact thread through the app-server
// daemon (`turn/start`, per the schema the installed CLI generates). The Ghostty key relay carries
// digits only (ADR 0006), so a session the daemon does not hold has no reply path at all.

private let session = UUID(uuidString: "01A09D9B-7642-7B51-BCCE-9B66CFE5361F")!
private let turn = UUID(uuidString: "01A09DB7-0C51-7F33-9EBC-4E44F91DF22C")!

private func completion(source: AttentionSource = .cli, session: UUID = session) -> AttentionCompletion {
    AttentionCompletion(source: source, session: session, turn: turn, arrivedAt: 100)
}

private func reachable(_ session: UUID = session) -> SessionReplyAvailability {
    SessionReplyAvailability(daemonConnected: true, daemonThreads: [session])
}

@Test func aLoadedThreadIsTheReplyTarget() {
    #expect(SessionReplyRouting.target(for: completion(), availability: reachable()) == .daemon(thread: session))
    // A desktop thread on the same daemon is replied to the same way; the source is a label only.
    #expect(SessionReplyRouting.target(for: completion(source: .desktop), availability: reachable()) == .daemon(thread: session))
}

@Test func anUnreachableSessionDisablesTheFieldAndSaysWhy() {
    let noDaemon = SessionReplyAvailability(daemonConnected: false, daemonThreads: [session])
    #expect(SessionReplyRouting.target(for: completion(), availability: noDaemon) == .unavailable(.noDaemon))
    let notLoaded = SessionReplyAvailability(daemonConnected: true, daemonThreads: [])
    #expect(SessionReplyRouting.target(for: completion(), availability: notLoaded) == .unavailable(.threadNotLoaded))
    let ended = SessionReplyAvailability(daemonConnected: true, daemonThreads: [session], endedSessions: [session])
    #expect(SessionReplyRouting.target(for: completion(), availability: ended) == .unavailable(.sessionEnded))
    // A session that started another turn is ambiguous: the reply would land in an unknown place.
    let working = SessionReplyAvailability(daemonConnected: true, daemonThreads: [session], workingSessions: [session])
    #expect(SessionReplyRouting.target(for: completion(), availability: working) == .unavailable(.sessionWorking))
    // Every reason is a sentence the card can show.
    for rejection in [SessionReplyPolicy.Rejection.noDaemon, .threadNotLoaded, .sessionEnded, .sessionWorking,
                      .notInQueue, .emptyText, .textTooLong, .notReady] {
        #expect(!SessionReplyPolicy.message(for: rejection).isEmpty)
    }
    #expect(SessionReplyTarget.daemon(thread: session).isReachable)
    #expect(SessionReplyTarget.unavailable(.noDaemon).isReachable == false)
    // The daemon's own refusal is quoted, and the card still says Herdly will not try again.
    #expect(SessionReplyPolicy.daemonRefused("no rollout found").contains("no rollout found"))
    #expect(SessionReplyPolicy.daemonRefused(nil).contains("will not retry"))
}

@Test func aSessionBlockedOnAQuestionCountsAsInATurn() {
    // Its running row is withheld from the display, but Codex is mid-turn: a reply target like this
    // is ambiguous, so the queue reports sessions in a turn rather than sessions shown as working.
    // The finished turn is the card; a later turn of the same session is the one blocked.
    let next = UUID(uuidString: "01A09DC4-1F22-7AA4-8C31-5B71A0C24D10")!
    var queue = AttentionQueue()
    queue.apply(completions: [completion()], running: [AttentionRunning(source: .cli, session: session, turn: next, arrivedAt: 100)])
    queue.apply(questions: [AttentionQuestion(source: .cli, session: session, turn: next, callID: "call_1", arrivedAt: 101,
                                              prompts: [QuestionPrompt(header: "H", question: "Which?", options: ["A", "B"])])])
    #expect(queue.items.contains { $0.kind == .running } == false)
    #expect(queue.sessionsInTurn == [session])
    let availability = SessionReplyAvailability(daemonConnected: true, daemonThreads: [session],
                                                workingSessions: queue.sessionsInTurn)
    #expect(SessionReplyRouting.target(for: completion(), availability: availability) == .unavailable(.sessionWorking))
}

@Test func turnStartCarriesOnlyTheThreadAndTheUsersText() {
    let params = SessionReplyRequest.params(thread: session, text: "  now add tests  ")
    #expect(SessionReplyRequest.method == "turn/start")
    #expect(params?["threadId"] as? String == session.uuidString.lowercased())
    let input = params?["input"] as? [[String: Any]]
    #expect(input?.count == 1)
    #expect(input?.first?["type"] as? String == "text")
    // The text is trimmed and sent verbatim; Herdly overrides no model, sandbox, or approval policy.
    #expect(input?.first?["text"] as? String == "now add tests")
    #expect(Set(params?.keys ?? Dictionary<String, Any>().keys) == ["threadId", "input"])
    #expect(SessionReplyRequest.params(thread: session, text: "   ") == nil)
}

@Test func oneReplyIsSentOnceAndNeverResent() {
    var progress = SessionReplyProgress(completion: completion().id)
    let plan = SessionReplySending.prepare(completion: completion(), availability: reachable(), progress: progress, text: "now add tests")
    guard case let .sending(next) = plan.outcome else { Issue.record("expected a send"); return }
    #expect(plan.params?["threadId"] as? String == session.uuidString.lowercased())
    #expect(next.phase == .sending("now add tests"))
    progress = next
    // A second click while the first is in flight sends nothing.
    let again = SessionReplySending.prepare(completion: completion(), availability: reachable(), progress: progress, text: "and lint")
    #expect(again.outcome == .refused(.notReady))
    #expect(again.params == nil)
    // Nor after the daemon accepted it: one card sends one reply.
    progress = progress.recordingSent(at: 200)
    #expect(progress.phase == .sent(text: "now add tests", at: 200))
    let third = SessionReplySending.prepare(completion: completion(), availability: reachable(), progress: progress, text: "and lint")
    #expect(third.outcome == .refused(.notReady))
    #expect(third.params == nil)
}

@Test func nothingIsSentForAnAbsentCompletionOrUnusableText() {
    let progress = SessionReplyProgress(completion: completion().id)
    // The completion left the queue since the card rendered.
    #expect(SessionReplySending.prepare(completion: nil, availability: reachable(), progress: progress, text: "hi").outcome
            == .refused(.notInQueue))
    #expect(SessionReplySending.prepare(completion: completion(), availability: reachable(), progress: progress, text: "   ").outcome
            == .refused(.emptyText))
    let long = String(repeating: "x", count: SessionReplyPolicy.maximumText + 1)
    #expect(SessionReplySending.prepare(completion: completion(), availability: reachable(), progress: progress, text: long).outcome
            == .refused(.textTooLong))
    // An unreachable target refuses with its own reason, and writes nothing.
    let notLoaded = SessionReplyAvailability(daemonConnected: true, daemonThreads: [])
    let refused = SessionReplySending.prepare(completion: completion(), availability: notLoaded, progress: progress, text: "hi")
    #expect(refused.outcome == .refused(.threadNotLoaded))
    #expect(refused.params == nil)
}

@Test func aSentReplyWaitsForCodexToRecordTheTurn() {
    var progress = SessionReplyProgress(completion: completion().id).startingSend(text: "now add tests").recordingSent(at: 200)
    // Nothing observed yet: the card keeps waiting inside the confirmation window.
    progress = progress.observing(sessionWorking: false, at: 205)
    #expect(progress.phase == .sent(text: "now add tests", at: 200))
    // The next turn start is the confirmation: the session is working again.
    let confirmed = progress.observing(sessionWorking: true, at: 206)
    #expect(confirmed.phase == .working(text: "now add tests"))
    #expect(confirmed.isFinished)
    // No turn inside the window: unconfirmed for good, and never resent.
    let quiet = progress.observing(sessionWorking: false, at: 200 + SessionReplyProgress.confirmationWindow)
    #expect(quiet.phase == .unconfirmed(text: "now add tests", sentAt: 200))
    #expect(quiet.isFinished)
    // A turn that starts late still confirms what Herdly sent.
    #expect(quiet.observing(sessionWorking: true, at: 400).phase == .working(text: "now add tests"))
    // Waiting never turns into another send.
    #expect(SessionReplySending.prepare(completion: completion(), availability: reachable(), progress: quiet, text: "again").outcome
            == .refused(.notReady))
}

@Test func aRefusedWriteIsTerminalAndNeverRetried() {
    let progress = SessionReplyProgress(completion: completion().id).startingSend(text: "now add tests")
        .recordingFailure("Could not write to Codex's daemon.")
    #expect(progress.phase == .failed("Could not write to Codex's daemon."))
    #expect(progress.isFinished)
    #expect(SessionReplySending.prepare(completion: completion(), availability: reachable(), progress: progress, text: "now add tests").outcome
            == .refused(.notReady))
    // A failure is only ever recorded for a send that was under way.
    #expect(SessionReplyProgress(completion: completion().id).recordingFailure("x").phase == .ready)
    #expect(SessionReplyProgress(completion: completion().id).recordingSent(at: 1).phase == .ready)
}

@Test func sendingAReplyDoesNotAcknowledgeTheCompletion() {
    var queue = AttentionQueue()
    queue.apply(completions: [completion()])
    #expect(queue.items.contains { $0.id == .completion(completion().id) })
    let progress = SessionReplyProgress(completion: completion().id).startingSend(text: "now add tests").recordingSent(at: 200)
    #expect(progress.isFinished == false)
    // The reply changes nothing about the queue: the completion is cleared only by dismissal or a
    // verified visit, exactly as before.
    #expect(queue.items.contains { $0.id == .completion(completion().id) })
    #expect(queue.acknowledgedCompletions.isEmpty)
    queue.dismiss(.completion(completion().id))
    #expect(queue.items.isEmpty)
    #expect(queue.acknowledgedCompletions.contains(completion().id))
}

// #271: a reply whose turn started and finished between two scans was never seen working, and the
// card said Codex had not started a turn. The session's turn-start record after the send confirms it.
@Test func aTurnThatStartedAndFinishedBetweenScansConfirmsTheReply() {
    // Clicked at 1000.4, the daemon answered at 1000.6; the hook dates its record to the whole second.
    let sent = SessionReplyProgress(completion: completion().id).startingSend(text: "kilo", at: 1000.4).recordingSent(at: 1000.6)
    let turnStart = RolloutTimestamp.parse("1970-01-01T00:16:40Z")!   // 1000, whole seconds
    // Never seen working: the turn was over by the next scan. Its start record is the confirmation.
    #expect(sent.observing(sessionWorking: false, latestTurnStart: turnStart, at: 1003).phase == .working(text: "kilo"))
    // Still confirmed when the record is first read after the window passed.
    #expect(sent.observing(sessionWorking: false, latestTurnStart: turnStart, at: 1020).phase == .working(text: "kilo"))
    // An unconfirmed card that later reads the record is confirmed too, and never resent.
    let quiet = sent.observing(sessionWorking: false, latestTurnStart: nil, at: 1011)
    #expect(quiet.phase == .unconfirmed(text: "kilo", sentAt: 1000.6))
    #expect(quiet.observing(sessionWorking: false, latestTurnStart: turnStart, at: 1030).phase == .working(text: "kilo"))
}

@Test func onlyATurnStartedBeforeTheSendLeavesTheReplyUnconfirmed() {
    let sent = SessionReplyProgress(completion: completion().id).startingSend(text: "kilo", at: 1000.4).recordingSent(at: 1000.6)
    // The completed turn the card is about started long before; one second before the send is earlier too.
    for earlier in [Double(700), 999] {
        let waiting = sent.observing(sessionWorking: false, latestTurnStart: earlier, at: 1005)
        #expect(waiting.phase == .sent(text: "kilo", at: 1000.6))
        let quiet = sent.observing(sessionWorking: false, latestTurnStart: earlier,
                                   at: 1000.6 + SessionReplyProgress.confirmationWindow)
        #expect(quiet.phase == .unconfirmed(text: "kilo", sentAt: 1000.6))
        #expect(quiet.isFinished)
        #expect(quiet.observing(sessionWorking: false, latestTurnStart: earlier, at: 2000).phase == quiet.phase)
    }
    // An unreadable start time confirms nothing.
    #expect(sent.observing(sessionWorking: false, latestTurnStart: .nan, at: 1011).phase
            == .unconfirmed(text: "kilo", sentAt: 1000.6))
    // Without a recorded send start, the second the reply counted as sent is the bound.
    let unanchored = SessionReplyProgress(completion: completion().id).startingSend(text: "kilo").recordingSent(at: 1000.6)
    #expect(unanchored.observing(sessionWorking: false, latestTurnStart: 1000, at: 1001).phase == .working(text: "kilo"))
    #expect(unanchored.observing(sessionWorking: false, latestTurnStart: 999, at: 1001).phase == .sent(text: "kilo", at: 1000.6))
}

// The turn starts a reply is confirmed by: each session's UserPromptSubmit records, read both as CLI
// events and by the hook reader that decodes every record whatever surface the scan classified the
// session as, so a reclassified session still confirms (#271).
@Test func replyTurnStartsAreEachSessionsLatestPromptRecord() {
    let other = UUID(uuidString: "01A11611-0AE8-7042-9F19-FD36707AB5D6")!
    let next = UUID(uuidString: "01A13417-F3AF-7452-AC9D-67D0BB79846A")!
    let cli: [CLIEvent] = [.turnStarted(session: session, turn: turn, receivedAt: "2026-10-13T07:05:19Z"),
                           .turnCompleted(session: session, turn: turn, receivedAt: "2026-10-13T07:05:22Z"),
                           .turnStarted(session: other, turn: turn, receivedAt: "not a time")]
    let hooks: [DesktopEvent] = [.promptSubmitted(session: session, turn: next, prompt: "kilo", receivedAt: "2026-10-13T07:09:07Z"),
                                 .turnCompleted(session: session, turn: next, receivedAt: "2026-10-13T07:09:10Z"),
                                 .toolStarted(session: other, turn: next, useID: "t", action: nil, capturedAt: 1_791_875_400)]
    let starts = ReplyTurnStarts.latest(cliEvents: cli, hookEvents: hooks)
    // The later prompt wins; a turn's end, a tool call and an unreadable time start nothing.
    #expect(starts == [session: RolloutTimestamp.parse("2026-10-13T07:09:07Z")!])
    #expect(ReplyTurnStarts.latest(cliEvents: cli, hookEvents: [])[session] == RolloutTimestamp.parse("2026-10-13T07:05:19Z"))
}
