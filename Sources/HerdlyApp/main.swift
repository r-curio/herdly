import AppKit
import QuartzCore
import SwiftUI
import HerdlyCore

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

/// What the latest read of the Codex desktop app's read state found (docs/desktop-read-state.md).
enum DesktopReadStateStatus: Equatable, Sendable {
    case notChecked
    /// The switch is off; desktop completions clear only by dismissal.
    case off
    /// The file is missing or in an unexpected format; desktop completions clear only by dismissal.
    case unavailable(fileName: String)
    /// The file was read; `summary` says when it was written, what it held and what this scan cleared.
    case readable(summary: String)

    /// The status line, shown as the switch's tooltip in Settings.
    var message: String {
        switch self {
        case .notChecked: "Desktop read state: not checked yet."
        case .off: "Desktop read state: off. Desktop completions clear only by dismissal."
        case .unavailable(let fileName):
            "Desktop read state: unavailable (\(fileName) missing or in an unexpected format). Desktop completions clear only by dismissal."
        case .readable(let summary): "Desktop read state: \(summary)"
        }
    }

    /// The line Settings shows under the switch, nil when nothing needs saying.
    var problemLine: String? {
        guard case .unavailable = self else { return nil }
        return "Herdly can't read Codex's read state, so desktop completions clear only when dismissed."
    }
}

@MainActor
final class NotchPanel: NSPanel {
    /// Key status is only ever taken by a deliberate click or Tab into the panel; automatic
    /// presentation uses orderFrontRegardless, which never makes the panel key.
    override var canBecomeKey: Bool { true }
    var onEscape: (() -> Void)?
    /// Up and Down arrows move the queue's row selection; Return acts on the selected row. Only
    /// keys no control in the panel handled reach here. Each returns false when it did nothing, so
    /// the key continues to AppKit.
    var onMoveSelection: ((QueueRowSelection.Direction) -> Bool)?
    var onReturn: (() -> Bool)?
    /// A digit 1 through 9 selects that option on a question card (#321); it never sends.
    var onDigit: ((Int) -> Bool)?

    /// Virtual key codes from the HIToolbox `kVK_*` table.
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }
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

    /// Escape follows `NotchPresentationController.escape()`: a clicked card steps back to the
    /// queue; otherwise the panel collapses and returns keyboard input to the app the user was using.
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let handled: Bool
        switch (modifiers.isEmpty, event.keyCode) {
        case (true, KeyCode.downArrow): handled = onMoveSelection?(.down) ?? false
        case (true, KeyCode.upArrow): handled = onMoveSelection?(.up) ?? false
        case (true, KeyCode.returnKey), (true, KeyCode.keypadEnter): handled = onReturn?() ?? false
        default:
            if modifiers.isEmpty, let characters = event.charactersIgnoringModifiers, characters.count == 1,
               let digit = Int(characters), (1...9).contains(digit) {
                handled = onDigit?(digit) ?? false
            } else {
                handled = false
            }
        }
        if !handled { super.keyDown(with: event) }
    }

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
    /// Each approval's or question's delivery note after the user acted on it (D10); memory only.
    @Published var rowNotes = RowNotes()
    @Published var openingTask = false
    /// Each terminal card's Open line: the latest scan's unavailable cause, or a click's (#267).
    @Published var openLines = OpenUnavailableLines<String>()
    private static let launchedAt = Date().timeIntervalSince1970
    @Published var queue = AttentionQueue(snapshot: Companion.launchSnapshot, observingSince: Companion.launchedAt)
    /// Source-scoped queue for adapters that have bounded native observations. The legacy
    /// Codex presentation queue remains the display path until its UI migration slice.
    @Published var agentQueue = AgentAttentionQueue(snapshot: Companion.launchSnapshot)
    /// Claude names are presentation metadata only; source scope keeps identical session IDs apart.
    @Published private(set) var claudeSessionNames: [AgentSessionIdentity: String] = [:]
    /// Each Claude session's working directory from its inventory, for the row's "project @ branch".
    @Published private(set) var claudeSessionDirectories: [AgentSessionIdentity: String] = [:]
    /// Each Claude turn's prompt and last message from the latest scan of its root, for its result
    /// card (#341). Memory only, like Codex's completion previews; looked up by the exact turn.
    @Published private(set) var claudeTurnResults: [AgentTurnIdentity: ClaudeTurnResult] = [:]
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
    /// Herdly's own bookkeeping of what it relayed for each waiting question. Memory only: a restart
    /// returns every question as plain pending and nothing is ever re-sent.
    @Published var answerProgress: [QuestionIdentity: QuestionAnswerProgress] = [:]
    var daemonDraftRequests: [QuestionIdentity: AppServerQuestionRequest] = [:]
    /// The route each question's unsent selection was made on (#321); Send refuses a selection made
    /// on another route, so a daemon pick never becomes a typed key or the reverse.
    var selectionRoutes: [QuestionIdentity: QuestionAnswerRoute] = [:]
    /// The last digit or Return pressed while one question card is shown (#321). The card acts on it:
    /// a digit selects, Return does the card's Next or Send when it is enabled. Never sent by itself.
    @Published var questionCardKeyPress: QuestionCardKeyPress?
    var answering = false
    /// The keys Herdly may have sent per call and question index, and the last relay failure per call.
    @Published var relayLedger = QuestionRelayLedger()
    /// Herdly's own bookkeeping of the one reply each completion card sent. Memory only, and a card
    /// that has sent one never sends another.
    @Published var replyProgress: [CompletionIdentity: SessionReplyProgress] = [:]
    private var replying = false
    /// Each Codex session's latest turn start in the last scan's hook records (`ReplyTurnStarts`):
    /// what confirms a sent reply whose turn finished before any scan saw it running (#271).
    private var replyTurnStarts: [UUID: Double] = [:]
    /// Sessions Codex recorded as ended; a completion for one has nothing left to reply to.
    @Published var endedSessions: Set<UUID> = []
    /// The second client on Codex's app-server daemon socket, when one exists. Inert otherwise.
    let daemonClient = AppServerDaemonClient(socketPath: Companion.daemonSocketPath)
    /// The daemon's pending question requests on the current connection, and the ones Herdly answered.
    @Published var daemonBook = AppServerQuestionBook()
    @Published var daemonStatus = "Codex daemon: not checked yet."
    /// The daemon path is available; the preview renders it with a seeded request.
    var daemonConnected: Bool { daemonClient.isConnected || previewMode != nil }
    private var savedSnapshot = Companion.launchSnapshot
    /// Every terminal app's and multiplexer's switch, remembered across launches (product.md, "Agreed
    /// terminal host presentation"). Herdly scans and contacts only hosts that are switched on.
    @Published private(set) var hostSwitches = TerminalHostSwitches()
    /// Ghostty's switch; switched off only by the user or an Automation denial.
    var ghosttyEnabled: Bool {
        get { hostSwitches.isOn(.ghostty) }
        set { hostSwitches.set(.ghostty, on: newValue) }
    }
    @Published var ghosttyPermissionVerified = false
    /// iTerm2's permission, scan and visit state (Companion+ITerm2.swift, #238).
    let iTerm2 = ITerm2State()
    /// The latest Automation consent check for Ghostty; nil until one has run in this launch.
    @Published var ghosttyAccess: GhosttyAutomationAccess?
    /// Read the Codex desktop app's own unread flags to acknowledge desktop completions it has
    /// cleared. Private format; on by default, off with one switch when a desktop update breaks it.
    @Published var desktopReadStateEnabled = UserDefaults.standard.object(forKey: "desktopReadStateEnabled") as? Bool ?? true
    /// The latest read-state outcome; Settings shows a problem line only while it is `.unavailable`.
    @Published private(set) var desktopReadState = DesktopReadStateStatus.notChecked
    /// Follow the pointer, or keep the notch on one display; saved by `setNotchDisplayPreference`.
    @Published private(set) var notchDisplayPreference = NotchDisplayPreference.restored(
        id: UserDefaults.standard.string(forKey: "notchDisplayPinID"),
        name: UserDefaults.standard.string(forKey: "notchDisplayPinName"))
    /// The display picker's entries, checked entry, and detail line; see `updateNotchDisplayChoices`.
    @Published private(set) var notchDisplayChoices = NotchDisplayChoices(displays: [], preference: .followPointer)
    /// Strip and queue choices for each kind of display, edited in the Notch settings pane.
    @Published private(set) var appearances: [DisplayProfile: NotchAppearance] = Dictionary(
        uniqueKeysWithValues: DisplayProfile.allCases.map { profile in
            (profile, NotchAppearance.load(profile: profile) { key in UserDefaults.standard.string(forKey: key) })
        })
    /// The kind of display the notch is on now; `refresh` follows the panel between displays.
    @Published private(set) var activeProfile = DisplayProfile(hasCameraHousing: !NSScreen.screens.filter {
        $0.safeAreaInsets.top > 0 }.isEmpty)
    var appearance: NotchAppearance { appearances[activeProfile] ?? .standard }
    /// The macOS system sound played when a completion or question card opens.
    @Published private(set) var completionSound = UserDefaults.standard.string(forKey: "completionSound") ?? Companion.defaultSound
    nonisolated static let defaultSound = "Glass"
    /// How long a new card stays open on its own.
    @Published var cardOpenDuration = Companion.loadCardOpenDuration() {
        didSet { UserDefaults.standard.set(cardOpenDuration.rawValue, forKey: "cardOpenDuration") }
    }
    /// Migrates the old "keepCardsOpen" switch once: when no readable duration is saved, the
    /// resolved one is written, so later launches never read the old key again. The old key is
    /// left in place and no longer written.
    private static func loadCardOpenDuration() -> CardOpenDuration {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "cardOpenDuration")
        let duration = CardOpenDuration.resolve(saved: saved,
                                                legacyKeepCardsOpen: defaults.object(forKey: "keepCardsOpen") as? Bool)
        if saved != duration.rawValue { defaults.set(duration.rawValue, forKey: "cardOpenDuration") }
        return duration
    }
    /// Codex's own thread names by session, refreshed every scan; unknown sessions keep their identifier.
    @Published var threadNames: [UUID: String] = [:]
    /// Checked-out branch by working directory, for the queue row's identity line. Read off the
    /// main actor with each reminder scan; presentation only.
    @Published private(set) var gitBranches: [String: String] = [:]
    /// Codex's usage windows from the newest rollout, refreshed every scan; nil until one is read.
    @Published var usage: CodexUsageReading?
    /// The strip's readings: only windows that have not yet reset are shown.
    var currentUsage: CodexUsageReading? { usage?.current(now: Date().timeIntervalSince1970) }
    var currentWeeklyLimit: CodexUsageWindow? { currentUsage?.weekly }
    /// Claude readings remain keyed by their selected configuration root; values are never merged.
    @Published var claudeUsage: [String: ClaudeUsageReading] = [:]
    /// The strip's usage bars, Claude's then Codex's, from one clock reading so the bars drawn and
    /// the wing laid out for them agree.
    var usageStripReadouts: [UsageStripReadout] {
        guard appearance.usage != .hidden else { return [] }
        let now = Date().timeIntervalSince1970
        return UsageStripReadouts.make(codex: usage?.current(now: now),
                                       claude: ClaudeUsageReading.newest(claudeUsage.values, now: now),
                                       fiveHour: appearance.usage == .compact)
    }
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
    /// False until the first Codex setup detection lands; `setupStatus` is only a default before then.
    @Published var setupChecked = false
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
    /// Terminal sessions Codex's app-server daemon has loaded (a TUI, not the desktop), live or not:
    /// the Codex half of herdr's gate counts them, so a session whose only surface is a herdr pane
    /// can be found there before it is proved live (ADR 0012).
    var daemonCLISessions: Set<UUID> = []
    var liveCLI: Set<UUID> = []
    /// A reminder scan has set `liveCLI` at least once since launch, so a session missing from it ended.
    private(set) var cliLivenessRead = false
    /// Sessions a Ghostty inventory proved CLI by their session-id title, this launch. They stay CLI
    /// after the tab closes, and that closing ends them (`ReminderReader.scan`). Memory only.
    private var knownCLISessions: Set<UUID> = []
    /// The newest titles each contactable host besides Ghostty and herdr showed, from inventories its
    /// own scans already read (`recordHostTitles`). The reminder scan ends no daemon session a tab
    /// here shows (#265). Memory only; a host Herdly may no longer contact is dropped.
    private var hostTitleReadings: [TerminalHost: TerminalHostTitles] = [:]
    /// The host whose inventory last showed each Codex session's title (`ReminderScan.surfaceHosts`),
    /// so a session is not ended while that app is not running (H7). Memory only.
    private(set) var lastSeenHosts: [UUID: TerminalHost] = [:]
    /// The terminal app each Claude CLI card's registry process last walked to, keyed by its Open line
    /// key (`ClaudeLastSeenHost`, #280), so a card no longer live says that app isn't running. Memory only.
    var lastSeenClaudeHosts: [String: TerminalHost] = [:]
    /// Daemon-held sessions whose end check waits on a switched-on host's inventory
    /// (`ReminderScan.awaitingHostInventories`): the iTerm2, Terminal.app and WezTerm scans read while
    /// this is not empty, even with nothing of theirs to show (#265).
    private(set) var codexSessionsAwaitingInventory: Set<UUID> = []
    /// Complete root inventories used to prove which canonical Claude sessions are live. Memory only.
    var liveClaudeSessions: [String: [String]] = [:]
    /// herdr monitor, hook pane records and latest scan (Companion+Herdr.swift).
    let herdr = HerdrSessionBindings()
    /// Terminal.app permission, scan, visits and Claude replies (Companion+TerminalApp.swift).
    let terminalApp = TerminalAppState()
    /// WezTerm scan, visits and Open diagnostics (Companion+WezTerm.swift, #240).
    let wezTerm = WezTermState()
    /// tmux scan, visits and typed routes (Companion+Tmux.swift, #241).
    let tmux = TmuxState()
    /// Zellij scan, visits and typed routes (Companion+Zellij.swift, #242).
    let zellij = ZellijState()
    /// The scan behind each terminal card's Open line (Companion+OpenAvailability.swift, #267).
    let openAvailability = OpenAvailabilityScanState()
    var claudeInventoryAvailable: [String: Bool] = [:]
    var claudeInventories: [String: ClaudeInventoryScan] = [:]
    /// Unix time of the inventory in `ghosttyFocusState`, for dating a session end at the tab's absence.
    private(set) var ghosttyInventoryAt: Double = 0
    /// ADR 0016's visit interval and dwell run over Ghostty title-route tabs, one reading per Ghostty scan.
    private var ghosttyVisits = TerminalVisitTracker<GhosttyTarget>()
    private var checkingGhostty = false
    private var nextGhosttyScan: Double = 0
    private var checkingApprovalFocus = false
    private var nextApprovalFocusScan: Double = 0
    private var ghosttyFocusState: GhosttyFocusState = .disabled
    /// Consent checks may block on the macOS prompt; one runs at a time, and a result from before
    /// the user last switched controls applies to nothing.
    private var probingGhosttyAccess = false
    private var ghosttyAccessGeneration = 0
    private var ghosttyLaunchObserver: NSObjectProtocol?
    /// The value `ghosttyChanged` last acted on. Code that sets `ghosttyEnabled` and calls it also
    /// fires the Settings toggle's `onChange`; the repeat call is a no-op.
    private var appliedGhosttyEnabled = false
    private var ghosttyStartupRetries = 0
    static let ghosttyEnabledKey = TerminalHost.ghostty.defaultsKey
    static let ghosttyOfferedKey = "ghosttyFirstRunOffered"

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
              result.work.scanGeneration == claudeApprovalScanGeneration || current != nil else {
            // Receipt can no longer be verified against this root and scan; the note says what was written.
            updateRowNote(.claudeDecisionUnverified(published: result.published), for: .approval(result.work.approvalID))
            refresh()
            return
        }
        verifiedClaudeApprovalReceipts.removeValue(forKey: result.work.requestID)
        verifiedClaudeApprovalRoots.removeValue(forKey: result.work.requestID)
        updateRowNote(RowNoteUpdate.claudeDecision(result.work.decision, published: result.published, delivered: result.delivered),
                      for: .approval(result.work.approvalID))
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
    /// What the last scan decoded, so unchanged rollouts and Claude records are not reread every scan.
    private var rolloutCache = RolloutCache()
    /// Codex hook record bytes, shared by the reminder and desktop readers within a scan.
    private var hookCache = HookFileCache()
    /// Per Claude events directory path.
    private var claudeRecordCaches: [String: ClaudeRecordCache] = [:]
    private var pruningEvents = false
    /// Next due time per events directory, so a Claude root that loads after launch is pruned
    /// on the next refresh instead of waiting out another directory's interval.
    private var eventPruneDue: [String: Double] = [:]
    var orderedAttentionItems: [AttentionItem] { queue.items }
    /// Queue priority order (live approvals by soonest deadline, D12). The strip, spotlight, and
    /// center label always read this order, so the "Newest first" sort can never move what needs the
    /// user outside the open queue.
    var orderedAgentAttentionItems: [AgentAttentionItem] {
        agentQueue.items(at: Date().timeIntervalSince1970, earlier: appearance.earlier)
    }
    /// The open queue's rows in the user's chosen sort.
    var queueAgentAttentionItems: [AgentAttentionItem] {
        agentQueue.items(at: Date().timeIntervalSince1970, earlier: appearance.earlier, sort: appearance.sort)
    }
    var count: Int { orderedAgentAttentionItems.count + (attention.pending ? 1 : 0) }
    var workingCount: Int { agentQueue.workingCount }
    /// Every row needing the user, including Earlier results; the restart lab records this.
    var toCheckCount: Int { agentQueue.toCheckCount + (attention.pending ? 1 : 0) }
    /// What settings shows, matching the strip badge: Earlier results are left out.
    var currentToCheckCount: Int {
        agentQueue.toCheckCount(at: Date().timeIntervalSince1970, earlier: appearance.earlier) + (attention.pending ? 1 : 0)
    }
    /// One presentation mode prevents passive hover from replacing a new item's focused card.
    @Published var expanded = false
    @Published var presentationMode: NotchPresentationMode = .collapsed
    /// The open queue's keyboard selection (Up and Down arrows); cleared whenever the queue closes.
    @Published private(set) var queueSelection = QueueRowSelection()
    /// Whether the user opened the "N working" fold; closed again whenever the panel collapses.
    @Published var workingFoldOpen = false {
        didSet { if workingFoldOpen != oldValue { reconcileSelection() } }
    }
    /// Kind sections whose "+N more" the user opened; closed again whenever the panel collapses.
    @Published var openQueueFolds: Set<QueueKindSection> = [] {
        didSet { if openQueueFolds != oldValue { reconcileSelection() } }
    }
    /// The one running row opened in place (#319). Changed only through Companion+RunningRow.swift.
    @Published var openRunningRow = OpenRunningRow()
    /// A result row's Open waiting to fold the panel back once it finishes (#322). Not published:
    /// it changes nothing on screen by itself. Changed only through Companion+ResultRow.swift (and
    /// cancelled by `collapse`).
    var rowOpenFold = RowOpenFold()
    /// The rows the open panel shows, under their group headings: the explicit queue (working rows
    /// folded below anything that needs the user), or only the one card. A card is never grouped.
    /// The view draws these and the keyboard selection steps through them.
    var visibleSections: QueueSections {
        let items: [AgentAttentionItem]
        if presentationMode.showsAll {
            items = queueAgentAttentionItems
        } else if let id = presentationMode.singleCard {
            items = orderedAgentAttentionItems.filter { $0.id == id }
        } else {
            items = []
        }
        let grouping = presentationMode.showsAll ? appearance.grouping : .none
        return QueueSections.make(items, grouping: grouping, project: projectFolder(for:),
                                  kindSections: presentationMode.showsAll, openSections: openQueueFolds)
    }
    /// The open queue's rows in reading order as they are on screen: the arrows step through these,
    /// skipping a closed working fold.
    var selectableRows: [AgentAttentionID] {
        presentationMode.showsAll ? visibleSections.selectableRows(workingOpen: workingFoldOpen) : []
    }
    /// Fresh response previews are intentionally process-memory only.
    @Published private(set) var completionPreviews: [CompletionIdentity: CompletionPreviewAvailability] = [:]
    @Published private(set) var spotlightContexts: [AttentionItemID: SpotlightRecordContext] = [:]
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Natural height of the open panel's content, reported by the view after layout.
    private(set) var contentHeight: CGFloat = 0
    /// When the open panel began without a measured height (`NotchOpenHeight`); nil while collapsed or measured.
    private var openHeightWaitingSince: Double?
    /// How the strip splits around the housing on the current display; the view lays out by it.
    @Published var stripLayout = StripLayout(leading: 140, gap: 0, trailing: 60, height: NotchPlacement.collapsedHeight)
    var hovering = false
    /// Whether a text field on screen in the notch holds unsent text (`DraftInProgressKey`).
    var notchDraftInProgress = false
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
    var previewViewedQuestion: Int?
    private var previewSpotlightAgent: AgentAttentionID?
    /// `--preview-queue` modes that open the sample item in the spotlight.
    static let spotlightPreviewModes: Set<String> = ["spotlight", "spotlight-approval", "spotlight-handed-back",
                                                       "spotlight-question", "spotlight-question-edit", "spotlight-question-review",
                                                       "spotlight-question-long", "spotlight-question-unavailable", "spotlight-claude-question", "spotlight-claude-multiselect",
                                                       "spotlight-result", "spotlight-result-markdown"]
    private var targetFrame: CGRect = .zero
    /// The frame animation in flight, so a refresh mid-animation does not mistake it for drift.
    private var frameAnimation: UUID?
    /// `--preview-queue <collapsed|spotlight|spotlight-approval|spotlight-handed-back|spotlight-question|spotlight-claude-question|spotlight-result|spotlight-result-markdown|row-note-reply|expanded>`
    /// seeds in-memory sample items for screenshots; `clicked-approval` shows the approval sample as a
    /// clicked card (`clicked-approval-long` with a command past the six-line cap, `clicked-claude-approval`
    /// a Claude request with no command), and `row-note` the queue with that row selected and carrying a note;
    /// `empty-collapsed`, `empty-expanded`, and `empty-not-connected` seed only the usage readouts, to show the empty notch.
    /// It never scans Codex events, never saves, and never releases approvals.
    let previewMode = Companion.argumentValue(for: "--preview-queue")
    private var status: NSStatusItem!
    private var notchDisplayMenu: NotchDisplayMenu!
    private var panel: NotchPanel!
    private var controls: NSWindow?
    private var controlsAnimationGeneration = 0
    private var controlsAnimatingOut = false
    private var controlsRestingFrame: NSRect?
    private var timer: Timer?
    private var refreshInterval = RefreshCadence.active
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// The display the panel was last placed on; placement freezes here while the user interacts.
    private var currentDisplayID: UInt32?
    /// SwiftUI's hover flag can go stale when the panel is re-placed out from under the pointer
    /// (a display disconnect, for example), so it is confirmed against the actual pointer location.
    /// SwiftUI never reports hover for the row on the screen's top edge (see `NotchHover`), so a
    /// pointer pushed against the edge above the strip counts by geometry instead.
    private var pointerInsidePanel: Bool {
        let pointer = NSEvent.mouseLocation
        guard panel.isVisible else { return false }
        return (hovering && panel.frame.contains(pointer)) || NotchHover.pointerTouchesTopEdge(of: panel.frame, pointer: pointer)
    }
    /// Pointer-move monitors that refresh as soon as the pointer reaches or leaves the top-edge row.
    private var pointerMonitors: [Any] = []
    private var pointerOnTopEdge = false

    nonisolated static func argumentValue(for flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// Herdly's own support directory, never Codex's. `--attention-snapshot` isolates lab runs.
    nonisolated static var snapshotURL: URL {
        if let path = argumentValue(for: "--attention-snapshot") { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Herdly/attention-snapshot.json")
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
        status.button?.toolTip = "Herdly"
        status.button?.setAccessibilityLabel("Herdly menu")
        let menu = NSMenu()
        let heading = NSMenuItem(title: "Herdly", action: nil, keyEquivalent: "")
        menu.addItem(heading)
        for (title, action) in [("Show Herdly controls", #selector(showControls)),
                                ("Send test notification", #selector(sendTest)),
                                ("Dismiss test notification", #selector(dismissTest)),
                                ("Mute sound", #selector(toggleMute)),
                                ("Quit Herdly", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if action == #selector(toggleMute) { item.state = muted ? .on : .off }
            menu.addItem(item)
        }
        notchDisplayMenu = NotchDisplayMenu(choices: { [weak self] in self?.updateNotchDisplayChoices() },
                                            select: { [weak self] in self?.setNotchDisplayPreference($0) })
        let displayItem = NSMenuItem(title: "Show notch on", action: nil, keyEquivalent: "")
        displayItem.submenu = notchDisplayMenu.menu
        menu.insertItem(displayItem, at: menu.indexOfItem(withTitle: "Show Herdly controls") + 1)
        status.menu = menu
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window shadow: its rim would outline the panel and break the fusion with the menu bar.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Notch(model: self, claudeSetup: claude))
        panel.onEscape = { [weak self] in self?.escape() }
        panel.onMoveSelection = { [weak self] in self?.moveSelection($0) ?? false }
        panel.onReturn = { [weak self] in
            guard let self else { return false }
            return self.pressQuestionCardKey(.primary) || self.activateSelectedRow()
        }
        panel.onDigit = { [weak self] in self?.pressQuestionCardKey(.digit($0)) ?? false }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        // Display connect, disconnect, and rearrangement re-place the one panel; queue state is untouched.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.updateNotchDisplayChoices(); self?.refresh() } }
        // Mouse-move monitoring needs no Accessibility permission. Only a change of the top-edge
        // state refreshes, so ordinary pointer movement elsewhere costs one comparison.
        let pointerMoved: () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let onEdge = self.panel.isVisible
                    && NotchHover.pointerTouchesTopEdge(of: self.panel.frame, pointer: NSEvent.mouseLocation)
                guard onEdge != self.pointerOnTopEdge else { return }
                self.pointerOnTopEdge = onEdge
                // Refreshes now and, on leaving, again once the hover grace has passed.
                self.setHovering(self.hovering)
            }
        }
        pointerMonitors = [NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in pointerMoved() },
                           NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in pointerMoved(); return event }]
            .compactMap { $0 }
        scheduleRefreshTimer(RefreshCadence.active)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }
        daemonClient.onMessage = { [weak self] message in
            guard let self else { return }
            _ = self.daemonBook.apply(message: message, now: Date().timeIntervalSince1970)
        }
        daemonClient.onDisconnect = { [weak self] in self?.daemonBook.disconnect() }
        if let mode = previewMode { seedPreview(mode) }
        updateNotchDisplayChoices()
        refresh()
        refreshSetup()
        // A first/unconfigured launch should explain setup immediately. Once state
        // exists, refresh can keep the normal quiet launch behavior.
        if previewMode == nil, launchAtLogin.shouldOpenUnconfiguredControls,
           !FileManager.default.fileExists(atPath: setupRoots.stateURL.path) { showControls() }
        if CommandLine.arguments.contains("--smoke-test") {
            precondition(QuestionCardStyle.fontsRegistered, "Bundled question fonts must load from the packaged app")
            showControls()
            precondition(controls?.isVisible == true && controls?.contentView != nil)
            // The title follows the selected pane (DESIGN.md, Settings Window) and starts as "Herdly".
            precondition(controls?.title.isEmpty == false && controls?.styleMask.contains(.resizable) == true)
            precondition(controls?.frame.width ?? 0 >= 720 && controls?.frame.height ?? 0 >= 540)
            precondition(status.button?.title == "S" && status.menu?.items.count == 7)
            precondition(status.menu?.item(withTitle: "Show notch on")?.submenu === notchDisplayMenu.menu)
            dismissControls(animated: false)
            precondition(controls?.isVisible == false)
            presentControls(animated: false)
            precondition(controls?.isVisible == true && controls?.alphaValue == 1)
            print("Herdly controls-window smoke check passed.")
            app.terminate(nil)
        }
        writePlacementProbeAndQuitIfRequested()
        printSetupProbeAndQuitIfRequested()
        startGhosttyControls()
    }

    /// Restores every host's remembered switch, then resumes remembered Ghostty controls or offers
    /// them once on the first interactive launch. Preview and probe launches never read the saved
    /// choices, so every host stays off.
    private func startGhosttyControls() {
        guard previewMode == nil,
              !["--smoke-test", "--setup-probe", "--placement-probe"].contains(where: CommandLine.arguments.contains) else { return }
        observeGhosttyLaunches()
        let defaults = UserDefaults.standard
        restoreHostSwitches(defaults)
        startITerm2()
        startTerminalApp()
        startWezTerm()
        let stored = defaults.object(forKey: Companion.ghosttyEnabledKey) as? Bool
        if stored == true {
            ghosttyEnabled = true
            appliedGhosttyEnabled = true
            ghosttyFocusState = .checking
            probeGhosttyAccess()
            return
        }
        // Controls are off: a silent check only restores a remembered denial's Settings guidance.
        Task { @MainActor in
            let access = await Task.detached { GhosttyAutomationPermission.check(askIfNeeded: false) }.value
            if access == .denied, !ghosttyEnabled { ghosttyAccess = access }
        }
        guard GhosttyControlsPolicy.shouldOfferFirstRun(offeredBefore: defaults.bool(forKey: Companion.ghosttyOfferedKey),
                                                        storedPreference: stored) else { return }
        // Ask after launch finishes, on the controls window, so the notch keeps refreshing.
        DispatchQueue.main.async { [weak self] in self?.offerGhosttyControls() }
    }

    /// Every switch but Ghostty's, whose Automation flow below restores it. Writes back herdr's
    /// starting position on the first launch after the upgrade (`TerminalHostSwitches.restore`).
    private func restoreHostSwitches(_ defaults: UserDefaults) {
        var stored: [TerminalHost: Bool] = [:]
        for host in TerminalHost.allCases {
            if let value = defaults.object(forKey: host.defaultsKey) as? Bool { stored[host] = value }
        }
        let restored = TerminalHostSwitches.restore(stored: stored)
        for (host, value) in restored.toPersist { defaults.set(value, forKey: host.defaultsKey) }
        var switches = restored.switches
        switches.set(.ghostty, on: false)
        hostSwitches = switches
    }

    /// Herdly's own explanation before macOS's one-time Automation prompt, so Not Now leaves that
    /// prompt unused. A sheet, not `runModal`, so the refresh timer and approval cards keep running.
    private func offerGhosttyControls() {
        showControls()
        guard let window = controls else { return }
        let alert = NSAlert()
        alert.messageText = "Use Ghostty with Herdly?"
        alert.informativeText = "Herdly can bring you back to the exact Ghostty tab for a Codex or Claude session, and relay the option you pick for a question. macOS will ask you to allow Herdly to control Ghostty. You can change this later in Settings › Terminals."
        alert.addButton(withTitle: "Enable Ghostty Controls")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                // Recorded on an answer, so quitting with the sheet open offers it again next launch.
                UserDefaults.standard.set(true, forKey: Companion.ghosttyOfferedKey)
                guard response == .alertFirstButtonReturn else { return }
                self.ghosttyEnabled = true
                self.ghosttyChanged(true)
            }
        }
    }

    private func observeGhosttyLaunches() {
        guard ghosttyLaunchObserver == nil else { return }
        ghosttyLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let launched = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard launched == GhosttyAutomationPermission.bundleIdentifier else { return }
            Task { @MainActor in
                guard let self, self.ghosttyEnabled, !self.ghosttyPermissionVerified else { return }
                self.probeGhosttyAccess()
            }
        }
    }

    /// Asks macOS for Automation consent to Ghostty, showing its prompt when no decision exists.
    /// Only a denial switches controls off; Ghostty not running keeps them on until it launches.
    /// Tab scans wait while a check is open, so the prompt never races an `osascript` deadline.
    private func probeGhosttyAccess() {
        guard ghosttyEnabled, !probingGhosttyAccess else { return }
        probingGhosttyAccess = true
        let generation = ghosttyAccessGeneration
        Task { @MainActor in
            let access = await Task.detached { GhosttyAutomationPermission.check(askIfNeeded: true) }.value
            probingGhosttyAccess = false
            // The user switched controls while the check was open, or Ghostty launched during a
            // check that found it absent: check again for the current state.
            if generation != ghosttyAccessGeneration {
                probeGhosttyAccess()
                return
            }
            if access == .ghosttyNotRunning, GhosttyAutomationPermission.ghosttyIsRunning,
               ghosttyStartupRetries < 10 {
                // Ghostty is listed before it accepts Apple Events; retry once a second, ten times
                // at most, then wait for the next launch or toggle.
                ghosttyStartupRetries += 1
                probingGhosttyAccess = true   // tab scans keep waiting through the pause
                try? await Task.sleep(for: .seconds(1))
                probingGhosttyAccess = false
                probeGhosttyAccess()
                return
            }
            ghosttyStartupRetries = 0
            applyGhosttyAccess(access)
            refresh()
        }
    }

    private func applyGhosttyAccess(_ access: GhosttyAutomationAccess) {
        guard ghosttyEnabled else { return }
        ghosttyAccess = access
        switch GhosttyControlsPolicy.outcome(for: access) {
        case .verified:
            ghosttyPermissionVerified = true
            nextGhosttyScan = 0
        case .disable:
            ghosttyEnabled = false
            ghosttyChanged(false)
        case .awaitGhostty:
            ghosttyPermissionVerified = false
            ghosttyFocusState = .unknown
        case .unverified:
            break
        }
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
        let chosen = NotchDisplaySelection.choose(displays: displays, pointer: pointer, current: currentDisplayID, interacting: false,
                                                  preference: notchDisplayPreference)
        func rect(_ r: CGRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        let report: [String: Any] = [
            "displays": displays.map { ["id": Int($0.id), "frame": rect($0.frame), "top_inset": Double($0.topInset), "physical_notch": $0.hasPhysicalNotch,
                                        "built_in": $0.isBuiltIn, "persistent_id": $0.persistentID ?? NSNull(), "name": $0.name ?? NSNull()] },
            "display_preference": notchDisplayPreference.pin.map { ["pinned_id": $0.id, "pinned_name": $0.name] as Any } ?? "follow_pointer",
            "pointer": ["x": pointer.x, "y": pointer.y],
            "chosen_display": chosen.map { Int($0.id) } ?? NSNull(),
            "collapsed_frame": chosen.map { rect(NotchPlacement.frame(on: $0, expanded: false, rows: 0, extraRows: false, wing: UsageStripReadouts.wingWidth(usageStripReadouts))) } ?? NSNull(),
            "expanded_frame_three_rows": chosen.map { rect(NotchPlacement.frame(on: $0, expanded: true, rows: 3, extraRows: false, wing: UsageStripReadouts.wingWidth(usageStripReadouts))) } ?? NSNull(),
            "five_hour_shown": usageStripReadouts.contains { $0.source == .codex && $0.caption != nil },
            "usage_readouts": usageStripReadouts.count,
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
            // The UUID survives reboots and reconnects, unlike the display number, so a pin keys on it.
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            }
            return NotchDisplay(id: number.uint32Value, frame: screen.frame, topInset: screen.safeAreaInsets.top,
                                housingWidth: housing, menuBarHeight: menuBar,
                                isBuiltIn: CGDisplayIsBuiltin(number.uint32Value) != 0,
                                persistentID: uuid, name: screen.localizedName)
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
        updateNotchDisplayChoices()
        if controls == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 780),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Herdly"
            // Each pane draws its own title row beside the traffic lights, as in System Settings;
            // the window title stays set for the Window menu and VoiceOver.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = SettingsStyle.windowBackground
            // An empty unified toolbar gives the title bar its full 52pt height, so the window
            // buttons line up with each pane's title row.
            window.toolbar = NSToolbar(identifier: "HerdlySettings")
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: 720, height: 600)
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
        var next = agentQueue
        let items = queue.items
        let keeping = Set(items.map { item -> AgentAttentionID in
            switch item.kind {
            case .actionableRequest, .handedBackRequest: return .approval(CodexAttentionAdapter.approval(from: item.request!).id)
            case .question: return .question(CodexAttentionAdapter.question(from: item.question!).id)
            case .completion: return .outcome(CodexAttentionAdapter.outcome(from: item.completion!).id)
            case .running: return .running(CodexAttentionAdapter.running(from: item.running!).id)
            }
        })
        next.reconcile(source: .codex, sourceScope: CodexAttentionAdapter.sourceScope, keeping: keeping)
        let requests = items.compactMap { $0.request }
        let questions = items.compactMap { $0.question }
        let completions = items.compactMap { $0.completion }
        let running = items.compactMap { $0.running }
        next.apply(CodexAttentionAdapter.observations(requests: requests, questions: questions,
                                                      completions: completions, running: running), now: now)
        next.expire(at: now)
        if next != agentQueue { agentQueue = next }
    }

    /// Hook records accumulate without bound, so Herdly deletes expired ones itself: at launch and
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

    /// Keeps the titles of `inventories`, read at `takenAt`, for each host Herdly may still contact,
    /// unless a newer reading is already held. Called by the host scans with reads they took anyway.
    func recordHostTitles(_ inventories: [TerminalHost: TerminalHostInventory], takenAt: Double) {
        hostTitleReadings = TerminalHostTitles.merged(hostTitleReadings, inventories: inventories, takenAt: takenAt,
                                                      contactable: Set(TerminalHost.allCases.filter(hostSwitches.mayContact)))
    }

    /// Forgets readings of hosts Herdly may no longer contact, so one switched back on starts unknown.
    private func dropUncontactableHostTitles() {
        hostTitleReadings = hostTitleReadings.filter { hostSwitches.mayContact($0.key) }
    }

    /// How many running Codex TUIs' process ancestry reaches each host (`CodexCLIProcesses.hostReached`),
    /// from `ps -axo pid=,args=` output already read; every host, without bound, when it could not be
    /// read, since none can be ruled out. Walks only processes whose command line names Codex. Off the
    /// main actor.
    nonisolated static func codexReach(processList: String?) -> [TerminalHost: Int] {
        guard let processList else { return Dictionary(uniqueKeysWithValues: TerminalHost.allCases.map { ($0, Int.max) }) }
        let ancestries = CodexCLIProcesses.candidatePIDs(processList: processList).map { pid -> [ProcessAncestor] in
            let chain = HerdrProcessTree.ancestry(of: pid)
            guard chain.first?.pid == pid else { return [] }
            return chain.map { ProcessAncestor(command: $0.command, bundleIdentifier: TerminalApps.appBundleIdentifier(of: $0.pid)) }
        }
        return CodexCLIProcesses.hostsReached(by: ancestries)
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
        let herdrTitles = herdrPaneTitlesReader()
        // The other hosts' latest titles (#265). Whether each terminal app runs comes from macOS, and
        // which hosts a Codex TUI runs under from the process list and its ancestry: none contacts a host.
        dropUncontactableHostTitles()
        let switches = hostSwitches
        let hostReadings = hostTitleReadings
        let lastSeen = lastSeenHosts
        let appsRunning = Set(TerminalHost.terminals.filter { TerminalApps.isRunning($0) })
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
        let branchDirectories = Set(agentQueue.items(at: observationNow).compactMap(rowDirectory(for:)))
        let rolloutCache = rolloutCache
        let hookCache = hookCache
        let claudeRecordCaches = claudeRecordCaches
        Task { @MainActor in
            let result = await Task.detached {
                let processList = ProcessList.listing()
                let claudeScans = claudeRoots.map { root in
                    ClaudeObservationReader.scan(events: root.events, sourceScope: root.scope,
                                                 installationID: root.installationID, observingSince: observingSince,
                                                 now: observationNow,
                                                 cache: claudeRecordCaches[root.events.path] ?? ClaudeRecordCache())
                }
                let otherHosts = TerminalHostTitles.forScan(switches: switches, latest: hostReadings, appsRunning: appsRunning,
                                                            codexReach: Companion.codexReach(processList: processList),
                                                            now: Date().timeIntervalSince1970)
                let reminders = ReminderReader.scan(events: events, rollouts: rolloutRoot, ghostty: inventory,
                                                    knownCLISessions: known, daemonThreads: daemonThreads,
                                                    herdrTitles: herdrTitles(), otherHosts: otherHosts,
                                                    ghosttyOn: switches.isOn(.ghostty), lastSeenHosts: lastSeen,
                                                    rolloutCache: rolloutCache, hookCache: hookCache)
                // The desktop reader reads the same window, so it starts from the reminder scan's reads.
                let desktop = DesktopEventReader.read(from: events, cache: reminders.hookCache)
                return (reminders,
                 desktop.events,
                 readStateURL.flatMap(DesktopReadStateReader.read), ThreadNameReader.read(namesURL) ?? [:],
                 CodexUsageReader.latest(root: rolloutRoot),
                 SessionDiscovery.candidates(root: rolloutRoot, now: Date().timeIntervalSince1970),
                 processList.map { CodexCLIProcesses.isRunning(processList: CodexCLIProcesses.arguments(processList: $0)) } ?? false,
                 claudeInventoryRoots.map { root in
                     ClaudeSetupDetection.activeSessionInventory(root: root.root, capabilities: root.capabilities,
                                                                 observedAt: observationNow)
                 },
                 claudeScans.map(\.scan),
                 claudeRoots.map { root in
                     ClaudeQuestionStore.pending(in: root.events, installationID: root.installationID,
                                                 observingSince: observingSince, now: observationNow)
                         .map { (request: $0, events: root.events, sourceScope: root.scope) }
                 },
                 claudeUsageRoots.reduce(into: [String: ClaudeUsageReading]()) { result, root in
                     if let reading = ClaudeUsageReader.latest(root: root.directory, sourceScope: root.scope, now: observationNow) {
                         result[root.scope] = reading
                     }
                 },
                 branchDirectories.reduce(into: [String: String]()) { result, directory in
                     result[directory] = GitBranchReader.branch(forDirectory: directory)
                 },
                 claudeScans.map(\.cache),
                 reminders.hookCache.merging(desktop.cache))
            }.value
            let scan = result.0
            let desktopEvents = result.1
            let readState = result.2
            let claudeObservationScans = result.8
            guard eventsPath.isEmpty || eventsPath == events.path else { scanning = false; refresh(); return }
            self.rolloutCache = scan.rolloutCache
            self.hookCache = result.13
            // Roots no longer connected drop out with their caches.
            self.claudeRecordCaches = Dictionary(zip(claudeRoots.map(\.events.path), result.12)) { _, latest in latest }
            let previousAgent = Set(agentQueue.items(at: Date().timeIntervalSince1970).map(\.id))
            let scanNow = Date().timeIntervalSince1970
            var approvalReceiptWork: [ClaudeApprovalReceiptWork] = []
            for (root, claudeScan) in zip(claudeRoots, claudeObservationScans) {
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
            var scannedAgent = agentQueue
            for claudeScan in claudeObservationScans {
                scannedAgent.apply(claudeScan, now: scanNow)
            }
            if scannedAgent != agentQueue { agentQueue = scannedAgent }
            // An unavailable root keeps its last results, as it keeps its queue state; a root no
            // longer connected drops them.
            let connectedScopes = Set(claudeObservationScans.map(\.sourceScope))
            var turnResults = claudeTurnResults.filter { connectedScopes.contains($0.key.session.sourceScope) }
            for claudeScan in claudeObservationScans where claudeScan.available {
                turnResults = turnResults.filter { $0.key.session.sourceScope != claudeScan.sourceScope }
                turnResults.merge(claudeScan.results) { _, latest in latest }
            }
            if turnResults != claudeTurnResults { claudeTurnResults = turnResults }
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
                                     observedIDs: observedClaudeQuestionIDs(claudeObservationScans))
            // A root can contain many pending rendezvous files. Writes happen off the main actor;
            // the completion rechecks the scan generation, root identity, and request deadline.
            publishClaudeQuestionReceipts(receiptWork)
            var inventoriedAgent = agentQueue
            for inventory in result.7 {
                inventoriedAgent.apply(inventory, now: Date().timeIntervalSince1970)
                for session in inventory.sessions {
                    let identity = AgentSessionIdentity(source: .claude, sourceScope: inventory.sourceScope,
                                                        session: session.sessionID, surface: .cli)
                    if !session.name.isEmpty, claudeSessionNames[identity] != session.name {
                        claudeSessionNames[identity] = session.name
                    }
                    if let directory = session.directory, claudeSessionDirectories[identity] != directory {
                        claudeSessionDirectories[identity] = directory
                    }
                }
            }
            if inventoriedAgent != agentQueue { agentQueue = inventoriedAgent }
            if threadNames != result.3 { threadNames = result.3 }
            if usage != result.4 { usage = result.4 }
            if claudeUsage != result.10 { claudeUsage = result.10 }
            if gitBranches != result.11 { gitBranches = result.11 }
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
            if endedSessions != scan.endedSessions { endedSessions = scan.endedSessions }
            cliSessions = scan.cliSessions.union(discoveredCLI)
            daemonCLISessions = scan.cliSessions.intersection(daemonThreads)
            liveCLI = scan.cliState.liveSessions.union(discoveredCLI)
            cliLivenessRead = true
            knownCLISessions.formUnion(scan.titledCLISessions)
            lastSeenHosts.merge(scan.surfaceHosts) { _, latest in latest }
            codexSessionsAwaitingInventory = scan.awaitingHostInventories
            let previous = Set(queue.items.map(\.id))
            // A receipt found on disk is not a verified live interaction: such a request enters handed
            // back and, when a real helper receipt exists, a no-decision record releases it to Codex at once.
            var scannedQueue = queue
            let unverified = scannedQueue.apply(scan: scan, desktopEvents: desktopEvents, now: Date().timeIntervalSince1970)
            scannedQueue.apply(discovered: discovered)
            if scannedQueue != queue { queue = scannedQueue }
            acknowledgeCodexCompletions(Array(CodexReplyAcknowledgment.acknowledged(
                queue.items.compactMap(\.completion), events: scan.cliEvents)))
            replyTurnStarts = ReplyTurnStarts.latest(cliEvents: scan.cliEvents, hookEvents: desktopEvents)
            applyDesktopReadState(readState, enabled: readStateURL != nil, desktopThreads: scan.desktopOriginatedSessions)
            for request in unverified where ApprovalReceipts.existing(for: request.id, in: events) != nil {
                _ = ApprovalStore.publish(ApprovalDecisionRecord(requestID: request.id, decision: .noDecision,
                                                                 decidedAt: Date().timeIntervalSince1970), in: events)
            }
            // Companion receipt: the deadline starts here, including for requests queued behind others.
            let receipted = ApprovalReceipts.issue(scan.awaitingReceipt, in: events, cliSessions: scan.cliSessions,
                                                   now: Date().timeIntervalSince1970)
            if !receipted.isEmpty { queue.recordReceipts(receipted, now: Date().timeIntervalSince1970) }
            queue.dropDesktopDuplicates(terminalSessions: cliSessions)
            syncAgentQueueWithCodex(now: Date().timeIntervalSince1970)
            agentQueue.dropDesktopDuplicates(codexTerminalSessions: Set(cliSessions.map(\.uuidString)))
            let current = queue.items
            let currentAgent = agentQueue.items(at: Date().timeIntervalSince1970)
            let newAgentItems = currentAgent.filter { !previousAgent.contains($0.id) }
            let newAgentOutcomes = newAgentItems.compactMap(\.outcome)
            let newAgentQuestions = newAgentItems.compactMap(\.question)
            // #323: a restored or pre-launch result goes to the queue without a card or a sound.
            let freshAgentOutcomes = newAgentOutcomes.filter { ResultPop.isFresh($0, launchedAt: Companion.launchedAt) }
            let freshAgentQuestions = newAgentQuestions.filter { $0.arrivedAt >= Companion.launchedAt }
            let newAgentRequests = newAgentItems.filter {
                ($0.kind == .actionableApproval || $0.kind == .handedBackApproval)
            }
            let freshAgentRequests = newAgentRequests.filter { $0.arrivedAt >= Companion.launchedAt }
            let newItems = current.filter { !previous.contains($0.id) }
            let newCompletions = newItems.compactMap(\.completion)
            for completion in newCompletions where !completion.uncertain {
                let turn = TurnIdentity(session: completion.session, turn: completion.turn)
                let preview = scan.completionPreviews[turn].map(CompletionPreviewAvailability.available)
                    ?? .unavailable("Codex did not provide a readable final response for this turn.")
                if completionPreviews[completion.id] != preview { completionPreviews[completion.id] = preview }
                let context = scan.turnContexts[turn] ?? SpotlightRecordContext()
                if spotlightContexts[.completion(completion.id)] != context { spotlightContexts[.completion(completion.id)] = context }
            }
            let liveCompletionIDs = Set(current.compactMap(\.completion).map(\.id))
            let livePreviews = completionPreviews.filter { liveCompletionIDs.contains($0.key) }
            if livePreviews.count != completionPreviews.count { completionPreviews = livePreviews }
            let liveItemIDs = Set(current.map(\.id))
            let liveContexts = spotlightContexts.filter { liveItemIDs.contains($0.key) }
            if liveContexts.count != spotlightContexts.count { spotlightContexts = liveContexts }
            for item in current where item.kind != .completion {
                let turn = item.request?.turn ?? item.question?.turn ?? item.running?.turn
                if let turn, let context = scan.turnContexts[TurnIdentity(session: item.session, turn: turn)],
                   spotlightContexts[item.id] != context {
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
            // A dismiss of a card that is not showing would still publish and re-render the notch (#306).
            if !currentAgent.contains(where: { $0.approval != nil }) {
                if reminderPresentation.pending || reminderPresentation.expanded { reminderPresentation.dismiss() }
            } else if newItems.contains(where: { $0.kind == .handedBackRequest || $0.kind == .actionableRequest })
                    || !freshAgentRequests.isEmpty {
                reminderPresentation.enqueue()
            } else if !newAgentRequests.isEmpty, !reminderPresentation.pending {
                reminderPresentation = Attention(restored: true)
            }
            if !currentAgent.contains(where: { $0.outcome != nil }), completionPresentation.pending || completionPresentation.expanded {
                completionPresentation.dismiss()
            }
            // A question posed before this launch is shown but does not pop or chime: the user may
            // already be looking at it, and Herdly was not observing when it arrived.
            if !currentAgent.contains(where: { $0.question != nil }) {
                if questionPresentation.pending || questionPresentation.expanded { questionPresentation.dismiss() }
            } else if !freshAgentQuestions.isEmpty { questionPresentation.enqueue() }
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

    /// Runs `refresh` every `interval` (RefreshCadence, #301); an unchanged interval keeps the
    /// current timer, so a refresh never pushes the next one back.
    private func scheduleRefreshTimer(_ interval: Double) {
        guard timer == nil || refreshInterval != interval else { return }
        timer?.invalidate()
        refreshInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        // A result row's finished Open folds the panel back; collapsing refreshes on its own (#322).
        if settleRowOpenFold() { return }
        scanReminders()
        pruneEventRecords()
        // Published values are written back only when they change: each write re-renders the notch,
        // and an unchanged one on every tick and scan was most of Herdly's drawing cost (#306).
        var expired = queue
        expired.expire(at: Date().timeIntervalSince1970)
        if expired != queue { queue = expired }
        pruneAnswerProgress()
        pruneReplyProgress()
        pruneRowNotes()
        pruneClaudeReplies()
        if previewMode == nil {
            // A waiting question on a thread Herdly has not subscribed to yet: ask for the list now.
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
        checkITerm2Visits()
        checkWezTerm()
        checkScheduledTabHosts()
        checkOpenAvailability()
        // App identity only: no window contents, task titles, or accessibility queries.
        // App activation affects notification delivery, never the notch's visibility.
        let codexForeground = previewMode == nil ? desktopAdapter.codexForeground() : false
        // Each published value below is written only when it changes: an unchanged write still makes
        // SwiftUI re-render and lay out the notch, which cost more than the scans on every tick (#301).
        if desktopForeground != (codexForeground == true) { desktopForeground = codexForeground == true }
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
        var reminder = reminderPresentation
        var firstReminderPresentation = reminder.update(codexForeground: !agentItems.contains {
            $0.kind == .actionableApproval || $0.kind == .handedBackApproval
        }, hovering: interacting,
                                                                    now: ProcessInfo.processInfo.systemUptime)
        let ghosttyFocus: CompletionFocus
        switch ghosttyFocusState {
        case .disabled: ghosttyFocus = .disabled
        case .checking: ghosttyFocus = .checking
        // A Ghostty reading in hand: whether the session's own tab is the one in front is
        // `ResultPop`'s call below; a reading with no tab selected means Ghostty is not in front (#323).
        case .known: ghosttyFocus = .away
        case .unknown: ghosttyFocus = .unknown
        }
        let ghosttySnapshot: GhosttySnapshot? = if case .known(let snapshot) = ghosttyFocusState { snapshot } else { nil }
        func completionIsEligible(_ item: AgentAttentionItem) -> Bool {
            guard let outcome = item.outcome, !outcome.uncertain else { return false }
            guard outcome.session.source == .claude else {
                guard let session = UUID(uuidString: outcome.session.session) else { return false }
                let source: AttentionSource = outcome.session.surface == .cli ? .cli : .desktop
                guard CompletionVisibility.allows(source: source, codexForeground: codexForeground,
                                                 ghosttyFocus: ghosttyFocus) else { return false }
                return ResultPop.ghosttyAllows(source: source, session: session, ghosttyEnabled: ghosttyEnabled,
                                               live: liveCLI, snapshot: ghosttySnapshot,
                                               reading: ghosttyFocus == .checking)
            }
            // ADR 0016's one rule for Claude too: no pop while its own Ghostty tab is in front.
            return ResultPop.claudeGhosttyAllows(outcome.session, ghosttyEnabled: ghosttyEnabled,
                                                 liveSessionsByScope: liveClaudeSessions,
                                                 inventoryAvailable: claudeInventoryAvailable,
                                                 configuredScopes: Set(configuredClaudeNavigationRoots().map { $0.root.path }),
                                                 snapshot: ghosttySnapshot)
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
        let agentSpotlightAvailable = notchPresentation.acceptsAgentSpotlight(interacting: interacting,
                                                                             draftInProgress: notchDraftInProgress, now: now)
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
        if completionPresentation != nextCompletionPresentation { completionPresentation = nextCompletionPresentation }

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
        var question = questionPresentation
        var firstQuestionPresentation = question.update(
            codexForeground: questionForegroundGate,
            hovering: interacting, now: ProcessInfo.processInfo.systemUptime)
        let selectedReminder = selectedFreshAgent.flatMap { id in freshRequests.first { $0.id == id } }
        if selectedReminder != nil, reminder.presented, !firstReminderPresentation {
            reminder.enqueue()
            firstReminderPresentation = reminder.update(
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
            if completionPresentation != nextCompletionPresentation { completionPresentation = nextCompletionPresentation }
        }
        if firstCompletionPresentation, let id = selectedCompletion?.id {
            freshAgentCompletionIDs.remove(id)
        }
        if selectedQuestion != nil, question.presented, !firstQuestionPresentation {
            question.enqueue()
            firstQuestionPresentation = question.update(
                codexForeground: questionForegroundGate, hovering: interacting,
                now: ProcessInfo.processInfo.systemUptime)
        }
        if firstQuestionPresentation, let id = selectedQuestion?.id {
            freshAgentQuestionIDs.remove(id)
        }
        if reminderPresentation != reminder { reminderPresentation = reminder }
        if questionPresentation != question { questionPresentation = question }
        let selectedPresentationWasFresh = (selectedReminder != nil && firstReminderPresentation)
            || (selectedCompletion != nil && firstCompletionPresentation)
            || (selectedQuestion != nil && firstQuestionPresentation)
        if selectedPresentationWasFresh, let id = selectedFreshAgent {
            notchPresentation.present(id, now: now, duration: cardOpenDuration)
        }
        if let mode = previewMode, Self.spotlightPreviewModes.contains(mode), let id = previewSpotlightAgent { notchPresentation.present(id, now: now) }
        let resolvedPresentation = notchPresentation.update(interacting: interacting, draftInProgress: notchDraftInProgress,
                                                            now: now, legacyPopup: attention.expanded, queued: liveAgentIDs)
        let spotlightItem: AgentAttentionID? = if case let .agentSpotlight(id) = resolvedPresentation { id } else { nil }
        switch previewMode {
        case "expanded", "empty-expanded", "empty-not-connected", "row-note", "row-note-reply": presentationMode = .queue
        case "clicked-approval", "clicked-approval-long", "clicked-claude-approval":
            let mode = previewSpotlightAgent.map(NotchPresentationMode.clickedCard) ?? .collapsed
            if presentationMode != mode { presentationMode = mode }
        case "collapsed", "empty-collapsed": presentationMode = .collapsed
        case _ where Self.spotlightPreviewModes.contains(previewMode ?? ""):
            let mode = spotlightItem.map(NotchPresentationMode.agentSpotlight) ?? .collapsed
            if presentationMode != mode { presentationMode = mode }
        default:
            if presentationMode != resolvedPresentation { presentationMode = resolvedPresentation }
        }
        if expanded != presentationMode.expanded {
            expanded = presentationMode.expanded
            if !expanded {
                workingFoldOpen = false
                openQueueFolds = []
                closeOpenRunningRow()
            }
        }
        reconcileSelection()
        let actionableApproval = agentItems.contains { $0.kind == .actionableApproval }
            || queue.items.contains { $0.request?.state == .actionable }
        scheduleRefreshTimer(RefreshCadence.interval(presenting: presentationMode != .collapsed,
                                                     interacting: interacting || pointerOnTopEdge,
                                                     actionableApproval: actionableApproval))
        // Sound follows the card opening: the frame below is set in the same pass, so the chime
        // lands as the card lands. Muted, restored, and foreground cases never reach here.
        let selectedAgentSound = (selectedCompletion != nil && firstCompletionPresentation)
            || (selectedQuestion != nil && firstQuestionPresentation)
        if CompletionSound.shouldPlay(firstPresentation: selectedAgentSound, muted: muted) {
            NSSound(named: completionSound)?.play()
        }
        guard DesktopVisibility.isVisible(hasActivity: count > 0, codexForeground: codexForeground) else {
            panel.orderOut(nil)
            hovering = false
            targetFrame = .zero
            contentHeight = 0
            openHeightWaitingSince = nil
            currentDisplayID = nil
            return
        }
        // One panel, one queue: the display is chosen by the documented rule (the pinned display when
        // there is one) and frozen while the user is interacting, so controls never move away
        // mid-action. Only geometry changes here.
        guard let display = NotchDisplaySelection.choose(displays: Companion.attachedDisplays(), pointer: NSEvent.mouseLocation,
                                                         current: currentDisplayID, interacting: interacting && panel.isVisible,
                                                         preference: notchDisplayPreference)
        else { panel.orderOut(nil); currentDisplayID = nil; return }
        currentDisplayID = display.id
        let profile = DisplayProfile(hasCameraHousing: display.hasPhysicalNotch)
        if activeProfile != profile { activeProfile = profile }
        let wing = UsageStripReadouts.wingWidth(usageStripReadouts)
        let center = appearance.effectiveCenterLabel(on: profile) == .off ? 0 : NotchPlacement.centerLabelWidth
        let width = appearance.panelWidth
        let layout = NotchPlacement.strip(on: display, expanded: expanded, wing: wing, centerLabel: center, width: width)
        if stripLayout != layout { stripLayout = layout }
        let singleCard = presentationMode.showsSingleCard
        let rows = presentationMode.showsAll ? orderedAgentAttentionItems.count : (singleCard ? 1 : 0)
        let openHeight: NotchOpenHeight
        if expanded {
            let since = contentHeight > 0 ? nil : (openHeightWaitingSince ?? now)
            openHeightWaitingSince = since
            openHeight = NotchOpenHeight.choose(measured: contentHeight, waitingSince: since ?? now, now: now)
        } else {
            openHeightWaitingSince = nil
            openHeight = .estimate
        }
        var frame = switch openHeight {
        case .measured(let height):
            NotchPlacement.frame(on: display, expanded: expanded, contentHeight: height, wing: wing, centerLabel: center, width: width)
        case .awaitingMeasurement:
            NotchPlacement.frame(on: display, expanded: expanded, contentHeight: 0, wing: wing, centerLabel: center, width: width)
        case .estimate:
            NotchPlacement.frame(on: display, expanded: expanded, rows: rows,
                                 extraRows: attention.pending && (presentationMode.showsAll || !singleCard),
                                 wing: wing, centerLabel: center, width: width)
        }
        // With no menu bar and no housing the strip rests above the screen edge and slides in for
        // the pointer at the top edge or an open panel, so it does not cover a full-screen app.
        if NotchTuck.isTucked(display: display, pointer: NSEvent.mouseLocation, interacting: interacting, open: expanded) {
            frame = NotchTuck.tuckedFrame(frame)
        }
        switch NotchFrameSync.action(target: frame, lastTarget: targetFrame, actual: panel.frame,
                                     animating: frameAnimation != nil) {
        case .none:
            break
        case .restoreDrifted:
            // The window server moved the panel (a display slept, woke, or was reconfigured).
            panel.setFrame(frame, display: true)
        case .moveToNewTarget:
            let opening = frame.height > panel.frame.height
            targetFrame = frame
            if reduceMotion || !panel.isVisible {
                frameAnimation = nil
                panel.setFrame(frame, display: true)
            } else {
                // Only the newest animation's completion clears the flag; a superseded one may finish first.
                let animation = UUID()
                frameAnimation = animation
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = opening ? 0.16 : 0.2
                    context.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                } completionHandler: { [weak self] in
                    Task { @MainActor in
                        if self?.frameAnimation == animation { self?.frameAnimation = nil }
                    }
                }
            }
        }
        // Never makes the panel key: an automatic notification does not take input from the user's app.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// React to pointer entry without waiting for the background polling interval. Pointer exit
    /// keeps the core hover grace, then refreshes exactly when that grace expires.
    /// Saves one display kind's strip and queue choices and redraws the notch with them.
    func setAppearance(_ appearance: NotchAppearance, for profile: DisplayProfile) {
        guard appearances[profile] != appearance else { return }
        appearances[profile] = appearance
        appearance.save(profile: profile) { key, value in UserDefaults.standard.set(value, forKey: key) }
        refresh()
    }

    /// Chooses the card sound and plays it once so the choice is heard.
    func setCompletionSound(_ name: String) {
        completionSound = name
        UserDefaults.standard.set(name, forKey: "completionSound")
        NSSound(named: name)?.play()
    }

    /// The system sounds offered in Settings, by name, sorted.
    nonisolated static var systemSoundNames: [String] {
        let folder = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let names = files.map { $0.deletingPathExtension().lastPathComponent }
        return names.isEmpty ? [defaultSound] : names.sorted()
    }

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

    /// One Escape, from the panel or a text field (D6): an opened running row closes (#319); a clicked
    /// card returns to the queue; otherwise the panel collapses. None of them dismisses anything.
    func escape() {
        // A clicked card replaces the queue, so an open running row and a clicked card never coexist.
        if escapeOpenRunningRow() { return }
        switch notchPresentation.escape() {
        case .backToQueue: refresh()
        case .collapse: collapse()
        }
    }

    /// Opens one approval or question from the queue as its own card (D5, D18). Its deadline is untouched.
    func openCard(_ id: AgentAttentionID) {
        guard notchPresentation.openCard(id) else { return }
        refresh()
    }

    /// ‹ Queue: leaves the clicked card for the queue without dismissing anything.
    func backToQueue() {
        notchPresentation.backToQueue()
        refresh()
    }

    /// Approve, Deny or Send on a clicked card returns to the queue at once (D10); the row note
    /// carries the outcome from there. The caller refreshes.
    func leaveClickedCard(after id: AgentAttentionID) {
        notchPresentation.leaveCard(after: id)
    }

    /// Keeps the selection on a row that is still on screen; it clears when the queue closes, its
    /// row leaves, or its fold closes, so Return never acts on a hidden row.
    private func reconcileSelection() {
        var selection = queueSelection
        selection.reconcile(rows: selectableRows)
        if selection != queueSelection { queueSelection = selection }
        reconcileOpenRunningRow()
    }

    /// Returns false when the queue is not shown or has no rows, so the arrow key goes on to AppKit.
    func moveSelection(_ direction: QueueRowSelection.Direction) -> Bool {
        let rows = selectableRows
        guard !rows.isEmpty else { return false }
        var selection = queueSelection
        selection.move(direction, in: rows)
        if selection != queueSelection { queueSelection = selection }
        return true
    }

    /// Hands a digit or Return to the one question card on screen (the spotlight or a clicked card).
    /// False when no question card is shown, so the key goes on to the queue or AppKit.
    func pressQuestionCardKey(_ key: QuestionCardKeyPress.Key) -> Bool {
        guard expanded, let id = presentationMode.singleCard, case .question = id else { return false }
        questionCardKeyPress = QuestionCardKeyPress(key: key, card: id, serial: (questionCardKeyPress?.serial ?? 0) + 1)
        return true
    }

    /// Return on the selected row does what a click on it does (`activateRow`): approvals and
    /// questions open as their clicked card, a working row opens or closes in place (#319), and a
    /// result row opens its session (#322). An unreachable result row does nothing, so the key is
    /// not handled.
    func activateSelectedRow() -> Bool {
        reconcileSelection()
        guard let selected = queueSelection.selected else { return false }
        return activateRow(selected)
    }

    /// Collapses the panel and hands keyboard input back to the app the user was using.
    func collapse() {
        rowOpenFold.cancel()
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
    /// Recomputes the display picker from the attached displays. Called at launch, on display
    /// changes, and when the controls window or the menu opens, so it stays current while the panel
    /// is hidden and placement is not running.
    @discardableResult
    func updateNotchDisplayChoices() -> NotchDisplayChoices {
        let choices = NotchDisplayChoices(displays: Companion.attachedDisplays(), preference: notchDisplayPreference)
        if notchDisplayChoices != choices { notchDisplayChoices = choices }
        return choices
    }
    /// Saves the choice and re-places the panel at once. Only placement changes: the queue,
    /// presentations, and approval deadlines are untouched.
    func setNotchDisplayPreference(_ preference: NotchDisplayPreference) {
        notchDisplayPreference = preference
        if let pin = preference.pin {
            UserDefaults.standard.set(pin.id, forKey: "notchDisplayPinID")
            UserDefaults.standard.set(pin.name, forKey: "notchDisplayPinName")
        } else {
            UserDefaults.standard.removeObject(forKey: "notchDisplayPinID")
            UserDefaults.standard.removeObject(forKey: "notchDisplayPinName")
        }
        updateNotchDisplayChoices()
        refresh()
    }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    func openTestTask() {
        guard !openingTask else { return }
        openingTask = true
        let id = taskID
        Task { @MainActor in
            _ = await desktopAdapter.open(taskID: id)
            openingTask = false
            // Navigation never calls dismissTest or writes the saved completion flag.
        }
    }
    /// Acknowledges desktop completions the Codex desktop app itself no longer flags as unread.
    /// Only ever removes items; a missing or unparsable file changes nothing and says so.
    private func applyDesktopReadState(_ snapshot: DesktopReadStateSnapshot?, enabled: Bool, desktopThreads: Set<UUID>) {
        guard enabled else { desktopReadState = .off; return }
        guard let snapshot else {
            desktopReadState = .unavailable(fileName: Companion.desktopReadStateURL.lastPathComponent)
            return
        }
        let queued = queue.items.compactMap(\.completion)
        let acknowledged = DesktopReadAcknowledgment.acknowledged(queued, snapshot: snapshot, desktopThreads: desktopThreads)
        acknowledgeCodexCompletions(Array(acknowledged))
        let written = Date(timeIntervalSince1970: snapshot.modifiedAt).formatted(date: .omitted, time: .standard)
        let tested = CodexSetupRequirements.minimumDesktopVersion
        let version = setupCapabilities.desktopVersion ?? "unknown"
        desktopReadState = .readable(summary: "file written \(written), \(snapshot.unread.count) unread threads"
            + (acknowledged.isEmpty ? "." : ", cleared \(acknowledged.count) completion\(acknowledged.count == 1 ? "" : "s") this scan.")
            + (version == tested ? "" : " Format tested with desktop \(tested); installed \(version)."))
    }

    /// Persists unacknowledged completions and acknowledgments atomically whenever they change.
    func saveCompletions() {
        guard previewMode == nil else { return }
        let snapshot = agentQueue.snapshot
        guard snapshot != savedSnapshot else { return }
        if AttentionSnapshotStore.save(snapshot, to: Companion.snapshotURL) { savedSnapshot = snapshot }
    }

    /// Acknowledges Codex completions in both queues. `agentQueue` keeps outcomes through
    /// `syncAgentQueueWithCodex`, so dismissing them from `queue` alone leaves their cards showing.
    func acknowledgeCodexCompletions(_ ids: [CompletionIdentity]) {
        for id in ids {
            queue.dismiss(.completion(id))
            agentQueue.dismiss(.outcome(CodexAttentionAdapter.outcomeID(for: id)))
        }
    }

    func codexSession(_ identity: AgentSessionIdentity) -> UUID? {
        guard identity.source == .codex else { return nil }
        return UUID(uuidString: identity.session)
    }

    func codexTurn(_ identity: AgentTurnIdentity) -> AttentionCompletion? {
        guard let session = codexSession(identity.session), let turn = UUID(uuidString: identity.turn) else { return nil }
        return queue.items.compactMap(\.completion).first { $0.session == session && $0.turn == turn }
    }

    /// Ends the Ghostty tabs' visit interval and dwell run as of `at` (an Open, or controls switched off).
    func resetGhosttyVisits(at: Double) {
        ghosttyVisits.reset(at: at)
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
        guard let request = codexCLIRequest(for: approval) else {
            refresh()
            return
        }
        decide(request, as: decision)
    }

    /// Whether this approval's source takes Approve and Deny from Herdly at all (#320): a Codex CLI
    /// request the queue still holds as actionable, or a Claude request with a verified live helper
    /// route. It has no deadline and reads no clock, so a card drawn between the deadline and the
    /// recorded hand-back keeps its controls in place; `ApprovalCardReading` disables them from the
    /// card's own clock. Display only: `decideAgent` still refuses anything past its deadline
    /// (`ApprovalDecisionPolicy.accepts`, `canDecideAgent`).
    func canDecide(_ item: AgentAttentionItem) -> Bool {
        guard item.kind == .actionableApproval, let approval = item.approval else { return false }
        if approval.identity.session.source == .claude { return hasClaudeDecisionRoute(approval) }
        return codexCLIRequest(for: approval)?.state == .actionable
    }

    /// The queue's own copy of a Codex CLI approval, by its request id; nil for any other source.
    private func codexCLIRequest(for approval: AgentApproval) -> AttentionRequest? {
        guard approval.identity.session.source == .codex,
              approval.identity.session.surface == .cli,
              let requestID = UUID(uuidString: approval.identity.call) else { return nil }
        return queue.items.compactMap(\.request).first { $0.id == requestID }
    }

    /// A Claude approval Herdly may decide now: a verified live route (`hasClaudeDecisionRoute`)
    /// and neither the request's nor its receipt's deadline passed.
    func canDecideAgent(_ approval: AgentApproval) -> Bool {
        let now = Date().timeIntervalSince1970
        guard approval.expiresAt > now, hasClaudeDecisionRoute(approval),
              let requestID = approval.hookRequestID,
              let receipt = verifiedClaudeApprovalReceipts[requestID],
              receipt.expiresAt > now else { return false }
        return true
    }

    /// The deadline-free part of `canDecideAgent`: an actionable Claude CLI request whose helper is
    /// live, whose root is connected, with no decision pending, and with a receipt verified for this
    /// exact root and installation.
    private func hasClaudeDecisionRoute(_ approval: AgentApproval) -> Bool {
        guard approval.identity.session.source == .claude,
              approval.identity.session.surface == .cli,
              approval.state == .actionable,
              let requestID = approval.hookRequestID,
              liveClaudeApprovalIDs.contains(requestID),
              let root = claude.roots.first(where: { $0.url.standardizedFileURL.path == approval.identity.session.sourceScope }),
              case .connected = root.status,
              !root.eventsPath.isEmpty,
              !pendingClaudeApprovalDecisions.contains(requestID),
              verifiedClaudeApprovalReceipts[requestID] != nil,
              let installationID = root.plan?.installationID,
              verifiedClaudeApprovalRoots[requestID] == claudeApprovalRootKey(
                  sourceScope: approval.identity.session.sourceScope,
                  events: URL(fileURLWithPath: root.eventsPath, isDirectory: true),
                  installationID: installationID) else {
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
            refresh()
            return
        }
        let now = Date().timeIntervalSince1970
        liveClaudeApprovalIDs.remove(requestID)
        // Remove direct controls immediately. The detached worker reports mailbox publication and
        // the helper's output acknowledgment separately; a crash leaves Claude's native prompt
        // available without leaving a second direct control.
        agentQueue.apply(.approval(approval.with(state: .handedBack)), now: now)
        updateRowNote(.record(.sending), for: .approval(approval.id), userAction: true)
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
        dismissAgents([id])
    }
    /// Dismisses exactly the listed items, each as its own Dismiss would, then saves once. Items
    /// not listed stay queued, including results that move into Earlier after the list was taken.
    func dismissAgents(_ ids: [AgentAttentionID]) {
        for id in ids {
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
        }
        syncAgentQueueWithCodex(now: Date().timeIntervalSince1970)
        saveCompletions()
        refresh()
    }
    /// Whether a row looks stuck enough to offer Remove (`AgentAttentionQueue.isRemovable`).
    func canRemoveAgentRow(_ item: AgentAttentionItem) -> Bool {
        agentQueue.isRemovable(item, at: Date().timeIntervalSince1970)
    }
    /// Removes a stuck Claude running, waiting, or status-unavailable row. Claude is not contacted;
    /// the row returns on new activity (`AgentAttentionQueue.remove`).
    func removeAgentRow(_ item: AgentAttentionItem) {
        guard canRemoveAgentRow(item) else { return }
        agentQueue.remove(item.id)
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
    /// What Herdly can see right now about reaching a finished session: the daemon's own loaded
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
                                        endedSessions: endedSessions, workingSessions: working,
                                        terminalRoutes: terminalReplyRoutes)
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
        return SpotlightDetails.make(item: item, context: context, response: response, home: NSHomeDirectory())
    }

    /// The folder a row's session works in, when Herdly has seen one; used only to group the queue
    /// by project. Rows without one are grouped under "Other".
    func projectFolder(for item: AgentAttentionItem) -> String? {
        if let project = item.approval?.details?.project, !project.isEmpty { return project }
        return spotlightDetails(for: item)?.directory?.full
    }

    /// The absolute working directory a row's session reported, for its identity line and branch:
    /// a request's project or turn directory, otherwise the exact turn's directory, or for Claude the
    /// session's directory from its inventory. Nil when Herdly has seen none, or when the value is a
    /// name rather than a path.
    func rowDirectory(for item: AgentAttentionItem) -> String? {
        let details = spotlightDetails(for: item)
        let candidates = [item.approval?.details?.project, details?.request?.directory?.full, details?.directory?.full,
                          claudeSessionDirectories[item.session]]
        return candidates.compactMap { $0 }.first { $0.hasPrefix("/") }
    }

    /// "project @ branch" for a row in the profile's label format, when its working directory is
    /// known. A request that names its project but no path still shows that name, without a branch.
    func rowPlace(for item: AgentAttentionItem) -> String? {
        let format = appearance.labelFormat
        guard let directory = rowDirectory(for: item) else {
            return QueueRowPresentation.place(directory: item.approval?.details?.project, branch: nil, format: format)
        }
        return QueueRowPresentation.place(directory: directory, branch: gitBranches[directory], format: format)
    }

    func spotlightDetails(for item: AgentAttentionItem) -> SpotlightDetails? {
        // A Claude result reads its exact turn's prompt and last message; other Claude rows have none.
        if item.session.source == .claude {
            return item.outcome.flatMap { claudeTurnResults[$0.identity]?.details }
        }
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

    /// The one approval card body (#320), for the spotlight and the clicked card alike: Codex's
    /// exact-turn context when Herdly has it, otherwise the approval's own details placed in the
    /// session's directory, so a Claude request reads the same way. Nil for every other row.
    func approvalCard(for item: AgentAttentionItem) -> SpotlightRequest? {
        guard let approval = item.approval else { return nil }
        if let request = spotlightDetails(for: item)?.request { return request }
        return SpotlightRequest(approval: approval, contextDirectory: rowDirectory(for: item), home: NSHomeDirectory())
    }

    func codexCompletion(for outcome: AgentOutcome) -> AttentionCompletion? { codexTurn(outcome.identity) }

    /// One Send on a completion card. The reply starts a new turn on that exact thread through the
    /// daemon, after re-reading the queue and the target as they are right now. Sending does not
    /// acknowledge the completion, and a card that has sent one reply never sends another.
    func sendReply(to completion: AttentionCompletion, text: String) {
        guard !replying else { return }
        let current = queue.items.compactMap(\.completion).first { $0.id == completion.id }
        let plan = SessionReplySending.prepare(completion: current, availability: replyAvailability,
                                               progress: reply(for: completion), text: text,
                                               at: Date().timeIntervalSince1970)
        switch plan.outcome {
        case .refused:
            refresh()
        case let .sending(next):
            guard previewMode == nil else {
                refresh()
                return
            }
            // ADR 0017: the daemon does not hold the thread; type the reply into the bound tab.
            if let terminal = plan.terminal {
                if terminal.pane.host == .wezTerm {
                    sendWezTermCodexReply(completion, send: terminal, progress: next)
                } else {
                    sendTypedCodexReply(completion, send: terminal, progress: next)
                }
                return
            }
            guard let params = plan.params else { return }
            replying = true
            replyProgress[completion.id] = next
            refresh()
            daemonClient.call(SessionReplyRequest.method, params: params) { [weak self] accepted, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.replying = false
                    let progress = self.reply(for: completion)
                    self.replyProgress[completion.id] = accepted
                        ? progress.recordingSent(at: Date().timeIntervalSince1970)
                        : progress.recordingFailure(SessionReplyPolicy.daemonRefused(error))
                    self.refresh()
                }
            }
        }
    }

    /// Keeps a card's reply only while its completion is queued, and lets a sent one reach its final
    /// state: confirmed by the session working again or by a turn start recorded after the send (a
    /// turn that finished between scans, #271), or unconfirmed once the window passes.
    private func pruneReplyProgress() {
        guard !replyProgress.isEmpty else { return }
        let queued = Set(queue.items.compactMap { $0.completion?.id })
        let working = queue.sessionsInTurn
        let now = Date().timeIntervalSince1970
        let next = replyProgress.filter { queued.contains($0.key) }
            .mapValues { $0.observing(sessionWorking: working.contains($0.completion.session),
                                      latestTurnStart: replyTurnStarts[$0.completion.session], at: now) }
        if next != replyProgress { replyProgress = next }
    }
    func decide(_ request: AttentionRequest, as decision: ApprovalDecision) {
        // Re-read the queue's current copy: a request handed back since the row rendered must not be answered.
        guard !eventsPath.isEmpty else { refresh(); return }
        guard let current = queue.items.compactMap(\.request).first(where: { $0.identity == request.identity }) else {
            refresh(); return
        }
        guard ApprovalDecisionPolicy.accepts(current, decision: decision, now: Date().timeIntervalSince1970) else {
            refresh(); return
        }
        let record = ApprovalDecisionRecord(requestID: request.id, decision: decision,
                                            decidedAt: Date().timeIntervalSince1970)
        guard ApprovalStore.publish(record, in: URL(fileURLWithPath: eventsPath)) else {
            refresh()
            return
        }
        // A Codex CLI request leaves the queue as soon as its decision is written, so its row carries
        // no note (an accepted decision, #312); a clicked card on it returns to the queue explicitly.
        leaveClickedCard(after: .approval(CodexAttentionAdapter.approval(from: current).id))
        queue.dismiss(.request(request.identity))
        refresh()
    }

    func handBackApproval(_ request: AttentionRequest) {
        guard request.state == .actionable else { return }
        let now = Date().timeIntervalSince1970
        if !eventsPath.isEmpty {
            let events = URL(fileURLWithPath: eventsPath)
            // A failed write leaves the helper waiting for its own deadline; the row loses its controls regardless.
            ApprovalStore.publish(ApprovalDecisionRecord(requestID: request.id, decision: .noDecision, decidedAt: now), in: events)
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
        guard ghosttyEnabled, !probingGhosttyAccess, ghosttyAccess != .ghosttyNotRunning, !checkingGhostty, !openingTask, now >= nextGhosttyScan,
              !cliItems.isEmpty || !queue.items.isEmpty || !liveCLI.isEmpty || !knownCLISessions.isEmpty
                || !liveClaudeSessions.isEmpty
                || orderedAgentAttentionItems.contains(where: { $0.session.source == .claude }) else { return }
        checkingGhostty = true
        // Keep the last verified snapshot while a re-check is in flight. Resetting to
        // `.checking` every poll collapsed an already presented CLI popup early.
        if case .known = ghosttyFocusState {} else { ghosttyFocusState = .checking }
        nextGhosttyScan = now + 2
        let configuredRoots = configuredClaudeNavigationRoots()
        // ADR 0016: frontmost comes from macOS, read as the scan starts; Ghostty's own answer must agree.
        let scanStart = Date().timeIntervalSince1970
        let frontmost = TerminalApps.frontmostHost()
        Task { @MainActor in
            let observedAt = Date().timeIntervalSince1970
            let result = await Task.detached {
                let shared = GhosttyNavigation.scheduledSnapshot(notBefore: scanStart)
                let inventories = configuredRoots.map { root in
                    ClaudeSetupDetection.activeSessionInventory(root: root.root, capabilities: root.capabilities,
                                                                observedAt: observedAt)
                }
                return (shared.snapshot, inventories, shared.takenAt)
            }.value
            let snapshot = result.0
            // A snapshot another scheduled scan read is dated by when that read began (ADR 0016).
            let snapshotAt = result.2
            if ghosttyEnabled, let snapshot {
                if !ghosttyPermissionVerified { ghosttyPermissionVerified = true }
                ghosttyFocusState = .known(snapshot)
                ghosttyInventoryAt = snapshotAt
                // ADR 0016: one visit and dwell rule for Codex and Claude tabs alike. Only completions are
                // acknowledged, and only when the session's own bound tab is the one visible.
                ghosttyVisits.record(TerminalVisibilityScan(takenAt: snapshotAt,
                                                            reading: TerminalVisibility.ghostty(snapshot, frontmost: frontmost)))
                let queued = cliItems
                for session in Set(queued.map(\.session)) {
                    let completions = queued.filter { $0.session == session }
                        .map(TerminalCompletionCandidate.init)
                    let target = GhosttyVisitTargets.codex(session, live: liveCLI, snapshot: snapshot)
                    acknowledgeCodexCompletions(Array(ghosttyVisits.acknowledged(completions, target: target)))
                }
                let liveByScope = Dictionary(uniqueKeysWithValues: result.1.map { scan in
                    (scan.sourceScope, scan.available
                        ? scan.sessions.filter { $0.kind == .interactive }.map(\.sessionID)
                        : [])
                })
                let inventoryAvailable = Dictionary(uniqueKeysWithValues: result.1.map { ($0.sourceScope, $0.available) })
                let currentScopes = Set(configuredClaudeNavigationRoots().map { $0.root.path })
                let outcomes = agentQueue.snapshot.outcomes.filter { $0.session.source == .claude && $0.session.surface == .cli }
                for identity in Set(outcomes.map(\.session)) {
                    let completions = outcomes.filter { $0.session == identity }
                        .map(TerminalCompletionCandidate.init)
                    let target = GhosttyVisitTargets.claude(identity, liveSessionsByScope: liveByScope,
                                                            inventoryAvailable: inventoryAvailable,
                                                            configuredScopes: currentScopes, snapshot: snapshot)
                    for id in ghosttyVisits.acknowledged(completions, target: target) { agentQueue.dismiss(.outcome(id)) }
                }
                saveCompletions()
            } else if ghosttyEnabled {
                ghosttyVisits.record(TerminalVisibilityScan(takenAt: observedAt, reading: .unknown))
                let generation = ghosttyAccessGeneration
                let access = await Task.detached { GhosttyAutomationPermission.check(askIfNeeded: false) }.value
                if generation == ghosttyAccessGeneration, ghosttyEnabled {
                    // A denial switches controls off and remembers it; Ghostty not running keeps them
                    // on and waits for its launch instead of polling. Otherwise the scan failed for a
                    // passing reason: tabs are unknown until the next scan, and controls stay on.
                    // A result from before the user switched controls applies to nothing.
                    switch GhosttyControlsPolicy.afterFailedScan(access) {
                    case .applyAccess: applyGhosttyAccess(access)
                    case .retry: ghosttyFocusState = .unknown
                    }
                }
            }
            checkingGhostty = false
            refresh()
        }
    }

    /// Takes the open content's measured height and resizes the panel to it at once rather than on
    /// the next refresh tick, so an opening panel grows straight to its height (`NotchOpenHeight`).
    func reportContentHeight(_ height: CGFloat) {
        guard abs(contentHeight - height) > 0.5 else { return }
        contentHeight = height
        guard expanded, height > 0 else { return }
        // Reported during layout; resizing waits until the pass has finished.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
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
        if let width = Self.argumentValue(for: "--preview-width").flatMap(PanelWidth.init(rawValue:)) {
            for profile in DisplayProfile.allCases { appearances[profile]?.panelWidth = width }
        }
        let now = Date().timeIntervalSince1970
        queue = AttentionQueue(observingSince: now)
        agentQueue = AgentAttentionQueue()

        usage = CodexUsageReading(weekly: CodexUsageWindow(usedPercent: 37, resetsAt: now + 3 * 86400),
                                  fiveHour: CodexUsageWindow(usedPercent: 40, resetsAt: now + 2 * 3600))
        claudeUsage = ["~/.claude": ClaudeUsageReading(sourceScope: "~/.claude", sessionID: "00000000-0000-4000-8000-000000000001",
                                                       fiveHour: ClaudeUsageWindow(usedPercentage: 62, resetsAt: now + 3 * 3600),
                                                       sevenDay: ClaudeUsageWindow(usedPercentage: 18, resetsAt: now + 5 * 86400),
                                                       observedAt: now)]
        if mode.hasPrefix("empty") { return }
        let working = UUID(uuidString: "01A0916C-337B-4E2A-9D11-0000000000A1")!
        let finished = UUID(uuidString: "7C2F5D10-88AA-4B7E-8E0B-0000000000B2")!
        let asking = UUID(uuidString: "3E9D1B44-51C3-4F0A-9A77-0000000000C3")!
        let details = ApprovalDetails(taskName: "fix auth bug", project: "herdly", action: "Run command",
                                      command: "swift test --filter AuthTests", reason: "Verify the token refresh fix before committing.")
        let request = AttentionRequest(id: UUID(), source: .cli, session: asking, turn: UUID(), arrivedAt: now - 5, details: details)
        let completion = AttentionCompletion(source: .desktop, session: finished, turn: UUID(), arrivedAt: now - 2)
        let running = AttentionRunning(source: .cli, session: working, turn: UUID(), arrivedAt: now - 60)
        let question = AttentionQuestion(source: .cli, session: working, turn: UUID(), callID: "call_preview", arrivedAt: now - 3,
                                         prompts: [QuestionPrompt(id: "packages", header: "Packages",
                                                                  question: "Which stays should recalculated package prices apply to?",
                                                                  options: ["Standard stays only (Recommended)", "All stays, including group bookings"], isOther: true),
                                                   QuestionPrompt(id: "payments", header: "Payments",
                                                                  question: "For paid or partly paid stays, how should recalculated totals affect money already collected?",
                                                                  options: ["Adjust balance only (Recommended)", "Unpaid stays only"], isOther: true)])
        let desktopQuestion = AttentionQuestion(source: .desktop, session: finished, turn: UUID(), callID: "call_preview_desktop",
                                                arrivedAt: now - 4,
                                                prompts: [QuestionPrompt(header: "Storage",
                                                                         question: "Where should the cache live?",
                                                                         options: ["Application Support (Recommended)", "Caches", "Next to the app"])])
        // The expanded preview also shows an Earlier result and the identity line's place.
        let earlier = AttentionCompletion(source: .cli, session: UUID(uuidString: "9D3A6E21-4B5C-4D7E-8F90-0000000000E5")!,
                                          turn: UUID(), arrivedAt: now - 42 * 60)
        queue.recordReceipts([request], now: now)
        queue.apply(completions: mode == "expanded" ? [completion, earlier] : [completion], running: [running], now: now)
        queue.apply(questions: [question, desktopQuestion])
        if mode == "expanded" {
            let project = NSHomeDirectory() + "/Developer/herdly"
            spotlightContexts[.completion(completion.id)] = SpotlightRecordContext(workingDirectory: project)
            spotlightContexts[.running(running.id)] = SpotlightRecordContext(workingDirectory: project)
            gitBranches = [project: "feat/queue-row-identity"]
            threadNames = [working: "Usage strip tweaks", finished: "Weekly bars"]
        }
        // The CLI sample is reachable through the daemon in the preview: a seeded request whose
        // second question takes a typed answer, so the card shows both controls.
        _ = daemonBook.apply(message: ["jsonrpc": "2.0", "id": 1, "method": "item/tool/requestUserInput",
                                       "params": ["threadId": working.uuidString, "turnId": question.turn.uuidString,
                                                  "itemId": "call_preview",
                                                  "questions": question.prompts.map { prompt in
                                                      ["id": prompt.id ?? "", "header": prompt.header ?? "", "question": prompt.question ?? "",
                                                       "isOther": true, "options": prompt.options.map { ["label": $0, "description": ""] }] as [String: Any]
                                                  }]], now: now)
        if mode.hasPrefix("spotlight-question") {
            threadNames[working] = "Check Paper MCP access"
            let project = NSHomeDirectory() + "/bscale/strata"
            spotlightContexts[.question(question.id)] = SpotlightRecordContext(workingDirectory: project)
            gitBranches[project] = "main"
            answerProgress[question.id] = QuestionAnswerProgress(call: question.id).recordingDraft(question: 0, answer: .option(0))
            if mode == "spotlight-question-edit" || mode == "spotlight-question-review" { previewViewedQuestion = 0 }
            if mode == "spotlight-question-review" {
                daemonBook.disconnect()
                _ = relayLedger.spend(question.id, question: 0, route: .ghostty)
            }
            if mode == "spotlight-question-unavailable" {
                daemonBook.disconnect()
                answerProgress[question.id] = QuestionAnswerProgress(call: question.id)
                    .startingSend(question: 0).recordingFailure("This question is no longer available here. Answer it in Codex.")
            }
            if mode == "spotlight-question-long" {
                answerProgress[question.id] = QuestionAnswerProgress(call: question.id)
                    .recordingDraft(question: 0, answer: .text(String(repeating: "A longer answer to review. ", count: 6)))
            }
        }
        if let request = daemonBook.request(for: question), answerProgress[question.id] != nil {
            daemonDraftRequests[question.id] = request
        }
        completionPresentation = Attention(restored: true)
        reminderPresentation = Attention(restored: true)
        questionPresentation = Attention(restored: true)
        syncAgentQueueWithCodex(now: now)
        // A Claude call with several questions: Claude's answer control takes one, so the card is
        // read-only and leads with where to answer it.
        let claudeSession = AgentSessionIdentity(source: .claude, sourceScope: "~/.claude",
                                                 session: "00000000-0000-4000-8000-000000000002", surface: .cli)
        agentQueue.apply(.question(AgentQuestion(session: claudeSession, turn: "preview-turn", call: "toolu_preview", arrivedAt: now - 1,
                                                 prompts: [QuestionPrompt(header: "Player", question: "Who is the primary player, and when do they play?",
                                                                          options: ["Curious casual, short break", "Geo-game enthusiast", "Learner / classroom"]),
                                                           QuestionPrompt(header: "Purpose", question: "What is this prototype for: what does success look like?",
                                                                          options: ["Portfolio / learning", "User-test the concept", "Seed of a real product"])])),
                         now: now)
        previewSpotlightAgent = .outcome(CodexAttentionAdapter.outcome(from: completion).id)
        if mode.hasPrefix("spotlight-question") { previewSpotlightAgent = .question(CodexAttentionAdapter.question(from: question).id) }
        if mode == "spotlight-result" || mode == "spotlight-result-markdown" || mode == "row-note-reply" {
            // #323: a CLI result's card (9NU): a message past five lines, the turn's prompt, and a
            // reachable reply field; `row-note-reply` shows its row after a send, with the reply's note.
            let notes = UUID(uuidString: "2B7C9E10-3D4F-4A5B-8C6D-0000000000F6")!
            let result = AttentionCompletion(source: .cli, session: notes, turn: UUID(), arrivedAt: now - 1)
            queue.apply(completions: [completion, result], running: [running], now: now)
            let project = NSHomeDirectory() + "/Developer/herdly"
            threadNames[notes] = "Release notes"
            gitBranches[project] = "docs/release-notes"
            spotlightContexts[.completion(result.id)] = SpotlightRecordContext(
                workingDirectory: project, prompt: "Draft the 1.4 release notes from the merged PRs since 1.3.")
            let message = ["Drafted the 1.4 notes in docs/release-notes.md: three fixes, the new sprite picker, and the tmux",
                           "support marked as preview. I left the version date blank for you to fill in.",
                           "", "Fixes:", "- Snapshots write atomically.", "- Approval deadlines no longer drift.",
                           "- Question cards keep their drafts.", "", "Run `make release-notes` to regenerate."].joined(separator: "\n")
            // `spotlight-result-markdown`: a reply whose table, emphasis, and code read as formatting.
            let markdown = ["Rotate in this order, across **Production and Dev**:", "",
                            "| Priority | Secrets | Why |", "|---|---|---|",
                            "| **1 — Database access** | PostgreSQL password / `DATABASE_URL` | Could expose or alter customer data. |",
                            "| **2 — Login and internal access** | `BETTER_AUTH_SECRET`, `INTERNAL_SECRET` | Could allow impersonation. |",
                            "| **3 — Infrastructure access** | Private registry GitHub token | Could enable malicious deploys. |",
                            "", "## Then", "1. Redeploy each service.", "2. Run:", "", "```", "make verify-secrets", "```",
                            "> Old tokens stay valid until revoked."].joined(separator: "\n")
            if let preview = CompletionPreview(mode == "spotlight-result-markdown" ? markdown : message) { completionPreviews[result.id] = .available(preview) }
            syncAgentQueueWithCodex(now: now)
            if mode == "row-note-reply" {
                replyProgress[result.id] = SessionReplyProgress(completion: result.id)
                    .startingSend(text: "Use today's date and commit it", at: now).recordingSent(at: now)
            }
            previewSpotlightAgent = .outcome(CodexAttentionAdapter.outcome(from: result).id)
        }
        if mode == "spotlight-claude-multiselect" {
            let sample = AgentQuestion(session: claudeSession, turn: "preview-multi", call: "toolu_multi", arrivedAt: now,
                                       prompts: [QuestionPrompt(header: "Checks", question: "Which checks should run before handing this back?",
                                                                options: ["Core suite (Recommended)", "Package smoke check", "Visual review"], multiSelect: true)],
                                       helperRequestID: "preview-helper")
            agentQueue.apply(.question(sample), now: now)
            previewSpotlightAgent = .question(sample.id)
        }
        if mode == "spotlight-claude-question" {
            previewSpotlightAgent = .question(AgentCallIdentity(session: claudeSession, turn: "preview-turn", call: "toolu_preview"))
        }
        if mode == "clicked-claude-approval" {
            // A Claude request that names no command (D9); with no live helper it cannot be decided here.
            let approval = AgentApproval(session: claudeSession, turn: "preview-turn", call: "toolu_preview_approval",
                                         arrivedAt: now - 4, details: ApprovalDetails(action: "Bash"))
            agentQueue.apply(.approval(approval), now: now)
            previewSpotlightAgent = .approval(approval.id)
        }
        if mode == "spotlight-approval" || mode == "spotlight-handed-back" || mode == "clicked-approval"
            || mode == "clicked-approval-long" || mode == "row-note" {
            // One request in the spotlight's own reading order: Codex's ask lifted from its tool input,
            // a command the card already shows, and a home-relative working directory.
            let handedBack = mode == "spotlight-handed-back"
            let fetching = UUID(uuidString: "5B1E7A20-6C4D-4F8E-A3B9-0000000000D4")!
            let input = #"{"command":"git fetch origin","description":"Allow fetching remote main so I can update this checkout?"}"#
            // Nine lines, so the card's command box caps at six and offers "Show full command".
            let command = mode == "clicked-approval-long"
                ? (1...9).map { "swift test --filter ApprovalCardTests/case\($0) --parallel --num-workers 4" }.joined(separator: " && \\\n  ")
                : "git fetch origin"
            let fetch = AttentionRequest(id: UUID(), source: .cli, session: fetching, turn: UUID(),
                                         arrivedAt: handedBack ? now - 130 : now - 4,
                                         expiresAt: handedBack ? now - 100 : now + 26,
                                         state: handedBack ? .handedBack : .actionable,
                                         details: ApprovalDetails(taskName: "Pull from remote main",
                                                                  project: NSHomeDirectory() + "/Developer/herdly",
                                                                  action: "Bash", command: command,
                                                                  longText: mode == "clicked-approval-long" ? nil : input))
            queue.recordReceipts([fetch], now: now)
            syncAgentQueueWithCodex(now: now)
            previewSpotlightAgent = .approval(CodexAttentionAdapter.approval(from: fetch).id)
            if mode == "row-note", let id = previewSpotlightAgent {
                rowNotes.record(.sentUnconfirmed, for: id, pending: rowNotePendingIDs)
                queueSelection = QueueRowSelection(selected: id)
            }
        }
        if mode.hasPrefix("spotlight-question") || mode.hasPrefix("spotlight-claude-") {
            let selected = agentQueue.items(at: now).first { $0.id == previewSpotlightAgent }?.question
            queue = AttentionQueue(observingSince: now)
            agentQueue = AgentAttentionQueue()
            if let selected {
                if selected.identity.session.source == .codex { queue.apply(questions: [question]) }
                agentQueue.apply(.question(selected), now: now)
            }
            ghosttyEnabled = true
            claudeUsage = [:]
            usage = CodexUsageReading(weekly: CodexUsageWindow(usedPercent: 34, resetsAt: now + 86400), fiveHour: nil)
            for profile in DisplayProfile.allCases {
                appearances[profile]?.usage = .weeklyOnly
                appearances[profile]?.centerLabel = .off
            }
        }

    }

    func desktopReadStateChanged(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "desktopReadStateEnabled")
        if !enabled { desktopReadState = .off }
        nextScan = 0
    }
    /// The Settings switch of a host without Automation access (every host but Ghostty, which goes
    /// through `ghosttyChanged`). Remembered at once; herdr's gate is re-evaluated now.
    func setHostSwitch(_ host: TerminalHost, on: Bool) {
        guard host != .ghostty, hostSwitches.isOn(host) != on else { return }
        hostSwitches.set(host, on: on)
        if previewMode == nil { UserDefaults.standard.set(on, forKey: host.defaultsKey) }
        if host == .herdr { scanHerdr() }
        if host == .iTerm2 { iTerm2SwitchChanged(on) }
        if host == .terminalApp { terminalAppSwitchChanged(on) }
        if host == .wezTerm { wezTermSwitchChanged(on) }
        // tmux is contacted only while a terminal is on too (ADR 0014), so any switch can move its gate.
        tmuxSwitchChanged(hostSwitches.isOn(.tmux))
        zellijSwitchChanged(hostSwitches.isOn(.zellij))
        dropUncontactableHostTitles()
    }

    func ghosttyChanged(_ enabled: Bool) {
        guard enabled != appliedGhosttyEnabled else { return }
        appliedGhosttyEnabled = enabled
        ghosttyStartupRetries = 0
        UserDefaults.standard.set(enabled, forKey: Companion.ghosttyEnabledKey)
        ghosttyAccessGeneration += 1
        // A denial stays visible after controls switch off; enabling checks again.
        if enabled { ghosttyAccess = nil }
        ghosttyPermissionVerified = false
        ghosttyFocusState = enabled ? .checking : .disabled
        if !enabled { resetGhosttyVisits(at: Date().timeIntervalSince1970) }
        if enabled {
            nextGhosttyScan = 0
            probeGhosttyAccess()
        }
    }
}

let app = NSApplication.shared
let companion = Companion()
app.setActivationPolicy(.accessory)
app.delegate = companion
app.run()
