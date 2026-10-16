import CoreText
import SwiftUI

enum QuestionCardStyle {
    static let fontsRegistered: Bool = {
        // SwiftPM's generated accessor looks beside the app, not inside Contents/Resources.
        let bundle = Bundle.main.url(forResource: "Steer_SteerApp", withExtension: "bundle").flatMap(Bundle.init(url:))
            ?? (Bundle.main.bundleURL.pathExtension == "app" ? nil : Bundle.module)
        for name in ["JetBrainsMono-Regular", "JetBrainsMono-SemiBold"] {
            guard let url = bundle?.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else { return false }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard fontsRegistered else { return NotchStyle.mono(size, weight) }
        return .custom(weight == .semibold ? "JetBrainsMono-SemiBold" : "JetBrainsMono-Regular", fixedSize: size)
    }
}

private struct QuestionCardKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var questionCard: Bool {
        get { self[QuestionCardKey.self] }
        set { self[QuestionCardKey.self] = newValue }
    }
}
