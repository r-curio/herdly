import Foundation

/// Where the notch hotkey puts the keyboard (#427, Paper L "2 · Keyboard in", K "A · Hotkey").
/// A card on screen takes it; otherwise the queue opens with its top row selected. The hotkey only
/// moves keyboard focus: it pauses no countdown (ADR 0020) and acts on nothing.
public enum NotchKeyboardEntry {
    public enum Target: Equatable, Sendable {
        /// The one card on screen (a spotlight or a clicked card) gets the keyboard; the queue stays shut.
        case card(AgentAttentionID)
        /// The full queue opens, top row selected.
        case queue
    }

    public static func target(showing mode: NotchPresentationMode) -> Target {
        if let card = mode.singleCard { return .card(card) }
        return .queue
    }

    /// The selection the queue opens with: its top row, or none when it lists nothing.
    public static func firstSelection(rows: [AgentAttentionID]) -> QueueRowSelection {
        QueueRowSelection(selected: rows.first)
    }
}

extension NotchKeyboardEntry {
    public enum Press: Equatable, Sendable {
        /// Take the keyboard into the notch.
        case enter
        /// Give it back to the app that had it.
        case handBack
    }

    /// The hotkey toggles: with the keyboard already in the notch (by the hotkey or a click) it hands
    /// back; otherwise it enters.
    public static func press(keyboardInNotch: Bool) -> Press {
        keyboardInNotch ? .handBack : .enter
    }
}

/// The app the keyboard returns to when the notch gives it back (#427): the hotkey, Escape at the top
/// level, or the panel folding for any reason. Only the app that was frontmost when the hotkey was
/// pressed is ever activated, and only while it still runs. Herdly never picks another app, such as
/// a terminal it guessed.
public struct NotchKeyboardReturn<App: Equatable & Sendable>: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Re-activate the app that had the keyboard when the hotkey was pressed.
        case activate(App)
        /// That app has quit, or there was none: activate nothing and let macOS choose.
        case leaveToSystem
        /// The keyboard came in by a click, which never activates Herdly: the app still frontmost is
        /// the one the user was using, so it is re-activated as before #427.
        case reactivateFrontmost
    }

    private enum Entry: Equatable, Sendable {
        case none
        case hotkey(remembered: App?)
    }

    private var entry = Entry.none

    public init() {}

    /// True from a hotkey entry until the keyboard is handed back or lost.
    public var enteredByHotkey: Bool { entry != .none }

    /// The hotkey put the keyboard in the notch; `frontmost` is the app that had it.
    public mutating func enter(frontmost: App?) { entry = .hotkey(remembered: frontmost) }

    /// The panel lost the keyboard without handing it back (the user clicked into another app): that
    /// app has it now, so nothing must be re-activated later.
    public mutating func forget() { entry = .none }

    /// What to activate as the notch gives the keyboard back. Spends the remembered app.
    public mutating func handBack(isRunning: (App) -> Bool) -> Action {
        defer { entry = .none }
        switch entry {
        case .none: return .reactivateFrontmost
        case .hotkey(remembered: let app?) where isRunning(app): return .activate(app)
        case .hotkey: return .leaveToSystem
        }
    }
}

/// The one key Herdly claims system-wide (#427): ⌃⌥Space unless the user records another. `keyCode`
/// is the virtual key code from the HIToolbox `kVK_*` table; `keyName` is how the key printed when it
/// was recorded, kept so the title never depends on the current keyboard layout.
public struct NotchHotkey: Equatable, Sendable {
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public static let standard = NotchHotkey(keyCode: 49, modifiers: [.control, .option], keyName: "Space")!

    public let keyCode: UInt32
    public let modifiers: Modifiers
    public let keyName: String

    /// Nil unless the shortcut holds Control, Option, or Command: a bare key or Shift and a key would
    /// take ordinary typing away from every other app.
    public init?(keyCode: UInt32, modifiers: Modifiers, keyName: String) {
        let name = keyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modifiers.isDisjoint(with: [.control, .option, .command]), !name.isEmpty else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = name
    }

    /// The shortcut as macOS menus print it, modifiers in their standard order: "⌃⌥Space".
    public var title: String {
        let symbols: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyName
    }
}

/// Settings › Notch › Keyboard: the hotkey and its off switch, saved in UserDefaults.
public struct NotchHotkeySetting: Equatable, Sendable {
    public var enabled: Bool
    public var hotkey: NotchHotkey

    public static let standard = NotchHotkeySetting(enabled: true, hotkey: .standard)

    public init(enabled: Bool, hotkey: NotchHotkey) {
        self.enabled = enabled
        self.hotkey = hotkey
    }

    /// Reads the setting through `value(key)`. Missing means on with ⌃⌥Space; a saved shortcut that
    /// is unreadable or not allowed falls back to ⌃⌥Space and keeps the saved switch.
    public static func load(value: (String) -> String?) -> NotchHotkeySetting {
        let enabled = value(Key.enabled).map { $0 == "true" } ?? true
        let saved = value(Key.keyCode).flatMap(UInt32.init).flatMap { keyCode in
            value(Key.modifiers).flatMap(Int.init).flatMap { modifiers in
                value(Key.keyName).flatMap { NotchHotkey(keyCode: keyCode, modifiers: .init(rawValue: modifiers), keyName: $0) }
            }
        }
        return NotchHotkeySetting(enabled: enabled, hotkey: saved ?? .standard)
    }

    public func save(write: (String, String) -> Void) {
        write(Key.enabled, enabled ? "true" : "false")
        write(Key.keyCode, String(hotkey.keyCode))
        write(Key.modifiers, String(hotkey.modifiers.rawValue))
        write(Key.keyName, hotkey.keyName)
    }

    private enum Key {
        static let enabled = "notchHotkey.enabled"
        static let keyCode = "notchHotkey.keyCode"
        static let modifiers = "notchHotkey.modifiers"
        static let keyName = "notchHotkey.keyName"
    }
}

/// The outcome of the last attempt to register the hotkey. Anything but `registered` leaves the notch
/// click-only; Herdly never falls back to watching every key.
public enum NotchHotkeyStatus: Equatable, Sendable {
    /// Switched off in Settings.
    case off
    case registered
    /// Another app holds the shortcut (`eventHotKeyExistsErr`).
    case taken
    /// Registration failed with this OSStatus.
    case failed(Int32)

    public var registered: Bool { self == .registered }

    /// The line Settings shows under the Keyboard row, nil when nothing needs saying.
    public var problemLine: String? {
        switch self {
        case .off, .registered: nil
        case .taken: "Another app already uses this shortcut, so the notch opens only by click. Choose another."
        case .failed(let status): "macOS refused this shortcut (error \(status)), so the notch opens only by click."
        }
    }
}
