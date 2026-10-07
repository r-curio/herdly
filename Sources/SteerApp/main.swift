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
    var answering = false
    /// The keys Steer may have sent per call and question index, and the last relay failure per call.
    @Published var relayLedger = QuestionRelayLedger()
    /// Steer's own bookkeeping of the one reply each completion card sent. Memory only, and a card
    /// that has sent one never sends another.
    @Published var replyProgress: [CompletionIdentity: SessionReplyProgress] = [:]
    private var replying = false
    /// Sessions Codex recorded as ended; a completion for one has nothing left to reply to.
    @Published var endedSessions: Set<UUID> = []
    /// The second client on Codex's app-server daemon socket, when one exists. Inert otherwise.
    let daemonClient = AppServerDaemonClient(socketPath: Companion.daemonSocketPath)
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
    struct LiveClaudeQuestion {
        let request: ClaudeQuestionRequest
        let events: URL
        let sourceScope: String
    }
    var liveClaudeQuestions: [String: LiveClaudeQuestion] = [:]
    var availableClaudeQuestionTokens: Set<String> = []
    var spentClaudeQuestionTokens: Set<String> = []
    var pendingClaudeQuestionReceipts: Set<String> = []
    var claudeQuestionScanGeneration: UInt64 = 0
    private var claudeApprovalScanGeneration: UInt64 = 0
    @Published var launchAtLogin = LaunchAtLoginState()
    @Published var desktopForeground = false
    let launchAtLoginCoordinator = LaunchAtLoginCoordinator(service: LaunchAtLoginService())
    let desktopAdapter = DesktopAdapter()
    var cliSessions: Set<UUID> = []
    var liveCLI: Set<UUID> = []
    /// Sessions a Ghostty inventory proved CLI by their session-id title, this launch. They stay CLI
    /// after the tab closes, and that closing ends them (`ReminderReader.scan`). Memory only.
    private var knownCLISessions: Set<UUID> = []
    /// Complete root inventories used to prove which canonical Claude sessions are live. Memory only.
    var liveClaudeSessions: [String: [String]] = [:]
    /// herdr monitor, hook pane records and latest scan (Companion+Herdr.swift).
    let herdr = HerdrSessionBindings()
    var claudeInventoryAvailable: [String: Bool] = [:]
    var claudeInventories: [String: ClaudeInventoryScan] = [:]
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

    var visibleReminders: [Reminder] {
        queue.items.compactMap { $0.request }.map {
            Reminder(request_id: $0.id, session_id: $0.session, turn_id: $0.turn, outcome: "no_decision")
        }
    }
    var cliItems: [AttentionCompletion] {
        queue.items.compactMap(\.completion).filter { $0.source == .cli }
    }
    private var scanning = false
    var nextScan: Double = 0
    private var pruningEvents = false
    /// Next due time per events directory, so a Claude root that loads after launch is pruned
    /// on the next refresh instead of waiting out another directory's interval.
    private var eventPruneDue: [String: Double] = [:]
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

    var shownControlsForSetup = false

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

    /// Hook records accumulate without bound, so Steer deletes expired ones itself: at launch and
    /// then every ten minutes, off the main actor. Frequent passes keep hour-old tool records from
    /// crowding the readers' newest-record window (see docs/event-retention.md). Readers stay correct while a
    /// pass runs; a record deleted mid-scan is simply not read.
    func pruneEventRecords() {
        let now = ProcessInfo.processInfo.systemUptime
        guard previewMode == nil, !CommandLine.arguments.contains("--smoke-test"),
              !pruningEvents else { return }
        // Every configured root, connected or not, so one does not overflow while disconnected.
        let due = Set([eventsPath] + claude.roots.map(\.eventsPath))
            .filter { !$0.isEmpty && now >= eventPruneDue[$0, default: 0] }
        guard !due.isEmpty else { return }
        for path in due { eventPruneDue[path] = now + 10 * 60 }
        let directories = due.map { URL(fileURLWithPath: $0, isDirectory: true) }
        pruningEvents = true
        Task { @MainActor in
            await Task.detached(priority: .utility) {
                for directory in directories { HookEventRetention.prune(directory) }
            }.value
            pruningEvents = false
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
            scanHerdr()
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
        pruneEventRecords()
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

    func codexSession(_ identity: AgentSessionIdentity) -> UUID? {
        guard identity.source == .codex else { return nil }
        return UUID(uuidString: identity.session)
    }

    private func codexTurn(_ identity: AgentTurnIdentity) -> AttentionCompletion? {
        guard let session = codexSession(identity.session), let turn = UUID(uuidString: identity.turn) else { return nil }
        return queue.items.compactMap(\.completion).first { $0.session == session && $0.turn == turn }
    }

    var knownGhosttySnapshot: GhosttySnapshot? {
        guard case let .known(snapshot) = ghosttyFocusState, snapshot.status == "ok" else { return nil }
        return snapshot
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

    func handBackClaudeApproval(_ approval: AgentApproval) {
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

    func handBackApproval(_ request: AttentionRequest) {
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

let app = NSApplication.shared
let companion = Companion()
app.setActivationPolicy(.accessory)
app.delegate = companion
app.run()
