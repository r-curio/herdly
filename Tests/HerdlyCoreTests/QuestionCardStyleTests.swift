import AppKit
import CoreText
import Testing
@testable import HerdlyApp

@Test @MainActor func questionFontsAreBundledAndRegisteredWithoutSystemInstallation() {
    #expect(QuestionCardStyle.fontsRegistered)
    for name in ["JetBrainsMono-Regular", "JetBrainsMono-SemiBold"] {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        #expect(CTFontCopyPostScriptName(font) as String == name)
    }
}
