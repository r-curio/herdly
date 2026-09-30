import AppKit
import QuartzCore
import SwiftUI
import SteerCore

struct ClaudeQuestionRootKey: Hashable, Sendable {
    let sourceScope: String
    let eventsPath: String
    let installationID: String
}

struct ClaudeQuestionReceiptWork: Sendable {
    let request: ClaudeQuestionRequest
    let eventsPath: String
    let root: ClaudeQuestionRootKey
    let scanGeneration: UInt64
}

struct ClaudeQuestionReceiptResult: Sendable {
    let request: ClaudeQuestionRequest
    let requestID: String
    let root: ClaudeQuestionRootKey
    let scanGeneration: UInt64
    let written: Bool
}

struct ClaudeApprovalRootKey: Hashable, Sendable {
    let sourceScope: String
    let eventsPath: String
    let installationID: String
}

struct ClaudeApprovalReceiptWork: Sendable {
    let approval: AgentApproval
    let eventsPath: String
    let root: ClaudeApprovalRootKey
    let receivedAt: Double
    let scanGeneration: UInt64
}

struct ClaudeApprovalReceiptResult: Sendable {
    let approval: AgentApproval
    let requestID: String
    let root: ClaudeApprovalRootKey
    let receivedAt: Double
    let scanGeneration: UInt64
    let receipt: ClaudeApprovalReceipt?
    let issuedByThisProcess: Bool
}

struct ClaudeApprovalDecisionWork: Sendable {
    let requestID: String
    let approvalID: AgentCallIdentity
    let decision: ApprovalDecision
    let decidedAt: Double
    let receipt: ClaudeApprovalReceipt
    let eventsPath: String
    let root: ClaudeApprovalRootKey
    let scanGeneration: UInt64
}

struct ClaudeApprovalDecisionResult: Sendable {
    let work: ClaudeApprovalDecisionWork
    let published: Bool
    let delivered: Bool
}

enum ClaudeQuestionReceiptDisposition: Equatable {
    case accept
    case staleAccept
    case discard
}

func claudeQuestionReceiptDisposition(_ result: ClaudeQuestionReceiptResult,
                                      currentGeneration: UInt64,
                                      liveRequest: ClaudeQuestionRequest?, rootIsCurrent: Bool,
                                      now: Double) -> ClaudeQuestionReceiptDisposition {
    guard result.written, rootIsCurrent, let liveRequest,
          liveRequest == result.request, result.request.expiresAt > now else { return .discard }
    // A worker may finish after a newer scan. Exact request/root identity makes that immutable
    // receipt safe to use; a different live request or root remains fail-closed.
    return result.scanGeneration == currentGeneration ? .accept : .staleAccept
}

func claudeQuestionLivenessIsCurrent(_ liveness: ClaudeQuestionLiveness,
                                     request: ClaudeQuestionRequest, now: Double,
                                     maximumAge: TimeInterval = ClaudeQuestionTiming.livenessTimeout) -> Bool {
    guard now.isFinite, liveness.requestID == request.requestID,
          liveness.installationID == request.installationID,
          liveness.sourceScope == request.sourceScope,
          liveness.eventDirectory == request.eventDirectory,
          liveness.sessionID == request.sessionID,
          liveness.promptID == request.promptID,
          liveness.toolUseID == request.toolUseID,
          liveness.heartbeatAt.isFinite,
          liveness.heartbeatAt >= request.publishedAt,
          liveness.heartbeatAt <= now,
          now - liveness.heartbeatAt <= maximumAge,
          request.expiresAt > now else { return false }
    return true
}

func claudeQuestionAwaitDeliveryAndCleanUp(_ request: ClaudeQuestionRequest,
                                           answer: ClaudeQuestionAnswer, in events: URL,
                                           timeout: TimeInterval = ClaudeQuestionTiming.deliveryAckTimeout) -> Bool {
    let confirmed = ClaudeQuestionHelper.awaitDelivery(for: request, answer: answer,
                                                       in: events, timeout: timeout)
    if !confirmed { ClaudeQuestionStore.removeAnswer(for: request.requestID, in: events) }
    return confirmed
}

private enum SetupInstallResult: Sendable {
    case success(CodexConnectionStatus)
    case failure(String)
}

private enum SetupUndoResult: Sendable {
    case success(CodexConnectionStatus)
    case failure(String)
}

private struct ClaudeNavigationRoot: Sendable {
    let root: URL
    let capabilities: ClaudeCapabilities
}

@MainActor
final class NotchPanel: NSPanel {
    /// Key status is only ever taken by a deliberate click or Tab into the panel; automatic
    /// presentation uses orderFrontRegardless, which never makes the panel key.
    override var canBecomeKey: Bool { true }
    var onEscape: (() -> Void)?
    /// True once the user has clicked in the panel; launch or app activation can also make the
    /// panel key, and that must not count as the user interacting with it.
    private(set) var clickedForKey = false

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { clickedForKey = true }
        super.sendEvent(event)
    }

    override func resignKey() {
        clickedForKey = false
        super.resignKey()
    }

    /// Keyboard focus the user asked for by clicking, as opposed to key status handed over at launch.
    var hasDeliberateKeyboardFocus: Bool { isKeyWindow && clickedForKey }

    /// Escape collapses the panel and returns keyboard input to the app the user was using.
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// AppKit pulls a frame back on screen; the tucked strip rests entirely above the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class Companion: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    private enum GhosttyFocusState {
        case disabled
        case checking
        case known(GhosttySnapshot)
        case unknown
    }
    @Published var attention = Attention(restored: UserDefaults.standard.bool(forKey: "testCompletion"))
    @Published var muted = UserDefaults.standard.bool(forKey: "muted")
    @Published var taskID = ""
    @Published var navigationMessage = ""
    @Published var openingTask = false
    private static let launchedAt = Date().timeIntervalSince1970
    @Published var queue = AttentionQueue(snapshot: Companion.launchSnapshot, observingSince: Companion.launchedAt)
    /// Source-scoped queue for adapters that have bounded native observations. The legacy
    /// Codex presentation queue remains the display path until its UI migration slice.
    @Published var agentQueue = AgentAttentionQueue(snapshot: Companion.launchSnapshot)
    /// Claude names are presentation metadata only; source scope keeps identical session IDs apart.
    @Published private(set) var claudeSessionNames: [AgentSessionIdentity: String] = [:]
    /// Direct Claude controls are valid only for receipts issued by this running companion. A
    /// persisted receipt must not recreate an active decision connection after a restart.
    private var liveClaudeApprovalIDs: Set<String> = []
    /// Receipt files are verified off the main actor and cached here for control rendering and
    /// the decision recheck. The cache is process memory only.
    private var verifiedClaudeApprovalReceipts: [String: ClaudeApprovalReceipt] = [:]
    private var verifiedClaudeApprovalRoots: [String: ClaudeApprovalRootKey] = [:]
    private var pendingClaudeApprovalReceipts: Set<String> = []
    private var pendingClaudeApprovalDecisions: Set<String> = []
    @Published var reminderPresentation = Attention()
    @Published var eventsPath = UserDefaults.standard.string(forKey: "approvalEventsPath") ?? ""
    @Published var completionPresentation = Attention()
    @Published var questionPresentation = Attention()
    /// Steer's own bookkeeping of what it relayed for each waiting question. Memory only: a restart
    /// returns every question as plain pending and nothing is ever re-sent.
    @Published var answerProgress: [QuestionIdentity: QuestionAnswerProgress] = [:]
    private var answering = false
    /// Steer's own bookkeeping of the one reply each completion card sent. Memory only, and a card
    /// that has sent one never sends another.
    @Published var replyProgress: [CompletionIdentity: SessionReplyProgress] = [:]
    private var replying = false
    /// Sessions Codex recorded as ended; a completion for one has nothing left to reply to.
    @Published var endedSessions: Set<UUID> = []
    /// The second client on Codex's app-server daemon socket, when one exists. Inert otherwise.
    private let daemonClient = AppServerDaemonClient(socketPath: Companion.daemonSocketPath)
    /// The daemon's pending question requests on the current connection, and the ones Steer answered.
    @Published var daemonBook = AppServerQuestionBook()
    @Published var daemonStatus = "Codex daemon: not checked yet."
    /// The daemon path is available; the preview renders it with a seeded request.
    var daemonConnected: Bool { daemonClient.isConnected || previewMode != nil }
    private var savedSnapshot = Companion.launchSnapshot
    @Published var ghosttyEnabled = false
    @Published var ghosttyPermissionVerified = false
    /// Read the Codex desktop app's own unread flags to acknowledge desktop completions it has
    /// cleared. Private format; on by default, off with one switch when a desktop update breaks it.
    @Published var desktopReadStateEnabled = UserDefaults.standard.object(forKey: "desktopReadStateEnabled") as? Bool ?? true
    @Published var desktopReadStateMessage = "Desktop read state: not checked yet."
    /// Codex's own thread names by session, refreshed every scan; unknown sessions keep their identifier.
    @Published var threadNames: [UUID: String] = [:]
    /// Codex's usage windows from the newest rollout, refreshed every scan; nil until one is read.
    @Published var usage: CodexUsageReading?
    /// The strip's readings: only windows that have not yet reset are shown.
    var currentUsage: CodexUsageReading? { usage?.current(now: Date().timeIntervalSince1970) }
    var currentWeeklyLimit: CodexUsageWindow? { currentUsage?.weekly }
    /// Shown beside the weekly reading only while Codex reports a five-hour window that is still
    /// running; the wing right of the housing widens for it and narrows back without it.
    var currentFiveHourLimit: CodexUsageWindow? { currentUsage?.fiveHour }
    /// Whether the strip is laying out for the five-hour readout right now.
    var fiveHourShown: Bool { currentFiveHourLimit != nil }
    /// Claude readings remain keyed by their selected configuration root; values are never merged.
    @Published var claudeUsage: [String: ClaudeUsageReading] = [:]
    /// `--reminder-rollouts <path>` points lab runs at a copy of Codex's sessions tree.
    nonisolated static var rolloutRoot: URL {
        argumentValue(for: "--reminder-rollouts").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }
    /// `--daemon-socket <path>` points lab runs at another app-server socket.
    nonisolated static var daemonSocketPath: String {
        argumentValue(for: "--daemon-socket") ?? AppServerDaemonClient.defaultSocketPath
    }
    /// `--thread-names <path>` points lab runs at a copy instead of the live Codex index.
    nonisolated static var threadNamesURL: URL {
        if let path = argumentValue(for: "--thread-names") { return URL(fileURLWithPath: path) }
        return ThreadNameReader.defaultURL(codexHome: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true))
    }
    /// `--desktop-read-state <path>` points lab runs at a copy instead of the live Codex file.
    nonisolated static var desktopReadStateURL: URL {
        if let path = argumentValue(for: "--desktop-read-state") { return URL(fileURLWithPath: path) }
        return DesktopReadStateReader.defaultURL(codexHome: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true))
    }
    @Published var setupStatus: CodexConnectionStatus = .notConfigured
    @Published var setupCapabilities = CodexCapabilities(cli: false, desktop: false, ghostty: false, supported: false)
    @Published var setupPlan: CodexSetupPlan?
    @Published var setupMessage = ""
    let claude = ClaudeSetupModel()
    private struct LiveClaudeQuestion {
        let request: ClaudeQuestionRequest
        let events: URL
        let sourceScope: String
    }
    private var liveClaudeQuestions: [String: LiveClaudeQuestion] = [:]
    private var availableClaudeQuestionTokens: Set<String> = []
    private var spentClaudeQuestionTokens: Set<String> = []
    private var pendingClaudeQuestionReceipts: Set<String> = []
    private var claudeQuestionScanGeneration: UInt64 = 0
    private var claudeApprovalScanGeneration: UInt64 = 0
    @Published private(set) var launchAtLogin = LaunchAtLoginState()
    @Published var desktopForeground = false
    private let launchAtLoginCoordinator = LaunchAtLoginCoordinator(service: LaunchAtLoginService())
    private let desktopAdapter = DesktopAdapter()
    private var cliSessions: Set<UUID> = []
    private var liveCLI: Set<UUID> = []
    /// Sessions a Ghostty inventory proved CLI by their session-id title, this launch. They stay CLI
    /// after the tab closes, and that closing ends them (`ReminderReader.scan`). Memory only.
    private var knownCLISessions: Set<UUID> = []
    /// Complete root inventories used to prove which canonical Claude sessions are live. Memory only.
    private var liveClaudeSessions: [String: [String]] = [:]
    private var claudeInventoryAvailable: [String: Bool] = [:]
    private var claudeInventories: [String: ClaudeInventoryScan] = [:]
    /// Unix time of the inventory in `ghosttyFocusState`, for dating a session end at the tab's absence.
    private var ghosttyInventoryAt: Double = 0
    /// The first successful snapshot establishes a baseline. Later selected-target changes are
    /// manual visits; a continuously focused tab cannot clear a completion that arrived after it.
    private var hasGhosttySelectionBaseline = false
    private var lastGhosttySelection: GhosttyTarget?
    private var lastGhosttySnapshotAt: Double?
    private var lastGhosttyVisitAfter: Double?
    private var checkingGhostty = false
    private var nextGhosttyScan: Double = 0
    private var checkingApprovalFocus = false
    private var nextApprovalFocusScan: Double = 0
    private var ghosttyFocusState: GhosttyFocusState = .disabled
    private var ghosttyUnavailable = false

    private func claudeQuestionRootKey(sourceScope: String, events: URL, installationID: String) -> ClaudeQuestionRootKey {
        ClaudeQuestionRootKey(sourceScope: sourceScope,
                              eventsPath: events.standardizedFileURL.path,
                              installationID: installationID)
    }

    private func claudeApprovalRootKey(sourceScope: String, events: URL, installationID: String) -> ClaudeApprovalRootKey {
        ClaudeApprovalRootKey(sourceScope: sourceScope,
                              eventsPath: events.standardizedFileURL.path,
                              installationID: installationID)
    }

    private func currentClaudeApprovalRoots() -> Set<ClaudeApprovalRootKey> {
        Set(claude.roots.compactMap { root in
            guard root.status == .connected, !root.eventsPath.isEmpty,
                  let installationID = root.plan?.installationID, !installationID.isEmpty else { return nil }
            return claudeApprovalRootKey(sourceScope: root.url.standardizedFileURL.path,
                                         events: URL(fileURLWithPath: root.eventsPath, isDirectory: true),
                                         installationID: installationID)
        })
    }

    private func publishClaudeApprovalReceipts(_ works: [ClaudeApprovalReceiptWork]) {
        guard !works.isEmpty else { return }
        Task { @MainActor [weak self] in
            let results = await Task.detached(priority: .utility) {
                works.map { work -> ClaudeApprovalReceiptResult in
                    let events = URL(fileURLWithPath: work.eventsPath, isDirectory: true)
                    let now = Date().timeIntervalSince1970
                    let requestID = work.approval.hookRequestID ?? ""
                    let live = ClaudeApprovalStore.liveness(for: requestID, in: events)
                    guard work.approval.expiresAt > Date().timeIntervalSince1970,
                          work.receivedAt.isFinite,
                          let live,
                          live.requestID == requestID,
                          live.publishedAt.isFinite, live.heartbeatAt.isFinite,
                          live.publishedAt <= live.heartbeatAt,
                          live.heartbeatAt <= now,
                          now - live.heartbeatAt <= ClaudeApprovalStore.livenessTimeout else {
                        return ClaudeApprovalReceiptResult(approval: work.approval,
                                                           requestID: requestID,
                                                           root: work.root, receivedAt: work.receivedAt,
                                                           scanGeneration: work.scanGeneration, receipt: nil,
                                                           issuedByThisProcess: false)
                    }
                    if let existing = ClaudeApprovalStore.receipt(for: requestID, in: events) {
                        return ClaudeApprovalReceiptResult(approval: work.approval,
                                                           requestID: work.approval.hookRequestID ?? "",
                                                           root: work.root, receivedAt: work.receivedAt,
                                                           scanGeneration: work.scanGeneration, receipt: existing,
                                                           issuedByThisProcess: false)
                    }
                    guard !requestID.isEmpty else {
                        return ClaudeApprovalReceiptResult(approval: work.approval, requestID: "", root: work.root,
                                                           receivedAt: work.receivedAt, scanGeneration: work.scanGeneration,
                                                           receipt: nil, issuedByThisProcess: false)
                    }
                    let created = ClaudeApprovalReceipt(requestID: requestID, receivedAt: work.receivedAt)
                    let written = ClaudeApprovalStore.publish(created, in: events)
                    let receipt = ClaudeApprovalStore.receipt(for: requestID, in: events)
                    return ClaudeApprovalReceiptResult(approval: work.approval, requestID: requestID, root: work.root,
                                                       receivedAt: work.receivedAt, scanGeneration: work.scanGeneration,
                                                       receipt: receipt, issuedByThisProcess: written && receipt != nil)
                }
            }.value
            self?.reconcileClaudeApprovalReceipts(results)
        }
    }

    private func reconcileClaudeApprovalReceipts(_ results: [ClaudeApprovalReceiptResult]) {
        let now = Date().timeIntervalSince1970
        let roots = currentClaudeApprovalRoots()
        let generation = claudeApprovalScanGeneration
        for result in results {
            if !result.requestID.isEmpty { pendingClaudeApprovalReceipts.remove(result.requestID) }
            let current = orderedAgentAttentionItems.compactMap(\.approval).first(where: {
                $0.id == result.approval.id && $0.hookRequestID == result.requestID
            })
            if result.receipt == nil {
                if roots.contains(result.root), current != nil {
                    liveClaudeApprovalIDs.remove(result.requestID)
                    verifiedClaudeApprovalReceipts.removeValue(forKey: result.requestID)
                    verifiedClaudeApprovalRoots.removeValue(forKey: result.requestID)
                }
                continue
            }
            guard let receipt = result.receipt,
                  result.requestID == receipt.requestID,
                  roots.contains(result.root),
                  receipt.receivedAt.isFinite, receipt.receivedAt <= now,
                  receipt.receivedAt >= result.approval.arrivedAt,
                  receipt.expiresAt > now,
                  result.approval.expiresAt > now,
                  let current,
                  result.scanGeneration == generation || current.hookRequestID == result.requestID else { continue }
            verifiedClaudeApprovalReceipts[result.requestID] = receipt
            verifiedClaudeApprovalRoots[result.requestID] = result.root
            if result.issuedByThisProcess { liveClaudeApprovalIDs.insert(result.requestID) }
            let normalized = AgentApproval(session: current.identity.session, turn: current.identity.turn,
                                           call: current.identity.call, arrivedAt: current.arrivedAt,
                                           expiresAt: receipt.expiresAt, state: current.state,
                                           details: current.details, hookRequestID: result.requestID)
            agentQueue.apply(.approval(normalized), now: now)
        }
        verifiedClaudeApprovalReceipts = verifiedClaudeApprovalReceipts.filter { $0.value.expiresAt > now }
        verifiedClaudeApprovalRoots = verifiedClaudeApprovalRoots.filter {
            verifiedClaudeApprovalReceipts[$0.key] != nil
        }
    }

    private func publishClaudeApprovalDecision(_ work: ClaudeApprovalDecisionWork) {
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                let events = URL(fileURLWithPath: work.eventsPath, isDirectory: true)
                let decision = ClaudeApprovalDecision(requestID: work.requestID,
                                                      decision: work.decision,
                                                      decidedAt: work.decidedAt)
                let published = ClaudeApprovalStore.publish(decision, in: events)
                let delivered = published && ClaudeApprovalHelper.awaitDelivery(for: work.requestID,
                                                                                  decision: decision,
                                                                                  in: events)
                return ClaudeApprovalDecisionResult(work: work, published: published, delivered: delivered)
            }.value
            self?.reconcileClaudeApprovalDecision(result)
        }
    }

    private func reconcileClaudeApprovalDecision(_ result: ClaudeApprovalDecisionResult) {
        pendingClaudeApprovalDecisions.remove(result.work.requestID)
        let current = orderedAgentAttentionItems.compactMap(\.approval).first {
            $0.id == result.work.approvalID && $0.hookRequestID == result.work.requestID
        }
        guard currentClaudeApprovalRoots().contains(result.work.root),
              result.work.receipt == verifiedClaudeApprovalReceipts[result.work.requestID],
              result.work.root == verifiedClaudeApprovalRoots[result.work.requestID],
              result.work.receipt.expiresAt > result.work.decidedAt,
              result.work.scanGeneration == claudeApprovalScanGeneration || current != nil else { return }
        verifiedClaudeApprovalReceipts.removeValue(forKey: result.work.requestID)
        verifiedClaudeApprovalRoots.removeValue(forKey: result.work.requestID)
        guard result.published else {
            navigationMessage = "Claude could not receive this decision; continue in Claude."
            refresh()
            return
        }
        if result.delivered {
            navigationMessage = result.work.decision == .allowOnce
                ? "Claude received the one-time approval."
                : "Claude received the denial."
        } else {
            navigationMessage = "Claude decision delivery is unconfirmed; continue in Claude."
        }
        refresh()
    }

    private func currentClaudeQuestionRoots() -> Set<ClaudeQuestionRootKey> {
        Set(claude.roots.compactMap { root in
            guard root.status == .connected, !root.eventsPath.isEmpty,
                  let installationID = root.plan?.installationID, !installationID.isEmpty else { return nil }
            return claudeQuestionRootKey(sourceScope: root.url.standardizedFileURL.path,
                                         events: URL(fileURLWithPath: root.eventsPath, isDirectory: true),
                                         installationID: installationID)
        })
    }

    private func observedClaudeQuestionIDs(_ scans: [ClaudeObservationScan]) -> Set<String> {
        Set(scans.flatMap { scan in
            scan.observations.compactMap { observation in
                guard case let .question(question) = observation else { return nil }
                return question.helperRequestID
            }
        })
    }

    private func pruneClaudeQuestionState(now: Double, roots: Set<ClaudeQuestionRootKey>,
                                          pendingIDs: Set<String>, observedIDs: Set<String>) {
        let retained = liveClaudeQuestions.filter { requestID, live in
            let root = claudeQuestionRootKey(sourceScope: live.sourceScope, events: live.events,
                                             installationID: live.request.installationID)
            return live.request.expiresAt > now && roots.contains(root)
                && (pendingIDs.contains(requestID) || observedIDs.contains(requestID))
        }
        let retainedIDs = Set(retained.keys)
        liveClaudeQuestions = retained
        availableClaudeQuestionTokens = availableClaudeQuestionTokens.filter { retainedIDs.contains($0) }
        spentClaudeQuestionTokens = spentClaudeQuestionTokens.filter { retainedIDs.contains($0) }
        pendingClaudeQuestionReceipts = pendingClaudeQuestionReceipts.filter { retainedIDs.contains($0) }
    }

    private func publishClaudeQuestionReceipts(_ works: [ClaudeQuestionReceiptWork]) {
        guard !works.isEmpty else { return }
        Task { @MainActor [weak self] in
            let results = await Task.detached(priority: .utility) {
                works.map { work -> ClaudeQuestionReceiptResult in
                    let now = Date().timeIntervalSince1970
                    guard work.request.expiresAt > now else {
                        return ClaudeQuestionReceiptResult(request: work.request, requestID: work.request.requestID,
                                                          root: work.root,
                                                          scanGeneration: work.scanGeneration, written: false)
                    }
                    let receipt = ClaudeQuestionReceipt(requestID: work.request.requestID,
                                                        installationID: work.request.installationID,
                                                        sourceScope: work.request.sourceScope,
                                                        eventDirectory: work.request.eventDirectory,
                                                        receivedAt: now, expiresAt: work.request.expiresAt)
                    let written = ClaudeQuestionStore.publish(
                        receipt, in: URL(fileURLWithPath: work.eventsPath, isDirectory: true))
                    return ClaudeQuestionReceiptResult(request: work.request, requestID: work.request.requestID,
                                                      root: work.root,
                                                      scanGeneration: work.scanGeneration, written: written)
                }
            }.value
            self?.reconcileClaudeQuestionReceipts(results)
        }
    }

    private func reconcileClaudeQuestionReceipts(_ results: [ClaudeQuestionReceiptResult]) {
        let now = Date().timeIntervalSince1970
        let roots = currentClaudeQuestionRoots()
        for result in results {
            let live = liveClaudeQuestions[result.requestID]
            let rootIsCurrent = roots.contains(result.root)
                && live.map {
                    claudeQuestionRootKey(sourceScope: $0.sourceScope, events: $0.events,
                                          installationID: $0.request.installationID) == result.root
                        && $0.request.sourceScope == $0.sourceScope
                        && $0.request.eventDirectory == $0.events.standardizedFileURL.path
                } == true
            let disposition = claudeQuestionReceiptDisposition(
                result, currentGeneration: claudeQuestionScanGeneration, liveRequest: live?.request,
                rootIsCurrent: rootIsCurrent, now: now)
            pendingClaudeQuestionReceipts.remove(result.requestID)
            switch disposition {
            case .accept, .staleAccept:
                availableClaudeQuestionTokens.insert(result.requestID)
            case .discard:
                continue
            }
        }
    }

    var visibleReminders: [Reminder] {
        queue.items.compactMap { $0.request }.map {
            Reminder(request_id: $0.id, session_id: $0.session, turn_id: $0.turn, outcome: "no_decision")
        }
    }
    var cliItems: [AttentionCompletion] {
        queue.items.compactMap(\.completion).filter { $0.source == .cli }
    }
    private var scanning = false
    private var nextScan: Double = 0
    var orderedAttentionItems: [AttentionItem] { queue.items }
    var orderedAgentAttentionItems: [AgentAttentionItem] { agentQueue.items(at: Date().timeIntervalSince1970) }
    var count: Int { orderedAgentAttentionItems.count + (attention.pending ? 1 : 0) }
    var workingCount: Int { agentQueue.workingCount }
    var toCheckCount: Int { agentQueue.toCheckCount + (attention.pending ? 1 : 0) }
    /// One presentation mode prevents passive hover from replacing a new item's focused card.
    @Published var expanded = false
    @Published var presentationMode: NotchPresentationMode = .collapsed
    /// Fresh response previews are intentionally process-memory only.
    @Published private(set) var completionPreviews: [CompletionIdentity: CompletionPreviewAvailability] = [:]
    @Published private(set) var spotlightContexts: [AttentionItemID: SpotlightRecordContext] = [:]
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Natural height of the open panel's content, reported by the view after layout.
    var contentHeight: CGFloat = 0
    /// How the strip splits around the housing on the current display; the view lays out by it.
    @Published var stripLayout = StripLayout(leading: 140, gap: 0, trailing: 60, height: NotchPlacement.collapsedHeight)
    var hovering = false
    private var hoverHold = HoverHold()
    private var hoverHeld = false
    private var hoverExitTask: Task<Void, Never>?
    /// After Escape, hover does not reopen the panel until the pointer has left it.
    private var hoverSuppressed = false
    private var notchPresentation = NotchPresentationController()
    /// Fresh IDs stay pending until an eligible card is selected for the single shared spotlight.
    /// Keeping all IDs lets a Claude card remain eligible when a same-scan Codex card is newer.
    private var freshAgentRequestIDs: Set<AgentAttentionID> = []
    private var freshAgentCompletionIDs: Set<AgentAttentionID> = []
    private var freshAgentQuestionIDs: Set<AgentAttentionID> = []
    private var previewSpotlightAgent: AgentAttentionID?
    private var targetFrame: CGRect = .zero
    /// `--preview-queue <collapsed|spotlight|expanded>` seeds in-memory sample items for screenshots.
    /// It never scans Codex events, never saves, and never releases approvals.
    let previewMode = Companion.argumentValue(for: "--preview-queue")
    private var status: NSStatusItem!
    private var panel: NotchPanel!
    private var controls: NSWindow?
    private var controlsAnimationGeneration = 0
    private var controlsAnimatingOut = false
    private var controlsRestingFrame: NSRect?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// The display the panel was last placed on; placement freezes here while the user interacts.
    private var currentDisplayID: UInt32?
    /// SwiftUI's hover flag can go stale when the panel is re-placed out from under the pointer
    /// (a display disconnect, for example), so it is confirmed against the actual pointer location.
    private var pointerInsidePanel: Bool {
        hovering && panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
    }
    private var setupRoots: CodexSetupRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let helper = home.appendingPathComponent("Library/Application Support/Steer", isDirectory: true)
        return CodexSetupRoots(configDirectory: home.appendingPathComponent(".codex", isDirectory: true),
                               helperDirectory: helper, eventsDirectory: helper.appendingPathComponent("events", isDirectory: true))
    }

    nonisolated static func argumentValue(for flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// Steer's own support directory, never Codex's. `--attention-snapshot` isolates lab runs.
    nonisolated static var snapshotURL: URL {
        if let path = argumentValue(for: "--attention-snapshot") { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steer/attention-snapshot.json")
    }

    nonisolated static let launchSnapshot = restoredSnapshot()

    /// The saved snapshot, or the pre-snapshot acknowledgment lists from UserDefaults when none exists yet.
    /// An unreadable or invalid snapshot loads as empty; startup never depends on it.
    nonisolated private static func restoredSnapshot() -> AttentionSnapshot {
        let snapshot = AttentionSnapshotStore.load(from: snapshotURL)
        guard snapshot == AttentionSnapshot(), !FileManager.default.fileExists(atPath: snapshotURL.path) else { return snapshot }
        let decoder = JSONDecoder()
        let cli = UserDefaults.standard.data(forKey: "cliAcknowledgments")
            .flatMap { try? decoder.decode(Set<TurnIdentity>.self, from: $0) } ?? []
        let desktop = UserDefaults.standard.data(forKey: "desktopAcknowledgments")
            .flatMap { try? decoder.decode(Set<TurnIdentity>.self, from: $0) } ?? []
        return AttentionSnapshot(legacyCLI: cli, legacyDesktop: desktop)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        refreshLaunchAtLogin()
        for flag in ["--reminder-events", "--desktop-events"] {
            if let path = Companion.argumentValue(for: flag) { eventsPath = path }
        }
        // Restored completions never replay their sound or popup.
        if agentQueue.items(at: Date().timeIntervalSince1970).contains(where: { $0.outcome != nil }) {
            completionPresentation = Attention(restored: true)
        }
        // Checkpoint what was restored: the store keeps the current valid file as the fallback for the next
        // save, and rewrites a corrupt file from that fallback. A missing snapshot is not created here.
        if FileManager.default.fileExists(atPath: Companion.snapshotURL.path) {
            AttentionSnapshotStore.save(Companion.launchSnapshot, to: Companion.snapshotURL)
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.title = "S"
        status.button?.toolTip = "Steer"
        status.button?.setAccessibilityLabel("Steer menu")
        let menu = NSMenu()
        let heading = NSMenuItem(title: "Steer", action: nil, keyEquivalent: "")
        menu.addItem(heading)
        for (title, action) in [("Show Steer controls", #selector(showControls)),
                                ("Send test notification", #selector(sendTest)),
                                ("Dismiss test notification", #selector(dismissTest)),
                                ("Mute sound", #selector(toggleMute)),
                                ("Quit Steer", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if action == #selector(toggleMute) { item.state = muted ? .on : .off }
            menu.addItem(item)
        }
        status.menu = menu
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window shadow: its rim would outline the panel and break the fusion with the menu bar.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Notch(model: self))
        panel.onEscape = { [weak self] in self?.collapse() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        // Display connect, disconnect, and rearrangement re-place the one panel; queue state is untouched.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }
        daemonClient.onMessage = { [weak self] message in
            guard let self else { return }
            _ = self.daemonBook.apply(message: message, now: Date().timeIntervalSince1970)
        }
        daemonClient.onDisconnect = { [weak self] in self?.daemonBook.disconnect() }
        if let mode = previewMode { seedPreview(mode) }
        refresh()
        refreshSetup()
        // A first/unconfigured launch should explain setup immediately. Once state
        // exists, refresh can keep the normal quiet launch behavior.
        if previewMode == nil, launchAtLogin.shouldOpenUnconfiguredControls,
           !FileManager.default.fileExists(atPath: setupRoots.stateURL.path) { showControls() }
        if CommandLine.arguments.contains("--smoke-test") {
            showControls()
            precondition(controls?.isVisible == true && controls?.contentView != nil)
            precondition(controls?.title == "Steer" && controls?.styleMask.contains(.resizable) == true)
            precondition(controls?.frame.width ?? 0 >= 720 && controls?.frame.height ?? 0 >= 540)
            precondition(status.button?.title == "S" && status.menu?.items.count == 6)
            dismissControls(animated: false)
            precondition(controls?.isVisible == false)
            presentControls(animated: false)
            precondition(controls?.isVisible == true && controls?.alphaValue == 1)
            print("Steer controls-window smoke check passed.")
            app.terminate(nil)
        }
        writePlacementProbeAndQuitIfRequested()
        printSetupProbeAndQuitIfRequested()
    }

    /// `--setup-probe`: print the Codex setup status and plan this build computes, then quit.
    /// It reads the same files the controls window reads and changes nothing.
    private func printSetupProbeAndQuitIfRequested() {
        guard CommandLine.arguments.contains("--setup-probe") else { return }
        let roots = setupRoots
        let capabilities = CodexSetupDetection.capabilities()
        let snapshot = CodexSetupDetection.setupSnapshot(roots: roots, capabilities: capabilities)
        print("status: \(snapshot.status)")
        print("capabilities: cli=\(capabilities.cli) desktop=\(capabilities.desktop) ghostty=\(capabilities.ghostty) supported=\(capabilities.supported)")
        if let plan = snapshot.plan {
            print("plan: \(plan.status) requiresConfigure=\(plan.requiresConfigure)")
            print("config change adds hooks flag: \(CodexSetupValidator.hasHooksEnabled(in: plan.configChange))")
        } else {
            print("plan: nil (config or hooks unreadable)")
        }
        app.terminate(nil)
    }

    /// `--placement-probe <path>`: record the attached displays, the active-display choice, and the
    /// panel frames this build would use, then quit. It reads screen geometry only.
    private func writePlacementProbeAndQuitIfRequested() {
        guard let path = Companion.argumentValue(for: "--placement-probe") else { return }
        // An in-memory test item makes the panel present; nothing is written to UserDefaults.
        attention.enqueue()
        refresh()
        let displays = Companion.attachedDisplays()
        let pointer = NSEvent.mouseLocation
        let chosen = NotchDisplaySelection.choose(displays: displays, pointer: pointer, current: currentDisplayID, interacting: false)
        func rect(_ r: CGRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        let report: [String: Any] = [
            "displays": displays.map { ["id": Int($0.id), "frame": rect($0.frame), "top_inset": Double($0.topInset), "physical_notch": $0.hasPhysicalNotch] },
            "pointer": ["x": pointer.x, "y": pointer.y],
            "chosen_display": chosen.map { Int($0.id) } ?? NSNull(),
            "collapsed_frame": chosen.map { rect(NotchPlacement.frame(on: $0, expanded: false, rows: 0, extraRows: false, fiveHourShown: fiveHourShown)) } ?? NSNull(),
            "expanded_frame_three_rows": chosen.map { rect(NotchPlacement.frame(on: $0, expanded: true, rows: 3, extraRows: false, fiveHourShown: fiveHourShown)) } ?? NSNull(),
            "five_hour_shown": fiveHourShown,
            "panel_frame": rect(panel.frame),
            "codex_foreground": desktopForeground,
            "panel": ["level": panel.level.rawValue, "nonactivating": panel.styleMask.contains(.nonactivatingPanel),
                      "can_join_all_spaces": panel.collectionBehavior.contains(.canJoinAllSpaces),
                      "full_screen_auxiliary": panel.collectionBehavior.contains(.fullScreenAuxiliary),
                      "is_key_after_presentation": panel.isKeyWindow, "visible": panel.isVisible]
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: path))
        }
        app.terminate(nil)
    }

    /// AppKit screens as the placement rules see them. The top safe-area inset is the camera housing;
    /// the menu bar height is that of the bar actually showing on the screen, zero under a
    /// full-screen app or an auto-hidden bar (`visibleFrame` reserves the strip either way).
    nonisolated static func attachedDisplays() -> [NotchDisplay] {
        let menuBars = shownMenuBars()
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            var housing: CGFloat = 0
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                housing = max(0, screen.frame.width - left.width - right.width)
            }
            let menuBar = NotchDisplay.shownMenuBarHeight(on: screen.frame, menuBars: menuBars)
            return NotchDisplay(id: number.uint32Value, frame: screen.frame, topInset: screen.safeAreaInsets.top,
                                housingWidth: housing, menuBarHeight: menuBar,
                                isBuiltIn: CGDisplayIsBuiltin(number.uint32Value) != 0)
        }
    }

    /// The menu bar windows the window server has on screen, in AppKit global coordinates. The
    /// window server draws one per display that is showing a menu bar, at the main-menu window
    /// level; a display under a full-screen app has none. Owner and level are readable without
    /// Screen Recording permission; window names are not, so they are not used.
    nonisolated static func shownMenuBars() -> [CGRect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        return windows.compactMap { window in
            guard window[kCGWindowOwnerName as String] as? String == "Window Server",
                  window[kCGWindowLayer as String] as? Int == menuLevel,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            // Core Graphics measures from the top-left of the primary display; AppKit from its bottom-left.
            return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    @objc func showControls() {
        refreshLaunchAtLogin()
        if controls == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Steer"
            window.minSize = NSSize(width: 720, height: 540)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: Controls(model: self))
            window.center()
            controls = window
            controlsRestingFrame = window.frame
        }
        presentControls(animated: !reduceMotion)
    }

    private func presentControls(animated: Bool) {
        guard let window = controls else { return }
        let wasAnimatingOut = controlsAnimatingOut
        controlsAnimationGeneration += 1
        controlsAnimatingOut = false
        let finalFrame = wasAnimatingOut ? controlsRestingFrame ?? window.frame : window.frame
        controlsRestingFrame = finalFrame

        if window.isVisible, !wasAnimatingOut, window.alphaValue > 0.99 {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        if animated, !wasAnimatingOut {
            window.alphaValue = 0
            window.setFrame(finalFrame.offsetBy(dx: 0, dy: -10), display: false)
        } else if !animated {
            window.alphaValue = 1
            window.setFrame(finalFrame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard animated else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === controls else { return true }
        dismissControls(animated: !reduceMotion)
        return false
    }

    private func dismissControls(animated: Bool) {
        guard let window = controls, window.isVisible else { return }
        controlsAnimationGeneration += 1
        let generation = controlsAnimationGeneration
        controlsAnimatingOut = true
        let finalFrame = window.frame
        controlsRestingFrame = finalFrame

        guard animated else {
            window.orderOut(nil)
            window.alphaValue = 1
            controlsAnimatingOut = false
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(finalFrame.offsetBy(dx: 0, dy: -8), display: true)
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window, generation == self.controlsAnimationGeneration else { return }
                window.orderOut(nil)
                window.setFrame(finalFrame, display: false)
                window.alphaValue = 1
                self.controlsAnimatingOut = false
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLoginCoordinator.refresh()
        launchAtLogin = launchAtLoginCoordinator.state
    }

    func launchAtLoginChanged(_ enabled: Bool) {
        launchAtLoginCoordinator.setEnabled(enabled)
        launchAtLogin = launchAtLoginCoordinator.state
    }

    func openLoginItemsSettings() {
        launchAtLoginCoordinator.openSystemSettings()
    }

    @objc func connectReminders() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.message = "Choose the Codex hook lab’s events folder. Steer reads it without changing hooks."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        // Requests and running work belong to the old folder; undismissed completions are kept, now uncertain.
        queue = AttentionQueue(snapshot: queue.snapshot, observingSince: Date().timeIntervalSince1970)
        reminderPresentation.dismiss()
        questionPresentation.dismiss()
        completionPresentation = Attention(restored: queue.items.contains { $0.kind == .completion })
        eventsPath = url.path
        UserDefaults.standard.set(eventsPath, forKey: "approvalEventsPath")
        nextScan = 0
        refresh()
    }

    func refreshSetup() {
        let roots = setupRoots
        Task { @MainActor [weak self] in
            let snapshot = await Task.detached {
                let capabilities = CodexSetupDetection.capabilities()
                return CodexSetupDetection.setupSnapshot(roots: roots, capabilities: capabilities)
            }.value
            guard let self else { return }
            self.setupCapabilities = snapshot.capabilities
            self.setupPlan = snapshot.plan
            self.setupStatus = snapshot.status
            self.adoptInstalledEventsFolder(roots)
            // Until Codex is delivering events, the controls window is the only way to finish setup,
            // so a launch that finds setup incomplete shows it without waiting for a reopen.
            if !self.shownControlsForSetup, self.previewMode == nil {
                self.shownControlsForSetup = true
                if case .connected = snapshot.status {} else if self.launchAtLogin.shouldOpenUnconfiguredControls {
                    self.showControls()
                }
            }
        }
    }
    private var shownControlsForSetup = false

    /// Projects the legacy Codex adapter into the source-neutral queue used by the notch. Claude
    /// observations already arrive there, so this keeps both sources under one ordering/count path.
    private func syncAgentQueueWithCodex(now: Double) {
        let items = queue.items
        let keeping = Set(items.map { item -> AgentAttentionID in
            switch item.kind {
            case .actionableRequest, .handedBackRequest: return .approval(CodexAttentionAdapter.approval(from: item.request!).id)
            case .question: return .question(CodexAttentionAdapter.question(from: item.question!).id)
            case .completion: return .outcome(CodexAttentionAdapter.outcome(from: item.completion!).id)
            case .running: return .running(CodexAttentionAdapter.running(from: item.running!).id)
            }
        })
        agentQueue.reconcile(source: .codex, sourceScope: CodexAttentionAdapter.sourceScope, keeping: keeping)
        let requests = items.compactMap { $0.request }
        let questions = items.compactMap { $0.question }
        let completions = items.compactMap { $0.completion }
        let running = items.compactMap { $0.running }
        agentQueue.apply(CodexAttentionAdapter.observations(requests: requests, questions: questions,
                                                            completions: completions, running: running), now: now)
        agentQueue.expire(at: now)
    }

    /// A connected install delivers to Steer's own events folder; watch it even if an earlier lab
    /// folder was chosen or a previous Configure attempt ended before recording the path.
    private func adoptInstalledEventsFolder(_ roots: CodexSetupRoots) {
        guard previewMode == nil, Companion.argumentValue(for: "--reminder-events") == nil,
              Companion.argumentValue(for: "--desktop-events") == nil else { return }
        switch setupStatus {
        case .connected, .configuredAwaitingRestart, .permissionRequired: break
        default: return
        }
        let installed = roots.eventsDirectory.path
        guard eventsPath != installed else { return }
        queue = AttentionQueue(snapshot: queue.snapshot, observingSince: Date().timeIntervalSince1970)
        reminderPresentation.dismiss()
        questionPresentation.dismiss()
        completionPresentation = Attention(restored: queue.items.contains { $0.kind == .completion })
        eventsPath = installed
        UserDefaults.standard.set(installed, forKey: "approvalEventsPath")
        nextScan = 0
        refresh()
    }

    func configureCodex() {
        let roots = setupRoots
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await Task.detached {
                let capabilities = CodexSetupDetection.capabilities()
                return CodexSetupDetection.setupSnapshot(roots: roots, capabilities: capabilities)
            }.value
            self.setupCapabilities = snapshot.capabilities
            self.setupPlan = snapshot.plan
            self.setupStatus = snapshot.status
            guard let plan = self.setupPlan, case .ready = plan.status else {
                self.setupMessage = "Steer cannot configure Codex until the setup preview is ready."
                return
            }
            let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SteerHook")
            guard let helper = CodexSetupDetection.boundedRegularData(at: helperURL, maximum: CodexSetupLimits.maximumFileSize) else {
                self.setupMessage = "The bundled Steer helper is unavailable. Reinstall Steer and try again."
                return
            }
            let helperIsValid = await Task.detached { CodexSetupDetection.validateHelper(helperURL) }.value
            guard helperIsValid else {
                self.setupMessage = "The bundled Steer helper failed its self-test. Reinstall Steer and try again."
                return
            }
            let result = await Task.detached {
                do {
                    return SetupInstallResult.success(
                        try CodexSetupInstaller().install(plan, roots: roots, helper: helper,
                                                          capabilities: snapshot.capabilities))
                } catch {
                    return SetupInstallResult.failure(error.localizedDescription)
                }
            }.value
            guard case .success(let status) = result else {
                if case .failure(let message) = result { self.setupMessage = message }
                self.refreshSetup()
                return
            }
            self.setupStatus = status
            switch status {
            case .connected, .configuredAwaitingRestart, .permissionRequired:
                self.eventsPath = roots.eventsDirectory.path
                UserDefaults.standard.set(self.eventsPath, forKey: "approvalEventsPath")
            default: break
            }
            self.setupMessage = self.setupStatusText + " Restart new Codex sessions to load settings; Steer did not restart existing sessions. Review Codex's hook-trust prompt. Ghostty Automation permission is not verified; enable Ghostty controls to let macOS prompt."
        }
    }

    func undoCodexSetup() {
        let roots = setupRoots
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached {
                do { return SetupUndoResult.success(try CodexSetupInstaller().undo(roots: roots)) }
                catch { return SetupUndoResult.failure(error.localizedDescription) }
            }.value
            switch result {
            case .success(let status):
                self.setupStatus = status
                if self.eventsPath == roots.eventsDirectory.path {
                    self.eventsPath = ""
                    UserDefaults.standard.removeObject(forKey: "approvalEventsPath")
                }
                self.setupMessage = "Disconnected. Existing Codex approval and sandbox settings were left unchanged."
            case .failure(let message):
                self.setupMessage = message
                self.refreshSetup()
            }
        }
    }

    var setupStatusText: String {
        switch setupStatus {
        case .connected: return "Codex event delivery connected"
        case .notConfigured: return "Codex detected; Steer is not configured."
        case .configuredAwaitingRestart(let value), .unavailable(let value), .unsupported(let value), .permissionRequired(let value), .malformed(let value), .conflict(let value), .repairRequired(let value): return value
        }
    }

    var setupSurfaceStatusText: [String] {
        func text(_ name: String, installed: Bool, supported: Bool, version: String?, minimum: String) -> String {
            guard installed else { return "\(name): unavailable" }
            guard supported else { return "\(name) \(version ?? "version unknown"): unsupported; requires ≥ \(minimum)" }
            return "\(name) \(version ?? "version unknown"): available"
        }
        return [
            text("Codex CLI", installed: setupCapabilities.cliInstalled, supported: setupCapabilities.cli,
                 version: setupCapabilities.cliVersion, minimum: CodexSetupRequirements.minimumCLIVersion),
            text("Codex desktop", installed: setupCapabilities.desktopInstalled, supported: setupCapabilities.desktop,
                 version: setupCapabilities.desktopVersion, minimum: CodexSetupRequirements.minimumDesktopVersion),
            text("Ghostty", installed: setupCapabilities.ghosttyInstalled, supported: setupCapabilities.ghostty,
                 version: setupCapabilities.ghosttyVersion, minimum: CodexSetupRequirements.minimumGhosttyVersion)
        ]
    }

    var canUndoSetup: Bool {
        switch setupStatus {
        case .connected, .configuredAwaitingRestart, .permissionRequired: return true
        default: return false
        }
    }

    var canConfigureSetup: Bool {
        guard let plan = setupPlan, case .ready = plan.status else { return false }
        switch setupStatus {
        case .notConfigured, .repairRequired: return true
        default: return false
        }
    }

    func scanReminders() {
        let now = ProcessInfo.processInfo.systemUptime
        let hasClaudeInventoryRoot = claude.roots.contains { $0.capabilities.supported }
        guard previewMode == nil, (!eventsPath.isEmpty || hasClaudeInventoryRoot), !scanning, now >= nextScan else { return }
        scanning = true
        nextScan = now + 2
        claudeQuestionScanGeneration &+= 1
        let questionScanGeneration = claudeQuestionScanGeneration
        claudeApprovalScanGeneration &+= 1
        let approvalScanGeneration = claudeApprovalScanGeneration
        // Claude inventory can be the only connected source. The empty Codex input is read from
        // /dev/null so the existing bounded readers produce no Codex observations.
        let events = URL(fileURLWithPath: eventsPath.isEmpty ? "/dev/null" : eventsPath)
        let rolloutRoot = Companion.rolloutRoot
        let readStateURL = desktopReadStateEnabled ? Companion.desktopReadStateURL : nil
        let namesURL = Companion.threadNamesURL
        // Ghostty's current tab titles prove which sessions are CLI sessions when the rollout header
        // cannot (a TUI on the app-server daemon is recorded as `vscode`). Empty with controls off.
        let inventory: GhosttyInventory? = {
            if case .known(let snapshot) = ghosttyFocusState, snapshot.status == "ok" {
                return GhosttyInventory(titles: snapshot.terminalNames, takenAt: ghosttyInventoryAt)
            }
            return nil
        }()
        let known = knownCLISessions
        let daemonThreads = daemonClient.loadedThreads
        let observingSince = Companion.launchedAt
        let observationNow = Date().timeIntervalSince1970
        let claudeRoots = claude.roots.compactMap { root -> (scope: String, events: URL, installationID: String)? in
            guard root.status == .connected, !root.eventsPath.isEmpty,
                  let installationID = root.plan?.installationID, !installationID.isEmpty else { return nil }
            return (root.url.standardizedFileURL.path, URL(fileURLWithPath: root.eventsPath, isDirectory: true), installationID)
        }
        let claudeInventoryRoots = claude.roots.compactMap { root -> (root: URL, capabilities: ClaudeCapabilities)? in
            guard root.capabilities.supported else { return nil }
            return (root.url.standardizedFileURL, root.capabilities)
        }
        let claudeUsageRoots = claude.roots.compactMap { root -> (scope: String, directory: URL)? in
            guard claude.usageEnabled(for: root), !root.usagePath.isEmpty else { return nil }
            return (root.url.standardizedFileURL.path, URL(fileURLWithPath: root.usagePath, isDirectory: true))
        }
        Task { @MainActor in
            let result = await Task.detached {
                (ReminderReader.scan(events: events, rollouts: rolloutRoot, ghostty: inventory, knownCLISessions: known,
                                     daemonThreads: daemonThreads), DesktopEventReader.read(from: events),
                 readStateURL.flatMap(DesktopReadStateReader.read), ThreadNameReader.read(namesURL) ?? [:],
                 CodexUsageReader.latest(root: rolloutRoot),
                 SessionDiscovery.candidates(root: rolloutRoot, now: Date().timeIntervalSince1970),
                 ProcessList.arguments().map(CodexCLIProcesses.isRunning(processList:)) ?? false,
                 claudeInventoryRoots.map { root in
                     ClaudeSetupDetection.activeSessionInventory(root: root.root, capabilities: root.capabilities,
                                                                 observedAt: observationNow)
                 },
                 claudeRoots.map { root in
                     ClaudeObservationReader.scan(events: root.events, sourceScope: root.scope,
                                                  installationID: root.installationID, observingSince: observingSince,
                                                  now: observationNow)
                 },
                 claudeRoots.map { root in
                     ClaudeQuestionStore.pending(in: root.events, installationID: root.installationID,
                                                 observingSince: observingSince, now: observationNow)
                         .map { (request: $0, events: root.events, sourceScope: root.scope) }
                 },
                 claudeUsageRoots.reduce(into: [String: ClaudeUsageReading]()) { result, root in
                     if let reading = ClaudeUsageReader.latest(root: root.directory, sourceScope: root.scope, now: observationNow) {
                         result[root.scope] = reading
                     }
                 })
            }.value
            let scan = result.0
            let desktopEvents = result.1
            let readState = result.2
            guard eventsPath.isEmpty || eventsPath == events.path else { scanning = false; refresh(); return }
            let previousAgent = Set(agentQueue.items(at: Date().timeIntervalSince1970).map(\.id))
            let scanNow = Date().timeIntervalSince1970
            var approvalReceiptWork: [ClaudeApprovalReceiptWork] = []
            for (root, claudeScan) in zip(claudeRoots, result.8) {
                for approval in claudeScan.observations.compactMap({ observation -> AgentApproval? in
                    if case let .approval(value) = observation { return value }
                    return nil
                }) {
                    guard claudeScan.available, approval.expiresAt > scanNow,
                          let requestID = approval.hookRequestID,
                          !pendingClaudeApprovalReceipts.contains(requestID) else { continue }
                    pendingClaudeApprovalReceipts.insert(requestID)
                    approvalReceiptWork.append(ClaudeApprovalReceiptWork(
                        approval: approval,
                        eventsPath: root.events.standardizedFileURL.path,
                        root: claudeApprovalRootKey(sourceScope: root.scope, events: root.events,
                                                    installationID: root.installationID),
                        receivedAt: scanNow,
                        scanGeneration: approvalScanGeneration))
                }
            }
            for claudeScan in result.8 {
                agentQueue.apply(claudeScan, now: scanNow)
            }
            // Receipt reads and writes happen off the main actor. The completion rechecks the
            // exact root, request, and deadline before making controls available.
            publishClaudeApprovalReceipts(approvalReceiptWork)
            let configuredClaudeScopes = Set(configuredClaudeNavigationRoots().map { $0.root.path })
            claudeInventories = Dictionary(uniqueKeysWithValues: result.7.filter {
                configuredClaudeScopes.contains($0.sourceScope)
            }.map { ($0.sourceScope, $0) })
            liveClaudeSessions = Dictionary(uniqueKeysWithValues: result.7.filter {
                configuredClaudeScopes.contains($0.sourceScope)
            }.map { scan in
                (scan.sourceScope, scan.available
                    ? scan.sessions.filter { $0.kind == .interactive }.map(\.sessionID)
                    : [])
            })
            claudeInventoryAvailable = Dictionary(uniqueKeysWithValues: result.7.filter {
                configuredClaudeScopes.contains($0.sourceScope)
            }.map { ($0.sourceScope, $0.available) })
            var pendingClaudeQuestionIDs = Set<String>()
            var receiptWork: [ClaudeQuestionReceiptWork] = []
            for requests in result.9 {
                for live in requests {
                    guard live.request.sourceScope == live.sourceScope,
                          live.request.eventDirectory == live.events.standardizedFileURL.path else { continue }
                    pendingClaudeQuestionIDs.insert(live.request.requestID)
                    liveClaudeQuestions[live.request.requestID] = LiveClaudeQuestion(request: live.request,
                                                                                       events: live.events,
                                                                                       sourceScope: live.sourceScope)
                    guard !spentClaudeQuestionTokens.contains(live.request.requestID),
                          !availableClaudeQuestionTokens.contains(live.request.requestID),
                          pendingClaudeQuestionReceipts.insert(live.request.requestID).inserted else { continue }
                    receiptWork.append(ClaudeQuestionReceiptWork(
                        request: live.request, eventsPath: live.events.standardizedFileURL.path,
                        root: claudeQuestionRootKey(sourceScope: live.sourceScope, events: live.events,
                                                    installationID: live.request.installationID),
                        scanGeneration: questionScanGeneration))
                }
            }
            pruneClaudeQuestionState(now: scanNow, roots: currentClaudeQuestionRoots(),
                                     pendingIDs: pendingClaudeQuestionIDs,
                                     observedIDs: observedClaudeQuestionIDs(result.8))
            // A root can contain many pending rendezvous files. Writes happen off the main actor;
            // the completion rechecks the scan generation, root identity, and request deadline.
            publishClaudeQuestionReceipts(receiptWork)
            for inventory in result.7 {
                agentQueue.apply(inventory, now: Date().timeIntervalSince1970)
                for session in inventory.sessions {
                    let identity = AgentSessionIdentity(source: .claude, sourceScope: inventory.sourceScope,
                                                        session: session.sessionID, surface: .cli)
                    if !session.name.isEmpty { claudeSessionNames[identity] = session.name }
                }
            }
            if threadNames != result.3 { threadNames = result.3 }
            if usage != result.4 { usage = result.4 }
            if claudeUsage != result.10 { claudeUsage = result.10 }
            // Sessions already working before their first hook event: shown only with liveness
            // evidence, and only as working (see docs/session-discovery.md).
            let candidates = result.5
            let cliCandidates = Set(candidates.filter { $0.source == .cli }.map(\.session))
            var inGhostty: Set<UUID> = []
            if case .known(let snapshot) = ghosttyFocusState { inGhostty = GhosttyMatch.sessions(in: snapshot, among: cliCandidates) }
            let liveness = SessionLiveness(desktopRunning: !desktopAdapter.runningInstallations().isEmpty,
                                           cliProcessRunning: result.6, cliSessionsInGhostty: inGhostty,
                                           sessionEnds: scan.sessionEnds)
            let discovered = SessionDiscovery.running(candidates, liveness: liveness)
            let discoveredCLI = Set(discovered.filter { $0.source == .cli }.map(\.session))
            endedSessions = Set(scan.sessionEnds.keys)
            cliSessions = scan.cliSessions.union(discoveredCLI)
            liveCLI = scan.cliState.liveSessions.union(discoveredCLI)
            knownCLISessions.formUnion(scan.titledCLISessions)
            let previous = Set(queue.items.map(\.id))
            // A receipt found on disk is not a verified live interaction: such a request enters handed
            // back and, when a real helper receipt exists, a no-decision record releases it to Codex at once.
            let unverified = queue.apply(scan: scan, desktopEvents: desktopEvents, now: Date().timeIntervalSince1970)
            queue.apply(discovered: discovered)
            applyDesktopReadState(readState, enabled: readStateURL != nil)
            for request in unverified where ApprovalReceipts.existing(for: request.id, in: events) != nil {
                _ = ApprovalStore.publish(ApprovalDecisionRecord(requestID: request.id, decision: .noDecision,
                                                                 decidedAt: Date().timeIntervalSince1970), in: events)
            }
            // Companion receipt: the deadline starts here, including for requests queued behind others.
            let receipted = ApprovalReceipts.issue(scan.awaitingReceipt, in: events, cliSessions: scan.cliSessions,
                                                   now: Date().timeIntervalSince1970)
            if !receipted.isEmpty { queue.recordReceipts(receipted, now: Date().timeIntervalSince1970) }
            syncAgentQueueWithCodex(now: Date().timeIntervalSince1970)
            let current = queue.items
            let currentAgent = agentQueue.items(at: Date().timeIntervalSince1970)
            let newAgentItems = currentAgent.filter { !previousAgent.contains($0.id) }
            let newAgentOutcomes = newAgentItems.compactMap(\.outcome)
            let newAgentQuestions = newAgentItems.compactMap(\.question)
            let freshAgentOutcomes = newAgentOutcomes.filter { !$0.uncertain && $0.arrivedAt >= Companion.launchedAt }
            let freshAgentQuestions = newAgentQuestions.filter { $0.arrivedAt >= Companion.launchedAt }
            let newAgentRequests = newAgentItems.filter {
                ($0.kind == .actionableApproval || $0.kind == .handedBackApproval)
            }
            let freshAgentRequests = newAgentRequests.filter { $0.arrivedAt >= Companion.launchedAt }
            let newItems = current.filter { !previous.contains($0.id) }
            let newCompletions = newItems.compactMap(\.completion)
            for completion in newCompletions where !completion.uncertain {
                let turn = TurnIdentity(session: completion.session, turn: completion.turn)
                completionPreviews[completion.id] = scan.completionPreviews[turn].map(CompletionPreviewAvailability.available)
                    ?? .unavailable("Codex did not provide a readable final response for this turn.")
                spotlightContexts[.completion(completion.id)] = scan.turnContexts[turn] ?? SpotlightRecordContext()
            }
            let liveCompletionIDs = Set(current.compactMap(\.completion).map(\.id))
            completionPreviews = completionPreviews.filter { liveCompletionIDs.contains($0.key) }
            let liveItemIDs = Set(current.map(\.id))
            spotlightContexts = spotlightContexts.filter { liveItemIDs.contains($0.key) }
            for item in current where item.kind != .completion {
                let turn = item.request?.turn ?? item.question?.turn ?? item.running?.turn
                if let turn, let context = scan.turnContexts[TurnIdentity(session: item.session, turn: turn)] {
                    spotlightContexts[item.id] = context
                }
            }
            freshAgentCompletionIDs.formUnion(freshAgentOutcomes.map { .outcome($0.id) })
            freshAgentRequestIDs.formUnion(freshAgentRequests.map(\.id))
            freshAgentQuestionIDs.formUnion(freshAgentQuestions.map { .question($0.id) })
            if !freshAgentOutcomes.isEmpty { completionPresentation.enqueue() }
            else if newAgentOutcomes.contains(where: { !$0.uncertain }), !completionPresentation.pending {
                completionPresentation = Attention(restored: true)
            }
            if ghosttyEnabled && newCompletions.contains(where: { $0.source == .cli }) { nextGhosttyScan = 0 }
            if !currentAgent.contains(where: { $0.approval != nil }) { reminderPresentation.dismiss() }
            else if newItems.contains(where: { $0.kind == .handedBackRequest || $0.kind == .actionableRequest })
                    || !freshAgentRequests.isEmpty {
                reminderPresentation.enqueue()
            } else if !newAgentRequests.isEmpty, !reminderPresentation.pending {
                reminderPresentation = Attention(restored: true)
            }
            if !currentAgent.contains(where: { $0.outcome != nil }) { completionPresentation.dismiss() }
            // A question posed before this launch is shown but does not pop or chime: the user may
            // already be looking at it, and Steer was not observing when it arrived.
            if !currentAgent.contains(where: { $0.question != nil }) { questionPresentation.dismiss() }
            else if !freshAgentQuestions.isEmpty { questionPresentation.enqueue() }
            else if !newAgentQuestions.isEmpty, !questionPresentation.pending { questionPresentation = Attention(restored: true) }
            saveCompletions()
            scanning = false
            claude.refreshUsage()
            completedAScan = true
            refresh()
            writeRestartReportAndQuitIfRequested(unverified: unverified)
        }
    }

    /// `--daemon-report <path>`: a few seconds after launch, record what the daemon client saw on
    /// `--daemon-socket`, then quit. Used by the daemon lab against a fake daemon; nothing is answered.
    private var daemonReportDue: Double?
    /// True once a scan has published its result; the lab reports wait for it.
    private var completedAScan = false
    private func writeDaemonReportAndQuitIfRequested() {
        guard let path = Companion.argumentValue(for: "--daemon-report") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let due = daemonReportDue else { daemonReportDue = now + 4; return }
        // A scan must have finished, or the report would describe an empty queue rather than what
        // the seeded session produced; the deadline still ends the run if no scan ever completes.
        guard now >= due, completedAScan || now >= due + 6 else { return }
        let report: [String: Any] = [
            "socket": daemonClient.socketPath,
            "status": daemonClient.statusText,
            "connected": daemonClient.isConnected,
            "subscribed": daemonClient.subscribed.sorted(),
            "question_routes": queue.items.compactMap(\.question).map { "\($0.callID): \(route(for: $0))" },
            // Where each completion card's reply field would send, without sending anything.
            "completion_reply_targets": queue.items.compactMap(\.completion)
                .map { "\($0.session.uuidString.lowercased()): \(replyTarget(for: $0))" },
            "pending_requests": daemonBook.pendingRequests.map { request -> [String: Any] in
                ["thread": request.thread.uuidString.lowercased(), "turn": request.turn?.uuidString.lowercased() ?? "",
                 "item_id": request.itemID, "request_id": "\(request.requestID)",
                 "questions": request.questions.map { ["id": $0.id, "options": $0.options ?? [], "takes_text": $0.takesText, "is_secret": $0.isSecret] },
                 "route": queue.items.compactMap(\.question).first { $0.session == request.thread && $0.callID == request.itemID }
                    .map { "\(route(for: $0))" } ?? "no rollout question in the queue"]
            }
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: path))
        }
        app.terminate(nil)
    }

    /// `--restart-report <path>`: after the first scan, record what a restart produced, then quit.
    /// Used by the restart lab; it reads nothing beyond the queue this process already holds.
    private func writeRestartReportAndQuitIfRequested(unverified: [AttentionRequest]) {
        guard let path = Companion.argumentValue(for: "--restart-report") else { return }
        let report: [String: Any] = [
            "snapshot": Companion.snapshotURL.path,
            "working_count": workingCount,
            "to_check_count": toCheckCount,
            "items": queue.items.map { item -> [String: Any] in
                var row: [String: Any] = ["kind": "\(item.kind)", "session": item.session.uuidString]
                if let completion = item.completion { row["turn"] = completion.turn.uuidString; row["uncertain"] = completion.uncertain
                                                     row["source"] = completion.source.rawValue }
                if let request = item.request { row["request"] = request.id.uuidString; row["state"] = "\(request.state)" }
                if let question = item.question { row["call_id"] = question.callID; row["turn"] = question.turn.uuidString
                                                  row["source"] = question.source.rawValue
                                                  if let progress = answerProgress[question.id] { row["answer_phase"] = "\(progress.phase)" }
                                                  row["answer_path"] = "\(route(for: question))" }
                return row
            },
            "released_unverified_requests": unverified.map { $0.id.uuidString },
            "completion_presentation": ["pending": completionPresentation.pending, "presented": completionPresentation.presented,
                                        "expanded": completionPresentation.expanded],
            "acknowledged_count": queue.acknowledgedCompletions.count
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: path))
        }
        app.terminate(nil)
    }

    func refresh() {
        scanReminders()
        queue.expire(at: Date().timeIntervalSince1970)
        pruneAnswerProgress()
        pruneReplyProgress()
        if previewMode == nil {
            // A waiting question on a thread Steer has not subscribed to yet: ask for the list now.
            if daemonClient.isConnected,
               queue.items.contains(where: { item in
                   item.question.map { !daemonClient.subscribed.contains($0.session.uuidString.lowercased()) } ?? false
               }) {
                daemonClient.pollThreadsSoon()
            }
            daemonClient.tick(now: ProcessInfo.processInfo.systemUptime)
            if daemonStatus != daemonClient.statusText { daemonStatus = daemonClient.statusText }
            writeDaemonReportAndQuitIfRequested()
        }
        checkApprovalFocus()
        checkGhosttyFocus()
        // App identity only: no window contents, task titles, or accessibility queries.
        // App activation affects notification delivery, never the notch's visibility.
        let codexForeground = previewMode == nil ? desktopAdapter.codexForeground() : false
        desktopForeground = codexForeground == true
        // Desktop decision transport is unproven: release every desktop request at once.
        if previewMode == nil {
            queue.items.compactMap(\.request)
                .filter { $0.state == .actionable && ApprovalHandoff.releasesOnReceipt(source: $0.source) }
                .forEach(handBackApproval)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let pointerInside = pointerInsidePanel
        if !pointerInside { hoverSuppressed = false }
        hoverHeld = hoverHold.update(pointerInside: pointerInside && !hoverSuppressed, now: now)
        let interacting = NotchInteraction.isActive(pointerInside: hoverHeld, keyboardFocus: panel.hasDeliberateKeyboardFocus)
        var next = attention
        let firstPresentation = next.update(codexForeground: codexForeground, hovering: interacting,
                                            now: ProcessInfo.processInfo.systemUptime)
        if next.pending != attention.pending || next.presented != attention.presented || next.expanded != attention.expanded {
            attention = next
        }
        if firstPresentation && !muted { NSSound(named: "Glass")?.play() }
        // Use the same visibility as the count and rows, including CLI reminders.
        let agentItems = orderedAgentAttentionItems
        let liveAgentIDs = Set(agentItems.map(\.id))
        freshAgentRequestIDs.formIntersection(liveAgentIDs)
        freshAgentCompletionIDs.formIntersection(liveAgentIDs)
        freshAgentQuestionIDs.formIntersection(liveAgentIDs)
        let freshRequests = agentItems.filter { freshAgentRequestIDs.contains($0.id)
            && ($0.kind == .actionableApproval || $0.kind == .handedBackApproval) }
        var firstReminderPresentation = reminderPresentation.update(codexForeground: !agentItems.contains {
            $0.kind == .actionableApproval || $0.kind == .handedBackApproval
        }, hovering: interacting,
                                                                    now: ProcessInfo.processInfo.systemUptime)
        let ghosttyFocus: CompletionFocus
        switch ghosttyFocusState {
        case .disabled: ghosttyFocus = .disabled
        case .checking: ghosttyFocus = .checking
        case .known(let snapshot): ghosttyFocus = snapshot.selected == nil ? .unknown : .away
        case .unknown: ghosttyFocus = .unknown
        }
        func completionIsEligible(_ item: AgentAttentionItem) -> Bool {
            guard let outcome = item.outcome, !outcome.uncertain else { return false }
            guard outcome.session.source == .claude else {
                guard let session = UUID(uuidString: outcome.session.session) else { return false }
                let source: AttentionSource = outcome.session.surface == .cli ? .cli : .desktop
                guard CompletionVisibility.allows(source: source, codexForeground: codexForeground,
                                                 ghosttyFocus: ghosttyFocus) else { return false }
                guard source == .cli, ghosttyEnabled else { return true }
                guard case .known(let snapshot) = ghosttyFocusState,
                      let target = GhosttyMatch.target(session: session, live: liveCLI, snapshot: snapshot)
                else { return false }
                return snapshot.selected != target
            }
            return true
        }
        let freshCompletions = agentItems.filter { freshAgentCompletionIDs.contains($0.id) }
        let eligibleFreshCompletions = freshCompletions.filter(completionIsEligible)
        let canPresentCompletion = agentItems.contains(where: completionIsEligible)
        func questionIsEligible(_ item: AgentAttentionItem) -> Bool {
            guard item.question != nil else { return false }
            return item.session.source == .claude || codexForeground != true
        }
        let freshQuestions = agentItems.filter { freshAgentQuestionIDs.contains($0.id) }
        let eligibleFreshQuestions = freshQuestions.filter(questionIsEligible)
        let canPresentQuestion = agentItems.contains(where: questionIsEligible)
        let agentSpotlightAvailable = !notchPresentation.agentSpotlightIsActive(interacting: interacting, now: now)
        var freshAgentSpotlightCandidates = Set<AgentAttentionID>()
        if agentSpotlightAvailable {
            freshAgentSpotlightCandidates.formUnion(freshRequests.map(\.id))
            freshAgentSpotlightCandidates.formUnion(eligibleFreshCompletions.map(\.id))
            freshAgentSpotlightCandidates.formUnion(eligibleFreshQuestions.map(\.id))
        }
        let selectedFreshAgent = AgentPresentationSelection.highestPriority(in: agentItems,
                                                                              candidates: freshAgentSpotlightCandidates)

        var nextCompletionPresentation = completionPresentation
        let selectedCompletion = selectedFreshAgent.flatMap { id in
            eligibleFreshCompletions.first { $0.id == id }
        }
        let completionForegroundGate: Bool? = if let selectedCompletion {
            AgentPresentationEligibility.foregroundGate(source: selectedCompletion.session.source,
                                                        codexForeground: codexForeground)
        } else if !freshCompletions.isEmpty {
            // A higher priority card owns this tick, or Codex's focus/target gate is still closed.
            true
        } else {
            canPresentCompletion ? codexForeground : true
        }
        var firstCompletionPresentation = nextCompletionPresentation.update(
            codexForeground: completionForegroundGate,
            hovering: interacting,
            now: ProcessInfo.processInfo.systemUptime
        )
        completionPresentation = nextCompletionPresentation

        // A question pops under the same away-from-Codex rule as a completion; Ghostty focus is
        // not consulted because the question stays pending until Codex records the answer.
        let selectedQuestion = selectedFreshAgent.flatMap { id in
            eligibleFreshQuestions.first { $0.id == id }
        }
        let questionForegroundGate: Bool? = if let selectedQuestion {
            AgentPresentationEligibility.foregroundGate(source: selectedQuestion.session.source,
                                                        codexForeground: codexForeground)
        } else if !freshQuestions.isEmpty {
            true
        } else {
            canPresentQuestion ? codexForeground : true
        }
        var firstQuestionPresentation = questionPresentation.update(
            codexForeground: questionForegroundGate,
            hovering: interacting, now: ProcessInfo.processInfo.systemUptime)
        let selectedReminder = selectedFreshAgent.flatMap { id in freshRequests.first { $0.id == id } }
        if selectedReminder != nil, reminderPresentation.presented, !firstReminderPresentation {
            reminderPresentation.enqueue()
            firstReminderPresentation = reminderPresentation.update(
                codexForeground: false, hovering: interacting, now: ProcessInfo.processInfo.systemUptime)
        }
        if firstReminderPresentation, let id = selectedReminder?.id {
            freshAgentRequestIDs.remove(id)
        }
        if selectedCompletion != nil, completionPresentation.presented, !firstCompletionPresentation {
            nextCompletionPresentation = completionPresentation
            nextCompletionPresentation.enqueue()
            firstCompletionPresentation = nextCompletionPresentation.update(
                codexForeground: completionForegroundGate, hovering: interacting,
                now: ProcessInfo.processInfo.systemUptime)
            completionPresentation = nextCompletionPresentation
        }
        if firstCompletionPresentation, let id = selectedCompletion?.id {
            freshAgentCompletionIDs.remove(id)
        }
        if selectedQuestion != nil, questionPresentation.presented, !firstQuestionPresentation {
            questionPresentation.enqueue()
            firstQuestionPresentation = questionPresentation.update(
                codexForeground: questionForegroundGate, hovering: interacting,
                now: ProcessInfo.processInfo.systemUptime)
        }
        if firstQuestionPresentation, let id = selectedQuestion?.id {
            freshAgentQuestionIDs.remove(id)
        }
        let selectedPresentationWasFresh = (selectedReminder != nil && firstReminderPresentation)
            || (selectedCompletion != nil && firstCompletionPresentation)
            || (selectedQuestion != nil && firstQuestionPresentation)
        if selectedPresentationWasFresh, let id = selectedFreshAgent {
            notchPresentation.present(id, now: now)
        }
        if let mode = previewMode, mode == "spotlight", let id = previewSpotlightAgent { notchPresentation.present(id, now: now) }
        let resolvedPresentation = notchPresentation.update(interacting: interacting, now: now, legacyPopup: attention.expanded)
        let spotlightItem: AgentAttentionID? = if case let .agentSpotlight(id) = resolvedPresentation { id } else { nil }
        switch previewMode {
        case "expanded": presentationMode = .queue
        case "collapsed": presentationMode = .collapsed
        case "spotlight": presentationMode = spotlightItem.map(NotchPresentationMode.agentSpotlight) ?? .collapsed
        default:
            presentationMode = resolvedPresentation
        }
        expanded = presentationMode.expanded
        // Sound follows the card opening: the frame below is set in the same pass, so the chime
        // lands as the card lands. Muted, restored, and foreground cases never reach here.
        let selectedAgentSound = (selectedCompletion != nil && firstCompletionPresentation)
            || (selectedQuestion != nil && firstQuestionPresentation)
        if CompletionSound.shouldPlay(firstPresentation: selectedAgentSound, muted: muted) {
            NSSound(named: "Glass")?.play()
        }
        guard DesktopVisibility.isVisible(hasActivity: count > 0, codexForeground: codexForeground) else {
            panel.orderOut(nil)
            hovering = false
            targetFrame = .zero
            contentHeight = 0
            currentDisplayID = nil
            return
        }
        // One panel, one queue: the display is chosen by the documented rule and frozen while the
        // user is interacting, so controls never move away mid-action. Only geometry changes here.
        guard let display = NotchDisplaySelection.choose(displays: Companion.attachedDisplays(), pointer: NSEvent.mouseLocation,
                                                         current: currentDisplayID, interacting: interacting && panel.isVisible)
        else { panel.orderOut(nil); currentDisplayID = nil; return }
        currentDisplayID = display.id
        let layout = NotchPlacement.strip(on: display, expanded: expanded, fiveHourShown: fiveHourShown)
        if stripLayout != layout { stripLayout = layout }
        let rows = presentationMode.showsAll ? orderedAgentAttentionItems.count : (spotlightItem == nil ? 0 : 1)
        var frame = contentHeight > 0
            ? NotchPlacement.frame(on: display, expanded: expanded, contentHeight: contentHeight, fiveHourShown: fiveHourShown)
            : NotchPlacement.frame(on: display, expanded: expanded, rows: rows,
                                   extraRows: attention.pending && (presentationMode.showsAll || spotlightItem == nil), fiveHourShown: fiveHourShown)
        // With no menu bar and no housing the strip rests above the screen edge and slides in for
        // the pointer at the top edge or an open panel, so it does not cover a full-screen app.
        if NotchTuck.isTucked(display: display, pointer: NSEvent.mouseLocation, interacting: interacting, open: expanded) {
            frame = NotchTuck.tuckedFrame(frame)
        }
        if targetFrame != frame {
            let opening = frame.height > panel.frame.height
            targetFrame = frame
            if reduceMotion || !panel.isVisible {
                panel.setFrame(frame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = opening ? 0.16 : 0.2
                    context.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                }
            }
        }
        // Never makes the panel key: an automatic notification does not take input from the user's app.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// React to pointer entry without waiting for the background polling interval. Pointer exit
    /// keeps the core hover grace, then refreshes exactly when that grace expires.
    func setHovering(_ hovering: Bool) {
        self.hovering = hovering
        hoverExitTask?.cancel()
        hoverExitTask = nil
        refresh()
        guard !hovering else { return }
        hoverExitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(HoverHold.grace))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Collapses the panel and hands keyboard input back to the app the user was using.
    func collapse() {
        attention.collapse()
        reminderPresentation.collapse()
        completionPresentation.collapse()
        questionPresentation.collapse()
        notchPresentation.collapse()
        hoverSuppressed = true
        hoverHold = HoverHold()
        if panel.isKeyWindow {
            panel.orderOut(nil)
            NSWorkspace.shared.frontmostApplication?.activate()
        }
        refresh()
    }

    @objc func sendTest() {
        attention.enqueue()
        UserDefaults.standard.set(true, forKey: "testCompletion")
        refresh()
    }
    @objc func dismissTest() {
        attention.dismiss()
        UserDefaults.standard.set(false, forKey: "testCompletion")
        refresh()
    }
    @objc func toggleMute(_ sender: NSMenuItem) {
        muted.toggle()
        UserDefaults.standard.set(muted, forKey: "muted")
        sender.state = muted ? .on : .off
    }
    func setSoundEnabled(_ enabled: Bool) {
        muted = !enabled
        UserDefaults.standard.set(muted, forKey: "muted")
        status.menu?.items.first { $0.action == #selector(toggleMute) }?.state = muted ? .on : .off
    }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    func openTestTask() {
        guard !openingTask else { return }
        openingTask = true
        navigationMessage = "Opening link…"
        let id = taskID
        Task { @MainActor in
            let result = await desktopAdapter.open(taskID: id)
            navigationMessage = result.rawValue
            openingTask = false
            // Navigation never calls dismissTest or writes the saved completion flag.
        }
    }
    /// Acknowledges desktop completions the Codex desktop app itself no longer flags as unread.
    /// Only ever removes items; a missing or unparsable file changes nothing and says so.
    private func applyDesktopReadState(_ snapshot: DesktopReadStateSnapshot?, enabled: Bool) {
        guard enabled else { desktopReadStateMessage = "Desktop read state: off. Desktop completions clear only by dismissal."; return }
        guard let snapshot else {
            desktopReadStateMessage = "Desktop read state: unavailable (\(Companion.desktopReadStateURL.lastPathComponent) missing or in an unexpected format). Desktop completions clear only by dismissal."
            return
        }
        let queued = queue.items.compactMap(\.completion)
        let acknowledged = DesktopReadAcknowledgment.acknowledged(queued, snapshot: snapshot)
        for id in acknowledged { queue.dismiss(.completion(id)) }
        let written = Date(timeIntervalSince1970: snapshot.modifiedAt).formatted(date: .omitted, time: .standard)
        let tested = CodexSetupRequirements.minimumDesktopVersion
        let version = setupCapabilities.desktopVersion ?? "unknown"
        desktopReadStateMessage = "Desktop read state: file written \(written), \(snapshot.unread.count) unread threads"
            + (acknowledged.isEmpty ? "." : ", cleared \(acknowledged.count) completion\(acknowledged.count == 1 ? "" : "s") this scan.")
            + (version == tested ? "" : " Format tested with desktop \(tested); installed \(version).")
    }

    /// Persists unacknowledged completions and acknowledgments atomically whenever they change.
    func saveCompletions() {
        guard previewMode == nil else { return }
        let snapshot = agentQueue.snapshot
        guard snapshot != savedSnapshot else { return }
        if AttentionSnapshotStore.save(snapshot, to: Companion.snapshotURL) { savedSnapshot = snapshot }
    }

    private func codexSession(_ identity: AgentSessionIdentity) -> UUID? {
        guard identity.source == .codex else { return nil }
        return UUID(uuidString: identity.session)
    }

    private func codexTurn(_ identity: AgentTurnIdentity) -> AttentionCompletion? {
        guard let session = codexSession(identity.session), let turn = UUID(uuidString: identity.turn) else { return nil }
        return queue.items.compactMap(\.completion).first { $0.session == session && $0.turn == turn }
    }

    func openAgent(_ identity: AgentSessionIdentity) {
        if identity.source == .claude {
            openClaude(identity)
        } else if let session = codexSession(identity) {
            if identity.surface == .cli { openCLI(session) } else { openDesktop(session) }
        } else {
            navigationMessage = "Open in Codex is unavailable until Steer can verify the exact session."
            refresh()
        }
    }

    func canOpenClaude(_ identity: AgentSessionIdentity) -> Bool {
        guard identity.source == .claude, identity.surface == .cli, ghosttyEnabled,
              ghosttyPermissionVerified, !liveClaudeSessions.isEmpty,
              let configuredScopes = configuredClaudeNavigationScopes(),
              Set(liveClaudeSessions.keys) == configuredScopes,
              Set(claudeInventoryAvailable.keys) == configuredScopes,
              claudeInventoryAvailable.values.allSatisfy({ $0 }),
              liveClaudeSessions[identity.sourceScope]?.filter({ $0 == identity.session }).count == 1,
              let snapshot = knownGhosttySnapshot else { return false }
        let live = liveClaudeSessions.values.flatMap { $0 }
        guard let target = GhosttyMatch.target(claudeSessionID: identity.session, live: live, snapshot: snapshot) else { return false }
        return GhosttyMatch.isInCurrentWindow(target, snapshot: snapshot)
    }

    func isBackgroundClaudeSession(_ identity: AgentSessionIdentity) -> Bool {
        identity.source == .claude && claudeInventories[identity.sourceScope]?.isBackgroundSession(identity.session) == true
    }

    /// Navigation includes every supported root that has a configured or otherwise inspectable
    /// setup state. An awaiting-restart root is part of the global uniqueness gate even though it
    /// has not delivered a fresh hook event in this launch. A supported root with an unavailable
    /// setup status stays in the gate and makes navigation unavailable until its inventory is complete.
    private func configuredClaudeNavigationRoots() -> [ClaudeNavigationRoot] {
        claude.roots.compactMap { root in
            guard root.capabilities.supported else { return nil }
            switch root.status {
            case .notConfigured:
                return nil
            default:
                return ClaudeNavigationRoot(root: root.url.standardizedFileURL, capabilities: root.capabilities)
            }
        }
    }

    private func configuredClaudeNavigationScopes() -> Set<String>? {
        let roots = configuredClaudeNavigationRoots()
        guard !roots.isEmpty else { return nil }
        return Set(roots.map { $0.root.path })
    }

    private var knownGhosttySnapshot: GhosttySnapshot? {
        guard case let .known(snapshot) = ghosttyFocusState, snapshot.status == "ok" else { return nil }
        return snapshot
    }

    var claudeReturnUnavailableMessage: String {
        if !ghosttyEnabled { return "Enable Ghostty controls to open the exact Claude tab." }
        if !ghosttyPermissionVerified { return "Ghostty controls are awaiting Automation permission." }
        return "The exact Claude tab is unavailable until Steer can verify one live, unsplit target."
    }

    private func openClaude(_ identity: AgentSessionIdentity, approval: AgentApproval? = nil) {
        guard !openingTask else { return }
        guard ghosttyEnabled else { showControls(); return }
        guard identity.surface == .cli else {
            navigationMessage = "The exact Claude tab is unavailable for this session surface."
            refresh()
            return
        }
        openingTask = true
        navigationMessage = "Finding the matching Claude tab…"
        let configuredRoots = configuredClaudeNavigationRoots()
        let queued = orderedAgentAttentionItems.filter { $0.session == identity && $0.outcome != nil }.map(\.id)
        Task { @MainActor in
            let inventories = await Task.detached {
                configuredRoots.map { root in
                    ClaudeSetupDetection.activeSessionInventory(root: root.root, capabilities: root.capabilities)
                }
            }.value
            let freshScopes = Set(inventories.map(\.sourceScope))
            let currentScopes = Set(configuredClaudeNavigationRoots().map { $0.root.path })
            let complete = !inventories.isEmpty && freshScopes == currentScopes && inventories.allSatisfy(\.available)
            let live = inventories.flatMap { scan in
                scan.sessions.filter { $0.kind == .interactive }.map(\.sessionID)
            }
            let ownLive = inventories.first { $0.sourceScope == identity.sourceScope }
            let result: (opened: Bool, message: String)
            if !complete || ownLive?.sessions.filter({ $0.kind == .interactive && $0.sessionID == identity.session }).count != 1
                || live.filter({ $0 == identity.session }).count != 1 {
                result = (false, claudeReturnUnavailableMessage)
            } else {
                result = await Task.detached {
                    GhosttyNavigation.openClaude(sessionID: identity.session, live: live)
                }.value
            }
            navigationMessage = result.message
            if result.opened {
                if let approval,
                   let current = orderedAgentAttentionItems.compactMap(\.approval).first(where: { $0.id == approval.id }) {
                    handBackClaudeApproval(current)
                }
                for id in queued { agentQueue.dismiss(id) }
                saveCompletions()
            }
            openingTask = false
            refresh()
        }
    }

    func openAgentApproval(_ approval: AgentApproval) {
        if approval.identity.session.source == .claude {
            openClaude(approval.identity.session, approval: approval)
            return
        }
        guard approval.identity.session.source == .codex,
              let session = codexSession(approval.identity.session),
              let requestID = UUID(uuidString: approval.identity.call),
              let request = queue.items.compactMap(\.request).first(where: { $0.id == requestID }) else {
            navigationMessage = "Open in Claude is unavailable until Steer can verify the exact Claude tab."
            refresh()
            return
        }
        openApprovalInCodex(request)
        _ = session
    }

    func decideAgent(_ approval: AgentApproval, as decision: ApprovalDecision) {
        if approval.identity.session.source == .claude {
            decideClaudeApproval(approval, as: decision)
            return
        }
        guard approval.identity.session.source == .codex,
              approval.identity.session.surface == .cli,
              let requestID = UUID(uuidString: approval.identity.call),
              let request = queue.items.compactMap(\.request).first(where: { $0.id == requestID }) else {
            navigationMessage = approval.identity.session.source == .claude
                ? "Claude decisions are unavailable here; decide in Claude."
                : "Desktop Codex decisions are handled by Codex's native prompt."
            refresh()
            return
        }
        decide(request, as: decision)
    }

    func canDecideAgent(_ approval: AgentApproval) -> Bool {
        guard approval.identity.session.source == .claude,
              approval.identity.session.surface == .cli,
              approval.state == .actionable,
              approval.expiresAt > Date().timeIntervalSince1970,
              let requestID = approval.hookRequestID,
              liveClaudeApprovalIDs.contains(requestID),
              let root = claude.roots.first(where: { $0.url.standardizedFileURL.path == approval.identity.session.sourceScope }),
              case .connected = root.status,
              !root.eventsPath.isEmpty,
              !pendingClaudeApprovalDecisions.contains(requestID),
              let receipt = verifiedClaudeApprovalReceipts[requestID],
              let installationID = root.plan?.installationID,
              verifiedClaudeApprovalRoots[requestID] == claudeApprovalRootKey(
                  sourceScope: approval.identity.session.sourceScope,
                  events: URL(fileURLWithPath: root.eventsPath, isDirectory: true),
                  installationID: installationID),
              receipt.expiresAt > Date().timeIntervalSince1970 else {
            return false
        }
        return true
    }

    private func decideClaudeApproval(_ approval: AgentApproval, as decision: ApprovalDecision) {
        guard decision.isUserDecision else { return }
        guard canDecideAgent(approval),
              let requestID = approval.hookRequestID,
              let root = claude.roots.first(where: { $0.url.standardizedFileURL.path == approval.identity.session.sourceScope }),
              let installationID = root.plan?.installationID,
              !root.eventsPath.isEmpty,
              let receipt = verifiedClaudeApprovalReceipts[requestID],
              pendingClaudeApprovalDecisions.insert(requestID).inserted else {
            navigationMessage = "This Claude permission is no longer actionable; continue in Claude."
            refresh()
            return
        }
        let now = Date().timeIntervalSince1970
        liveClaudeApprovalIDs.remove(requestID)
        // Remove direct controls immediately. The detached worker reports mailbox publication and
        // the helper's output acknowledgment separately; a crash leaves Claude's native prompt
        // available without leaving a second direct control.
        agentQueue.apply(.approval(approval.with(state: .handedBack)), now: now)
        navigationMessage = "Sending the Claude decision; delivery confirmation is pending."
        publishClaudeApprovalDecision(ClaudeApprovalDecisionWork(
            requestID: requestID, approvalID: approval.id, decision: decision, decidedAt: now,
            receipt: receipt,
            eventsPath: URL(fileURLWithPath: root.eventsPath, isDirectory: true).standardizedFileURL.path,
            root: claudeApprovalRootKey(sourceScope: approval.identity.session.sourceScope,
                                        events: URL(fileURLWithPath: root.eventsPath, isDirectory: true),
                                        installationID: installationID),
            scanGeneration: claudeApprovalScanGeneration))
        refresh()
    }

    private func handBackClaudeApproval(_ approval: AgentApproval) {
        guard approval.state == .actionable,
              let requestID = approval.hookRequestID,
              let root = claude.roots.first(where: { $0.url.standardizedFileURL.path == approval.identity.session.sourceScope }),
              !root.eventsPath.isEmpty else { return }
        let events = URL(fileURLWithPath: root.eventsPath, isDirectory: true)
        liveClaudeApprovalIDs.remove(requestID)
        verifiedClaudeApprovalReceipts.removeValue(forKey: requestID)
        verifiedClaudeApprovalRoots.removeValue(forKey: requestID)
        agentQueue.apply(.approval(approval.with(state: .handedBack)), now: Date().timeIntervalSince1970)
        let decidedAt = Date().timeIntervalSince1970
        Task.detached(priority: .utility) {
            _ = ClaudeApprovalStore.publish(ClaudeApprovalDecision(requestID: requestID, decision: .noDecision,
                                                                   decidedAt: decidedAt), in: events)
        }
    }

    func chooseAgentOption(_ question: AgentQuestion, index: Int, option: Int) {
        if question.identity.session.source == .claude {
            guard index == 0, let prompt = question.prompts.first, option >= 0, option < prompt.options.count else {
                navigationMessage = "Claude question shape is unavailable; answer it in Claude."
                refresh()
                return
            }
            answerClaudeQuestion(question, kind: .option, answer: prompt.options[option])
            return
        }
        guard question.identity.session.source == .codex,
              let session = codexSession(question.identity.session),
              let turn = UUID(uuidString: question.turn),
              let current = queue.items.compactMap(\.question).first(where: { $0.session == session && $0.turn == turn && $0.callID == question.identity.call }) else {
            navigationMessage = "Claude questions are answered in Claude."
            refresh()
            return
        }
        chooseOption(current, question: index, option: option)
    }

    func codexQuestion(for question: AgentQuestion) -> AttentionQuestion? {
        guard question.identity.session.source == .codex,
              let session = codexSession(question.identity.session),
              let turn = UUID(uuidString: question.turn) else { return nil }
        return queue.items.compactMap(\.question).first {
            $0.session == session && $0.turn == turn && $0.callID == question.identity.call
        }
    }

    func canAnswerAgentQuestion(_ question: AgentQuestion) -> Bool {
        if question.identity.session.source == .claude {
            return liveClaudeQuestion(for: question) != nil && question.prompts.count == 1
                && question.prompts.first?.question != nil
        }
        guard let current = codexQuestion(for: question) else { return false }
        return showsOptionControls(for: current)
    }

    private func liveClaudeQuestion(for question: AgentQuestion) -> LiveClaudeQuestion? {
        let now = Date().timeIntervalSince1970
        guard question.identity.session.source == .claude,
              let requestID = question.helperRequestID,
              availableClaudeQuestionTokens.contains(requestID),
              let live = liveClaudeQuestions[requestID],
              live.sourceScope == question.identity.session.sourceScope,
              live.request.sourceScope == live.sourceScope,
              live.request.eventDirectory == live.events.standardizedFileURL.path,
              live.request.sessionID == question.identity.session.session,
              live.request.promptID == question.identity.turn,
              live.request.toolUseID == question.identity.call,
              live.request.expiresAt > now,
              live.request.prompts == question.prompts,
              let liveness = ClaudeQuestionStore.liveness(for: requestID, in: live.events),
              claudeQuestionLivenessIsCurrent(liveness, request: live.request, now: now) else { return nil }
        return live
    }

    func answerClaudeQuestion(_ question: AgentQuestion, kind: ClaudeQuestionAnswerKind, answer: String) {
        guard let live = liveClaudeQuestion(for: question) else {
            navigationMessage = "Claude's question answer control is unavailable; check Claude's native question."
            refresh()
            return
        }
        let record = ClaudeQuestionAnswer(requestID: live.request.requestID,
                                          installationID: live.request.installationID,
                                          sourceScope: live.request.sourceScope,
                                          eventDirectory: live.request.eventDirectory,
                                          sessionID: live.request.sessionID,
                                          promptID: live.request.promptID,
                                          toolUseID: live.request.toolUseID,
                                          kind: kind, answer: answer,
                                          decidedAt: Date().timeIntervalSince1970)
        guard ClaudeQuestionAnswerPolicy.accepts(request: live.request, answer: record) else {
            navigationMessage = "That answer is not valid for Claude's current question."
            refresh()
            return
        }
        let now = Date().timeIntervalSince1970
        guard let liveness = ClaudeQuestionStore.liveness(for: live.request.requestID, in: live.events),
              claudeQuestionLivenessIsCurrent(liveness, request: live.request, now: now) else {
            navigationMessage = "Claude answer delivery is unavailable; check Claude's question."
            refresh()
            return
        }
        // Spend the memory-only capability before writing. A failed write is never retried.
        availableClaudeQuestionTokens.remove(live.request.requestID)
        spentClaudeQuestionTokens.insert(live.request.requestID)
        guard ClaudeQuestionStore.publish(record, in: live.events) else {
            navigationMessage = "Claude answer delivery could not be confirmed; check Claude's question."
            refresh()
            return
        }
        let request = live.request
        let events = live.events
        Task { @MainActor [weak self] in
            let delivered = await Task.detached(priority: .utility) {
                claudeQuestionAwaitDeliveryAndCleanUp(request, answer: record, in: events)
            }.value
            guard let self else { return }
            self.navigationMessage = delivered
                ? "Answer sent to Claude."
                : "Claude answer delivery could not be confirmed; check Claude's question."
            self.refresh()
        }
    }

    func dismissAgent(_ id: AgentAttentionID) {
        if case let .outcome(identity) = id, let completion = codexTurn(identity) {
            queue.dismiss(.completion(completion.id))
        } else if case let .approval(identity) = id, let requestID = UUID(uuidString: identity.call),
                  let request = queue.items.compactMap(\.request).first(where: { $0.id == requestID }) {
            queue.dismiss(.request(request.identity))
        } else if case let .question(identity) = id, let session = codexSession(identity.session),
                  let turn = UUID(uuidString: identity.turn),
                  let question = queue.items.compactMap(\.question).first(where: { $0.session == session && $0.turn == turn && $0.callID == identity.call }) {
            queue.dismiss(.question(question.id))
        }
        agentQueue.dismiss(id)
        syncAgentQueueWithCodex(now: Date().timeIntervalSince1970)
        saveCompletions()
        refresh()
    }
    func dismissAttention(_ item: AttentionCompletion) {
        switch item.source {
        case .desktop:
            queue.dismiss(.completion(item.id)); saveCompletions(); refresh()
        case .cli:
            queue.dismiss(.completion(item.id)); saveCompletions(); refresh()
        }
    }
    /// Dismissal is in memory only: a question still pending in the rollout returns after a restart.
    func dismissQuestion(_ question: AttentionQuestion) {
        queue.dismiss(.question(question.id)); refresh()
    }

    /// Progress for a question the queue holds; a fresh, ready record when Steer has relayed nothing.
    func progress(for question: AttentionQuestion) -> QuestionAnswerProgress {
        let progress = answerProgress[question.id] ?? QuestionAnswerProgress(call: question.id)
        // A desktop pick made before the daemon delivered the request opened Codex and nothing more;
        // the daemon card starts from its first question.
        if case .daemon = route(for: question) { return progress.reopeningForDaemon() }
        return progress
    }

    /// Which path this question's card uses right now: the daemon when it holds the request,
    /// otherwise the Ghostty relay (CLI) or the desktop pick, exactly as before the daemon.
    func route(for question: AttentionQuestion) -> QuestionAnswerRoute {
        QuestionAnswerRouting.route(for: question, book: daemonBook, daemonConnected: daemonConnected)
    }

    /// Whether the card may show the options as controls: the daemon path, a CLI question with
    /// Ghostty controls on, or a desktop question (whose pick only opens Codex). Preview renders the
    /// controls as well.
    func showsOptionControls(for question: AttentionQuestion) -> Bool {
        switch route(for: question) {
        case .daemon: return true
        case .daemonAnswered: return false
        case .desktopPick: return true
        case .ghosttyRelay: return ghosttyEnabled || previewMode != nil
        }
    }

    /// One click on an option. Daemon: the exact answer by call id. Desktop: remember the pick and
    /// open the thread. CLI: relay the digit through Ghostty after re-checking the queue, the policy,
    /// and the rollout as it is right now.
    func chooseOption(_ question: AttentionQuestion, question index: Int, option: Int) {
        switch route(for: question) {
        case .daemon:
            answerThroughDaemon(question, question: index, answer: .option(option))
            return
        case .daemonAnswered:
            navigationMessage = AppServerAnswerPolicy.message(for: .alreadyAnswered); refresh()
            return
        case .desktopPick, .ghosttyRelay:
            break
        }
        if question.source == .desktop {
            guard case .options = QuestionAnswerProgress.offer(question, at: index) else { return }
            answerProgress[question.id] = progress(for: question).pickingInCodex(question: index, option: option)
            openAttentionSession(source: .desktop, session: question.session)
            return
        }
        guard !answering else { return }
        // Re-read the queue's current copy: a question answered since the row rendered must not be relayed.
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        let progress = progress(for: question)
        if let rejection = QuestionAnswerPolicy.rejection(for: current, ghosttyEnabled: ghosttyEnabled, progress: progress,
                                                          question: index, option: option) {
            navigationMessage = QuestionAnswerPolicy.message(for: rejection); refresh(); return
        }
        guard let current, previewMode == nil else { return }
        answering = true
        answerProgress[question.id] = progress.startingSend(question: index, option: option)
        let key = QuestionAnswerPolicy.key(forOption: option)
        let live = liveCLI
        let rolloutRoot = Companion.rolloutRoot
        navigationMessage = "Sending \(key)…"
        refresh()
        Task { @MainActor in
            let result = await Task.detached { () -> (sent: Bool, message: String) in
                // The rollout as of this instant: an answer Codex already recorded, or an ended turn,
                // means the pane is gone and the key would land in the composer instead.
                let evidence = ReminderReader.currentEvidence(for: current.session, in: rolloutRoot)
                guard QuestionAnswerGuard.stillPending(current, in: evidence) else {
                    return (false, "Codex already has an answer or the turn ended; nothing was sent.")
                }
                return GhosttyNavigation.answer(session: current.session, live: live, keys: [key])
            }.value
            answering = false
            navigationMessage = result.message
            guard queue.items.contains(where: { $0.id == .question(question.id) }) else {
                // Answered or ended while the key was in flight: the card is gone and so is the progress.
                answerProgress[question.id] = nil
                refresh()
                return
            }
            if let progress = answerProgress[question.id] {
                answerProgress[question.id] = result.sent
                    ? progress.recordingSent(question: index, option: option, of: current, at: Date().timeIntervalSince1970)
                    : progress.recordingFailure(result.message)
            }
            refresh()
        }
    }

    /// A typed answer; only the daemon path takes one.
    func answerText(_ question: AttentionQuestion, question index: Int, text: String) {
        guard case .daemon = route(for: question) else {
            navigationMessage = "Typed answers need Codex's daemon; answer this one in Codex."; refresh()
            return
        }
        answerThroughDaemon(question, question: index, answer: .text(text))
    }

    /// One answer through the daemon. A non-last question's answer is only drafted; the last one
    /// sends the whole call as one JSON-RPC response, after re-reading the rollout, and marks the
    /// request answered before the write so nothing is ever sent twice. Never on a timer or error.
    private func answerThroughDaemon(_ question: AttentionQuestion, question index: Int, answer: ChosenAnswer) {
        guard !answering else { return }
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        if let rejection = AppServerAnswerPolicy.rejection(for: current, book: daemonBook, progress: progress(for: question),
                                                           question: index, answer: answer) {
            navigationMessage = AppServerAnswerPolicy.message(for: rejection); refresh(); return
        }
        guard let current, previewMode == nil, let request = daemonBook.request(for: current) else { return }
        let isLast = index + 1 >= request.questions.count
        answering = true
        navigationMessage = ""
        let rolloutRoot = Companion.rolloutRoot
        Task { @MainActor in
            // The rollout as of this instant, only when the answer would leave Steer: an answer Codex
            // already recorded, or an ended turn, means the daemon request is stale.
            let pending = isLast ? await Task.detached {
                QuestionAnswerGuard.stillPending(current, in: ReminderReader.currentEvidence(for: current.session, in: rolloutRoot))
            }.value : true
            let now = Date().timeIntervalSince1970
            let latest = queue.items.compactMap(\.question).first { $0.id == question.id }
            let plan = AppServerAnswering.prepare(current: latest, book: daemonBook, progress: progress(for: question),
                                                  question: index, answer: answer, stillPending: { pending }, now: now)
            daemonBook = plan.book
            switch plan.outcome {
            case let .refused(rejection):
                navigationMessage = AppServerAnswerPolicy.message(for: rejection)
            case let .drafted(next):
                answerProgress[question.id] = next
            case let .sending(next):
                answerProgress[question.id] = next
                let written = plan.message.map { daemonClient.send($0) } ?? false
                if let latest {
                    answerProgress[question.id] = written
                        ? next.recordingSent(question: index, answer: answer, of: latest, at: now)
                        : next.recordingFailure("Could not write to Codex's daemon; Steer will not retry. Answer in Codex.")
                }
                navigationMessage = written ? "Answer sent to Codex's daemon." : "Could not write to Codex's daemon."
            }
            answering = false
            refresh()
        }
    }

    /// What Steer can see right now about reaching a finished session: the daemon's own loaded
    /// threads, the sessions Codex recorded as ended, and the sessions already working again.
    var replyAvailability: SessionReplyAvailability {
        // Sessions in a turn, not sessions shown as working: one blocked on a question is mid-turn
        // too, and its running row is only withheld from the display.
        let working = queue.sessionsInTurn
        guard previewMode == nil else {
            // The preview has no daemon; it renders the field as a reachable session would.
            return SessionReplyAvailability(daemonConnected: true,
                                            daemonThreads: Set(queue.items.compactMap { $0.completion?.session }),
                                            endedSessions: endedSessions, workingSessions: working)
        }
        return SessionReplyAvailability(daemonConnected: daemonClient.isConnected, daemonThreads: daemonClient.loadedThreads,
                                        endedSessions: endedSessions, workingSessions: working)
    }

    /// Where this completion's reply would go, or why the field is disabled.
    func replyTarget(for completion: AttentionCompletion) -> SessionReplyTarget {
        SessionReplyRouting.target(for: completion, availability: replyAvailability)
    }

    /// This card's reply so far; a fresh, ready record when the user has sent nothing.
    func reply(for completion: AttentionCompletion) -> SessionReplyProgress {
        replyProgress[completion.id] ?? SessionReplyProgress(completion: completion.id)
    }

    /// The view renders this stable projection and does not infer notification state from optional
    /// queue payloads itself.
    func spotlightDetails(for item: AttentionItem) -> SpotlightDetails {
        let context = spotlightContexts[item.id]
        let response = item.completion.flatMap { completionPreviews[$0.id] }
        return SpotlightDetails.make(item: item, context: context, response: response) {
            Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard)
        }
    }

    func spotlightDetails(for item: AgentAttentionItem) -> SpotlightDetails? {
        guard item.session.source == .codex,
              let session = UUID(uuidString: item.session.session) else { return nil }
        let legacy = queue.items.first { candidate in
            guard candidate.session == session else { return false }
            switch (candidate.id, item.id) {
            case let (.request(request), .approval(approval)): return request.request.uuidString.lowercased() == approval.call.lowercased()
            case let (.question(question), .question(agent)): return question.callID == agent.call
            case let (.completion(completion), .outcome(outcome)): return completion.turn.uuidString.lowercased() == outcome.turn.lowercased()
            case let (.running(running), .running(agent)): return running.turn.uuidString.lowercased() == agent.turn.lowercased()
            default: return false
            }
        }
        return legacy.map { spotlightDetails(for: $0) }
    }

    func codexCompletion(for outcome: AgentOutcome) -> AttentionCompletion? { codexTurn(outcome.identity) }

    /// One Send on a completion card. The reply starts a new turn on that exact thread through the
    /// daemon, after re-reading the queue and the target as they are right now. Sending does not
    /// acknowledge the completion, and a card that has sent one reply never sends another.
    func sendReply(to completion: AttentionCompletion, text: String) {
        guard !replying else { return }
        let current = queue.items.compactMap(\.completion).first { $0.id == completion.id }
        let plan = SessionReplySending.prepare(completion: current, availability: replyAvailability,
                                               progress: reply(for: completion), text: text)
        switch plan.outcome {
        case let .refused(rejection):
            navigationMessage = SessionReplyPolicy.message(for: rejection)
            refresh()
        case let .sending(next):
            guard previewMode == nil else {
                navigationMessage = "Preview only; nothing was sent."
                refresh()
                return
            }
            guard let params = plan.params else { return }
            replying = true
            replyProgress[completion.id] = next
            navigationMessage = "Sending your reply to Codex's daemon…"
            refresh()
            daemonClient.call(SessionReplyRequest.method, params: params) { [weak self] accepted, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.replying = false
                    let progress = self.reply(for: completion)
                    self.replyProgress[completion.id] = accepted
                        ? progress.recordingSent(at: Date().timeIntervalSince1970)
                        : progress.recordingFailure(SessionReplyPolicy.daemonRefused(error))
                    self.navigationMessage = accepted ? "Reply sent to Codex's daemon." : "Could not send the reply to Codex's daemon."
                    self.refresh()
                }
            }
        }
    }

    /// Keeps a card's reply only while its completion is queued, and lets a sent one reach its final
    /// state: confirmed by the session working again, or unconfirmed once the window passes.
    private func pruneReplyProgress() {
        guard !replyProgress.isEmpty else { return }
        let queued = Set(queue.items.compactMap { $0.completion?.id })
        let working = queue.sessionsInTurn
        let now = Date().timeIntervalSince1970
        let next = replyProgress.filter { queued.contains($0.key) }
            .mapValues { $0.observing(sessionWorking: working.contains($0.completion.session), at: now) }
        if next != replyProgress { replyProgress = next }
    }

    /// Drops progress for questions no longer waiting and turns an unconfirmed send into its final state.
    private func pruneAnswerProgress() {
        guard !answerProgress.isEmpty else { return }
        let waiting = Set(queue.items.compactMap { $0.question?.id })
        let now = Date().timeIntervalSince1970
        let next = answerProgress.filter { waiting.contains($0.key) }.mapValues { $0.expiring(at: now) }
        if next != answerProgress { answerProgress = next }
    }
    func openCLI(_ session: UUID) {
        guard !openingTask else { return }
        guard ghosttyEnabled else { showControls(); return }
        openingTask = true
        navigationMessage = "Finding the matching Ghostty tab…"
        let live = liveCLI
        let queued = cliItems.filter { $0.session == session }.map(\.id)
        Task { @MainActor in
            let result = await Task.detached { GhosttyNavigation.open(session: session, live: live) }.value
            navigationMessage = result.message
            // A verified visit acknowledges only completions already queued for this session.
            if result.opened {
                for id in queued { queue.dismiss(.completion(id)) }
                saveCompletions()
            }
            openingTask = false
            refresh()
        }
    }
    func reminderActionTitle(_ item: Reminder) -> String {
        cliSessions.contains(item.session_id) && !ghosttyEnabled ? "Set up Ghostty" : "Open in Codex"
    }
    var needsGhosttySetup: Bool {
        !ghosttyEnabled && (!cliItems.isEmpty || visibleReminders.contains { cliSessions.contains($0.session_id) }
                            || queue.items.contains { $0.question?.source == .cli })
    }
    func openReminder(_ item: Reminder) {
        if cliSessions.contains(item.session_id) { openCLI(item.session_id) }
        else { taskID = item.session_id.uuidString; openTestTask() }
    }
    func openAttentionSession(source: AttentionSource, session: UUID) {
        if source == .cli { openCLI(session) }
        else { taskID = session.uuidString; openTestTask() }
    }

    /// Open in Codex releases the pending interaction at once: the user decides in Codex's own prompt.
    func openApprovalInCodex(_ request: AttentionRequest) {
        if let current = queue.items.compactMap(\.request).first(where: { $0.identity == request.identity }) {
            handBackApproval(current)
        }
        openAttentionSession(source: request.source, session: request.session)
    }

    func decide(_ request: AttentionRequest, as decision: ApprovalDecision) {
        // Re-read the queue's current copy: a request handed back since the row rendered must not be answered.
        guard !eventsPath.isEmpty else { navigationMessage = "Codex events are not connected."; refresh(); return }
        guard let current = queue.items.compactMap(\.request).first(where: { $0.identity == request.identity }) else {
            navigationMessage = "This request is no longer in the queue."; refresh(); return
        }
        guard ApprovalDecisionPolicy.accepts(current, decision: decision, now: Date().timeIntervalSince1970) else {
            navigationMessage = "This request was handed back to Codex; answer it there."; refresh(); return
        }
        let record = ApprovalDecisionRecord(requestID: request.id, decision: decision,
                                            decidedAt: Date().timeIntervalSince1970)
        guard ApprovalStore.publish(record, in: URL(fileURLWithPath: eventsPath)) else {
            navigationMessage = "This approval was already answered or is no longer available."
            refresh()
            return
        }
        queue.dismiss(.request(request.identity))
        navigationMessage = decision == .allowOnce ? "Approved once." : "Denied."
        refresh()
    }

    private func handBackApproval(_ request: AttentionRequest) {
        guard request.state == .actionable else { return }
        let now = Date().timeIntervalSince1970
        if !eventsPath.isEmpty {
            let events = URL(fileURLWithPath: eventsPath)
            let released = ApprovalStore.publish(ApprovalDecisionRecord(requestID: request.id, decision: .noDecision, decidedAt: now), in: events)
            if !released && ApprovalDecisions.existing(for: request.id, in: events) == nil {
                // The helper still waits for its own deadline; the row loses its controls regardless.
                navigationMessage = "Steer could not write the handoff record; Codex will show its own prompt within 30 seconds."
            }
        }
        let handedBack = AttentionRequest(id: request.id, source: request.source, session: request.session,
                                          turn: request.turn, arrivedAt: request.arrivedAt, expiresAt: request.expiresAt,
                                          state: .handedBack, details: request.details)
        queue.apply(requests: [handedBack], now: now)
    }

    private func checkApprovalFocus() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !checkingApprovalFocus, now >= nextApprovalFocusScan else { return }
        let requests = queue.items.compactMap(\.request).filter { $0.source == .cli && $0.state == .actionable }
        guard previewMode == nil, !requests.isEmpty else { return }
        nextApprovalFocusScan = now + 2
        guard ghosttyEnabled else {
            requests.filter { ApprovalHandoff.mustHandBack(source: $0.source, paneFocus: .disabled) }.forEach(handBackApproval)
            return
        }
        checkingApprovalFocus = true
        let live = liveCLI
        Task { @MainActor in
            let snapshot = await Task.detached { GhosttyNavigation.snapshot() }.value
            for request in requests {
                let focus: CompletionFocus
                if let snapshot, let target = GhosttyMatch.target(session: request.session, live: live, snapshot: snapshot) {
                    focus = snapshot.selected == target ? .focused : .away
                } else {
                    focus = .unknown
                }
                if ApprovalHandoff.mustHandBack(source: request.source, paneFocus: focus) { handBackApproval(request) }
            }
            checkingApprovalFocus = false
            refresh()
        }
    }
    func openDesktop(_ session: UUID) {
        guard !openingTask else { return }
        openingTask = true
        navigationMessage = "Opening link…"
        Task { @MainActor in
            let result = await desktopAdapter.open(taskID: session.uuidString)
            navigationMessage = result.rawValue
            openingTask = false
            refresh()
        }
    }
    func checkGhosttyFocus() {
        let now = ProcessInfo.processInfo.systemUptime
        guard ghosttyEnabled, !checkingGhostty, !openingTask, now >= nextGhosttyScan,
              !cliItems.isEmpty || !queue.items.isEmpty || !liveCLI.isEmpty || !knownCLISessions.isEmpty
                || !liveClaudeSessions.isEmpty
                || orderedAgentAttentionItems.contains(where: { $0.session.source == .claude }) else { return }
        checkingGhostty = true
        // Keep the last verified snapshot while a re-check is in flight. Resetting to
        // `.checking` every poll collapsed an already presented CLI popup early.
        if case .known = ghosttyFocusState {} else { ghosttyFocusState = .checking }
        nextGhosttyScan = now + 2
        let queued = cliItems
        let configuredRoots = configuredClaudeNavigationRoots()
        Task { @MainActor in
            let observedAt = Date().timeIntervalSince1970
            let result = await Task.detached {
                let snapshot = GhosttyNavigation.snapshot()
                let inventories = configuredRoots.map { root in
                    ClaudeSetupDetection.activeSessionInventory(root: root.root, capabilities: root.capabilities,
                                                                observedAt: observedAt)
                }
                return (snapshot, inventories)
            }.value
            let snapshot = result.0
            if ghosttyEnabled, let snapshot {
                ghosttyPermissionVerified = true
                ghosttyFocusState = .known(snapshot)
                ghosttyInventoryAt = observedAt
                let previousSnapshotAt = lastGhosttySnapshotAt
                if hasGhosttySelectionBaseline, snapshot.selected != lastGhosttySelection,
                   let previousSnapshotAt {
                    // The selection changed sometime after the prior snapshot. Requiring the
                    // outcome to predate that snapshot rejects the interval race where an outcome
                    // arrives after a human switch but before this poll observes it.
                    lastGhosttyVisitAfter = previousSnapshotAt
                }
                lastGhosttySelection = snapshot.selected
                hasGhosttySelectionBaseline = true
                lastGhosttySnapshotAt = observedAt
                for session in Set(queued.map(\.session)) {
                    if let target = GhosttyMatch.target(session: session, live: liveCLI, snapshot: snapshot), snapshot.selected == target {
                        for item in queued where item.session == session {
                            queue.dismiss(.completion(CompletionIdentity(source: .cli, session: item.session, turn: item.turn)))
                        }
                    }
                }
                let liveByScope = Dictionary(uniqueKeysWithValues: result.1.map { scan in
                    (scan.sourceScope, scan.available
                        ? scan.sessions.filter { $0.kind == .interactive }.map(\.sessionID)
                        : [])
                })
                let inventoryAvailable = Dictionary(uniqueKeysWithValues: result.1.map { ($0.sourceScope, $0.available) })
                let currentScopes = Set(configuredClaudeNavigationRoots().map { $0.root.path })
                if currentScopes == Set(liveByScope.keys), let visitObservedAt = lastGhosttyVisitAfter {
                    let acknowledged = ClaudeVisitAcknowledgment.outcomes(
                        agentQueue.snapshot.outcomes,
                        liveSessionsByScope: liveByScope,
                        inventoryAvailable: inventoryAvailable,
                        snapshot: snapshot,
                        snapshotTakenAt: observedAt,
                        transitionAfter: visitObservedAt)
                    for id in acknowledged { agentQueue.dismiss(.outcome(id)) }
                }
                saveCompletions()
            } else if ghosttyEnabled {
                ghosttyFocusState = .unknown
                ghosttyUnavailable = true
                ghosttyEnabled = false
                ghosttyPermissionVerified = false
                hasGhosttySelectionBaseline = false
                lastGhosttySelection = nil
                lastGhosttySnapshotAt = nil
                lastGhosttyVisitAfter = nil
                navigationMessage = "Ghostty controls unavailable. Check Automation permission before enabling them again."
            }
            checkingGhostty = false
            refresh()
        }
    }
    /// Opens the whole queue from the strip (a click or VoiceOver activation); it stays open while
    /// the panel has the pointer or keyboard focus.
    func expand() {
        notchPresentation.openQueue()
        attention.expand(now: ProcessInfo.processInfo.systemUptime)
        refresh()
    }

    private var previewSpotlight: AttentionItemID?

    private func seedPreview(_ mode: String) {
        eventsPath = ""
        let now = Date().timeIntervalSince1970
        usage = CodexUsageReading(weekly: CodexUsageWindow(usedPercent: 37, resetsAt: now + 3 * 86400),
                                  fiveHour: CodexUsageWindow(usedPercent: 40, resetsAt: now + 2 * 3600))
        let working = UUID(uuidString: "01A0916C-337B-4E2A-9D11-0000000000A1")!
        let finished = UUID(uuidString: "7C2F5D10-88AA-4B7E-8E0B-0000000000B2")!
        let asking = UUID(uuidString: "3E9D1B44-51C3-4F0A-9A77-0000000000C3")!
        let details = ApprovalDetails(taskName: "fix auth bug", project: "steer", action: "Run command",
                                      command: "swift test --filter AuthTests", reason: "Verify the token refresh fix before committing.")
        let request = AttentionRequest(id: UUID(), source: .cli, session: asking, turn: UUID(), arrivedAt: now - 5, details: details)
        let completion = AttentionCompletion(source: .desktop, session: finished, turn: UUID(), arrivedAt: now - 2)
        let running = AttentionRunning(source: .cli, session: working, turn: UUID(), arrivedAt: now - 60)
        let question = AttentionQuestion(source: .cli, session: working, turn: UUID(), callID: "call_preview", arrivedAt: now - 3,
                                         prompts: [QuestionPrompt(header: "List shape",
                                                                  question: "Should the list allow nested levels?",
                                                                  options: ["Nested levels (Recommended)", "One level only"]),
                                                   QuestionPrompt(header: "First release",
                                                                  question: "Should the first release also support checkout?",
                                                                  options: ["View only (Recommended)", "Include export"])])
        let desktopQuestion = AttentionQuestion(source: .desktop, session: finished, turn: UUID(), callID: "call_preview_desktop",
                                                arrivedAt: now - 4,
                                                prompts: [QuestionPrompt(header: "Storage",
                                                                         question: "Where should the cache live?",
                                                                         options: ["Application Support (Recommended)", "Caches", "Next to the app"])])
        queue.recordReceipts([request], now: now)
        queue.apply(completions: [completion], running: [running], now: now)
        queue.apply(questions: [question, desktopQuestion])
        // The CLI sample is reachable through the daemon in the preview: a seeded request whose
        // second question takes a typed answer, so the card shows both controls.
        _ = daemonBook.apply(message: ["jsonrpc": "2.0", "id": 1, "method": "item/tool/requestUserInput",
                                       "params": ["threadId": working.uuidString, "turnId": question.turn.uuidString,
                                                  "itemId": "call_preview",
                                                  "questions": [["id": "shape", "header": "List shape",
                                                                 "question": "Should the list allow nested levels?",
                                                                 "options": [["label": "Nested levels (Recommended)", "description": ""],
                                                                             ["label": "One level only", "description": ""]]],
                                                                ["id": "name", "header": "Name",
                                                                 "question": "What should the first release be called?", "isOther": true,
                                                                 "options": [["label": "View only (Recommended)", "description": ""],
                                                                             ["label": "Include export", "description": ""]]]]]],
                             now: now)
        completionPresentation = Attention(restored: true)
        reminderPresentation = Attention(restored: true)
        questionPresentation = Attention(restored: true)
        syncAgentQueueWithCodex(now: now)
        previewSpotlightAgent = .outcome(CodexAttentionAdapter.outcome(from: completion).id)
        _ = mode
    }

    func desktopReadStateChanged(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "desktopReadStateEnabled")
        if !enabled { desktopReadStateMessage = "Desktop read state: off. Desktop completions clear only by dismissal." }
        nextScan = 0
    }
    func ghosttyChanged(_ enabled: Bool) {
        if !enabled && ghosttyUnavailable { return }
        ghosttyUnavailable = false
        ghosttyPermissionVerified = false
        ghosttyFocusState = enabled ? .checking : .disabled
        if !enabled {
            hasGhosttySelectionBaseline = false
            lastGhosttySelection = nil
            lastGhosttySnapshotAt = nil
            lastGhosttyVisitAfter = nil
        }
        if enabled { nextGhosttyScan = 0 }
    }
}

private enum ControlSection: String, CaseIterable, Identifiable {
    case general
    case agents
    case terminals
    case notifications
    case advanced
    case about

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .agents: "sparkles"
        case .terminals: "terminal.fill"
        case .notifications: "bell.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        case .about: "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: .gray
        case .agents: .indigo
        case .terminals: .mint
        case .notifications: .orange
        case .advanced: .blue
        case .about: .cyan
        }
    }
}

struct Controls: View {
    @ObservedObject var model: Companion
    @State private var selection: ControlSection

    init(model: Companion) {
        self.model = model
        // This is an intentional one-time navigation seed: restore the user's last section, then
        // let setup lead on a fresh install until an agent is connected.
        let saved = UserDefaults.standard.string(forKey: "controlsSection").flatMap(ControlSection.init(rawValue:))
        _selection = State(initialValue: saved ?? (model.canUndoSetup ? .general : .agents))
    }

    var body: some View {
        NavigationSplitView {
            ControlsSidebar(selection: $selection, quit: model.quit)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            ControlsDetail(section: selection, model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 540)
        .onChange(of: selection) { _, section in
            UserDefaults.standard.set(section.rawValue, forKey: "controlsSection")
        }
    }
}

private struct ControlsSidebar: View {
    @Binding var selection: ControlSection
    let quit: () -> Void

    private let primarySections: [ControlSection] = [.general, .agents, .terminals, .notifications, .advanced]

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(primarySections) { section in
                    SidebarLabel(section: section).tag(section)
                }

                Section {
                    SidebarLabel(section: .about).tag(ControlSection.about)
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button(role: .destructive, action: quit) {
                Label("Quit Steer", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .accessibilityHint("Stops Steer and closes its menu-bar companion.")
        }
    }
}

private struct SidebarLabel: View {
    let section: ControlSection

    var body: some View {
        Label {
            Text(section.title).font(.body.weight(.medium))
        } icon: {
            Image(systemName: section.symbol)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(section.color, in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
    }
}

private struct ControlsDetail: View {
    let section: ControlSection
    @ObservedObject var model: Companion

    var body: some View {
        switch section {
        case .general: GeneralControls(model: model)
        case .agents: AgentControls(model: model)
        case .terminals: TerminalControls(model: model)
        case .notifications: NotificationControls(model: model)
        case .advanced: AdvancedControls(model: model)
        case .about: AboutControls()
        }
    }
}

private struct ControlsPage<Content: View>: View {
    let section: ControlSection
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    Image(systemName: section.symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(section.color, in: .rect(cornerRadius: 10))
                        .accessibilityHidden(true)
                    Text(section.title).font(.title.bold())
                }
                content
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(30)
        }
        .background(.background)
        .navigationTitle(section.title)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)) }
            .compositingGroup()
            .clipShape(.rect(cornerRadius: 12))
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 20)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(title)")
    }
}

private struct GeneralControls: View {
    @ObservedObject var model: Companion

    private var isConnected: Bool { model.canUndoSetup }

    var body: some View {
        ControlsPage(section: .general) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isConnected ? "Steer is monitoring agent sessions" : "Steer needs an agent connection")
                    .font(.title3.weight(.semibold))
                Text(isConnected ? "\(model.workingCount) working · \(model.toCheckCount) to check" : model.setupStatusText)
                    .foregroundStyle(.secondary)
                StatusBadge(title: isConnected ? "Connected" : "Setup required", color: isConnected ? .green : .orange)
            }

            Text("Connections").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Agents", detail: isConnected ? "Codex is connected." : "Connect an agent to start monitoring work.") {
                    StatusBadge(title: isConnected ? "Ready" : "Setup required", color: isConnected ? .green : .orange)
                }
                Divider()
                SettingsRow(title: "Terminals", detail: model.ghosttyEnabled ? "Ghostty controls are enabled." : "No terminal controls are enabled.") {
                    StatusBadge(title: model.ghosttyEnabled ? "Enabled" : "Off", color: model.ghosttyEnabled ? .green : .secondary)
                }
                Divider()
                SettingsRow(title: "Notifications", detail: model.muted ? "Completion sounds are muted." : "Completion sounds are on.") {
                    StatusBadge(title: model.muted ? "Muted" : "On", color: model.muted ? .secondary : .green)
                }
            }

            Text("Startup").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Launch at login", detail: model.launchAtLogin.detail) {
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.launchAtLogin.isOn },
                        set: { enabled in model.launchAtLoginChanged(enabled) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!model.launchAtLogin.canChange)
                    .accessibilityLabel("Launch at login")
                    .accessibilityValue(model.launchAtLogin.statusTitle)
                    .accessibilityHint(model.launchAtLogin.detail)
                }
                if let statusTitle = model.launchAtLogin.settingsActionStatusTitle {
                    Divider()
                    HStack {
                        StatusBadge(title: statusTitle, color: .orange)
                        Spacer()
                        Button("Open Login Items", action: model.openLoginItemsSettings)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                if let error = model.launchAtLogin.operationError {
                    Divider()
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(16)
                        .accessibilityLabel("Launch at login error: \(error)")
                }
            }
            Text("Closing this window keeps Steer running in the menu bar.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct AgentControls: View {
    @ObservedObject var model: Companion

    var body: some View {
        ControlsPage(section: .agents) {
            Text("Connect and manage the AI agents Steer can observe.")
                .foregroundStyle(.secondary)

            Text("Available agents").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Codex", detail: model.setupStatusText) {
                    StatusBadge(title: model.canUndoSetup ? "Connected" : "Not configured",
                                color: model.canUndoSetup ? .green : .orange)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.setupSurfaceStatusText.prefix(2)), id: \.self) { status in
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                    if let plan = model.setupPlan, case .ready = plan.status, plan.requiresConfigure {
                        DisclosureGroup("Show exact configuration preview") {
                            let hooks = String(data: plan.hooksChange, encoding: .utf8) ?? "(unreadable)"
                            Text("config.toml\n\(plan.configChange)\n\nhooks.json\n\(hooks)\n\nhelper command\n\(plan.helperCommand)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Button("Review again", action: model.refreshSetup)
                        if model.canConfigureSetup {
                            Button("Configure Codex", action: model.configureCodex)
                                .buttonStyle(.borderedProminent)
                        }
                        if model.canUndoSetup { Button("Undo setup", action: model.undoCodexSetup) }
                    }
                    if !model.setupMessage.isEmpty {
                        Text(model.setupMessage).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            ClaudeAgentControls(setup: model.claude,
                                ghosttyEnabled: model.ghosttyEnabled,
                                ghosttyPermissionVerified: model.ghosttyPermissionVerified)
        }
    }
}

private struct ClaudeAgentControls: View {
    @ObservedObject var setup: ClaudeSetupModel
    let ghosttyEnabled: Bool
    let ghosttyPermissionVerified: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Code").font(.headline).foregroundStyle(.secondary)
            Text("Each configuration root is configured independently. Steer never merges roots or changes Claude permissions.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Steer configures the selected user root. Arbitrary future project files or command-line --settings values may override it; this root-only preview cannot know those values without an exact launch context. Connection requires a fresh SessionStart from this exact root.")
                .font(.caption).foregroundStyle(.secondary)
            SettingsCard {
                ForEach(Array(setup.roots.enumerated()), id: \.element.id) { index, root in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(root.displayPath).font(.body.weight(.medium))
                                Text(ClaudeSetupModel.statusText(root.status)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusBadge(title: root.status == .connected ? "Connected" : "Not ready",
                                        color: root.status == .connected ? .green : .orange)
                        }
                        Text(root.capabilities.version.map { "Claude Code \($0) · tested baseline \(ClaudeSetupRequirements.minimumCLIVersion)" }
                             ?? "Claude Code not detected")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(ghosttyStatusText).font(.caption).foregroundStyle(.secondary)
                        Text("Active sessions needing restart: \(root.activeSessionStatus.displayText)")
                            .font(.caption).foregroundStyle(.secondary)
                        if setup.usageEnabled(for: root) {
                            Text(usageText(root.usage, status: root.usageStatus))
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Claude usage for \(root.displayPath): \(usageText(root.usage, status: root.usageStatus))")
                        }
                        if let plan = root.plan, case .ready = plan.status {
                            Toggle("Include optional Claude usage", isOn: Binding(
                                get: { setup.usageEnabled(for: root) },
                                set: { setup.setUsageEnabled($0, for: root) }
                            ))
                            .accessibilityLabel("Include optional Claude usage for \(root.displayPath)")
                            Text("Off by default. An existing status line is wrapped only after its cancellation compatibility probe passes.")
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Show setup preview") {
                                let hookFields = plan.ownedHooks.map { hook in
                                    "  hooks.\(hook.event) matcher=\(hook.matcher ?? "<any>") command=\(hook.command) timeout=\(ClaudeSetupRequirements.hookTimeout)"
                                }.joined(separator: "\n")
                                let environmentFields = plan.ownedEnvironment.isEmpty
                                    ? "  env.\(ClaudeSetupRequirements.titleDisableEnvironmentKey)=\(ClaudeSetupRequirements.titleDisableEnvironmentValue) (already present; preserved)"
                                    : plan.ownedEnvironment.map { key, value in
                                        "  env.\(key)=\(value) (Steer adds and owns)"
                                    }.sorted().joined(separator: "\n")
                                let previewText = [
                                    "settings.json: \(root.settingsPath)", hookFields, environmentFields,
                                    "owned helper: \(root.helperPath)",
                                    "owned event records: \(root.eventsPath)",
                                    "owned install record: \(root.statePath)",
                                    "owned backups: \(root.backupsPath)",
                                    "SessionStart and SessionEnd title: JSON terminalSequence with the full session ID / reset",
                                    "effective scope: selected user root; arbitrary future project files or command-line --settings may override it (launch context unavailable)",
                                    "optional usage intent: \(plan.usageEnabled ? (root.usageInstalled ? "on (installed)" : "on (pending compatibility probe)") : (root.usageInstalled ? "off (remove on Configure)" : "off"))"
                                ].joined(separator: "\n")
                                Text(previewText)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack {
                                Button("Review again", action: setup.refresh)
                                    .accessibilityLabel("Review Claude setup for \(root.displayPath)")
                                if root.status != .connected || plan.requiresConfigure || root.usageInstalled != setup.usageEnabled(for: root) {
                                    Button("Configure Claude") { setup.configure(root) }
                                        .buttonStyle(.borderedProminent)
                                        .accessibilityLabel("Configure Claude for \(root.displayPath)")
                                }
                                if root.status != .notConfigured {
                                    Button("Undo setup") { setup.undo(root) }
                                        .accessibilityLabel("Undo Claude setup for \(root.displayPath)")
                                }
                                if index > 0 {
                                    Button("Remove root") { setup.removeAlternateRoot(root) }
                                        .accessibilityLabel("Remove Claude root \(root.displayPath)")
                                }
                            }
                        } else if index > 0 {
                            Button("Remove root") { setup.removeAlternateRoot(root) }
                                .accessibilityLabel("Remove Claude root \(root.displayPath)")
                        }
                    }
                    .padding(16)
                }
                Button("Add alternate Claude root", action: setup.addAlternateRoot)
                    .padding(16)
            }
            if !setup.message.isEmpty {
                Text(setup.message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var ghosttyStatus: ClaudeGhosttyStatus {
        if !ghosttyEnabled { return .off }
        return ghosttyPermissionVerified ? .ready : .permissionRequired
    }

    private var ghosttyStatusText: String {
        switch ghosttyStatus {
        case .off: "Ghostty controls: off"
        case .permissionRequired: "Ghostty controls: permission needed"
        case .ready: "Ghostty controls: ready"
        case .unavailable(let message): "Ghostty controls: \(message)"
        }
    }

    private func usageText(_ reading: ClaudeUsageReading?, status: ClaudeUsageSetupStatus) -> String {
        if case let .unavailable(message) = status { return message }
        if case let .conflict(message) = status { return message }
        guard let reading = reading?.current(now: Date().timeIntervalSince1970) else {
            return "Claude usage: unavailable (no current subscription window reported)."
        }
        let five = reading.fiveHour.map { "5h \($0.percentText)" } ?? "5h unavailable"
        let seven = reading.sevenDay.map { "7d \($0.percentText)" } ?? "7d unavailable"
        return "Claude usage: \(five), \(seven) (last reported)"
    }
}

private struct TerminalControls: View {
    @ObservedObject var model: Companion

    var body: some View {
        ControlsPage(section: .terminals) {
            Text("Choose which terminal hosts Steer may use to return to an agent session.")
                .foregroundStyle(.secondary)

            Text("Available terminals").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Ghostty", detail: "One agent session per unsplit tab.") {
                    Toggle("", isOn: $model.ghosttyEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Enable Ghostty controls")
                        .onChange(of: model.ghosttyEnabled) { _, enabled in model.ghosttyChanged(enabled) }
                }
                Divider()
                SettingsRow(title: "Automation permission",
                            detail: model.ghosttyPermissionVerified ? "Verified by a navigation probe." : "Enable Ghostty to let macOS request access.") {
                    StatusBadge(title: model.ghosttyPermissionVerified ? "Granted" : "Not verified",
                                color: model.ghosttyPermissionVerified ? .green : .orange)
                }
                Divider()
                Text(model.setupSurfaceStatusText.last ?? "Ghostty: unavailable")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
            }
        }
    }
}

private struct NotificationControls: View {
    @ObservedObject var model: Companion

    var body: some View {
        ControlsPage(section: .notifications) {
            Text("Control how Steer presents work that needs your attention.")
                .foregroundStyle(.secondary)

            SettingsCard {
                SettingsRow(title: "Play completion sound", detail: "Plays once for each newly presented completion.") {
                    Toggle("", isOn: Binding(get: { !model.muted }, set: { enabled in model.setSoundEnabled(enabled) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Play completion sound")
                }
                Divider()
                SettingsRow(title: "Clear completions marked read", detail: "Reads Codex's own desktop read state; Steer never marks a task read.") {
                    Toggle("", isOn: $model.desktopReadStateEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Clear completions marked read")
                        .onChange(of: model.desktopReadStateEnabled) { _, enabled in model.desktopReadStateChanged(enabled) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.desktopReadStateMessage).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Send test notification", action: model.sendTest)
                        Button("Dismiss test", action: model.dismissTest).disabled(!model.attention.pending)
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct AdvancedControls: View {
    @ObservedObject var model: Companion

    var body: some View {
        ControlsPage(section: .advanced) {
            Text("Diagnostics and integration details for troubleshooting Steer.")
                .foregroundStyle(.secondary)

            Text("Event delivery").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                SettingsRow(title: "Agent events", detail: model.eventsPath.isEmpty ? "Not connected." : model.eventsPath) {
                    Button("Choose…", action: model.connectReminders)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.daemonStatus).font(.callout)
                    Text("Steer connects only to a daemon that is already running; it never starts one.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(16)
            }

            Text("Task-link check").font(.headline).foregroundStyle(.secondary)
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Local Codex task ID", text: $model.taskID)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Local Codex task ID")
                        Button("Open task", action: model.openTestTask).disabled(model.openingTask)
                    }
                    Text(model.navigationMessage.isEmpty ? "Opening a task does not dismiss its notification." : model.navigationMessage)
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }
}

private struct AboutControls: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }

    var body: some View {
        ControlsPage(section: .about) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Steer").font(.title2.bold())
                Text("Keeps agent activity and requests within reach while you work.")
                    .foregroundStyle(.secondary)
                Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
            }
            Text("Steer currently supports Codex and Ghostty. Other agent and terminal integrations appear only when they are implemented.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

let app = NSApplication.shared
let companion = Companion()
app.setActivationPolicy(.accessory)
app.delegate = companion
app.run()
