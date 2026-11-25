import Foundation

/// Every change Herdly makes to a Claude folder's files runs here, one at a time: Configure, Undo
/// Setup, the helper refresh, and detection's automatic usage upgrade (#481). A switch flipped while
/// detection adds usage therefore waits for it instead of interleaving with it. Each body reads the
/// files it changes when its turn comes, and the installer refuses settings that changed since its
/// plan was read, so a change queued behind another never writes from stale bytes. Bodies are
/// synchronous, so nothing else runs on this actor until one returns.
actor ClaudeSetupWrites {
    static let shared = ClaudeSetupWrites()

    func run<T: Sendable>(_ body: @Sendable () throws -> T) rethrows -> T {
        try body()
    }
}
