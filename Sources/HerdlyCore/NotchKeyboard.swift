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

    /// The app the hotkey took the keyboard from, while the notch still holds it; nil after a click
    /// entry, a hand-back, or once another app took the keyboard.
    public var rememberedApp: App? {
        if case let .hotkey(remembered) = entry { return remembered }
        return nil
    }

    /// The hotkey put the keyboard in the notch; `frontmost` is the app that had it.
    public mutating func enter(frontmost: App?) { entry = .hotkey(remembered: frontmost) }

    /// The panel lost the keyboard without handing it back (the user clicked into another app): that
    /// app has it now, so nothing must be re-activated later.
    public mutating func forget() { entry = .none }

    /// What to activate as the notch gives the keyboard back. Spends the remembered app.
    /// `frontmost` is the app in front now and `herdly` is Herdly itself. When some third app has come
    /// forward since the hotkey (an Open from the notch brought a terminal forward), that app keeps
    /// the keyboard: the remembered app is not pulled back over it.
    public mutating func handBack(isRunning: (App) -> Bool, frontmost: App?, herdly: App?) -> Action {
        defer { entry = .none }
        guard case let .hotkey(remembered) = entry else { return .reactivateFrontmost }
        if let frontmost, frontmost != remembered, frontmost != herdly { return .reactivateFrontmost }
        guard let remembered, isRunning(remembered) else { return .leaveToSystem }
        return .activate(remembered)
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
    /// `kVK_Escape`: alone it cancels recording; with a modifier it is a shortcut like any other key.
    public static let escapeKeyCode: UInt32 = 53

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

/// What one key press does while Settings records a new shortcut.
public enum NotchHotkeyRecording: Equatable, Sendable {
    /// Escape alone: stop recording and keep the current shortcut.
    case cancel
    /// A shortcut Herdly accepts: save it and stop recording.
    case shortcut(NotchHotkey)
    /// Not a shortcut (no Control, Option or Command, or no key name): keep listening.
    case ignore

    public static func decide(keyCode: UInt32, modifiers: NotchHotkey.Modifiers, keyName: String) -> Self {
        if keyCode == NotchHotkey.escapeKeyCode && modifiers.isEmpty { return .cancel }
        return NotchHotkey(keyCode: keyCode, modifiers: modifiers, keyName: keyName).map(Self.shortcut) ?? .ignore
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

    /// Reads the switch through `bool(key)` and the shortcut through `string(key)`. A missing switch
    /// means on; a saved shortcut that is unreadable or not allowed falls back to ⌃⌥Space and keeps
    /// the saved switch.
    public static func load(bool: (String) -> Bool?, string: (String) -> String?) -> NotchHotkeySetting {
        let saved = string(Key.keyCode).flatMap(UInt32.init).flatMap { keyCode in
            string(Key.modifiers).flatMap(Int.init).flatMap { modifiers in
                string(Key.keyName).flatMap { NotchHotkey(keyCode: keyCode, modifiers: .init(rawValue: modifiers), keyName: $0) }
            }
        }
        return NotchHotkeySetting(enabled: bool(Key.enabled) ?? true, hotkey: saved ?? .standard)
    }

    public func save(bool: (String, Bool) -> Void, string: (String, String) -> Void) {
        bool(Key.enabled, enabled)
        string(Key.keyCode, String(hotkey.keyCode))
        string(Key.modifiers, String(hotkey.modifiers.rawValue))
        string(Key.keyName, hotkey.keyName)
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

    /// The line Settings shows under the Keyboard row, nil when nothing needs saying.
    public var problemLine: String? {
        switch self {
        case .off, .registered: nil
        case .taken: "Another app already uses this shortcut, so the notch opens only by click. Choose another."
        case .failed(let status): "macOS refused this shortcut (error \(status)), so the notch opens only by click."
        }
    }
}
