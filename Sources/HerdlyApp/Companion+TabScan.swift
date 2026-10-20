import AppKit
import Foundation
import HerdlyCore

/// What Terminal.app's part of a shared scheduled read binds, captured on the main actor.
struct TerminalAppScanPlan {
    let codexSessions: Set<UUID>
    let claudeRows: [AgentSessionIdentity: [ClaudeInventorySession]]
    let generation: Int
}

/// What tmux's part of a shared scheduled read binds, captured on the main actor.
struct TmuxScanPlan {
    let codexSessions: Set<UUID>
    let claudeRows: [AgentSessionIdentity: [ClaudeInventorySession]]
    let livePIDs: [Int32]
    let generation: Int
}

/// What Zellij's part of a shared scheduled read binds, captured on the main actor.
struct ZellijScanPlan {
    let codexSessions: Set<UUID>
    let claudeRows: [AgentSessionIdentity: [ClaudeInventorySession]]
    let generation: Int
}

extension Companion {
    /// One scheduled `TerminalTabReads` for Terminal.app, tmux and Zellij every two seconds (#301).
    /// Each read covers every enabled host, so the three used to read the same hosts up to three
    /// times a cycle on their own clocks. They now share one read and one clock. Open, typed input
    /// and question keys still take their own fresh reads (ADR 0013, 0015).
    func checkScheduledTabHosts() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let terminalPlan = terminalAppScanPlan()
        let tmuxPlan = tmuxScanPlan()
        let zellijPlan = zellijScanPlan()
        var eligible: [TerminalHost: Double] = [:]
        if terminalPlan != nil { eligible[.terminalApp] = terminalApp.nextScan }
        if tmuxPlan != nil { eligible[.tmux] = tmux.nextScan }
        if zellijPlan != nil { eligible[.zellij] = zellij.nextScan }
        var hosts = SharedTabScan.hostsToRead(eligible: eligible, now: uptime)
        if hosts.contains(.terminalApp), !terminalAppStillRunning() { hosts.remove(.terminalApp) }
        guard !hosts.isEmpty else { return }
        let next = uptime + SharedTabScan.interval
        let terminalRead = hosts.contains(.terminalApp) ? terminalPlan : nil
        if terminalRead != nil { terminalApp.scanning = true; terminalApp.nextScan = next }
        let tmuxRead = hosts.contains(.tmux) ? tmuxPlan : nil
        if tmuxRead != nil { tmux.scanning = true; tmux.nextScan = next }
        let zellijRead = hosts.contains(.zellij) ? zellijPlan : nil
        if zellijRead != nil { zellij.scanning = true; zellij.nextScan = next }

        // The hosts derive the same rows from the queue; merged, each Claude process is read once.
        let claudeRows = [terminalRead?.claudeRows, tmuxRead?.claudeRows, zellijRead?.claudeRows]
            .compactMap { $0 }.reduce(into: [AgentSessionIdentity: [ClaudeInventorySession]]()) { merged, rows in
                merged.merge(rows) { first, _ in first }
            }
        let livePIDs = tmuxRead?.livePIDs ?? []
        let others = otherTabHosts
        // ADR 0016: frontmost comes from macOS as the scan starts.
        let frontmost = TerminalApps.frontmostHost()
        let terminalPID = frontmost == .terminalApp ? TerminalAppNavigation.pid() : nil
        Task { @MainActor in
            let takenAt = Date().timeIntervalSince1970
            let observed = await Task.detached { () -> (TerminalTabReads, [AgentSessionIdentity: ClaudeTabProcess],
                                                        [TmuxSessionProcess], Set<Int>?,
                                                        TerminalVisibilityReading<String>) in
                let claude = claudeRows.mapValues(ClaudeTabProcess.read)
                let reads = TerminalTabReads.take(others: others, claudeTTYs: Set(claude.values.compactMap(\.tty)), second: false)
                let processes = livePIDs.map { pid in
                    let chain = HerdrProcessTree.ancestry(of: pid)
                    return TmuxSessionProcess(tty: chain.first?.tty, ancestorCommands: chain.map(\.command))
                }
                let onScreen = terminalPID.flatMap { TerminalAppNavigation.onScreenWindowIDs(pid: $0) }
                return (reads, claude, processes, onScreen, Companion.hostFront(reads, frontmost: frontmost, onScreen: onScreen))
            }.value
            let (reads, claude, processes, onScreen, hostFront) = observed
            if let terminalRead {
                finishTerminalAppScan(terminalRead, reads: reads, claude: claude, frontmost: frontmost,
                                      onScreen: onScreen, takenAt: takenAt)
            }
            if let tmuxRead {
                finishTmuxScan(tmuxRead, reads: reads, claude: claude, processes: processes, hostFront: hostFront,
                               takenAt: takenAt)
            }
            if let zellijRead {
                finishZellijScan(zellijRead, reads: reads, claude: claude, hostFront: hostFront, takenAt: takenAt)
            }
            refresh()
        }
    }
}
