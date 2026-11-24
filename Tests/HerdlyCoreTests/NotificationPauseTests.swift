import Foundation
import Testing
@testable import HerdlyCore

// #456: "Pause notifications" in the menu bar menu. While paused, new items still join the queue,
// but completions never pop, sound, or alert the phone; approvals and questions follow the two
// "While paused" settings. Every rule takes the clock and calendar explicitly.

private let codexCLI = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex-1", surface: .cli)
private let codexWorking = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "codex-3", surface: .cli)
private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/Users/me/.claude", session: "claude-1", surface: .cli)

private var london: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
}

/// 2026-11-24 (a Tuesday) at the given local time in London.
private func tuesday(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    london.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: hour, minute: minute, second: second))!
}

private let quiet = PausedNotificationSettings(approvals: .stayQuiet, questions: .stayQuiet)

// MARK: - The pause and its end

@Test func aTimedPauseIsActiveUntilItsEndAndEndsExactlyThen() {
    let end = tuesday(14, 30)
    let pause = NotificationPause.until(end)

    #expect(pause.isActive(at: end.addingTimeInterval(-0.001)))
    #expect(!pause.isActive(at: end))
    #expect(!pause.isActive(at: end.addingTimeInterval(1)))
    #expect(pause.endsAt == end)
}

@Test func untilIResumeHasNoEndAndNotPausedIsNeverActive() {
    #expect(NotificationPause.indefinite.isActive(at: .distantFuture))
    #expect(NotificationPause.indefinite.endsAt == nil)
    #expect(!NotificationPause.none.isActive(at: tuesday(10)))
}

@Test func forOneHourEndsSixtyMinutesFromNow() {
    let now = tuesday(13, 30, 15)
    #expect(NotificationPause.starting(.oneHour, now: now, calendar: london) == .until(tuesday(14, 30, 15)))
}

@Test func untilIResumeStartsAnIndefinitePause() {
    #expect(NotificationPause.starting(.untilResumed, now: tuesday(10), calendar: london) == .indefinite)
}

@Test func untilTomorrowEndsAtTheNextNineOClock() {
    let wednesdayNine = london.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 9))!
    // After 09:00: tomorrow's 09:00.
    #expect(NotificationPause.starting(.untilTomorrow, now: tuesday(14, 30), calendar: london) == .until(wednesdayNine))
    // Exactly 09:00 is not "after now", so it is tomorrow's 09:00 too.
    #expect(NotificationPause.starting(.untilTomorrow, now: tuesday(9), calendar: london) == .until(wednesdayNine))
    // Before 09:00 (a late night): this morning's 09:00 is the next one.
    #expect(NotificationPause.starting(.untilTomorrow, now: tuesday(2, 15), calendar: london) == .until(tuesday(9)))
    #expect(NotificationPause.starting(.untilTomorrow, now: tuesday(8, 59, 59), calendar: london) == .until(tuesday(9)))
}

@Test func untilTomorrowFollowsLocalTimeAcrossADaylightSavingChange() {
    // London leaves summer time on 2026-10-25 at 02:00; 09:00 is still 09:00 local afterwards.
    let saturdayEvening = london.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 22))!
    let sundayNine = london.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9))!
    #expect(NotificationPause.starting(.untilTomorrow, now: saturdayEvening, calendar: london) == .until(sundayNine))
    #expect(sundayNine.timeIntervalSince(saturdayEvening) == 12 * 3600)
}

@Test func anEndedPauseResolvesToNotPaused() {
    let end = tuesday(14, 30)
    #expect(NotificationPause.until(end).resolved(at: end.addingTimeInterval(-1)) == .until(end))
    #expect(NotificationPause.until(end).resolved(at: end) == NotificationPause.none)
    #expect(NotificationPause.indefinite.resolved(at: .distantFuture) == .indefinite)
}

// MARK: - The menu item

@Test func theMenuItemNamesThePauseAndItsEnd() {
    let british = Locale(identifier: "en_GB")
    #expect(NotificationPause.none.menuTitle(now: tuesday(13), calendar: london, locale: british) == "Pause notifications")
    #expect(NotificationPause.indefinite.menuTitle(now: tuesday(13), calendar: london, locale: british) == "Resume notifications")
    #expect(NotificationPause.until(tuesday(14, 30)).menuTitle(now: tuesday(13, 30), calendar: london, locale: british)
            == "Resume notifications (paused until 14:30)")
    // An end on another day also names its weekday.
    let wednesdayNine = london.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 9))!
    #expect(NotificationPause.until(wednesdayNine).menuTitle(now: tuesday(18), calendar: london, locale: british)
            == "Resume notifications (paused until Wed 09:00)")
    // An ended pause reads as not paused.
    #expect(NotificationPause.until(tuesday(14, 30)).menuTitle(now: tuesday(14, 30), calendar: london, locale: british)
            == "Pause notifications")
}

@Test func theMenuTimeFollowsTheUsersLocale() {
    let american = Locale(identifier: "en_US")
    let title = NotificationPause.until(tuesday(14, 30)).menuTitle(now: tuesday(13, 30), calendar: london, locale: american)
    #expect(title.hasPrefix("Resume notifications (paused until 2:30"))
    #expect(title.hasSuffix("PM)"))
}

// MARK: - Who may interrupt while paused

@Test(arguments: [PausedInterruption.popOpen, .stayQuiet])
func anApprovalArrivingWhilePausedFollowsItsSetting(setting: PausedInterruption) {
    let settings = PausedNotificationSettings(approvals: setting, questions: .popOpen)
    let allowed = NotificationInterruption.allows(.approval, pause: .indefinite, settings: settings, at: tuesday(10))
    #expect(allowed == (setting == .popOpen))
}

@Test(arguments: [PausedInterruption.popOpen, .stayQuiet])
func aQuestionArrivingWhilePausedFollowsItsSetting(setting: PausedInterruption) {
    let settings = PausedNotificationSettings(approvals: .popOpen, questions: setting)
    let allowed = NotificationInterruption.allows(.question, pause: .indefinite, settings: settings, at: tuesday(10))
    #expect(allowed == (setting == .popOpen))
}

@Test func theApprovalAndQuestionSettingsAreIndependent() {
    let settings = PausedNotificationSettings(approvals: .stayQuiet, questions: .popOpen)
    #expect(!NotificationInterruption.allows(.approval, pause: .indefinite, settings: settings, at: tuesday(10)))
    #expect(NotificationInterruption.allows(.question, pause: .indefinite, settings: settings, at: tuesday(10)))
}

@Test func completionsAndEverythingElseAreAlwaysQuietWhilePaused() {
    let loud = PausedNotificationSettings(approvals: .popOpen, questions: .popOpen)
    for kind in [NotificationInterruptionKind.completion, .other] {
        #expect(!NotificationInterruption.allows(kind, pause: .indefinite, settings: loud, at: tuesday(10)))
        #expect(!NotificationInterruption.allows(kind, pause: .until(tuesday(11)), settings: loud, at: tuesday(10)))
    }
}

@Test func withNoActivePauseEveryKindMayInterrupt() {
    for kind in [NotificationInterruptionKind.approval, .question, .completion, .other] {
        #expect(NotificationInterruption.allows(kind, pause: .none, settings: quiet, at: tuesday(10)))
        // A timed pause stops at its end: an arrival at that moment interrupts as usual.
        #expect(NotificationInterruption.allows(kind, pause: .until(tuesday(10)), settings: quiet, at: tuesday(10)))
    }
    #expect(!NotificationInterruption.allows(.completion, pause: .until(tuesday(10)), settings: quiet,
                                             at: tuesday(10).addingTimeInterval(-0.001)))
}

@Test func queueRowsMapToTheirInterruptionKind() {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: codexCLI, turn: "t1", call: "a1", arrivedAt: 100)), now: 100)
    queue.apply(.question(AgentQuestion(session: claude, turn: "t2", call: "q1", arrivedAt: 100)), now: 100)
    queue.apply(.outcome(AgentOutcome(session: claude, turn: "t3", status: .finished, arrivedAt: 100)), now: 100)
    queue.apply(.running(AgentRunning(session: codexWorking, turn: "t4", arrivedAt: 100)), now: 100)
    let kinds = queue.items(at: 100).map { ($0.kind, NotificationInterruptionKind($0)) }
    #expect(kinds.contains { $0 == (.actionableApproval, .approval) })
    #expect(kinds.contains { $0 == (.question, .question) })
    #expect(kinds.contains { $0 == (.outcome, .completion) })
    #expect(kinds.contains { $0 == (.running, .other) })
    // A handed-back approval is still an approval.
    #expect(queue.items(at: 200).contains { $0.kind == .handedBackApproval && NotificationInterruptionKind($0) == .approval })
}

@Test func aQuietApprovalStillTimesOutAtItsOwnDeadlineWithNoDecision() {
    // The pause never reaches the deadline: the queue takes no pause, and a quiet approval stays
    // actionable from the queue until its unchanged 30-second deadline, then hands back.
    let arrived = 1_000.0
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: codexCLI, turn: "t1", call: "a1", arrivedAt: arrived)), now: arrived)
    let pause = NotificationPause.indefinite
    #expect(!NotificationInterruption.allows(.approval, pause: pause, settings: quiet, at: Date(timeIntervalSince1970: arrived)))

    let live = queue.items(at: arrived + 29.999)
    #expect(live.map(\.kind) == [.actionableApproval])
    #expect(live.first?.approval?.expiresAt == arrived + 30)
    let after = queue.items(at: arrived + 30)
    #expect(after.map(\.kind) == [.handedBackApproval])
    #expect(after.first?.approval?.expiresAt == arrived + 30)
    #expect(pause.isActive(at: Date(timeIntervalSince1970: arrived + 30)))
}

// MARK: - Persistence

@Test func aPauseSurvivesARestartBeforeItsEnd() {
    var stored: [String: String] = [:]
    let end = tuesday(14, 30)
    NotificationPause.until(end).save { key, value in stored[key] = value }

    let restarted = NotificationPause.load(now: tuesday(14, 29)) { stored[$0] }
    #expect(restarted == .until(end))
}

@Test func aRestartAfterThePauseEndedStartsUnpaused() {
    var stored: [String: String] = [:]
    let end = tuesday(14, 30)
    NotificationPause.until(end).save { key, value in stored[key] = value }

    #expect(NotificationPause.load(now: end) { stored[$0] } == NotificationPause.none)
    #expect(NotificationPause.load(now: tuesday(18)) { stored[$0] } == NotificationPause.none)
}

@Test func untilIResumeSurvivesAnyRestartAndResumingClearsIt() {
    var stored: [String: String] = [:]
    NotificationPause.indefinite.save { key, value in stored[key] = value }
    #expect(NotificationPause.load(now: .distantFuture) { stored[$0] } == .indefinite)

    NotificationPause.none.save { key, value in stored[key] = value }
    #expect(stored[NotificationPause.key] == nil)
    #expect(NotificationPause.load(now: tuesday(10)) { stored[$0] } == NotificationPause.none)
}

@Test(arguments: [nil, "", "forever", "until:", "until:soon", "until:nan", "until:inf"])
func anUnreadablePauseLoadsAsNotPaused(saved: String?) {
    #expect(NotificationPause.load(now: tuesday(10)) { _ in saved } == NotificationPause.none)
}

@Test func theWhilePausedSettingsDefaultToStillPopOpen() {
    #expect(PausedNotificationSettings.standard == PausedNotificationSettings(approvals: .popOpen, questions: .popOpen))
    #expect(PausedNotificationSettings.load { _ in nil } == .standard)
    #expect(PausedNotificationSettings.load { _ in "sometimes" } == .standard)
}

@Test func theWhilePausedSettingsRoundTrip() {
    var stored: [String: String] = [:]
    let settings = PausedNotificationSettings(approvals: .stayQuiet, questions: .popOpen)
    settings.save { key, value in stored[key] = value }
    #expect(PausedNotificationSettings.load { stored[$0] } == settings)
    // One unreadable value falls back alone.
    stored[PausedNotificationSettings.approvalsKey] = "loud"
    #expect(PausedNotificationSettings.load { stored[$0] } == PausedNotificationSettings(approvals: .popOpen, questions: .popOpen))
}

@Test func theSettingsChoicesReadAsAgreed() {
    #expect(PausedInterruption.allCases.map(\.title) == ["Still pop open", "Stay quiet"])
    #expect(NotificationPauseChoice.allCases.map(\.title) == ["For 1 hour", "Until tomorrow", "Until I resume"])
}

// MARK: - Phone alerts

@Test func aQuietArrivalIsSpentForThePhoneWithoutAnAlert() {
    var queue = AgentAttentionQueue()
    queue.apply(.question(AgentQuestion(session: claude, turn: "t2", call: "q1", arrivedAt: 1_005)), now: 1_005)
    let item = queue.items(at: 1_005)[0]
    let candidate = PhoneAlertCandidate(item, project: "/Users/me/src/herdly", launchedAt: 1_000)!.respecting(mayInterrupt: false)
    #expect(candidate.arrival == .paused)
    var ledger = PhoneAlertLedger()
    #expect(ledger.consider([candidate], idleSeconds: 600, setting: .on).isEmpty)
    // Once spent, the same item never alerts later, even after the pause.
    let loud = PhoneAlertCandidate(item, project: "/Users/me/src/herdly", launchedAt: 1_000)!.respecting(mayInterrupt: true)
    #expect(loud.arrival == .fresh)
    #expect(ledger.consider([loud], idleSeconds: 600, setting: .on).isEmpty)
}

// MARK: - Which new rows may interrupt, by their own arrival time

/// New rows as a scan hands them over: one of each kind, all arriving at `arrivedAt` (seconds since 1970).
private func newRows(arrivedAt: Double) -> [AgentAttentionItem] {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: codexCLI, turn: "t1", call: "a1", arrivedAt: arrivedAt)), now: arrivedAt)
    queue.apply(.question(AgentQuestion(session: claude, turn: "t2", call: "q1", arrivedAt: arrivedAt)), now: arrivedAt)
    queue.apply(.outcome(AgentOutcome(session: codexWorking, turn: "t3", status: .finished, arrivedAt: arrivedAt)), now: arrivedAt)
    return queue.items(at: arrivedAt)
}

private func kinds(_ ids: Set<AgentAttentionID>, in rows: [AgentAttentionItem]) -> Set<NotificationInterruptionKind> {
    Set(rows.filter { ids.contains($0.id) }.map(NotificationInterruptionKind.init))
}

private let pauseStart = tuesday(13)
private let pauseEnd = tuesday(14)

/// A log holding one finished pause from 13:00 to 14:00.
private func finishedPause() -> NotificationPauseLog {
    var log = NotificationPauseLog()
    log.record(.until(pauseEnd), at: pauseStart)
    log.record(.none, at: pauseEnd)
    return log
}

@Test func itemsThatArrivedDuringAPauseStayQuietAfterItEnds() {
    let rows = newRows(arrivedAt: tuesday(13, 30).timeIntervalSince1970)
    let interrupting = NotificationPauseArrivals.interrupting(rows, pauses: finishedPause(), settings: quiet,
                                                               scannedAt: tuesday(13, 30))
    #expect(interrupting.isEmpty)
    // The pause is over, but the decision was taken at arrival: nothing pops afterwards.
    #expect(!finishedPause().covers(pauseEnd))
}

@Test func anItemThatArrivedDuringAPauseButWasScannedAfterItStaysQuiet() {
    let rows = newRows(arrivedAt: tuesday(13, 59).timeIntervalSince1970)
    let interrupting = NotificationPauseArrivals.interrupting(rows, pauses: finishedPause(), settings: quiet,
                                                               scannedAt: tuesday(14, 0, 5))
    #expect(interrupting.isEmpty)
}

@Test func anItemThatArrivedBeforeAPauseStartedIsUnaffectedByIt() {
    // Arrived 12:59, first scanned 13:00:05, after the pause started at 13:00.
    var log = NotificationPauseLog()
    log.record(.indefinite, at: pauseStart)
    let rows = newRows(arrivedAt: tuesday(12, 59).timeIntervalSince1970)
    let interrupting = NotificationPauseArrivals.interrupting(rows, pauses: log, settings: quiet, scannedAt: tuesday(13, 0, 5))
    #expect(interrupting == Set(rows.map(\.id)))
}

@Test func anItemArrivingAtThePauseEndInterruptsAsUsual() {
    let rows = newRows(arrivedAt: pauseEnd.timeIntervalSince1970)
    let interrupting = NotificationPauseArrivals.interrupting(rows, pauses: finishedPause(), settings: quiet, scannedAt: pauseEnd)
    #expect(interrupting == Set(rows.map(\.id)))
}

@Test(arguments: [PausedInterruption.popOpen, .stayQuiet], [PausedInterruption.popOpen, .stayQuiet])
func newRowsDuringAPauseFollowTheirSettingAndCompletionsStayQuiet(approvals: PausedInterruption, questions: PausedInterruption) {
    let rows = newRows(arrivedAt: tuesday(13, 30).timeIntervalSince1970)
    let settings = PausedNotificationSettings(approvals: approvals, questions: questions)
    let interrupting = NotificationPauseArrivals.interrupting(rows, pauses: finishedPause(), settings: settings,
                                                               scannedAt: tuesday(13, 30))
    var expected: Set<NotificationInterruptionKind> = []
    if approvals == .popOpen { expected.insert(.approval) }
    if questions == .popOpen { expected.insert(.question) }
    #expect(kinds(interrupting, in: rows) == expected)
}

@Test func anArrivalTimeMissingOrInTheFutureFallsBackToTheScanTime() {
    var log = NotificationPauseLog()
    log.record(.indefinite, at: pauseStart)
    let scannedDuringPause = tuesday(13, 30)
    #expect(NotificationPauseArrivals.arrival(of: .nan, scannedAt: scannedDuringPause) == scannedDuringPause)
    #expect(NotificationPauseArrivals.arrival(of: 0, scannedAt: scannedDuringPause) == scannedDuringPause)
    #expect(NotificationPauseArrivals.arrival(of: tuesday(15).timeIntervalSince1970, scannedAt: scannedDuringPause)
            == scannedDuringPause)
    #expect(NotificationPauseArrivals.arrival(of: tuesday(12).timeIntervalSince1970, scannedAt: scannedDuringPause) == tuesday(12))
}

@Test func thePauseLogKeepsEachSpanFromItsStartToItsEnd() {
    var log = NotificationPauseLog()
    log.record(.until(tuesday(14)), at: tuesday(13))
    // Resumed early at 13:20: the span ends then, not at 14:00.
    log.record(.none, at: tuesday(13, 20))
    log.record(.indefinite, at: tuesday(15))
    #expect(!log.covers(tuesday(12, 59)))
    #expect(log.covers(tuesday(13)))
    #expect(log.covers(tuesday(13, 19)))
    #expect(!log.covers(tuesday(13, 20)))
    #expect(!log.covers(tuesday(14, 59)))
    #expect(log.covers(tuesday(15)))
    #expect(log.covers(.distantFuture))
    // The end timer recording `.none` after a timed end never stretches the span.
    var timed = NotificationPauseLog()
    timed.record(.until(tuesday(14)), at: tuesday(13))
    timed.record(.none, at: tuesday(14, 0, 3))
    #expect(!timed.covers(tuesday(14, 0, 1)))
}

@Test func thePauseLogIsBounded() {
    var log = NotificationPauseLog(capacity: 2)
    for hour in 1...5 {
        log.record(.until(tuesday(hour, 30)), at: tuesday(hour))
    }
    #expect(log.spans.count == 2)
    #expect(!log.covers(tuesday(1, 10)))
    #expect(log.covers(tuesday(5, 10)))
}
