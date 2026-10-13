import AppKit
import SteerCore

// The Open line on terminal session cards (#267; product.md, Notch, "Open unavailable"). A scan every
// three seconds, while a Codex or Claude CLI card outside herdr (other than running work) is queued,
// picks each card's Open route on `CodexTabReads` of the hosts Steer may contact (SteerCore's
// `TerminalOpenScan`, which lists what it shares with a click) and resolves a miss with ADR 0015's
// fallback rules. A card whose Open is unavailable shows the reason's line in place of
// Open; a fallback shows nothing. A click's own recheck records its result too, so an Open the scan
// offered but the click found unavailable shows the same line on that card until the next scan. herdr
// sessions keep their own presentation (Companion+HerdrPresentation.swift).

/// The availability scan's scheduling. Main-actor only; memory only.
@MainActor
final class OpenAvailabilityScanState {
    var scanning = false
    var nextScan: Double = 0
}

/// The sessions one scan classifies, read on the main actor.
private struct OpenAvailabilityTargets: Sendable {
    var codex: [String: UUID] = [:]
    /// A card other than running work is queued: only then does the scan run (review round 1, S3).
    var openCardQueued = false
    var claude: [String: (identity: AgentSessionIdentity, rows: [ClaudeInventorySession], records: [HerdrHookPaneRecord])] = [:]

    var isEmpty: Bool { codex.isEmpty && claude.isEmpty }
}

/// What the scan read off the main actor: each session's route, and the walks and tty times its
/// fallback needs. Availability is resolved back on the main actor, where `TerminalApps.isRunning` reads.
private struct OpenAvailabilityObservations: Sendable {
    var routes: [String: (route: OpenScanRoute, agent: AgentSource)] = [:]
    var walks: [Int32: TerminalAppWalk] = [:]
    var ttyWrittenAt: [String: Double] = [:]
}

extension Companion {
    /// The key of a card's Open line, nil for a card that has none (a desktop session).
    func openLineKey(_ identity: AgentSessionIdentity) -> String? {
        switch identity.source {
        case .codex:
            guard isCodexTerminalSession(identity), let session = codexSession(identity) else { return nil }
            return openLineKey(codex: session)
        case .claude:
            guard identity.surface == .cli else { return nil }
            return "claude:\(identity.sourceScope):\(identity.session)"
        }
    }

    func openLineKey(codex session: UUID) -> String { "codex:\(session.uuidString.lowercased())" }

    /// Whether a terminal card offers Open: the latest scan did not find it unavailable.
    func offersTerminalOpen(_ identity: AgentSessionIdentity) -> Bool {
        openLineKey(identity).map(openLines.offersOpen) ?? true
    }

    /// The reason whose line a terminal card shows, from the scan or a click; nil for none.
    func terminalOpenLine(_ identity: AgentSessionIdentity) -> OpenUnavailableReason? {
        openLineKey(identity).flatMap(openLines.line(for:))
    }

    /// Records a Codex Open's result on its card (product.md: a click-time unavailable cause shows the
    /// same line as the navigation message, on that card).
    func recordOpen(_ result: TerminalOpenResult, codex session: UUID) {
        updateOpenLines { $0.recordOpen(result, for: openLineKey(codex: session), at: Date().timeIntervalSince1970) }
    }

    func recordOpen(_ result: TerminalOpenResult, claude identity: AgentSessionIdentity) {
        guard let key = openLineKey(identity) else { return }
        updateOpenLines { $0.recordOpen(result, for: key, at: Date().timeIntervalSince1970) }
    }

    /// Publishes only a change, so the 0.2 s refresh does not redraw the notch for nothing.
    private func updateOpenLines(_ change: (inout OpenUnavailableLines<String>) -> Void) {
        var lines = openLines
        change(&lines)
        if lines != openLines { openLines = lines }
    }

    /// The terminal cards whose Open takes a terminal route this scan can follow: Codex terminal sessions
    /// and live Claude CLI sessions with Open, neither routed through herdr (as `openCLI` and
    /// `openClaude` decide).
    private var openAvailabilityTargets: OpenAvailabilityTargets {
        var targets = OpenAvailabilityTargets()
        for item in orderedAgentAttentionItems {
            let identity = item.session
            guard let key = openLineKey(identity) else { continue }
            let openCard = item.kind != .running && item.kind != .waiting
            switch identity.source {
            case .codex:
                guard cliTerminalHostOn, let session = codexSession(identity) else { continue }
                let herdrRoute = herdrBinding(for: HerdrSessionKey(agent: .codex, sessionID: session.uuidString))
                if herdrRoute != .notInHerdr, ghosttyEnabled || herdrRoute != .unavailable(.ghosttyControlsOff) { continue }
                targets.codex[key] = session
                if openCard { targets.openCardQueued = true }
            case .claude:
                guard !isBackgroundClaudeSession(identity), canOpenClaude(identity) else { continue }
                let herdrRoute = herdrBinding(for: HerdrSessionKey(agent: .claude, sessionID: identity.session))
                if herdrRoute != .notInHerdr, herdrRoute != .unavailable(.ghosttyControlsOff) { continue }
                let rows = (claudeInventories[identity.sourceScope]?.sessions ?? [])
                    .filter { $0.kind == .interactive && $0.sessionID == identity.session }
                targets.claude[key] = (identity, rows, newestHookRecords(forClaudeSession: identity.session))
                if openCard { targets.openCardQueued = true }
            }
        }
        return targets
    }

    /// Seconds between availability scans.
    static let openAvailabilityInterval: Double = 3
    /// The oldest Ghostty inventory, in seconds, the scan reuses while Ghostty is the only host on
    /// (Ghostty's own scan runs every two seconds).
    static let openAvailabilityGhosttyMaxAge: Double = 6

    /// Every `openAvailabilityInterval` seconds while a terminal card other than running work is queued
    /// (running cards are classified alongside); one scan at a time, none during an Open, and none before
    /// the first reminder scan has said which Codex sessions are live. Hosts Steer may contact are read
    /// through `CodexTabReads.read`, as the iTerm2 Open's revalidation reads them; with Ghostty alone on,
    /// Ghostty's latest scan is reused and nothing is read.
    func checkOpenAvailability() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard previewMode == nil, !openAvailability.scanning, !openingTask, uptime >= openAvailability.nextScan else { return }
        let keys = Set(orderedAgentAttentionItems.compactMap { openLineKey($0.session) })
        updateOpenLines { $0.retain(keys) }
        let targets = openAvailabilityTargets
        // A host whose Automation consent is not settled is never read on a schedule, so no scan raises
        // macOS's prompt; Ghostty controls awaiting Automation cannot be read yet. A click still rechecks.
        func consentSettled(_ access: GhosttyAutomationAccess?) -> Bool {
            switch access {
            case nil, .consentRequired?: false
            default: true
            }
        }
        let consentPending = (hostSwitches.mayContact(.iTerm2) && (iTerm2.probing || !consentSettled(iTerm2.access)))
            || (terminalAppSwitchedOn && (terminalApp.probing || !consentSettled(terminalApp.access)))
        guard !targets.isEmpty, targets.openCardQueued, cliLivenessRead, !ghosttyEnabled || ghosttyPermissionVerified, !consentPending else {
            updateOpenLines { $0.applyScan([:], startedAt: Date().timeIntervalSince1970) }
            return
        }
        let others = otherTabHosts
        let otherHostOn = others.iTerm2Running != nil || others.terminalAppOn || others.wezTermRunning != nil
            || others.tmuxOn || others.zellijOn
        // Ghostty alone: its title route reads the inventory Ghostty's own two-second scan took.
        var ghosttySnapshot: GhosttySnapshot?
        var ghosttyRunning = others.ghosttyRunning
        if !otherHostOn {
            ghosttyRunning = ghosttyEnabled && TerminalApps.isRunning(.ghostty)
            ghosttySnapshot = knownGhosttySnapshot
            let fresh = Date().timeIntervalSince1970 - ghosttyInventoryAt <= Self.openAvailabilityGhosttyMaxAge
            if ghosttyRunning, ghosttySnapshot == nil || !fresh {
                // Nothing current to follow the route on: no card keeps a stale scan line.
                updateOpenLines { $0.applyScan([:], startedAt: Date().timeIntervalSince1970) }
                return
            }
        }
        openAvailability.scanning = true
        openAvailability.nextScan = uptime + Self.openAvailabilityInterval
        let terminalAppRunning: Bool? = terminalAppSwitchedOn ? TerminalApps.isRunning(.terminalApp) : nil
        let titles = Set(targets.codex.values.map(GhosttyMatch.title))
        let switches = hostSwitches
        let ghosttyOn = ghosttyEnabled
        let live = liveCLI
        let lastSeen = lastSeenHosts
        let liveClaude = liveClaudeSessions.values.flatMap { $0 }
        let snapshot = ghosttySnapshot
        let running = ghosttyRunning
        let startedAt = Date().timeIntervalSince1970
        Task { @MainActor in
            let observed = await Task.detached { () -> OpenAvailabilityObservations in
                let claudeProcesses = targets.claude.mapValues { ClaudeTabProcess.read($0.rows) }
                var reads = TerminalOpenScanReads(switches: switches, ghosttyOn: ghosttyOn, inventories: [:], processes: [:],
                                                  secondRead: [:], ghostty: snapshot, ghosttyRunning: running)
                if otherHostOn {
                    let taken = CodexTabReads.read(titles: titles, claudeTTYs: Set(claudeProcesses.values.compactMap(\.tty)),
                                                   ghosttyOn: others.ghosttyOn, ghosttyRunning: others.ghosttyRunning,
                                                   iTerm2Running: others.iTerm2Running, terminalAppRunning: terminalAppRunning,
                                                   wezTermRunning: others.wezTermRunning, tmuxOn: others.tmuxOn,
                                                   zellijOn: others.zellijOn)
                    reads = TerminalOpenScanReads(switches: switches, ghosttyOn: ghosttyOn, inventories: taken.inventories,
                                                  processes: taken.processes, secondRead: taken.secondRead,
                                                  multiplexerClientTTYs: taken.multiplexerClientTTYs, tmux: taken.tmux,
                                                  zellij: taken.zellij, ghostty: taken.ghostty, ghosttyRunning: running)
                }
                var result = OpenAvailabilityObservations()
                for (key, session) in targets.codex {
                    let route = TerminalOpenScan.codex(session: session, liveSessions: live, reads: reads,
                                                       lastSeenHost: lastSeen[session])
                    result.routes[key] = (route, .codex)
                }
                for (key, target) in targets.claude {
                    let process = claudeProcesses[key] ?? ClaudeTabProcess(process: .unidentified, observed: nil)
                    let route = TerminalOpenScan.claude(sessionID: target.identity.session, process: process.process,
                                                        observed: process.observed, newestRecords: target.records,
                                                        liveSessionIDs: liveClaude, reads: reads)
                    result.routes[key] = (route, .claude)
                }
                for pid in Set(result.routes.values.flatMap(\.route.pidsToWalk)) { result.walks[pid] = TerminalApps.walk(from: pid) }
                for tty in Set(result.routes.values.flatMap(\.route.ttysToTime)) {
                    result.ttyWrittenAt[tty] = TerminalTTYReads.writtenAt(tty)
                }
                return result
            }.value
            openAvailability.scanning = false
            // A switch that moved during the scan makes its reads apply to nothing.
            guard switches == hostSwitches, ghosttyOn == ghosttyEnabled else { return }
            let results = observed.routes.mapValues { entry in
                entry.route.availability(agent: entry.agent, switches: switches, walks: observed.walks,
                                         ttyWrittenAt: observed.ttyWrittenAt, isRunning: TerminalApps.isRunning)
            }
            let current = Set(orderedAgentAttentionItems.compactMap { openLineKey($0.session) })
            updateOpenLines { lines in
                lines.applyScan(results.filter { current.contains($0.key) }, startedAt: startedAt)
                lines.retain(current)
            }
        }
    }
}
