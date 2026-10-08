import Foundation
import SteerCore

/// Whether the Ghostty bundle declares each terminal's `tty` (ADR 0011), read off the main actor
/// and cached for presentation. The bundle can change while Steer runs, so a read older than
/// `maximumAge` is refreshed on the next request. Open's click-time recheck reads it fresh itself.
@MainActor
final class GhosttyTTYSupportMonitor: ObservableObject {
    static let shared = GhosttyTTYSupportMonitor()
    static let maximumAge: TimeInterval = 30

    /// Nil until the first read completes; presentation then lists no Ghostty problem.
    @Published private(set) var support: GhosttyTTYSupport?
    private var readAt: TimeInterval?
    private var reading = false

    func refreshIfStale(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !reading, readAt.map({ now - $0 >= Self.maximumAge }) ?? true else { return }
        reading = true
        Task { @MainActor in
            let value = await Task.detached(priority: .utility) { GhosttyScriptingSupport.ttySupport() }.value
            reading = false
            readAt = ProcessInfo.processInfo.systemUptime
            if support != value { support = value }
        }
    }
}

extension Companion {
    /// The herdr session key of a CLI session, or nil for any other surface.
    func herdrSessionKey(_ identity: AgentSessionIdentity) -> HerdrSessionKey? {
        guard identity.surface == .cli || isCodexTerminalSession(identity) else { return nil }
        let agent: HerdrAgentKind = switch identity.source {
        case .codex: .codex
        case .claude: .claude
        }
        return HerdrSessionKey(agent: agent, sessionID: identity.session)
    }

    /// Whether the notch offers Open for a session, from the latest scan and Ghostty's `tty`
    /// support. Reading this never contacts herdr. A session not in herdr keeps the Ghostty rules.
    func herdrOpenAvailability(_ identity: AgentSessionIdentity,
                               ttySupport: GhosttyTTYSupport?) -> HerdrOpenAvailability {
        guard let key = herdrSessionKey(identity) else { return .notInHerdr }
        return HerdrPresentation.openAvailability(binding: herdrBinding(for: key), ttySupport: ttySupport)
    }
}
