import Foundation

/// A connected Claude root as question receipts are bound to it.
public struct ClaudeQuestionRootKey: Hashable, Sendable {
    public let sourceScope: String
    public let eventsPath: String
    public let installationID: String

    public init(sourceScope: String, eventsPath: String, installationID: String) {
        self.sourceScope = sourceScope
        self.eventsPath = eventsPath
        self.installationID = installationID
    }

    public init(sourceScope: String, events: URL, installationID: String) {
        self.init(sourceScope: sourceScope, eventsPath: events.standardizedFileURL.path,
                  installationID: installationID)
    }
}

/// A pending helper request one scan listed, with the root it was listed under.
public struct LiveClaudeQuestion: Equatable, Sendable {
    public let request: ClaudeQuestionRequest
    public let events: URL
    public let sourceScope: String

    public init(request: ClaudeQuestionRequest, events: URL, sourceScope: String) {
        self.request = request
        self.events = events
        self.sourceScope = sourceScope
    }

    public var root: ClaudeQuestionRootKey {
        ClaudeQuestionRootKey(sourceScope: sourceScope, events: events, installationID: request.installationID)
    }

    /// The request names the root and event directory it was listed under.
    public var isConsistent: Bool {
        request.sourceScope == sourceScope && request.eventDirectory == events.standardizedFileURL.path
    }
}

public struct ClaudeQuestionReceiptWork: Sendable {
    public let request: ClaudeQuestionRequest
    public let eventsPath: String
    public let root: ClaudeQuestionRootKey
    public let scanGeneration: UInt64
    /// The receipt this running companion already issued for the request, from its ledger when
    /// the work was queued (#385); nil when it issued none or the token was spent.
    public let issued: ClaudeQuestionReceipt?
    /// The question's hover hold when the work was queued (ADR 0020), so re-adoption honors it.
    public let held: Double?

    public init(request: ClaudeQuestionRequest, eventsPath: String, root: ClaudeQuestionRootKey,
                scanGeneration: UInt64, issued: ClaudeQuestionReceipt?, held: Double?) {
        self.request = request
        self.eventsPath = eventsPath
        self.root = root
        self.scanGeneration = scanGeneration
        self.issued = issued
        self.held = held
    }
}

public struct ClaudeQuestionReceiptResult: Sendable {
    public let request: ClaudeQuestionRequest
    public let requestID: String
    public let root: ClaudeQuestionRootKey
    public let scanGeneration: UInt64
    /// The receipt this companion wrote, or re-adopted as its own, for the request; nil otherwise.
    public let receipt: ClaudeQuestionReceipt?

    public init(request: ClaudeQuestionRequest, requestID: String, root: ClaudeQuestionRootKey,
                scanGeneration: UInt64, receipt: ClaudeQuestionReceipt?) {
        self.request = request
        self.requestID = requestID
        self.root = root
        self.scanGeneration = scanGeneration
        self.receipt = receipt
    }

    public var written: Bool { receipt != nil }
}

/// Receipt work off the main actor: writes this companion's receipt, or re-adopts the identical
/// one it already issued (#385). A receipt on disk this companion did not issue yields nil.
public func claudeQuestionIssueReceipt(_ work: ClaudeQuestionReceiptWork, now: Double) -> ClaudeQuestionReceiptResult {
    let receipt = ClaudeQuestionStore.issueReceipt(for: work.request,
                                                   in: URL(fileURLWithPath: work.eventsPath, isDirectory: true),
                                                   issued: work.issued, held: work.held, now: now)
    return ClaudeQuestionReceiptResult(request: work.request, requestID: work.request.requestID, root: work.root,
                                       scanGeneration: work.scanGeneration, receipt: receipt)
}

public enum ClaudeQuestionReceiptDisposition: Equatable, Sendable {
    case accept
    case staleAccept
    case discard
}

/// Whether a landed receipt result grants the answer token. `held` is the question's hover hold
/// (ADR 0020): the result counts until the held deadline, capped at publish + 2 min.
public func claudeQuestionReceiptDisposition(_ result: ClaudeQuestionReceiptResult,
                                             currentGeneration: UInt64,
                                             liveRequest: ClaudeQuestionRequest?, rootIsCurrent: Bool,
                                             spent: Bool, held: Double?,
                                             now: Double) -> ClaudeQuestionReceiptDisposition {
    let deadline = ClaudeQuestionTiming.heldDeadline(publishedAt: result.request.publishedAt,
                                                     expiresAt: result.request.expiresAt, held: held)
    // A spent token is never granted again, even by a worker that landed after the spend.
    guard result.written, !spent, rootIsCurrent, let liveRequest,
          liveRequest == result.request, deadline > now else { return .discard }
    // A worker may finish after a newer scan. Exact request/root identity makes that immutable
    // receipt safe to use; a different live request or root remains fail-closed.
    return result.scanGeneration == currentGeneration ? .accept : .staleAccept
}

/// The question receipts this running companion issued (ADR 0020, amended 2026-10-30: Herdly can
/// answer only a question with "a receipt issued by this running companion"). Process memory
/// only, never persisted, so a receipt left on disk by a previous launch or another process is
/// never adopted. It outlives a pruned answer token (#385) so a rescan can re-adopt the same
/// receipt, and it remembers which tokens were spent so re-adoption never re-grants an answer.
public struct ClaudeQuestionReceiptLedger: Sendable {
    private var issued: [String: ClaudeQuestionReceipt] = [:]
    /// Spent request ids, each kept until its own time, independent of `issued`.
    private var spent: [String: Double] = [:]

    public init() {}

    /// Records a receipt this companion wrote, or re-adopted, for its request.
    public mutating func record(_ receipt: ClaudeQuestionReceipt) {
        issued[receipt.requestID] = receipt
    }

    /// Marks the request's answer token spent at `now`. A spent request is never re-adopted; the
    /// mark lasts `ApprovalTiming.helperWaitBound` from the spend, longer than any helper waits.
    public mutating func spend(_ requestID: String, now: Double) {
        spent[requestID] = max(spent[requestID] ?? now, now)
    }

    public func isSpent(_ requestID: String) -> Bool { spent[requestID] != nil }

    /// The receipt this companion issued for exactly `request`, for receipt work to re-adopt; nil
    /// when it issued none, the token was spent, or the receipt was issued for a request with the
    /// same id but another installation, root, event directory, publish time or window.
    public func adoptable(for request: ClaudeQuestionRequest) -> ClaudeQuestionReceipt? {
        guard !isSpent(request.requestID), let receipt = issued[request.requestID],
              receipt.requestID == request.requestID,
              receipt.installationID == request.installationID,
              receipt.sourceScope == request.sourceScope,
              receipt.eventDirectory == request.eventDirectory,
              receipt.expiresAt == request.expiresAt,
              receipt.receivedAt >= request.publishedAt else { return nil }
        return receipt
    }

    /// Forgets receipts and spent marks `ApprovalTiming.helperWaitBound` after their receipt or
    /// spend: memory housekeeping only. What keeps an old receipt from granting anything is the
    /// held-deadline check in `issueReceipt` and the disposition, which no question passes after
    /// publish + 2 min; a spent mark lasts past that, so it never lapses while a token could still
    /// be granted.
    public mutating func prune(now: Double) {
        issued = issued.filter { now < $0.value.receivedAt + ApprovalTiming.helperWaitBound }
        spent = spent.filter { now < $0.value + ApprovalTiming.helperWaitBound }
    }
}

/// The running companion's answer capability for live Claude questions (#385): which questions
/// the latest scans list, which hold this companion's receipt (answerable), which await receipt
/// work, their hover holds (ADR 0020) and the receipts and spends behind them. Process memory
/// only. A scan that misses a question drops its token, but not its hold, receipt or spent mark,
/// so the rescan re-adopts this companion's receipt inside the held deadline and never re-grants
/// a spent token.
public struct ClaudeQuestionCapabilities: Sendable {
    public private(set) var live: [String: LiveClaudeQuestion] = [:]
    private var available: Set<String> = []
    private var pendingReceipts: Set<String> = []
    /// Held deadlines, each already capped at publish + `ApprovalTiming.maximumHold`.
    private var holds: [String: Double] = [:]
    private var receipts = ClaudeQuestionReceiptLedger()

    public init() {}

    /// This companion holds the question's receipt and its token is unspent.
    public func canAnswer(_ requestID: String) -> Bool { available.contains(requestID) }

    /// The question's deadline with its hover hold, never past publish + 2 min.
    public func deadline(for request: ClaudeQuestionRequest) -> Double {
        ClaudeQuestionTiming.heldDeadline(publishedAt: request.publishedAt, expiresAt: request.expiresAt,
                                          held: holds[request.requestID])
    }

    /// One scan listed `question`. Returns receipt work when it has no token and none is pending.
    public mutating func observe(_ question: LiveClaudeQuestion, scanGeneration: UInt64) -> ClaudeQuestionReceiptWork? {
        let requestID = question.request.requestID
        live[requestID] = question
        guard !receipts.isSpent(requestID), !available.contains(requestID),
              pendingReceipts.insert(requestID).inserted else { return nil }
        return ClaudeQuestionReceiptWork(request: question.request,
                                         eventsPath: question.events.standardizedFileURL.path,
                                         root: question.root, scanGeneration: scanGeneration,
                                         issued: receipts.adoptable(for: question.request),
                                         held: holds[requestID])
    }

    /// After a scan: keeps a question only while its held deadline is ahead, its root is current
    /// and the scan listed it (`listedIDs`: pending request files and hook records).
    public mutating func prune(now: Double, roots: Set<ClaudeQuestionRootKey>, listedIDs: Set<String>) {
        live = live.filter { requestID, question in
            deadline(for: question.request) > now && roots.contains(question.root) && listedIDs.contains(requestID)
        }
        let retained = Set(live.keys)
        available = available.filter { retained.contains($0) }
        pendingReceipts = pendingReceipts.filter { retained.contains($0) }
        holds = holds.filter { $0.value > now }
        receipts.prune(now: now)
    }

    /// A receipt result landed. Records a receipt this companion issued even when the result is
    /// discarded, so the rescan of a pruned question can re-adopt it.
    @discardableResult
    public mutating func reconcile(_ result: ClaudeQuestionReceiptResult, currentGeneration: UInt64,
                                   roots: Set<ClaudeQuestionRootKey>, now: Double) -> ClaudeQuestionReceiptDisposition {
        let current = live[result.requestID]
        let rootIsCurrent = roots.contains(result.root)
            && current.map { $0.root == result.root && $0.isConsistent } == true
        if let receipt = result.receipt { receipts.record(receipt) }
        let disposition = claudeQuestionReceiptDisposition(
            result, currentGeneration: currentGeneration, liveRequest: current?.request,
            rootIsCurrent: rootIsCurrent, spent: receipts.isSpent(result.requestID),
            held: holds[result.requestID], now: now)
        pendingReceipts.remove(result.requestID)
        if disposition != .discard { available.insert(result.requestID) }
        return disposition
    }

    /// The pointer rests on the notch: keeps the later held deadline, capped at publish + 2 min.
    public mutating func hold(_ request: ClaudeQuestionRequest, until: Double) {
        let requestID = request.requestID
        holds[requestID] = ClaudeQuestionTiming.heldDeadline(publishedAt: request.publishedAt,
                                                             expiresAt: request.expiresAt,
                                                             held: max(holds[requestID] ?? until, until))
    }

    /// Spends the token before an answer is written. False when there was none to spend.
    @discardableResult
    public mutating func spend(_ requestID: String, now: Double) -> Bool {
        guard available.remove(requestID) != nil else { return false }
        receipts.spend(requestID, now: now)
        return true
    }
}
