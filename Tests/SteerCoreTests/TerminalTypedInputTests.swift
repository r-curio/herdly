import Foundation
import Testing
@testable import SteerCore

// ADR 0017: typed input into the one bound pane, the second reply route beside the daemon's
// `turn/start`. Host-neutral; Terminal.app (#239) is its first host and types replies only, through
// `do script … in <tab>`, which always appends a newline (docs/evidence/terminal-app-live.md).

private let session = UUID(uuidString: "01A129B8-E8DD-7821-BABB-CDC0EFB2CEF6")!
private let turn = UUID(uuidString: "01A12A00-0C51-7F33-9EBC-4E44F91DF22C")!
private let tab = TerminalTabTarget(host: .terminalApp, tabID: "9882", tty: "/dev/ttys005")
private let pane = TypedInputPane(host: .terminalApp, paneID: "9882", tty: "/dev/ttys005")

private func completion() -> AttentionCompletion {
    AttentionCompletion(source: .cli, session: session, turn: turn, arrivedAt: 100)
}

private func availability(daemon: Bool = false, route: TerminalReplyRoute? = .pane(pane),
                          working: Set<UUID> = [], ended: Set<UUID> = []) -> SessionReplyAvailability {
    SessionReplyAvailability(daemonConnected: daemon, daemonThreads: daemon ? [session] : [],
                             endedSessions: ended, workingSessions: working,
                             terminalRoutes: route.map { [session: $0] } ?? [:])
}

// MARK: - Hosts and routes

@Test func onlyHostsWithAProvenSendTypeReplies() {
    // ADR 0017's table as built so far: Terminal.app replies only; iTerm2 never types. Other hosts
    // gain replies in their own tickets or live proofs.
    #expect(TerminalHost.terminalApp.typesReplies)
    #expect(!TerminalHost.terminalApp.typesQuestionDigits)
    #expect(!TerminalHost.iTerm2.typesReplies && !TerminalHost.iTerm2.typesQuestionDigits)
    #expect(!TerminalHost.ghostty.typesReplies && TerminalHost.ghostty.typesQuestionDigits)
    #expect(!TerminalHost.herdr.typesReplies && TerminalHost.herdr.typesQuestionDigits)
}

@Test func aReplyRouteNeedsTheExactBindingOnAHostThatTypesReplies() {
    #expect(TerminalReplyRoute.from(.bound(tab)) == .pane(pane))
    // No binding (split, no exact match, two hosts, unreadable) is unreachable: never a fallback target.
    for reason: TerminalTabUnavailable in [.split, .duplicateTitles(2), .duplicateTTYs(2), .hostUnreadable(.terminalApp),
                                           .titleNotFound, .ttyNotInEnabledHost, .foregroundProcesses(count: 0)] {
        #expect(TerminalReplyRoute.from(.unavailable(reason)) == .unreachable)
    }
    // iTerm2 has no typed input (Broadcast Input); its line names it.
    let iTerm = TerminalTabTarget(host: .iTerm2, tabID: "w0t0p0", tty: "/dev/ttys009")
    #expect(TerminalReplyRoute.from(.bound(iTerm)) == .hostCannotType(.iTerm2))
    // A Ghostty tab is left to the routes it already has.
    #expect(TerminalReplyRoute.from(.unavailable(.ttyUnknown(.ghostty))) == nil)
    #expect(TerminalReplyRoute.from(.bound(TerminalTabTarget(host: .ghostty, tabID: "w/t", tty: "/dev/ttys004"))) == nil)
}

@Test func theDaemonWinsWhenItHoldsTheThread() {
    #expect(SessionReplyRouting.target(for: completion(), availability: availability(daemon: true)) == .daemon(thread: session))
    #expect(SessionReplyRouting.target(for: completion(), availability: availability()) == .terminal(pane))
    #expect(SessionReplyTarget.terminal(pane).isReachable)
}

@Test func anUnboundSessionSaysSoWithoutPointingToSettings() {
    let unreachable = SessionReplyRouting.target(for: completion(), availability: availability(route: .unreachable))
    #expect(unreachable == .unavailable(.terminalUnreachable))
    #expect(SessionReplyPolicy.message(for: .terminalUnreachable) == "Steer can't reach this session's tab. Reply in the session.")
    #expect(SessionReplyPolicy.message(for: .hostCannotType(.iTerm2)) == "Steer can't type into iTerm2. Reply in the session.")
    // No typed route at all keeps the daemon's reasons.
    #expect(SessionReplyRouting.target(for: completion(), availability: availability(route: nil)) == .unavailable(.noDaemon))
    // An ended or working session is refused whatever route exists.
    #expect(SessionReplyRouting.target(for: completion(), availability: availability(working: [session]))
        == .unavailable(.sessionWorking))
    #expect(SessionReplyRouting.target(for: completion(), availability: availability(ended: [session]))
        == .unavailable(.sessionEnded))
}

// MARK: - Text and writes

@Test func typedRepliesAreOneLineOfPlainTextAndNeverACommand() {
    #expect(TypedReplyText.sendable("  now add tests  ") == .success("now add tests"))
    #expect(TypedReplyText.sendable("   ") == .failure(.emptyText))
    #expect(TypedReplyText.sendable(String(repeating: "a", count: 4001)) == .failure(.textTooLong))
    #expect(TypedReplyText.sendable(String(repeating: "a", count: 4000)) == .success(String(repeating: "a", count: 4000)))
    #expect(TypedReplyText.sendable("first\nsecond") == .failure(.notOneLine))
    #expect(TypedReplyText.sendable("tab\there") == .failure(.notOneLine))
    #expect(TypedReplyText.sendable("bell\u{07}") == .failure(.notOneLine))
    #expect(TypedReplyText.sendable("/compact") == .failure(.commandText))
    #expect(TypedReplyText.sendable("  !rm -rf build") == .failure(.commandText))
    #expect(!SessionReplyPolicy.message(for: .commandText).isEmpty)
    #expect(!SessionReplyPolicy.message(for: .notOneLine).isEmpty)
}

@Test func codexGetsTextThenASeparateSubmitAndClaudeGetsBothInOneWrite() {
    #expect(TypedReplyWrites.plan(agent: .codex, text: "now add tests") == [.text("now add tests"), .submit])
    #expect(TypedReplyWrites.plan(agent: .claude, text: "now add tests") == [.textAndSubmit("now add tests")])
    #expect(TypedReplyWrites.submitDelay == 1)
    // Terminal.app's `do script` appends the newline itself: Claude's one write submits; Codex's
    // text stays in its composer until a second, empty `do script`.
    #expect(TypedReplyWrites.plan(agent: .codex, text: "now add tests").map(TerminalAppInput.script) == ["now add tests", ""])
    #expect(TypedReplyWrites.plan(agent: .claude, text: "now add tests").map(TerminalAppInput.script) == ["now add tests"])
}

@Test func codexRepliesOnTheTerminalRouteArePlannedAsWritesNotParams() {
    let progress = SessionReplyProgress(completion: completion().id)
    let plan = SessionReplySending.prepare(completion: completion(), availability: availability(), progress: progress,
                                           text: " now add tests ")
    #expect(plan.params == nil)
    #expect(plan.terminal == SessionReplySending.TerminalSend(pane: pane, writes: [.text("now add tests"), .submit]))
    guard case let .sending(next) = plan.outcome else { Issue.record("expected a send"); return }
    #expect(next.route == .terminal(pane))
    // A command or a second line never leaves on the terminal route.
    let command = SessionReplySending.prepare(completion: completion(), availability: availability(), progress: progress,
                                              text: "/compact")
    #expect(command.outcome == .refused(.commandText))
    #expect(command.terminal == nil)
    // The daemon route keeps sending the text as params.
    let daemon = SessionReplySending.prepare(completion: completion(), availability: availability(daemon: true),
                                             progress: progress, text: "now add tests")
    #expect(daemon.params != nil && daemon.terminal == nil)
}

// MARK: - Delivery

@Test func aTabThatMovedOrGainedATabIsNotTypedInto() {
    // The script types nothing when the tab is no longer alone and unique in its window.
    #expect(TerminalAppInput.delivery(.reply(Data(#"{"status":"moved"}"#.utf8))) == .notWritten)
}

// MARK: - Ghostty question keys beside other enabled hosts (ADR 0013 freshness, ADR 0017 fresh check)

private let codexTitle = GhosttyMatch.title(session)
private let terminalOn = TerminalHostSwitches(enabled: [.ghostty, .terminalApp])

@Test func aGhosttyKeyNeedsFreshReadsOfEveryOtherEnabledHost() {
    let elsewhere = TerminalHostInventory.tabs([TerminalTab(tabID: "9882", tty: "/dev/ttys005", title: codexTitle, paneCount: 1)])
    let unrelated = TerminalHostInventory.tabs([TerminalTab(tabID: "9935", tty: "/dev/ttys019", title: "Terminal", paneCount: 1)])
    // The session's title in Terminal.app: a Ghostty tab with that title is a decoy, so no key.
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: terminalOn, fresh: [.terminalApp: elsewhere])
        == .noQuestionKeys(.terminalApp))
    // Unreadable or denied, or never read: fail closed.
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: terminalOn, fresh: [.terminalApp: .unreadable])
        == .otherHostUnreadable(.terminalApp))
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: terminalOn, fresh: [:])
        == .otherHostUnreadable(.terminalApp))
    // Not running, or no tab with the title: the key may go.
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: terminalOn, fresh: [.terminalApp: .notRunning]) == nil)
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: terminalOn, fresh: [.terminalApp: unrelated]) == nil)
    // Switched off: never read, unchanged behavior.
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: TerminalHostSwitches(enabled: [.ghostty]),
                                              fresh: [:]) == nil)
    #expect(TerminalKeyRelayCheck.hostsToRead(switches: terminalOn) == [.terminalApp])
    #expect(TerminalKeyRelayCheck.hostsToRead(switches: TerminalHostSwitches(enabled: [.ghostty, .herdr])).isEmpty)
    #expect(HerdrQuestionRelayUnavailable.otherHostUnreadable(.terminalApp).message.contains("nothing was sent"))
}

@Test func theOneGhosttyKeyCheckCoversITerm2Too() {
    // Ported from #238's iTerm2-only check: title in iTerm2, iTerm2 unreadable, iTerm2 off.
    let iTerm2On = TerminalHostSwitches(enabled: [.ghostty, .iTerm2])
    let titled = TerminalHostInventory.tabs([TerminalTab(tabID: "w0t0p0", tty: "/dev/ttys009", title: codexTitle, paneCount: 1)])
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: iTerm2On, fresh: [.iTerm2: titled])
        == .noQuestionKeys(.iTerm2))
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: iTerm2On, fresh: [.iTerm2: .unreadable])
        == .otherHostUnreadable(.iTerm2))
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: iTerm2On, fresh: [.iTerm2: .notRunning]) == nil)
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: TerminalHostSwitches(enabled: [.ghostty]),
                                              fresh: [.iTerm2: titled]) == nil)
    // Both on: each is read, and either can veto.
    let both = TerminalHostSwitches(enabled: [.ghostty, .iTerm2, .terminalApp])
    #expect(TerminalKeyRelayCheck.hostsToRead(switches: both) == [.iTerm2, .terminalApp])
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, switches: both,
                                              fresh: [.iTerm2: .notRunning, .terminalApp: .unreadable])
        == .otherHostUnreadable(.terminalApp))
}

@Test func terminalAppWritesCountAsSentUnlessCertainlyNotWritten() {
    #expect(TerminalAppInput.delivery(.reply(Data(#"{"status":"ok"}"#.utf8))) == .written)
    // The script checks the tab-window before `do script` and reports gone without typing.
    #expect(TerminalAppInput.delivery(.reply(Data(#"{"status":"gone"}"#.utf8))) == .notWritten)
    #expect(TerminalAppInput.delivery(.denied) == .notWritten)
    // A timeout or script error may have typed: it counts as sent and is never resent.
    #expect(TerminalAppInput.delivery(.failed) == .possiblyWritten)
    #expect(TerminalAppInput.delivery(.reply(Data("??".utf8))) == .possiblyWritten)
    #expect(TypedInputDelivery.possiblyWritten.countsAsSent && TypedInputDelivery.written.countsAsSent)
    #expect(!TypedInputDelivery.notWritten.countsAsSent)
}

// MARK: - Fresh check and the write sequence

private func fresh(_ change: (inout TypedReplyFreshState) -> Void = { _ in }) -> TypedReplyFreshState {
    var state = TypedReplyFreshState(completionQueued: true, latestTurn: true, sessionIdle: true,
                                     pendingInteraction: false, daemonHoldsThread: false, route: .pane(pane))
    change(&state)
    return state
}

@Test func theFreshCheckVetoesEveryUnsafeWrite() {
    #expect(TypedReplyCheck.veto(fresh(), spent: pane) == nil)
    #expect(TypedReplyCheck.veto(fresh { $0.completionQueued = false }, spent: pane) == .notInQueue)
    #expect(TypedReplyCheck.veto(fresh { $0.latestTurn = false }, spent: pane) == .notLatestTurn)
    #expect(TypedReplyCheck.veto(fresh { $0.sessionIdle = false }, spent: pane) == .sessionBusy)
    #expect(TypedReplyCheck.veto(fresh { $0.pendingInteraction = true }, spent: pane) == .pendingInteraction)
    #expect(TypedReplyCheck.veto(fresh { $0.daemonHoldsThread = true }, spent: pane) == .daemonHoldsThread)
    // The card is spent once a send started (the current conservative choice): never "send again".
    #expect(TypedReplyVeto.daemonHoldsThread.message
        == "Codex's daemon now holds this session; nothing was sent. Reply in Codex.")
    #expect(TypedReplyCheck.veto(fresh { $0.route = .unreachable }, spent: pane) == .unreachable)
    #expect(TypedReplyCheck.veto(fresh { $0.route = nil }, spent: pane) == .unreachable)
    let other = TypedInputPane(host: .terminalApp, paneID: "9921", tty: "/dev/ttys017")
    #expect(TypedReplyCheck.veto(fresh { $0.route = .pane(other) }, spent: pane) == .paneChanged)
    #expect(TypedReplyVeto.allCases.allSatisfy { $0.message.contains("nothing was sent") })
}

/// Drives one sequence with scripted checks and deliveries, recording every call.
private actor Recorder {
    var events: [String] = []
    func log(_ event: String) { events.append(event) }
}

private func run(_ writes: [TypedWrite], checks: [TypedReplyVeto?], deliveries: [TypedInputDelivery],
                 recorder: Recorder) async -> TypedReplyRun {
    var checkIndex = 0
    var writeIndex = 0
    return await TypedReplySequence.run(
        writes: writes,
        check: {
            defer { checkIndex += 1 }
            await recorder.log("check")
            return checks[min(checkIndex, checks.count - 1)]
        },
        write: { write in
            defer { writeIndex += 1 }
            await recorder.log("write \(write)")
            return deliveries[min(writeIndex, deliveries.count - 1)]
        },
        pause: { seconds in await recorder.log("pause \(seconds)") })
}

@Test func everyWriteFollowsAFreshCheckAndCodexWaitsOneSecondForItsSubmit() async {
    let recorder = Recorder()
    let result = await run([.text("now"), .submit], checks: [nil], deliveries: [.written], recorder: recorder)
    #expect(result == .sent)
    #expect(await recorder.events == ["check", "write text(\"now\")", "pause 1.0", "check", "write submit"])
}

@Test func aVetoBeforeTheFirstWriteSendsNothing() async {
    let recorder = Recorder()
    let result = await run([.textAndSubmit("now")], checks: [.sessionBusy], deliveries: [.written], recorder: recorder)
    #expect(result == .notSent(.vetoed(.sessionBusy)))
    #expect(await recorder.events == ["check"])
}

@Test func aFirstWriteCertainlyNotWrittenSendsNothing() async {
    let recorder = Recorder()
    let result = await run([.text("now"), .submit], checks: [nil], deliveries: [.notWritten], recorder: recorder)
    #expect(result == .notSent(.notWritten))
    // The submit is never sent after text that did not go in.
    #expect(await recorder.events == ["check", "write text(\"now\")"])
}

@Test func aFailedSubmitLeavesTheTextInTheComposerAndIsNeverRetried() async {
    for (checks, deliveries) in [([nil, .paneChanged], [TypedInputDelivery.written]),
                                 ([nil], [.written, .notWritten])] as [([TypedReplyVeto?], [TypedInputDelivery])] {
        let recorder = Recorder()
        let result = await run([.text("now"), .submit], checks: checks, deliveries: deliveries, recorder: recorder)
        #expect(result == .sentTextOnly)
        #expect(await recorder.events.filter { $0 == "write submit" }.count <= 1)
    }
    // A write that may have gone in counts as sent and is never repeated.
    let recorder = Recorder()
    #expect(await run([.textAndSubmit("now")], checks: [nil], deliveries: [.possiblyWritten], recorder: recorder) == .sent)
    #expect(await recorder.events == ["check", "write textAndSubmit(\"now\")"])
}

// MARK: - Claude replies

@Test func claudeRepliesHaveOnlyTheTypedRoute() {
    // No typed route at all: the card offers no field, as before.
    #expect(ClaudeReplyRouting.target(ended: false, inTurn: false, route: nil) == nil)
    #expect(ClaudeReplyRouting.target(ended: false, inTurn: false, route: .pane(pane)) == .terminal(pane))
    #expect(ClaudeReplyRouting.target(ended: false, inTurn: false, route: .unreachable) == .unavailable(.terminalUnreachable))
    #expect(ClaudeReplyRouting.target(ended: false, inTurn: false, route: .hostCannotType(.iTerm2))
        == .unavailable(.hostCannotType(.iTerm2)))
    #expect(ClaudeReplyRouting.target(ended: true, inTurn: false, route: .pane(pane)) == .unavailable(.sessionEnded))
    #expect(ClaudeReplyRouting.target(ended: false, inTurn: true, route: .pane(pane)) == .unavailable(.sessionWorking))
    #expect(SessionReplyPolicy.message(for: .sessionWorking, agent: .claude).contains("Claude"))
    // Claude's one write carries text and submit.
    let outcome = AgentTurnIdentity(session: AgentSessionIdentity(source: .claude, sourceScope: "/c", session: "s", surface: .cli),
                                    turn: "t")
    let send = ClaudeReplyRouting.prepare(target: .terminal(pane), progress: ReplyProgress(completion: outcome), text: "go on")
    #expect(send == .success(SessionReplySending.TerminalSend(pane: pane, writes: [.textAndSubmit("go on")])))
    #expect(ClaudeReplyRouting.prepare(target: .terminal(pane), progress: ReplyProgress(completion: outcome), text: "!ls")
        == .failure(.commandText))
}

// MARK: - Progress after the run

@Test func aTypedReplySettlesOnceAndNeverResends() {
    let start = SessionReplyProgress(completion: completion().id).startingSend(text: "now add tests", route: .terminal(pane))
    #expect(start.phase == .sending("now add tests"))
    let sent = start.settling(.sent, at: 200)
    #expect(sent.phase == .sent(text: "now add tests", at: 200))
    #expect(!sent.composerMayHoldText)
    let textOnly = start.settling(.sentTextOnly, at: 200)
    #expect(textOnly.phase == .sent(text: "now add tests", at: 200))
    #expect(textOnly.composerMayHoldText)
    let vetoed = start.settling(.notSent(.vetoed(.paneChanged)), at: 200)
    #expect(vetoed.phase == .failed(TypedReplyVeto.paneChanged.message))
    #expect(vetoed.isFinished)
    // A finished or sent card refuses a second send.
    #expect(sent.startingSend(text: "again", route: .terminal(pane)) == sent)
    // Sending acknowledges nothing; the session's turn start confirms it.
    #expect(sent.observing(sessionWorking: true, at: 201).phase == .working(text: "now add tests"))
    #expect(sent.observing(sessionWorking: false, at: 210).phase == .unconfirmed(text: "now add tests", sentAt: 200))
}
