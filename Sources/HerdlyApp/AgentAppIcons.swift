import AppKit
import HerdlyCore

/// The app icons Settings › Agents shows beside each agent (#481, A2), looked up once per launch.
/// Codex uses `app.icns` from the app with Codex's bundle ID (Finder names it "ChatGPT"); its bundle
/// icon is the ChatGPT knot, so it is only the fallback. Claude Code uses Claude.app's bundle icon.
/// Nil means the app isn't installed and the row keeps its symbol tile.
@MainActor
enum AgentAppIcons {
    private static var cache: [AgentSource: NSImage?] = [:]

    static func icon(for agent: AgentSource) async -> NSImage? {
        if let cached = cache[agent] { return cached }
        let source = await Task.detached(priority: .utility) { IconSource.resolve(agent) }.value
        let image: NSImage? = switch source {
        case .file(let data)?: NSImage(data: data)
        case .bundle(let path)?: NSWorkspace.shared.icon(forFile: path)
        case nil: nil
        }
        cache[agent] = image
        return image
    }

    /// Where an agent's icon comes from, found off the main actor.
    private enum IconSource: Sendable {
        case file(Data)
        case bundle(String)

        /// An `.icns` larger than this is not an icon worth reading.
        static let maximumIconBytes = 16 * 1024 * 1024

        static func resolve(_ agent: AgentSource) -> IconSource? {
            let identifier = switch agent {
            case .codex: CodexSetupDetection.desktopBundleIdentifier
            case .claude: ClaudeDesktopSessionIndex.bundleIdentifier
            }
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
            if agent == .codex,
               let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/app.icns"), options: .mappedIfSafe),
               data.count <= maximumIconBytes {
                return .file(data)
            }
            return .bundle(app.path)
        }
    }
}
