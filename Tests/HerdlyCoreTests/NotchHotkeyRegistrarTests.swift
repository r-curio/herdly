import AppKit
import Carbon.HIToolbox
import Testing
@testable import HerdlyApp
@testable import HerdlyCore

@Test func eachModifierMapsToItsCarbonFlagAndBack() {
    let all: NotchHotkey.Modifiers = [.control, .option, .shift, .command]
    #expect(NotchHotkeyRegistrar.carbonModifiers(all)
            == UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey) | UInt32(cmdKey))
    #expect(NotchHotkeyRegistrar.carbonModifiers([.control, .option]) == UInt32(controlKey) | UInt32(optionKey))
    #expect(NotchHotkeyRegistrar.modifiers(from: [.control, .option, .capsLock, .function]) == [.control, .option])
    #expect(NotchHotkeyRegistrar.modifiers(from: [.shift, .command]) == [.shift, .command])
}

@Test func theShortcutIsRegisteredExclusivelySoOneAnotherAppHoldsIsReportedAsTaken() {
    // Without kEventHotKeyExclusive Carbon registers a shortcut another process holds without error.
    #expect(NotchHotkeyRegistrar.registrationOptions == OptionBits(kEventHotKeyExclusive))
}
