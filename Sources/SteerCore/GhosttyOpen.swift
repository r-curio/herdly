import Foundation

// ADR 0015 applied to Ghostty's title route (ADR 0005 for Codex, the full Claude title for Claude):
// which outcomes of revalidate → select → verify reach the exact tab, which fall back to raising
// Ghostty, and which stay unavailable. Pure: SteerApp reads the inventories, sends the selection and
// activates the app.

/// What one step of a Ghostty title Open established.
public enum GhosttyTitleRevalidation: Equatable, Sendable {
    /// Exactly one live session renders the title and exactly one unsplit terminal carries it (in the
    /// front window when the route is limited to it).
    case exact(GhosttyTarget)
    /// The exact tab cannot be reached; for a fallback, `candidates` counts the Ghostty terminals
    /// carrying the title, which identifies the app for a Codex session (`codexCandidates(count:)`).
    case miss(OpenMiss)
}

public enum GhosttyTitleOpen {
    /// Step 1 over a fresh inventory.
    ///
    /// - Parameters:
    ///   - live: the shortened titles of every live session of the agent, one entry per session.
    ///   - ghostty: the inventory, nil when it could not be read.
    ///   - running: whether Ghostty is running. A Ghostty that is not running counts as an empty
    ///     inventory (ADR 0013), so the session's app must come from elsewhere.
    ///   - sameWindowOnly: the exact route reaches only the front window (Claude tabs today).
    public static func revalidate(title: String, live: [String], ghostty: GhosttySnapshot?, running: Bool,
                                  sameWindowOnly: Bool) -> GhosttyTitleRevalidation {
        var carriers: [(target: GhosttyTarget, terminalsInTab: Int)] = []
        if running {
            guard let ghostty, ghostty.status == "ok" else { return .miss(.unavailable(.hostUnreadable(.ghostty))) }
            for window in ghostty.windows {
                guard !window.id.isEmpty else { return .miss(.unavailable(.hostUnreadable(.ghostty))) }
                for tab in window.tabs {
                    guard !tab.id.isEmpty else { return .miss(.unavailable(.hostUnreadable(.ghostty))) }
                    for terminal in tab.terminals {
                        guard !terminal.id.isEmpty else { return .miss(.unavailable(.hostUnreadable(.ghostty))) }
                        if terminal.name == title {
                            carriers.append((GhosttyTarget(window_id: window.id, tab_id: tab.id, terminal_id: terminal.id),
                                             tab.terminals.count))
                        }
                    }
                }
            }
        }
        let sessions = live.filter { $0 == title }.count
        guard sessions > 0 else { return .miss(.unavailable(.sessionEnded)) }
        guard sessions == 1, carriers.count == 1, let carrier = carriers.first else {
            return .miss(.fallBack(.noUniqueTarget, candidates: carriers.count))
        }
        guard carrier.terminalsInTab == 1 else { return .miss(.fallBack(.unsupportedLayout, candidates: 1)) }
        if sameWindowOnly, ghostty?.front_window_id != carrier.target.window_id {
            return .miss(.fallBack(.unsupportedLayout, candidates: 1))
        }
        return .exact(carrier.target)
    }

    /// Step 2: Ghostty's reply to the selection, nil when it reported ok. No reply at all (a script
    /// error, a timeout, Automation denied) is an unreadable host; a refusal because the tab changed
    /// under the request is any other error, which falls back (ADR 0016).
    public static func selection(status: String?) -> OpenMiss? {
        guard let status else { return .unavailable(.hostUnreadable(.ghostty)) }
        return status == "ok" ? nil : .fallBack(.notVerified, candidates: 1)
    }

    /// Step 3 over the inventory taken after the selection, nil when it shows `target` selected (and
    /// in the front window when required) and still the title's exact tab. Ghostty is already active,
    /// so a miss falls back, adding nothing (ADR 0016).
    public static func verify(_ target: GhosttyTarget, title: String, live: [String], after: GhosttySnapshot?,
                              sameWindowOnly: Bool) -> OpenMiss? {
        guard let after, !sameWindowOnly || GhosttyMatch.isInCurrentWindow(target, snapshot: after),
              after.selected == target,
              GhosttyMatch.target(title: title, live: live, snapshot: after) == target else {
            return .fallBack(.notVerified, candidates: 1)
        }
        return nil
    }

    /// ADR 0016's sequence for a title-route tab: revalidate on a fresh inventory, select and raise the
    /// tab once, then verify on a fresh inventory. A Ghostty that is not running is an empty inventory
    /// (ADR 0013) and is never asked.
    ///
    /// - Parameters:
    ///   - snapshot: a fresh inventory, nil when it could not be read.
    ///   - select: sends the selection (which rechecks the title and activates Ghostty) and returns
    ///     Ghostty's status, nil when Ghostty did not reply.
    public static func run(title: String, live: [String], running: Bool, sameWindowOnly: Bool,
                           now: @escaping () -> Double,
                           snapshot: @escaping () async -> GhosttySnapshot?,
                           select: @escaping (GhosttyTarget) async -> String?,
                           isolation: isolated (any Actor)? = #isolation) async -> TerminalOpenRun<GhosttyTarget, OpenMiss> {
        await TerminalOpenSequence.run(TerminalOpenSteps<GhosttyTarget, OpenMiss>(
            now: now,
            revalidate: { _ in
                let before = running ? await snapshot() : nil
                switch revalidate(title: title, live: live, ghostty: before, running: running,
                                  sameWindowOnly: sameWindowOnly) {
                case .exact(let target): return .success(target)
                case .miss(let miss): return .failure(miss)
                }
            },
            raise: { target in selection(status: await select(target)) },
            verify: { target in
                verify(target, title: title, live: live, after: await snapshot(), sameWindowOnly: sameWindowOnly)
            }))
    }

    /// The amendment's Codex candidates for `count` Ghostty terminals carrying the title. Until
    /// Ghostty exposes `tty`, its tabs bind by title alone (ADR 0013), so each titled terminal in
    /// Ghostty's own inventory is a candidate in Ghostty; tty times are not read, and are not needed
    /// while every candidate is in one app.
    public static func codexCandidates(count: Int) -> [CodexOpenCandidate] {
        Array(repeating: CodexOpenCandidate(walk: .reached(.ghostty), ttyWrittenAt: nil), count: max(0, count))
    }
}

extension TerminalHostInventory {
    /// Ghostty's inventory for ADR 0013 while it does not expose `tty` (#251): every terminal with its
    /// title and its tab's terminal count, and no tty, so it counts toward Codex title uniqueness across
    /// enabled hosts but never binds by tty (`ttyUnknown`). A running Ghostty whose inventory failed is
    /// unreadable; one that is not running holds nothing.
    public static func ghosttyTitles(_ snapshot: GhosttySnapshot?, running: Bool) -> TerminalHostInventory {
        guard running else { return .notRunning }
        guard let snapshot, snapshot.status == "ok" else { return .unreadable }
        var tabs: [TerminalTab] = []
        for window in snapshot.windows {
            for tab in window.tabs {
                for terminal in tab.terminals {
                    guard !terminal.id.isEmpty else { return .unreadable }
                    tabs.append(TerminalTab(tabID: terminal.id, tty: nil, title: terminal.name, paneCount: tab.terminals.count))
                }
            }
        }
        return .tabs(tabs)
    }
}
