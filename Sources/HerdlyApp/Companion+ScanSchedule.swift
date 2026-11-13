import AppKit
import Foundation
import HerdlyCore

/// The app-side inputs of `HookScanSchedule` (#306): which directories the hook scan lists and
/// watches, and what can change its result without a record arriving in one of them.
extension Companion {
    /// The hook event directories the scan lists: Codex's, and each connected Claude root's.
    var hookScanDirectories: [URL] {
        (eventsPath.isEmpty ? [] : [URL(fileURLWithPath: eventsPath)]) + claude.roots.compactMap { root in
            guard root.status == .connected, !root.eventsPath.isEmpty,
                  let installationID = root.plan?.installationID, !installationID.isEmpty else { return nil }
            return URL(fileURLWithPath: root.eventsPath, isDirectory: true)
        }
    }

    /// What an applied scan found that only another scan can see change.
    func scanNeeds(codexMayRun: Bool, codexActivity: Bool, unreadable: Bool) -> HookScanNeeds {
        var needs = HookScanNeeds()
        needs.codexMayRun = codexMayRun
        needs.sessionsLive = codexActivity
        needs.sourceUnwatchedOrUnreadable = unreadable
        return needs
    }

    /// The last scan's findings joined with what the app holds now. Any of these keeps the scan on its
    /// two-second clock; with none, it runs on change evidence and the safety interval.
    var hookScanNeeds: HookScanNeeds {
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
            || claude.roots.contains { root in
                root.capabilities.supported
                    && !(root.status == .connected && !root.eventsPath.isEmpty && root.plan?.installationID.isEmpty == false)
            }
        // A Claude usage window stops being shown at its reset time: keep the clock across it.
        let soon = Date().timeIntervalSince1970 + HookScanSchedule.safetyInterval
        let readings = Array(claudeUsage.values) + claude.roots.compactMap(\.usage)
        needs.timedStateDue = readings.contains { reading in
            [reading.fiveHour, reading.sevenDay].contains { window in window.map { !($0.resetsAt > soon) } ?? false }
        }
        needs.herdlyInUse = presentationMode != .collapsed || NSApp.isActive
        return needs
    }
}
