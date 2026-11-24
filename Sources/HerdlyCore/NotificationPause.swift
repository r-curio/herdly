import Foundation

/// "Pause notifications" (#456): the menu bar item that stops Herdly interrupting for a while. A
/// pause only decides whether a newly arrived item may pop its card, play its sound, or alert the
/// phone. It never drops, acknowledges, reorders, or counts an item differently, never touches an
/// approval's deadline, and never produces a decision. Every rule here takes the clock and the
/// calendar from the caller.

/// The three durations in the menu's "Pause notifications" submenu.
public enum NotificationPauseChoice: String, CaseIterable, Sendable {
    case oneHour
    case untilTomorrow
    case untilResumed

    public var title: String {
        switch self {
        case .oneHour: "For 1 hour"
        case .untilTomorrow: "Until tomorrow"
        case .untilResumed: "Until I resume"
        }
    }
}

/// Whether notifications are paused, and until when.
public enum NotificationPause: Equatable, Sendable {
    case none
    /// Paused until this moment; the pause has ended at it.
    case until(Date)
    /// "Until I resume": no end.
    case indefinite

    /// "Until tomorrow" ends at this local hour.
    public static let tomorrowHour = 9

    /// The pause a menu choice starts at `now`. "Until tomorrow" ends at the next 09:00 local time
    /// strictly after `now`: tomorrow's when it is 09:00 or later, this morning's when it is earlier
    /// (a pause started at 02:00 ends at 09:00 the same day).
    public static func starting(_ choice: NotificationPauseChoice, now: Date, calendar: Calendar) -> NotificationPause {
        switch choice {
        case .oneHour:
            return .until(now.addingTimeInterval(3600))
        case .untilTomorrow:
            let nine = DateComponents(hour: tomorrowHour, minute: 0, second: 0)
            guard let end = calendar.nextDate(after: now, matching: nine, matchingPolicy: .nextTime) else {
                // No such time in this calendar: a day from now is the closest honest answer.
                return .until(now.addingTimeInterval(24 * 3600))
            }
            return .until(end)
        case .untilResumed:
            return .indefinite
        }
    }

    public func isActive(at now: Date) -> Bool {
        switch self {
        case .none: false
        case let .until(end): now < end
        case .indefinite: true
        }
    }

    /// The end of a timed pause; nil when not paused or paused until the user resumes.
    public var endsAt: Date? {
        if case let .until(end) = self { return end }
        return nil
    }

    /// This pause, or `.none` once it has ended at `now`.
    public func resolved(at now: Date) -> NotificationPause {
        isActive(at: now) ? self : .none
    }

    /// The status menu item's title: "Pause notifications" when not paused, "Resume notifications"
    /// for Until I resume, and "Resume notifications (paused until 14:30)" for a timed pause, its
    /// time in the locale's short time style. An end on another calendar day than `now` also names
    /// its abbreviated weekday ("paused until Wed 09:00").
    public func menuTitle(now: Date, calendar: Calendar, locale: Locale) -> String {
        switch resolved(at: now) {
        case .none:
            return "Pause notifications"
        case .indefinite:
            return "Resume notifications"
        case let .until(end):
            let time = DateFormatter()
            time.locale = locale
            time.timeZone = calendar.timeZone
            time.calendar = calendar
            time.dateStyle = .none
            time.timeStyle = .short
            var when = time.string(from: end)
            if !calendar.isDate(end, inSameDayAs: now) {
                let weekday = DateFormatter()
                weekday.locale = locale
                weekday.timeZone = calendar.timeZone
                weekday.calendar = calendar
                weekday.setLocalizedDateFormatFromTemplate("EEE")
                when = "\(weekday.string(from: end)) \(when)"
            }
            return "Resume notifications (paused until \(when))"
        }
    }

    // MARK: Persistence

    /// The one UserDefaults key: "indefinite", or "until:<seconds since 1970>". Absent when not paused.
    public static let key = "notificationPause"

    /// The saved pause, read through `value(key)`. A timed pause whose end is at or before `now`
    /// starts unpaused, as does a missing or unreadable value.
    public static func load(now: Date, value: (String) -> String?) -> NotificationPause {
        guard let saved = value(key) else { return .none }
        if saved == "indefinite" { return .indefinite }
        guard saved.hasPrefix("until:"), let seconds = Double(saved.dropFirst("until:".count)),
              seconds.isFinite else { return .none }
        return NotificationPause.until(Date(timeIntervalSince1970: seconds)).resolved(at: now)
    }

    /// Writes this pause through `write(key, value)`; a nil value removes the key.
    public func save(write: (String, String?) -> Void) {
        switch self {
        case .none: write(Self.key, nil)
        case .indefinite: write(Self.key, "indefinite")
        case let .until(end): write(Self.key, "until:\(end.timeIntervalSince1970)")
        }
    }
}

/// One "While paused" choice in Settings › Notifications.
public enum PausedInterruption: String, CaseIterable, Sendable {
    /// Behaves exactly as when not paused: its card, its sound, its phone alert.
    case popOpen
    /// Waits silently in the queue: no card, no sound, no phone alert.
    case stayQuiet

    public var title: String {
        switch self {
        case .popOpen: "Still pop open"
        case .stayQuiet: "Stay quiet"
        }
    }
}

/// Settings › Notifications › While paused: one choice for approvals, one for questions. Both
/// default to Still pop open. Completions and everything else are always quiet while paused.
public struct PausedNotificationSettings: Equatable, Sendable {
    public var approvals: PausedInterruption
    public var questions: PausedInterruption

    public static let standard = PausedNotificationSettings(approvals: .popOpen, questions: .popOpen)
    public static let approvalsKey = "pausedApprovals"
    public static let questionsKey = "pausedQuestions"

    public init(approvals: PausedInterruption, questions: PausedInterruption) {
        self.approvals = approvals
        self.questions = questions
    }

    /// Reads both choices through `value(key)`; a missing or unrecognised value keeps its default.
    public static func load(value: (String) -> String?) -> PausedNotificationSettings {
        PausedNotificationSettings(
            approvals: value(approvalsKey).flatMap(PausedInterruption.init(rawValue:)) ?? standard.approvals,
            questions: value(questionsKey).flatMap(PausedInterruption.init(rawValue:)) ?? standard.questions)
    }

    public func save(write: (String, String) -> Void) {
        write(Self.approvalsKey, approvals.rawValue)
        write(Self.questionsKey, questions.rawValue)
    }
}

/// What kind of interruption a newly arrived row would make.
public enum NotificationInterruptionKind: Equatable, Sendable {
    /// A live or handed-back approval request.
    case approval
    case question
    case completion
    /// Running work, waiting and status-unavailable sessions: rows that never pop on their own.
    case other

    public init(_ item: AgentAttentionItem) {
        switch item.kind {
        case .actionableApproval, .handedBackApproval: self = .approval
        case .question: self = .question
        case .outcome, .earlierOutcome: self = .completion
        case .waiting, .statusUnavailable, .running: self = .other
        }
    }
}

public enum NotificationInterruption {
    /// Whether an item of `kind` arriving at `now` may pop its card, play its sound, and alert the
    /// phone. Without an active pause every kind may. While paused, approvals and questions follow
    /// their "While paused" setting and every other kind stays quiet. The answer is decided once, at
    /// arrival: an item kept quiet stays quiet after the pause ends, as a restored item does.
    public static func allows(_ kind: NotificationInterruptionKind, pause: NotificationPause,
                              settings: PausedNotificationSettings, at now: Date) -> Bool {
        guard pause.isActive(at: now) else { return true }
        switch kind {
        case .approval: return settings.approvals == .popOpen
        case .question: return settings.questions == .popOpen
        case .completion, .other: return false
        }
    }
}
