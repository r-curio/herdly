import Foundation

// Settings › About (Paper "Herdly Settings" › "About redesign (2026-11-25)", AB1–AB5, #483).

/// The version pill: the bundle's marketing version with its build dimmed, and what a click copies.
public struct AboutVersion: Equatable, Sendable {
    /// `CFBundleShortVersionString`, or nil for a development build with none.
    public let version: String?
    /// `CFBundleVersion`, shown only beside a version.
    public let build: String?

    /// Reads the two Info.plist values; empty or whitespace values count as missing.
    public init(version: String?, build: String?) {
        func present(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        self.version = present(version)
        self.build = self.version == nil ? nil : present(build)
    }

    public init(infoDictionary: [String: Any]?) {
        self.init(version: infoDictionary?["CFBundleShortVersionString"] as? String,
                  build: infoDictionary?["CFBundleVersion"] as? String)
    }

    /// The pill's leading text in the primary colour: the version, or "Development" without one.
    public var primaryText: String { version ?? "Development" }

    /// The dimmed suffix, " (build N)", or nil with no build.
    public var buildText: String? { build.map { " (build \($0))" } }

    /// What a click puts on the pasteboard: "0.1.0 (N)", "0.1.0" with no build, or "Development".
    public var copyText: String {
        guard let version else { return "Development" }
        return build.map { "\(version) (\($0))" } ?? version
    }

    /// VoiceOver's reading of the pill.
    public var accessibilityLabel: String {
        guard let version else { return "Version Development" }
        return build.map { "Version \(version), build \($0)" } ?? "Version \(version)"
    }
}

/// The "Works with" section: one row each for agents, terminal apps and multiplexers (AB4).
public enum AboutWorksWith {
    /// Every agent surface Herdly supports, in Settings order.
    public static let agents = ["Codex desktop", "Codex CLI", "Claude Code", "Claude Desktop"]
    /// Terminal apps whose Settings card is shown, in Settings order.
    public static var terminals: [String] { TerminalHost.terminals.filter(\.showsCard).map(\.displayName) }
    /// Multiplexers whose Settings card is shown, in Settings order.
    public static var multiplexers: [String] { TerminalHost.multiplexers.filter(\.showsCard).map(\.displayName) }
}
