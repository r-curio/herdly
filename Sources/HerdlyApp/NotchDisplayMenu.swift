import AppKit
import HerdlyCore

/// The status item's "Show notch on" submenu. It is rebuilt from the attached displays each time it
/// opens, with the current choice checked, and is the delegate of this one menu only.
@MainActor
final class NotchDisplayMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "Show notch on")
    private let choices: () -> NotchDisplayChoices?
    private let select: (NotchDisplayPreference) -> Void

    /// `choices` returns the current picker contents, or nil once the owner is gone; `select` saves
    /// a choice.
    init(choices: @escaping () -> NotchDisplayChoices?, select: @escaping (NotchDisplayPreference) -> Void) {
        self.choices = choices
        self.select = select
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let choices = choices() else { return }
        menu.removeAllItems()
        for option in choices.options {
            let item = NSMenuItem(title: option.label, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.preference
            item.state = option == choices.selected ? .on : .off
            menu.addItem(item)
            // Follow pointer stands apart from the displays below it.
            if option.preference == .followPointer, choices.options.count > 1 { menu.addItem(.separator()) }
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let preference = sender.representedObject as? NotchDisplayPreference else { return }
        select(preference)
    }
}
