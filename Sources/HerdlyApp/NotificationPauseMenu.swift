import AppKit
import HerdlyCore

/// The status item's "Pause notifications" entry (#456). Not paused, it holds a submenu of the three
/// durations; paused, it reads "Resume notifications (paused until 14:30)" and resumes on click. It is
/// the status menu's delegate, so the title is current (and an ended pause clears) each time the menu
/// opens.
@MainActor
final class NotificationPauseMenu: NSObject, NSMenuDelegate {
    let item = NSMenuItem(title: "Pause notifications", action: nil, keyEquivalent: "")
    private let durations = NSMenu(title: "Pause notifications")
    private let pause: () -> NotificationPause
    private let start: (NotificationPauseChoice) -> Void
    private let resume: () -> Void

    /// `pause` reads the current pause, already resolved against the clock; `start` and `resume`
    /// change it.
    init(pause: @escaping () -> NotificationPause, start: @escaping (NotificationPauseChoice) -> Void,
         resume: @escaping () -> Void) {
        self.pause = pause
        self.start = start
        self.resume = resume
        super.init()
        for choice in NotificationPauseChoice.allCases {
            let entry = NSMenuItem(title: choice.title, action: #selector(choose(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice
            durations.addItem(entry)
        }
        update()
    }

    /// Redraws the entry for the current pause.
    func update(now: Date = Date()) {
        let current = pause()
        item.title = current.menuTitle(now: now, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
        if current.isActive(at: now) {
            item.submenu = nil
            item.target = self
            item.action = #selector(resumeNow)
        } else {
            item.action = nil
            item.target = nil
            item.submenu = durations
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { update() }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? NotificationPauseChoice else { return }
        start(choice)
    }

    @objc private func resumeNow() { resume() }
}
