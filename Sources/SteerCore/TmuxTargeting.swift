import Foundation

// tmux targeting (#241): ADR 0014's layout and client checks, its two-layer Open, ADR 0016's visible
// test for a pane, and ADR 0017's typed input. Pure; SteerApp runs the commands (TmuxClient.swift).

/// How one tmux command ended, from SteerApp's side (`TmuxClient.run`).
public enum TmuxCommandOutcome: Equatable, Sendable {
    /// Exit status 0, with this stdout.
    case succeeded(String)
    /// A non-zero exit: tmux refused before acting (an unknown pane or client, no server).
    case failed
    /// No exit within the bounded wait; the process was terminated. It may have acted.
    case timedOut
    /// The binary could not be started.
    case notLaunched
}

// MARK: - Layout and clients

/// Why a bound tmux pane cannot be targeted. Each is a layout or pane state, never a reason to pick
/// another pane.
public enum TmuxPaneUnavailable: Error, Equatable, Hashable, Sendable {
    /// The pane is no longer listed.
    case paneGone
    /// Its window holds more than one pane (ADR 0004).
    case split
    /// It is listed in more than one session, or its session is grouped: `switch-client` would move
    /// every client of another session too, so Steer never acts on it.
    case groupedSession
    /// A client of its session runs inside a tmux pane: a multiplexer in a multiplexer.
    case nested
    /// Copy mode or another mode: keys would become mode commands, and a send there hung live.
    case inMode
    case paneDead
    /// `select-pane -d`: keys would be dropped silently.
    case inputOff
    /// No client is attached to the pane's session.
    case noClient
    /// `count` clients are attached to the pane's session.
    case clients(Int)
    /// The session's one client is a control-mode client, which has no host tab.
    case controlModeClient
}

public enum TmuxLayout {
    /// ADR 0014's pane layer: the pane listed once, alone in its window, and not nested. Enough for typed
    /// input together with `inputLayer`; Open also needs `client(for:in:)` and the host-tab join.
    public static func paneLayer(_ paneID: String, in snapshot: TmuxSnapshot) -> TmuxPaneUnavailable? {
        let listings = snapshot.listings(of: paneID)
        guard let pane = listings.first else { return .paneGone }
        guard listings.count == 1, !pane.sessionGrouped else { return .groupedSession }
        guard pane.windowPanes == 1 else { return .split }
        let paneTTYs = Set(snapshot.panes.map(\.tty))
        if snapshot.clients.contains(where: { $0.sessionID == pane.sessionID && paneTTYs.contains($0.tty) }) {
            return .nested
        }
        return nil
    }

    /// The pane layer plus what a send needs (ADR 0017): not in a mode, alive, accepting input. The
    /// host-tab join is not required, because the bytes never pass through the host tab.
    public static func inputLayer(_ paneID: String, in snapshot: TmuxSnapshot) -> TmuxPaneUnavailable? {
        if let reason = paneLayer(paneID, in: snapshot) { return reason }
        guard let pane = snapshot.listings(of: paneID).first else { return .paneGone }
        if pane.inMode { return .inMode }
        if pane.dead { return .paneDead }
        if pane.inputOff { return .inputOff }
        return nil
    }

    /// The one client attached to the pane's session (ADR 0014): zero or several are unavailable, and a
    /// control-mode client has no host tab.
    public static func client(for paneID: String, in snapshot: TmuxSnapshot) -> Result<TmuxClient, TmuxPaneUnavailable> {
        guard let pane = snapshot.listings(of: paneID).first else { return .failure(.paneGone) }
        let attached = snapshot.clients.filter { $0.sessionID == pane.sessionID }
        guard let client = attached.first else { return .failure(.noClient) }
        guard attached.count == 1 else { return .failure(.clients(attached.count)) }
        guard !client.controlMode else { return .failure(.controlModeClient) }
        return .success(client)
    }
}

// MARK: - Open (ADR 0014 "Open sequence")

/// What revalidation established and every later step must still hold: the bound pane, the one client
/// of its session, and where that client's tty joins (`MultiplexerHostTab.join`, or Ghostty's own join).
public struct TmuxOpenPlan: Equatable, Sendable {
    public let pane: TerminalTabTarget
    public let client: TmuxClient
    public let host: MultiplexerHostTarget

    public init(pane: TerminalTabTarget, client: TmuxClient, host: MultiplexerHostTarget) {
        self.pane = pane
        self.client = client
        self.host = host
    }
}

public enum TmuxOpen {
    /// Step 1 over a fresh binding (ADR 0013 across every enabled host, tmux panes included) and the
    /// tmux read behind it. `join` is called only once the pane and its one client hold, with that
    /// client's tty. A binding miss resolves as any tab's (ADR 0015); a layout or client problem falls
    /// back, and the fallback walks the session's clients (`fallbackClientPIDs`).
    public static func plan(_ binding: TerminalTabBinding, snapshot: TmuxSnapshot,
                            join: (String) -> MultiplexerHostJoin) -> Result<TmuxOpenPlan, OpenMiss> {
        let pane: TerminalTabTarget
        switch binding {
        case .unavailable(let reason): return .failure(TerminalTabOpen.miss(reason))
        case .bound(let target):
            guard target.host == .tmux else { return .failure(.fallBack(.noUniqueTarget, candidates: 1)) }
            pane = target
        }
        if TmuxLayout.paneLayer(pane.tabID, in: snapshot) != nil { return .failure(.fallBack(.unsupportedLayout, candidates: 1)) }
        let client: TmuxClient
        switch TmuxLayout.client(for: pane.tabID, in: snapshot) {
        case .success(let value): client = value
        case .failure: return .failure(.fallBack(.unsupportedLayout, candidates: 1))
        }
        switch join(client.tty) {
        case .tab(let tab): return .success(TmuxOpenPlan(pane: pane, client: client, host: .tab(tab)))
        case .ghostty: return .success(TmuxOpenPlan(pane: pane, client: client, host: .ghostty))
        case .miss(let miss): return .failure(miss)
        }
    }

    /// Step 2, sent once and never retried: moves the one client to the pane within its own session.
    public static func focusArguments(_ plan: TmuxOpenPlan) -> [String] {
        ["switch-client", "-c", plan.client.tty, "-t", plan.pane.tabID]
    }

    /// Step 2's result: whether it moved the client is step 3's to say. A failure falls back without
    /// touching the host tab; a binary that no longer starts is unreadable.
    public static func focused(_ outcome: TmuxCommandOutcome) -> OpenMiss? {
        switch outcome {
        case .succeeded: nil
        case .failed, .timedOut: .fallBack(.notVerified, candidates: 1)
        case .notLaunched: .unavailable(.hostUnreadable(.tmux))
        }
    }

    /// Step 3 over a fresh read and the binding re-run on it: the same client (tty and pid) is still the
    /// session's only one and now shows the pane, whose layout still holds.
    public static func verifyPane(_ plan: TmuxOpenPlan, read: TmuxRead, binding: TerminalTabBinding) -> OpenMiss? {
        let notVerified = OpenMiss.fallBack(.notVerified, candidates: 1)
        guard binding == .bound(plan.pane), let snapshot = read.snapshot,
              TmuxLayout.paneLayer(plan.pane.tabID, in: snapshot) == nil,
              case .success(let client) = TmuxLayout.client(for: plan.pane.tabID, in: snapshot),
              client.tty == plan.client.tty, client.pid == plan.client.pid,
              client.paneID == plan.pane.tabID else { return notVerified }
        return nil
    }

    /// Steps 4 and 5 by the host's own Open, after the pane verified: a host miss that would fall back is
    /// a partial reach, keeping the pane focus; an unavailable one (Automation denied, the tab gone)
    /// stays unavailable.
    public static func hostRaised(_ miss: OpenMiss?) -> OpenMiss? {
        guard case .fallBack? = miss else { return miss }
        return .fallBack(.partialReach, candidates: 1)
    }

    /// Every client attached to the pane's session, which an Open fallback walks to the app hosting it
    /// (ADR 0015, "Which app and window"). None leaves the app unidentified.
    public static func fallbackClientPIDs(for paneID: String, in snapshot: TmuxSnapshot?) -> [Int32] {
        guard let snapshot, let pane = snapshot.listings(of: paneID).first else { return [] }
        return snapshot.clients.filter { $0.sessionID == pane.sessionID }.map(\.pid)
    }

    /// ADR 0016's sequence with tmux's two layers, each step at most once, stopping at the first failure.
    /// Failures of the host steps pass through `hostRaised`.
    public static func run(now: @escaping () -> Double,
                           revalidate: @escaping () async -> Result<TmuxOpenPlan, OpenMiss>,
                           focus: @escaping (TmuxOpenPlan) async -> OpenMiss?,
                           verifyPane: @escaping (TmuxOpenPlan) async -> OpenMiss?,
                           raise: @escaping (TmuxOpenPlan) async -> OpenMiss?,
                           verifyHost: @escaping (TmuxOpenPlan) async -> OpenMiss?,
                           isolation: isolated (any Actor)? = #isolation) async -> TerminalOpenRun<TmuxOpenPlan, OpenMiss> {
        await TerminalOpenSequence.run(TerminalOpenSteps(
            now: now, revalidate: { _ in await revalidate() }, focusPane: focus, verifyPane: verifyPane,
            raise: { hostRaised(await raise($0)) }, verify: { hostRaised(await verifyHost($0)) }))
    }
}
