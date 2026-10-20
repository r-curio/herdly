import Foundation

// ADR 0016's Open sequence, the same for every terminal host and multiplexer: revalidate the binding on
// fresh reads, focus and verify the pane (multiplexers only), select and raise the host tab, then verify
// the target is visible. Each step is supplied by the host's integration; this only orders them, sends
// each once, and stops at the first failure. Whether a failure falls back to raising the app (ADR 0015)
// or stays unavailable is decided by the host's failure mapping, never here. Nothing is retried or
// rolled back.

/// The steps of ADR 0016's Open sequence, in order.
public enum TerminalOpenStep: Equatable, Sendable {
    /// Re-read the binding, layout and (for a pane) the host-tab join.
    case revalidate
    /// Focus the bound pane (multiplexers only), once.
    case focusPane
    /// A fresh multiplexer read shows the bound pane current.
    case verifyPane
    /// Select and raise the host tab, once.
    case raise
    /// A fresh read shows the target visible.
    case verify
}

/// What a sequence did: every verification passed, or the step that failed and its typed failure.
public enum TerminalOpenRun<Plan, Failure: Error> {
    /// Every step passed. `preOpenAt` is when the pre-Open read started (Unix seconds); a verified Open
    /// acknowledges only completions that arrived before it (`TerminalVisitAcknowledgment.afterOpen`).
    case opened(Plan, preOpenAt: Double)
    case failed(Failure, at: TerminalOpenStep)
}

extension TerminalOpenRun: Equatable where Plan: Equatable, Failure: Equatable {}
extension TerminalOpenRun: Sendable where Plan: Sendable, Failure: Sendable {}

/// One host's steps. `revalidate` receives the pre-Open time read just before it and returns the plan
/// every later step must still hold. `focusPane` and `verifyPane` are given only for a multiplexer pane,
/// together or not at all. Every other step returns nil when it passed.
public struct TerminalOpenSteps<Plan, Failure: Error> {
    public var now: () -> Double
    public var revalidate: (Double) async -> Result<Plan, Failure>
    public var focusPane: ((Plan) async -> Failure?)?
    public var verifyPane: ((Plan) async -> Failure?)?
    public var raise: (Plan) async -> Failure?
    public var verify: (Plan) async -> Failure?

    public init(now: @escaping () -> Double,
                revalidate: @escaping (Double) async -> Result<Plan, Failure>,
                focusPane: ((Plan) async -> Failure?)? = nil,
                verifyPane: ((Plan) async -> Failure?)? = nil,
                raise: @escaping (Plan) async -> Failure?,
                verify: @escaping (Plan) async -> Failure?) {
        self.now = now
        self.revalidate = revalidate
        self.focusPane = focusPane
        self.verifyPane = verifyPane
        self.raise = raise
        self.verify = verify
    }
}

public enum TerminalOpenSequence {
    /// Runs the steps in order on the caller's isolation, each at most once, stopping at the first
    /// failure. A failure after a pane focus keeps that focus: there is no rollback.
    public static func run<Plan, Failure: Error>(_ steps: TerminalOpenSteps<Plan, Failure>,
                                          isolation: isolated (any Actor)? = #isolation) async -> TerminalOpenRun<Plan, Failure> {
        let preOpenAt = steps.now()
        let plan: Plan
        switch await steps.revalidate(preOpenAt) {
        case .failure(let failure): return .failed(failure, at: .revalidate)
        case .success(let value): plan = value
        }
        if let focusPane = steps.focusPane, let verifyPane = steps.verifyPane {
            if let failure = await focusPane(plan) { return .failed(failure, at: .focusPane) }
            if let failure = await verifyPane(plan) { return .failed(failure, at: .verifyPane) }
        }
        if let failure = await steps.raise(plan) { return .failed(failure, at: .raise) }
        if let failure = await steps.verify(plan) { return .failed(failure, at: .verify) }
        return .opened(plan, preOpenAt: preOpenAt)
    }
}
