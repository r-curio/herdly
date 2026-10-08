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
    /// The Ghostty bundle does not declare a terminal `tty` (Ghostty 1.3.1). Checked before any herdr
    /// request, so none is sent.
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
        guard support == .supported else { return .failure(.ghosttyTTYUnsupported) }
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
        switch binding {
        case .unavailable(let reason): return .herdrVerifyUnavailable(reason)
        case .notInHerdr: return .herdrBindingChanged
        case .bound(let target): guard target == plan.pane else { return .herdrBindingChanged }
        }
        guard let scan = outcome?.scan else { return .herdrVerifyUnavailable(.notScanned) }
        guard focusedPane(in: scan.snapshot) == plan.pane.paneID else { return .herdrPaneNotFocused }
        guard let client = attachedClient(outcome), client.pid == plan.clientPID,
              client.tty == plan.clientTTY else { return .herdrClientChanged }
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
                                   serverPID: client.serverPID)
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
    /// Whether the installed Ghostty declares a terminal `tty`. Read first: when unsupported, no
    /// herdr request (not even a scan) is made.
    public var ttySupport: @MainActor () async -> GhosttyTTYSupport
    /// A fresh herdr scan and the session's binding against it.
    public var revalidate: @MainActor () async -> (binding: HerdrSessionBinding, outcome: HerdrScanOutcome?)
    /// A fresh Ghostty inventory, taken with `tty` when supported; nil when it could not be read.
    public var ghosttySnapshot: @MainActor () async -> GhosttySnapshot?
    /// `agent.focus` on the pane ID, sent once.
    public var focus: @MainActor (String) async -> Result<HerdrReply, HerdrUnavailableReason>
    /// Selects the target tab after rechecking its TTY (normalized `/dev/ttysNNN`) and activates Ghostty.
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
    /// Runs ADR 0011's five steps, stopping at the first failure. A failure after step 2 leaves herdr's
    /// focus as it is: there is no rollback and no fallback.
    @MainActor
    public static func run(_ effects: HerdrOpenEffects) async -> HerdrOpenResult {
        let support = await effects.ttySupport()
        guard support == .supported else { return .unavailable(.ghosttyTTYUnsupported) }
        let takenAt = effects.now()
        let fresh = await effects.revalidate()
        if let failure = HerdrOpen.herdrFailure(binding: fresh.binding, outcome: fresh.outcome) {
            return .unavailable(failure)
        }
        let plan: HerdrOpenPlan
        switch HerdrOpen.plan(support: support, binding: fresh.binding, outcome: fresh.outcome,
                              ghostty: await effects.ghosttySnapshot(), snapshotTakenAt: takenAt) {
        case .failure(let failure): return .unavailable(failure)
        case .success(let value): plan = value
        }
        if let failure = HerdrOpen.focusOutcome(await effects.focus(plan.pane.paneID)) { return .unavailable(failure) }
        let verify = await effects.revalidate()
        if let failure = HerdrOpen.verifyHerdr(plan, binding: verify.binding, outcome: verify.outcome) {
            return .unavailable(failure)
        }
        guard await effects.select(plan.ghosttyTarget, plan.clientTTY) else { return .unavailable(.ghosttySelectFailed) }
        if let failure = HerdrOpen.verifyGhostty(plan, ghostty: await effects.ghosttySnapshot()) {
            return .unavailable(failure)
        }
        return .opened(plan)
    }
}

// MARK: - Acknowledgment

/// A queued completion for a herdr session: its queue identity and arrival time (Unix seconds).
public struct HerdrCompletionCandidate<ID: Hashable & Sendable>: Equatable, Sendable {
    public let id: ID
    public let arrivedAt: Double

    public init(id: ID, arrivedAt: Double) {
        self.id = id
        self.arrivedAt = arrivedAt
    }
}

/// One scheduled herdr scan as the visit rule needs it. Only a scan with exactly one Ghostty-hosted
/// client produces an observation.
public struct HerdrFocusObservation: Equatable, Sendable {
    /// When the scan started, Unix seconds.
    public let takenAt: Double
    public let focusedPaneID: String?
    public let clientPID: Int32
    /// The client's TTY, normalized; nil when unusable.
    public let clientTTY: String?

    public init(takenAt: Double, focusedPaneID: String?, clientPID: Int32, clientTTY: String?) {
        self.takenAt = takenAt
        self.focusedPaneID = focusedPaneID
        self.clientPID = clientPID
        self.clientTTY = clientTTY
    }

    public static func from(_ outcome: HerdrScanOutcome?, takenAt: Double) -> HerdrFocusObservation? {
        guard takenAt.isFinite, let scan = outcome?.scan, let client = HerdrOpen.attachedClient(outcome) else { return nil }
        return HerdrFocusObservation(takenAt: takenAt, focusedPaneID: HerdrOpen.focusedPane(in: scan.snapshot),
                                     clientPID: client.pid, clientTTY: client.tty)
    }
}

/// ADR 0011's acknowledgment rule. Only completions are acknowledged by a visit; approval requests,
/// questions and reminders clear only on resolution evidence and are never passed here. On a Ghostty
/// without `tty`, an interim rule (issue #155) accepts Ghostty frontmost in place of the TTY join.
public enum HerdrOpenAcknowledgment {
    /// After an Open: only when it reported Opened, the completions that arrived strictly before the
    /// pre-Open herdr scan started.
    public static func afterOpen<ID>(_ completions: [HerdrCompletionCandidate<ID>], result: HerdrOpenResult) -> Set<ID> {
        guard case .opened(let plan) = result, plan.preOpenSnapshotAt.isFinite else { return [] }
        return Set(completions.filter { $0.arrivedAt.isFinite && $0.arrivedAt < plan.preOpenSnapshotAt }.map(\.id))
    }

    /// A manual visit (ADR 0009 interval rule): the bound pane was not focused in `previous` and is
    /// focused in `current`, both scans with exactly one Ghostty-hosted client, and a Ghostty inventory
    /// taken at or after `current` shows the TTY-matched tab selected with Ghostty frontmost. Only
    /// completions that arrived before `previous` started are acknowledged, so an outcome arriving
    /// during the observation interval stays queued.
    ///
    /// Interim (issue #155): when Ghostty lacks `tty`, Ghostty frontmost stands in for the selected
    /// matched tab. Steer cannot see which tab is selected, so a focus change the user did not watch
    /// can acknowledge; the user accepted that until a Ghostty with `tty` ships. A Ghostty that has
    /// `tty` always uses the exact join, with no fallback.
    public static func manualVisit<ID>(
        _ completions: [HerdrCompletionCandidate<ID>],
        boundPaneID: String,
        previous: HerdrFocusObservation?,
        current: HerdrFocusObservation?,
        support: GhosttyTTYSupport,
        ghostty: GhosttySnapshot?,
        ghosttyTakenAt: Double
    ) -> Set<ID> {
        guard let current, let ghostty else { return [] }
        return manualVisit(completions, boundPaneID: boundPaneID, previous: previous, current: current,
                           ghosttyShowsVisit: ghosttyShowsVisit(clientTTY: current.clientTTY, support: support,
                                                                ghostty: ghostty),
                           ghosttyTakenAt: ghosttyTakenAt)
    }

    /// The same rule with the Ghostty half already decided: `ghosttyShowsVisit` must be
    /// `ghosttyShowsVisit(clientTTY:support:ghostty:)` for `current`'s client against the inventory taken
    /// at `ghosttyTakenAt` (false without one), so one inventory serves every session in the pane.
    public static func manualVisit<ID>(
        _ completions: [HerdrCompletionCandidate<ID>],
        boundPaneID: String,
        previous: HerdrFocusObservation?,
        current: HerdrFocusObservation,
        ghosttyShowsVisit: Bool,
        ghosttyTakenAt: Double
    ) -> Set<ID> {
        guard let previous, ghosttyShowsVisit, ghosttyTakenAt.isFinite,
              previous.takenAt < current.takenAt, current.takenAt <= ghosttyTakenAt,
              previous.focusedPaneID != boundPaneID, current.focusedPaneID == boundPaneID else { return [] }
        return Set(completions.filter { $0.arrivedAt.isFinite && $0.arrivedAt < previous.takenAt }.map(\.id))
    }

    /// Whether a Ghostty inventory shows the herdr client's tab to the user: with `tty`, the
    /// TTY-matched tab selected with Ghostty frontmost; without it (interim, issue #155), Ghostty frontmost.
    public static func ghosttyShowsVisit(clientTTY: String?, support: GhosttyTTYSupport,
                                         ghostty: GhosttySnapshot) -> Bool {
        switch support {
        case .supported:
            guard let clientTTY,
                  case .matched(let target) = GhosttyTTYMatch.join(clientTTY: clientTTY, support: support,
                                                                   snapshot: ghostty) else { return false }
            return ghostty.selected == target
        case .unsupported:
            // `selected` is present only while Ghostty is frontmost (Ghostty.js).
            return ghostty.selected != nil
        }
    }
}

/// The dwell rule, agreed with the user on 2026-10-08: a completion that arrives while its bound pane is
/// already in front is acknowledged once that pane has stayed visible for `required` seconds after the
/// completion arrived. Visible means herdr reports the pane focused with exactly one Ghostty-hosted
/// client and a Ghostty inventory shows that client's tab (`HerdrOpenAcknowledgment.ghosttyShowsVisit`).
/// Visibility is sampled per scan, so a switch away and back between two scans goes unseen; a hidden
/// or different pane, a failed scan, or a gap longer than `maxGap` between visible scans (sleep, or
/// scans skipped while a check was slow) restarts the run. A completion that arrived before the run
/// began is left to the manual-visit rule and dismissal. Steer cannot tell whether the user is looking
/// at the screen; the user accepted that an unattended pane acknowledges.
public struct HerdrDwell: Equatable, Sendable {
    public static let required: Double = 5
    public static let maxGap: Double = 5

    /// The pane visible on every scan since `since`, or nil when no run is in progress.
    public private(set) var paneID: String?
    public private(set) var since: Double = 0
    private var lastSeenAt: Double = 0
    /// The scan time of the latest reset. An observation taken at or before it predates the scan
    /// that ended the run, such as a check still in flight then, and is ignored. A clock set back past
    /// it only withholds acknowledgment until the clock passes it again.
    private var resetAt = -Double.infinity

    public init() {}

    /// Records the Ghostty check of the scan taken at `at`. `visible` is false when the pane is focused
    /// but Ghostty does not show it.
    public mutating func observe(paneID: String, visible: Bool, at: Double) {
        guard at.isFinite else { reset(at: at); return }
        guard at > resetAt else { return }
        guard visible else { reset(at: at); return }
        if self.paneID != paneID || at < lastSeenAt || at - lastSeenAt > Self.maxGap { since = at }
        self.paneID = paneID
        lastSeenAt = at
    }

    /// Records a scan taken at `at` that had no Ghostty check because a check or an Open was in flight.
    /// `pendingPaneID` is the pane an in-flight check is sampling, if any. The scan cannot extend the
    /// run, so it keeps the run and the pending check only while it shows that pane focused (or, with no
    /// check in flight, the run's pane). A failed scan (nil) or another pane restarts the run, and the
    /// pending check, taken before this scan, is then ignored.
    public mutating func skip(focusedPaneID: String?, pendingPaneID: String?, at: Double) {
        if focusedPaneID == nil || focusedPaneID != (pendingPaneID ?? paneID) { reset(at: at) }
    }

    /// Ends the run as of the scan taken at `at`. A non-finite time ends it without ignoring anything.
    public mutating func reset(at: Double) {
        paneID = nil
        since = 0
        lastSeenAt = 0
        if at.isFinite { resetAt = max(resetAt, at) }
    }

    /// Completions for `boundPaneID` that arrived during the current run, at or after its start, and
    /// have been visible for `required` seconds since arriving by `now`, the latest observed scan.
    public func acknowledged<ID>(_ completions: [HerdrCompletionCandidate<ID>], boundPaneID: String,
                                 at now: Double) -> Set<ID> {
        guard paneID == boundPaneID, now.isFinite, now == lastSeenAt else { return [] }
        return Set(completions.filter {
            $0.arrivedAt.isFinite && $0.arrivedAt >= since && $0.arrivedAt + Self.required <= now
        }.map(\.id))
    }
}
