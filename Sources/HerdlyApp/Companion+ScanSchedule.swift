import AppKit
import Foundation
import HerdlyCore

/// The app-side inputs of `HookScanSchedule` (#306): which directories the hook scan lists and
/// watches, and what can change its result without a record arriving in one of them.
extension Companion {
    /// The hook event directories the scan lists: Codex's, and each connected Claude root's.
    var hookScanDirectories: [URL] {
        (eventsPath.isEmpty ? [] : [URL(fileURLWithPath: eventsPath)]) + claude.roots.compactMap(\.hookSource).map(\.events)
    }

    /// The last scan's findings joined with what the app holds at `wallNow` (Unix time). Any of these
    /// keeps the scan on its two-second clock; with none, it runs on change evidence and the safety interval.
    func hookScanNeeds(wallNow: Double) -> HookScanNeeds {
        var needs = lastScanNeeds
        needs.rowsHeld = queue.workingCount + queue.toCheckCount > 0 || agentQueue.holdsSessionState
            || !claudeQuestions.live.isEmpty
        needs.sessionsLive = needs.sessionsLive || !liveCLI.subtracting(endedSessions).isEmpty
            || !daemonCLISessions.isEmpty || !codexSessionsAwaitingInventory.isEmpty || !daemonClient.loadedThreads.isEmpty
            || listedClaudeSessions.values.contains { !$0.isEmpty }
            || claudeInventories.values.contains { !$0.sessions.isEmpty || !$0.backgroundSessionIDs.isEmpty }
        // Without Codex's hook directory its sessions are found from rollouts alone; a Claude root read
        // for its inventory but not connected (or waiting for a restart) writes no record Herdly watches.
        needs.sourceUnwatchedOrUnreadable = needs.sourceUnwatchedOrUnreadable || eventsPath.isEmpty
            || claude.roots.contains { $0.capabilities.supported && $0.hookSource == nil }
        needs.timedStateDue = HookScanNeeds.claudeUsageResetDue(Array(claudeUsage.values) + claude.roots.compactMap(\.usage),
                                                                wallNow: wallNow)
        needs.herdlyInUse = presentationMode != .collapsed || NSApp.isActive
        return needs
    }
}
