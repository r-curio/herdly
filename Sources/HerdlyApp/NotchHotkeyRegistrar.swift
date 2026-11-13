import AppKit
import Carbon.HIToolbox
import HerdlyCore

/// Registers the notch hotkey (#427) with Carbon `RegisterEventHotKey`, which needs no
/// Accessibility permission and sees only this one shortcut. Herdly never installs an event tap or
/// watches other keys; when registration fails the notch stays click-only and Settings says why.
@MainActor
final class NotchHotkeyRegistrar {
    /// Called on the main thread for each press of the registered shortcut.
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// 'Hrdy': tells this app's hot key events apart from any other Carbon client's in the process.
    nonisolated fileprivate static let signature: OSType = 0x4872_6479
    nonisolated fileprivate static let identifier: UInt32 = 1
    /// The registrar whose handler is installed; the C callback reaches it here, as it can carry no
    /// context across the isolation boundary. The app has one registrar for its whole life.
    fileprivate static weak var installed: NotchHotkeyRegistrar?

    /// Replaces any registered shortcut with `hotkey`; nil only unregisters. Returns the outcome.
    func register(_ hotkey: NotchHotkey?) -> NotchHotkeyStatus {
        unregister()
        guard let hotkey else { return .off }
        guard installHandler() else { return .failed(OSStatus(eventInternalErr)) }
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let status = RegisterEventHotKey(hotkey.keyCode, Self.carbonModifiers(hotkey.modifiers), id,
                                         GetApplicationEventTarget(), 0, &reference)
        switch status {
        case noErr:
            hotKey = reference
            return .registered
        case OSStatus(eventHotKeyExistsErr):
            return .taken
        default:
            return .failed(status)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandler() -> Bool {
        guard handler == nil else { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), notchHotkeyHandler, 1, &type, nil, &handler)
        guard status == noErr else { return false }
        Self.installed = self
        return true
    }

    static func carbonModifiers(_ modifiers: NotchHotkey.Modifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }

    /// The shortcut a key press in the recorder describes, or nil when it is not one Herdly accepts
    /// (no Control, Option or Command, or a key with no printable name).
    static func hotkey(from event: NSEvent) -> NotchHotkey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: NotchHotkey.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        let name = keyNames[event.keyCode]
            ?? event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return NotchHotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyName: name)
    }

    /// Keys that print nothing useful on their own, by `kVK_*` code.
    private static let keyNames: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12"
    ]
}

/// Carbon delivers application-target events on the main thread, so the registrar is reached on
/// the main actor. Only the press of this app's own shortcut is handled; any other hot key event
/// is left to the next handler.
private let notchHotkeyHandler: EventHandlerUPP = { _, event, _ in
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == NotchHotkeyRegistrar.signature,
          id.id == NotchHotkeyRegistrar.identifier else { return OSStatus(eventNotHandledErr) }
    MainActor.assumeIsolated { NotchHotkeyRegistrar.installed?.onPress?() }
    return noErr
}
