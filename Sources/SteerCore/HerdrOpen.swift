import Foundation

// ADR 0011: Open in Codex or Open in Claude for a session in a herdr tab. Steer focuses the bound
// herdr pane and then selects the Ghostty tab hosting herdr's single client, found only by an exact
// TTY join. Every step below is a pure function of the observations passed in; SteerApp supplies
// the herdr scans, Ghostty inventories, the socket focus and the Ghostty selection, and owns the
// main actor and scheduling. Nothing here retries, rolls back, falls back to another pane or tab,
// or sends input.

/// The five steps of ADR 0011's sequence, in order.
public enum HerdrOpenStep: Int, CaseIterable, Comparable, Sendable {
    /// Re-read herdr, `lsof` and a fresh Ghostty inventory, and join the client's TTY to one tab.
    case revalidate = 1
    /// Send `agent.focus` for the bound pane, once.
    case focusHerdr
    /// A fresh herdr scan must show exactly the bound pane focused, with the binding and client unchanged.
    case verifyHerdr
    /// Select the matched Ghostty tab and activate Ghostty.
    case raiseGhostty
    /// A fresh Ghostty inventory must show the matched tab selected, frontmost, with the join unchanged.
    case verifyGhostty

    public static func < (lhs: HerdrOpenStep, rhs: HerdrOpenStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why a herdr Open did not report Opened: one typed reason per failed step (ADR 0011). Every reason
/// retains the completion or reminder; none clears attention or grants a decision. The reason is for
/// diagnostics and for grouping on the card (docs/product.md, "Agreed herdr presentation").
public enum HerdrOpenFailure: Error, Equatable, Sendable {
    // Step 1: revalidate.
    /// The Ghostty bundle does not declare a terminal `tty` (Ghostty 1.3.1). No longer produced by
    /// `HerdrOpen.plan`, which applies the sole-terminal rule instead and reports its failure as
    /// `ghosttyTab(.ttyUnsupported)`; kept so recorded failures and the card mapping stay total.
    case ghosttyTTYUnsupported
    /// The fresh scan no longer puts the session in herdr: for Claude Code its newest hook event
    /// records no pane, for Codex no pane shows its title (ADR 0012). Open does not fall back to the
    /// Ghostty title route from a herdr click.
    case sessionNotInHerdr
    /// The fresh scan's binding is unavailable (ADR 0008 or ADR 0012 and ADR 0009 reasons, including the gate).
    case binding(HerdrSessionUnavailable)
    /// The single attached client's TTY could not be read or is not a `/dev/ttysNNN` device.
    case clientTTYUnknown
    /// Steer could not read Ghostty's tabs.
    case ghosttyInventoryUnavailable
    /// The client's TTY did not join to exactly one unsplit Ghostty tab in the current window. Never
    /// carries `.matched`.
    case ghosttyTab(GhosttyTTYJoin)

    // Step 2: focus herdr.
    /// herdr did not accept `agent.focus` (socket, timeout, refusal or malformed reply). Not retried.
    case focusRejected(HerdrUnavailableReason)

    // Step 3: verify herdr.
    /// The verification scan's binding is unavailable.
    case herdrVerifyUnavailable(HerdrSessionUnavailable)
    /// The verification scan binds the session to another pane, or no longer to a herdr pane.
    case herdrBindingChanged
    /// The verification snapshot does not show exactly the bound pane focused.
    case herdrPaneNotFocused
    /// The attached client's process or TTY differs from the revalidated one.
    case herdrClientChanged

    // Step 4: raise Ghostty.
    /// Ghostty refused the selection or its inventory changed under the request.
    case ghosttySelectFailed

    // Step 5: verify Ghostty.
    /// Steer could not read Ghostty's tabs after the selection.
    case ghosttyVerifyInventoryUnavailable
    /// The fresh inventory joins the client's TTY to a different tab, or to none.
    case ghosttyJoinChanged(GhosttyTTYJoin)
    /// The matched tab is not the selected tab of the frontmost Ghostty window, or Ghostty is not frontmost.
    case ghosttyTabNotSelected

    /// The step that produced this reason.
    public var step: HerdrOpenStep {
        switch self {
        case .ghosttyTTYUnsupported, .sessionNotInHerdr, .binding, .clientTTYUnknown,
             .ghosttyInventoryUnavailable, .ghosttyTab:
            return .revalidate
        case .focusRejected:
            return .focusHerdr
        case .herdrVerifyUnavailable, .herdrBindingChanged, .herdrPaneNotFocused, .herdrClientChanged:
            return .verifyHerdr
        case .ghosttySelectFailed:
            return .raiseGhostty
        case .ghosttyVerifyInventoryUnavailable, .ghosttyJoinChanged, .ghosttyTabNotSelected:
            return .verifyGhostty
        }
    }
}

/// What step 1 established and every later step must still hold.
public struct HerdrOpenPlan: Equatable, Sendable {
    public let pane: HerdrPaneTarget
    public let clientPID: Int32
    /// The client's TTY, normalized to `/dev/ttysNNN`.
    public let clientTTY: String
    public let ghosttyTarget: GhosttyTarget
    public let support: GhosttyTTYSupport
    /// When the pre-Open herdr scan started (Unix seconds). A successful Open acknowledges only
    /// completions that arrived before it.
    public let preOpenSnapshotAt: Double

    public init(pane: HerdrPaneTarget, clientPID: Int32, clientTTY: String, ghosttyTarget: GhosttyTarget,
                support: GhosttyTTYSupport, preOpenSnapshotAt: Double) {
        self.pane = pane
        self.clientPID = clientPID
        self.clientTTY = clientTTY
        self.ghosttyTarget = ghosttyTarget
        self.support = support
        self.preOpenSnapshotAt = preOpenSnapshotAt
    }
}

public enum HerdrOpenResult: Equatable, Sendable {
    /// Steps 3 and 5 both passed.
    case opened(HerdrOpenPlan)
    case unavailable(HerdrOpenFailure)

    public var failure: HerdrOpenFailure? {
        if case .unavailable(let failure) = self { return failure }
        return nil
    }
}

public enum HerdrOpen {
    /// Step 1 over a fresh herdr binding, its scan, and a fresh Ghostty inventory.
    ///
    /// - Parameter snapshotTakenAt: when the herdr scan behind `binding` started, Unix seconds.
    public static func plan(support: GhosttyTTYSupport, binding: HerdrSessionBinding, outcome: HerdrScanOutcome?,
                            ghostty: GhosttySnapshot?, snapshotTakenAt: Double) -> Result<HerdrOpenPlan, HerdrOpenFailure> {
        if let failure = herdrFailure(binding: binding, outcome: outcome) { return .failure(failure) }
        guard let pane = binding.target, let client = attachedClient(outcome), let tty = client.tty else {
            return .failure(.clientTTYUnknown)
        }
        guard let ghostty else { return .failure(.ghosttyInventoryUnavailable) }
        let join = GhosttyTTYMatch.join(clientTTY: tty, support: support, snapshot: ghostty)
        guard case .matched(let target) = join else { return .failure(.ghosttyTab(join)) }
        return .success(HerdrOpenPlan(pane: pane, clientPID: client.pid, clientTTY: tty, ghosttyTarget: target,
                                      support: support, preOpenSnapshotAt: snapshotTakenAt))
    }

    /// The herdr half of step 1, decided before Ghostty is asked for an inventory: nil when the
    /// session is bound and the single client has a usable TTY.
    public static func herdrFailure(binding: HerdrSessionBinding, outcome: HerdrScanOutcome?) -> HerdrOpenFailure? {
        switch binding {
        case .notInHerdr: return .sessionNotInHerdr
        case .unavailable(let reason): return .binding(reason)
        case .bound: break
        }
        guard attachedClient(outcome)?.tty != nil else { return .clientTTYUnknown }
        return nil
    }

    /// Step 2: any accepted reply passes; herdr's result is confirmed by step 3, not by this reply.
    public static func focusOutcome(_ reply: Result<HerdrReply, HerdrUnavailableReason>) -> HerdrOpenFailure? {
        if case .failure(let reason) = reply { return .focusRejected(reason) }
        return nil
    }

    /// Step 3 over a fresh herdr binding and its scan.
    public static func verifyHerdr(_ plan: HerdrOpenPlan, binding: HerdrSessionBinding,
                                   outcome: HerdrScanOutcome?) -> HerdrOpenFailure? {
        verifyPane(plan.pane, clientPID: plan.clientPID, clientTTY: plan.clientTTY, binding: binding, outcome: outcome)
    }

    /// Step 3 for any host: the fresh binding is still `pane`, herdr shows exactly it focused, and the
    /// single client is the one step 1 joined.
    public static func verifyPane(_ pane: HerdrPaneTarget, clientPID: Int32, clientTTY: String,
                                  binding: HerdrSessionBinding, outcome: HerdrScanOutcome?) -> HerdrOpenFailure? {
        switch binding {
        case .unavailable(let reason): return .herdrVerifyUnavailable(reason)
        case .notInHerdr: return .herdrBindingChanged
        case .bound(let target): guard target == pane else { return .herdrBindingChanged }
        }
        guard let scan = outcome?.scan else { return .herdrVerifyUnavailable(.notScanned) }
        guard focusedPane(in: scan.snapshot) == pane.paneID else { return .herdrPaneNotFocused }
        guard let client = attachedClient(outcome), client.pid == clientPID,
              client.tty == clientTTY else { return .herdrClientChanged }
        return nil
    }

    /// Step 5 over a fresh Ghostty inventory. `GhosttySnapshot.selected` is reported only while
    /// Ghostty is the frontmost application, so a selected matched tab also proves Ghostty frontmost.
    public static func verifyGhostty(_ plan: HerdrOpenPlan, ghostty: GhosttySnapshot?) -> HerdrOpenFailure? {
        guard let ghostty else { return .ghosttyVerifyInventoryUnavailable }
        let join = GhosttyTTYMatch.join(clientTTY: plan.clientTTY, support: plan.support, snapshot: ghostty)
        guard join == .matched(plan.ghosttyTarget) else { return .ghosttyJoinChanged(join) }
        guard ghostty.selected == plan.ghosttyTarget,
              ghostty.front_window_id == plan.ghosttyTarget.window_id else { return .ghosttyTabNotSelected }
        return nil
    }

    /// The single Ghostty-hosted client of a successful scan, with its TTY normalized (nil when unusable).
    public static func attachedClient(_ outcome: HerdrScanOutcome?) -> HerdrAttachedClient? {
        guard case .success(let client)? = outcome?.scan?.client else { return nil }
        return HerdrAttachedClient(pid: client.pid, tty: client.tty.flatMap(GhosttyTTYMatch.normalizedTTY),
                                   serverPID: client.serverPID, host: client.host)
    }

    /// The pane herdr reports focused, only when the snapshot's focused pane also marks itself focused.
    public static func focusedPane(in snapshot: HerdrSnapshot) -> String? {
        guard let id = snapshot.focusedPaneID, snapshot.panes.filter({ $0.paneID == id }).count == 1,
              snapshot.pane(id)?.focused == true else { return nil }
        return id
    }
}

/// The side effects of one Open, supplied by SteerApp. Each is called at most once per step, in
/// order; `focus` is called at most once per Open and only after step 1 passed.
@MainActor
public struct HerdrOpenEffects {
    /// Unix seconds, read immediately before the pre-Open herdr scan.
    public var now: @MainActor () -> Double
    /// Whether the installed Ghostty declares a terminal `tty`. Without it the Ghostty half of the
    /// join uses the sole-terminal rule (`GhosttyTTYMatch.soleTerminalJoin`).
    public var ttySupport: @MainActor () async -> GhosttyTTYSupport
    /// A fresh herdr scan and the session's binding against it.
    public var revalidate: @MainActor () async -> (binding: HerdrSessionBinding, outcome: HerdrScanOutcome?)
    /// A fresh Ghostty inventory, taken with `tty` when supported; nil when it could not be read.
    public var ghosttySnapshot: @MainActor () async -> GhosttySnapshot?
    /// `agent.focus` on the pane ID, sent once.
    public var focus: @MainActor (String) async -> Result<HerdrReply, HerdrUnavailableReason>
    /// Selects the target tab after rechecking its TTY (normalized `/dev/ttysNNN`), or without `tty`
    /// the sole-terminal rule, and activates Ghostty.
    public var select: @MainActor (GhosttyTarget, String) async -> Bool

    public init(now: @escaping @MainActor () -> Double,
                ttySupport: @escaping @MainActor () async -> GhosttyTTYSupport,
                revalidate: @escaping @MainActor () async -> (binding: HerdrSessionBinding, outcome: HerdrScanOutcome?),
                ghosttySnapshot: @escaping @MainActor () async -> GhosttySnapshot?,
                focus: @escaping @MainActor (String) async -> Result<HerdrReply, HerdrUnavailableReason>,
                select: @escaping @MainActor (GhosttyTarget, String) async -> Bool) {
        self.now = now
        self.ttySupport = ttySupport
        self.revalidate = revalidate
        self.ghosttySnapshot = ghosttySnapshot
        self.focus = focus
        self.select = select
    }
}

public enum HerdrOpenSequence {
    /// Runs ADR 0011's five steps as ADR 0016's sequence (`TerminalOpenSequence`): revalidate, focus and
    /// verify the herdr pane, raise and verify the Ghostty tab, stopping at the first failure. A failure
    /// after the focus leaves herdr's focus as it is: there is no rollback, and never another pane or tab.
    /// Whether the failure then raises the client's app is `HerdrOpenFallback`'s decision (ADR 0015).
    @MainActor
    public static func run(_ effects: HerdrOpenEffects) async -> HerdrOpenResult {
        let steps = TerminalOpenSteps<HerdrOpenPlan, HerdrOpenFailure>(
            now: { effects.now() },
            revalidate: { takenAt in
                let support = await effects.ttySupport()
                let fresh = await effects.revalidate()
                if let failure = HerdrOpen.herdrFailure(binding: fresh.binding, outcome: fresh.outcome) {
                    return .failure(failure)
                }
                return HerdrOpen.plan(support: support, binding: fresh.binding, outcome: fresh.outcome,
                                      ghostty: await effects.ghosttySnapshot(), snapshotTakenAt: takenAt)
            },
            focusPane: { plan in HerdrOpen.focusOutcome(await effects.focus(plan.pane.paneID)) },
            verifyPane: { plan in
                let verify = await effects.revalidate()
                return HerdrOpen.verifyHerdr(plan, binding: verify.binding, outcome: verify.outcome)
            },
            raise: { plan in await effects.select(plan.ghosttyTarget, plan.clientTTY) ? nil : .ghosttySelectFailed },
            verify: { plan in HerdrOpen.verifyGhostty(plan, ghostty: await effects.ghosttySnapshot()) })
        switch await TerminalOpenSequence.run(steps) {
        case .opened(let plan, _): return .opened(plan)
        case .failed(let failure, _): return .unavailable(failure)
        }
    }
}

// MARK: - Fallback (ADR 0015)

/// ADR 0015 over herdr's typed failures: a layout or match failure, a pane focus or verification that
/// did not hold, or a Ghostty tab that could not be raised after the pane verified, falls back to
/// raising the app hosting herdr's client. An unreadable herdr or Ghostty, a stale integration, an
/// ended session, a closed pane, a switch that keeps Steer from contacting herdr, and a client whose
/// tty cannot be joined stay unavailable with their own reason. The sequence itself is unchanged: it
/// still stops at the first failure and never rolls back.
public enum HerdrOpenFallback {
    /// Why `failure` falls back, or nil when it stays unavailable.
    public static func reason(for failure: HerdrOpenFailure) -> OpenFallbackReason? {
        switch failure {
        case .ghosttyTTYUnsupported: .noUniqueTarget
        case .sessionNotInHerdr, .clientTTYUnknown, .ghosttyInventoryUnavailable: nil
        case .binding(let reason), .herdrVerifyUnavailable(let reason): Self.reason(for: reason)
        case .ghosttyTab(let join): Self.reason(for: join)
        case .focusRejected(let reason): hostUnreadable(reason) ? nil : .notVerified
        case .herdrBindingChanged, .herdrPaneNotFocused, .herdrClientChanged: .notVerified
        case .ghosttySelectFailed, .ghosttyVerifyInventoryUnavailable, .ghosttyJoinChanged, .ghosttyTabNotSelected:
            .partialReach
        }
    }

    public static func reason(for session: HerdrSessionUnavailable) -> OpenFallbackReason? {
        switch session {
        case .herdrSwitchedOff, .ghosttyControlsOff, .notScanned, .serverIdentityUnknown: nil
        case .herdr(let reason): Self.reason(for: reason)
        case .binding(let reason): Self.reason(for: reason)
        }
    }

    public static func reason(for herdr: HerdrUnavailableReason) -> OpenFallbackReason? {
        switch herdr {
        case .split, .nonGhosttyClient: .unsupportedLayout
        case .wrongClientCount(let count): count > 1 ? .unsupportedLayout : nil
        case .herdrNotFound, .notRunning, .untrustedSocket, .unsupportedProtocol, .integrationNotCurrent,
             .namedSession, .voidBinding, .timeout, .malformedReply, .paneChangedDuringScan, .requestRefused: nil
        }
    }

    /// Several panes claiming the session still put it in herdr, whose client names the app. A pane
    /// that is missing, unidentified or contradicted does not show the session is there at all.
    public static func reason(for binding: HerdrBindingUnavailable) -> OpenFallbackReason? {
        switch binding {
        case .split, .multipleClients, .nonGhosttyClient: .unsupportedLayout
        case .duplicateMatches, .duplicateTitles, .sessionPrefixNotUnique: .noUniqueTarget
        case .sessionEnded, .noHookRecord, .notInHerdr, .conflictingHookRecords, .unsupportedProtocol, .socketUnknown,
             .namedSession, .herdrRestarted, .paneReusedBySession, .conflictingPaneObservations, .paneMissing,
             .agentSessionNull, .agentSessionMismatch, .conflictingTitle, .integrationNotCurrent, .noClient,
             .titleNotInHerdr, .titleInHerdrAndGhostty, .detectedAgent, .processInfoUnavailable,
             .foregroundProcesses, .agentProcessNotInForeground, .agentProcessAmbiguous: nil
        }
    }

    /// No unique Ghostty tab or an unsupported one falls back; an unreadable inventory or client tty does not.
    public static func reason(for join: GhosttyTTYJoin) -> OpenFallbackReason? {
        switch join {
        case .ttyUnsupported, .noMatch, .emptyValue, .multipleMatches: .noUniqueTarget
        case .split, .otherWindow: .unsupportedLayout
        case .matched, .inventoryUnavailable, .invalidClientTTY: nil
        }
    }

    /// The result of a herdr Open that failed with `failure`, or nil when the failure is not a fallback
    /// and its own typed reason stands. `clientWalks` are walks from every client attached in the
    /// latest scan (`clientPIDs`); the app they all reach is raised while running.
    public static func resolve(_ failure: HerdrOpenFailure, agent: AgentSource, clientWalks: [TerminalAppWalk],
                               switches: TerminalHostSwitches, isRunning: (TerminalHost) -> Bool) -> TerminalOpenResult? {
        guard let reason = reason(for: failure) else { return nil }
        return OpenFallback.resolve(reason, app: OpenFallback.processApp(walks: clientWalks, agent: agent, switches: switches),
                                    isRunning: isRunning)
    }

    /// Every client attached in a successful scan; none otherwise.
    public static func clientPIDs(_ outcome: HerdrScanOutcome?) -> [Int32] {
        outcome?.scan?.clientPIDs ?? []
    }

    /// herdr's socket is missing, untrusted, unusable or herdr is absent: the host cannot be read.
    private static func hostUnreadable(_ reason: HerdrUnavailableReason) -> Bool {
        switch reason {
        case .herdrNotFound, .notRunning, .untrustedSocket, .unsupportedProtocol: true
        default: false
        }
    }
}
