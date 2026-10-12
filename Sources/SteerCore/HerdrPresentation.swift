import Foundation

// The agreed herdr presentation (docs/product.md, "Agreed herdr presentation"; issue #127).
// Every typed reason Open or question relay can be unavailable for a herdr session maps to exactly
// one of four groups the user can act on, each with one fixed card line. The exact reason is kept
// for diagnostics only and never reaches the card.

/// The four user-actionable groups of herdr unavailable reasons.
public enum HerdrReasonGroup: Equatable, Hashable, Sendable {
    /// Ghostty does not expose each terminal's `tty`, so herdr's tab cannot be identified.
    case ghosttyTooOld
    /// herdr's integration for this agent is missing or not current.
    case integration(HerdrAgentKind)
    /// A split, several herdr clients, a named herdr session, or a Ghostty tab in another window.
    case layoutNotSupported
    /// Everything else.
    case generic
}

/// One reason a herdr session's Open (or relay) is unavailable, from any of the typed sources.
///
/// Extension point: when another path gains its own typed failure enum, add one case wrapping it
/// here, one case in `group`'s switch and one in `diagnostic`'s. Callers then route the failure
/// through `HerdrPresentation.cardLine(for:agent:)` like any other reason.
public enum HerdrUnavailableCause: Equatable, Sendable {
    /// The scan-time binding of the session (`Companion.herdrBinding(for:)`).
    case session(HerdrSessionUnavailable)
    /// ADR 0011's join of herdr's client TTY to one Ghostty terminal. `matched` is not a reason
    /// and maps to `generic` only so the switch stays total; callers never present it.
    case ghosttyTTY(GhosttyTTYJoin)
    /// The Ghostty bundle's scripting dictionary does not declare `tty`.
    case ghosttyTTYUnsupported
    /// A click-time Open that failed one of ADR 0011's steps (`Companion.herdrOpenFailure(for:)`).
    case open(HerdrOpenFailure)
    /// Why ADR 0010's key relay cannot answer a Codex question. For diagnostics: the card presents
    /// an unrelayed question through Open's cause (`HerdrPresentation.unrelayedQuestionLine`), never
    /// this one, so the group only keeps the mapping total.
    case relay(HerdrQuestionRelayUnavailable)

    public var group: HerdrReasonGroup {
        switch self {
        case .session(let reason): HerdrPresentation.group(reason)
        case .ghosttyTTY(let join): HerdrPresentation.group(join)
        case .ghosttyTTYUnsupported: .ghosttyTooOld
        case .open(let failure): HerdrPresentation.group(failure)
        case .relay(let reason): HerdrPresentation.group(reason)
        }
    }

    /// The exact internal reason, for diagnostics only. Never shown on a card.
    public var diagnostic: String {
        switch self {
        case .session(let reason): "herdr session: \(reason)"
        case .ghosttyTTY(let join): "Ghostty tty join: \(join)"
        case .ghosttyTTYUnsupported: "Ghostty tty: unsupported"
        case .open(let failure): "herdr Open, \(failure.step): \(failure)"
        case .relay(let reason): "herdr question relay: \(reason)"
        }
    }
}

/// Whether a herdr session's Open can be offered right now, as the notch presents it.
public enum HerdrOpenAvailability: Equatable, Sendable {
    /// The session is not in herdr; the Ghostty tab rules apply unchanged.
    case notInHerdr
    /// The scan bound the session and Ghostty can report `tty`; Open is offered and rechecks.
    case available
    /// Open is replaced by the cause's grouped reason line.
    case unavailable(HerdrUnavailableCause)
}

/// The settings row's badge. The row shows none while the first scan after the gate opened runs.
public enum HerdrReadinessBadge: Equatable, Sendable {
    /// herdr's switch is off.
    case off
    case notInUse
    case ready
    case needsAttention

    public var title: String {
        switch self {
        case .off: "Off"
        case .notInUse: "Not in use"
        case .ready: "Ready"
        case .needsAttention: "Needs attention"
        }
    }
}

/// One independent fix listed on the settings row.
public enum HerdrSettingsProblem: Equatable, Hashable, Sendable {
    /// herdr's integration for an agent Steer has seen in herdr is missing or not current.
    case integration(HerdrAgentKind)
    /// Ghostty does not expose each terminal's `tty`.
    case ghosttyCannotIdentifyTab
    /// herdr itself could not be used (not found, not running, protocol, socket, and similar).
    case herdrUnavailable
    /// herdr's switch is on but no terminal is, so Steer does not contact herdr (ADR 0014).
    case noTerminalOn

    public var message: String {
        switch self {
        case .integration(let agent):
            "Install or update herdr's \(HerdrPresentation.agentName(agent)) integration. Steer never runs this or edits herdr's configuration."
        case .ghosttyCannotIdentifyTab:
            "Ghostty cannot identify herdr's tab. Update Ghostty."
        case .herdrUnavailable:
            "herdr is unavailable. Check that herdr is installed and running."
        case .noTerminalOn:
            "Turn on the terminal you run herdr in."
        }
    }

    /// The exact command to copy, when the fix is one.
    public var command: String? {
        if case .integration(let agent) = self { return HerdrPresentation.installCommand(agent) }
        return nil
    }
}

/// The herdr card under Multiplexers in settings.
public struct HerdrSettingsRow: Equatable, Sendable {
    /// Nil only while the first scan after the gate opened is still running.
    public let badge: HerdrReadinessBadge?
    public let detail: String
    /// Every applicable problem, one per line: Claude's integration, Ghostty, herdr. Codex needs no
    /// herdr integration (ADR 0012).
    public let problems: [HerdrSettingsProblem]

    public init(badge: HerdrReadinessBadge?, detail: String, problems: [HerdrSettingsProblem]) {
        self.badge = badge
        self.detail = detail
        self.problems = problems
    }
}

public enum HerdrPresentation {
    // MARK: - Grouping

    public static func group(_ reason: HerdrSessionUnavailable) -> HerdrReasonGroup {
        switch reason {
        case .herdrSwitchedOff, .ghosttyControlsOff, .notScanned, .serverIdentityUnknown: .generic
        case .herdr(let reason): group(reason)
        case .binding(let reason): group(reason)
        }
    }

    public static func group(_ reason: HerdrUnavailableReason) -> HerdrReasonGroup {
        switch reason {
        case .integrationNotCurrent(let agent): .integration(agent)
        case .wrongClientCount(let count): count > 1 ? .layoutNotSupported : .generic
        case .split, .namedSession: .layoutNotSupported
        case .herdrNotFound, .notRunning, .untrustedSocket, .unsupportedProtocol, .nonGhosttyClient,
             .voidBinding, .timeout, .malformedReply, .paneChangedDuringScan, .requestRefused: .generic
        }
    }

    public static func group(_ reason: HerdrBindingUnavailable) -> HerdrReasonGroup {
        switch reason {
        case .integrationNotCurrent(let agent, _): .integration(agent)
        case .split, .namedSession, .multipleClients: .layoutNotSupported
        case .sessionEnded, .noHookRecord, .notInHerdr, .conflictingHookRecords, .unsupportedProtocol,
             .socketUnknown, .herdrRestarted, .paneReusedBySession, .conflictingPaneObservations,
             .duplicateMatches, .paneMissing, .agentSessionNull, .agentSessionMismatch, .conflictingTitle,
             .noClient, .nonGhosttyClient, .titleNotInHerdr, .duplicateTitles, .sessionPrefixNotUnique,
             .titleInHerdrAndGhostty, .detectedAgent, .processInfoUnavailable, .foregroundProcesses,
             .agentProcessNotInForeground, .agentProcessAmbiguous: .generic
        }
    }

    public static func group(_ join: GhosttyTTYJoin) -> HerdrReasonGroup {
        switch join {
        case .ttyUnsupported: .ghosttyTooOld
        case .split, .otherWindow: .layoutNotSupported
        case .matched, .inventoryUnavailable, .invalidClientTTY, .noMatch, .emptyValue, .multipleMatches: .generic
        }
    }

    /// A wrapped reason keeps its own group, wherever in ADR 0011's sequence it arose: a split or a
    /// stale integration found by the verification scan is as fixable as one found by the
    /// revalidation. Step-level failures with nothing for the user to fix (herdr refusing or timing
    /// out on `agent.focus`, focus or selection that did not verify, a client or binding that changed
    /// under the request, an unreadable inventory) are generic.
    public static func group(_ failure: HerdrOpenFailure) -> HerdrReasonGroup {
        switch failure {
        case .ghosttyTTYUnsupported: .ghosttyTooOld
        case .binding(let reason), .herdrVerifyUnavailable(let reason): group(reason)
        case .ghosttyTab(let join), .ghosttyJoinChanged(let join): group(join)
        case .sessionNotInHerdr, .clientTTYUnknown, .ghosttyInventoryUnavailable, .focusRejected,
             .herdrBindingChanged, .herdrPaneNotFocused, .herdrClientChanged, .ghosttySelectFailed,
             .ghosttyVerifyInventoryUnavailable, .ghosttyTabNotSelected: .generic
        }
    }

    /// A pane binding that does not hold keeps its own group. Every other veto is generic: the
    /// question is already answered or ended (`answeredInRollout`, `turnEnded`), held for the daemon
    /// (`daemonAnswerInProgress`), or its pending state or pane could not be confirmed. Those mean
    /// "answer it in Codex", not a reason Open is unavailable, which is why the card never presents
    /// a relay cause and uses Open's own instead. herdr refusing the key request is generic, like a
    /// refused `agent.focus`.
    public static func group(_ reason: HerdrQuestionRelayUnavailable) -> HerdrReasonGroup {
        switch reason {
        case .binding(let reason): group(reason)
        case .leftHerdr, .paneChanged, .answeredInRollout, .turnEnded, .rolloutUnreadable, .agentNotBlocked,
             .daemonAnswerInProgress, .herdrRefused, .noQuestionKeys, .otherHostUnreadable: .generic
        }
    }

    // MARK: - Card wording

    /// The one line that replaces Open on a card. `agent` is the card's own agent; an integration
    /// group names the agent whose integration is not current.
    public static func cardLine(for group: HerdrReasonGroup, agent: HerdrAgentKind) -> String {
        switch group {
        case .ghosttyTooOld:
            "Update Ghostty to return to herdr panes."
        case .integration(let integrationAgent):
            "Run \(installCommand(integrationAgent)) to return to herdr panes."
        case .layoutNotSupported:
            "Steer returns only to a single-pane herdr tab in one Ghostty window."
        case .generic:
            "\(openTitle(agent)) is unavailable until Steer can verify the exact herdr pane."
        }
    }

    public static func cardLine(for cause: HerdrUnavailableCause, agent: HerdrAgentKind) -> String {
        cardLine(for: cause.group, agent: agent)
    }

    /// The single line for a Codex question that cannot be relayed while Open is also unavailable.
    public static func unrelayedQuestionLine(openCause: HerdrUnavailableCause) -> String {
        "Answer this in Codex. " + cardLine(for: openCause, agent: .codex)
    }

    /// Where a Codex question card's relayed key went, as its status sentences name it: the herdr
    /// pane for the herdr route (ADR 0010), otherwise the Ghostty tab (ADR 0006).
    public static func keyDestination(for route: QuestionAnswerRoute) -> (place: String, noun: String) {
        route == .herdrRelay ? ("the herdr pane", "pane") : ("the Ghostty tab", "tab")
    }

    /// The card's sentence when no relay can answer a CLI question but Open still works. Ghostty
    /// controls are already on here, so the Ghostty fallback sentence would mislead. Only a session
    /// in herdr has a pane to open; daemon drafts in progress just point to Codex.
    public static func relayUnavailableLine(for reason: HerdrQuestionRelayUnavailable) -> String {
        if case .noQuestionKeys = reason { return reason.message }
        if case .otherHostUnreadable = reason { return "Steer can't reach this session's tab. Reply in the session." }
        if case .binding = reason { return "Steer can't answer this from here. Answer in Codex, or open its pane." }
        return "Steer can't answer this from here. Answer in Codex."
    }

    /// The Open button's title, the same for every agent.
    public static func openTitle(_ agent: HerdrAgentKind) -> String { "Open Session" }

    public static func agentName(_ agent: HerdrAgentKind) -> String {
        switch agent {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    public static func installCommand(_ agent: HerdrAgentKind) -> String {
        "herdr integration install \(agent.rawValue)"
    }

    // MARK: - Open availability

    /// Whether the notch offers Open for a session, from its scan-time binding and the Ghostty
    /// bundle's `tty` support. Unknown support (not yet read) does not block Open; the click-time
    /// recheck still applies. A binding reason takes precedence over the Ghostty one.
    ///
    /// - Parameter soleTerminal: without `tty`, the sole-terminal join of the client's TTY against the
    ///   latest Ghostty inventory (`GhosttyTTYMatch.join`), nil when either is unknown. Open is offered
    ///   only when it matched; otherwise its reason is shown, or "update Ghostty" when Ghostty has
    ///   several surfaces.
    ///
    /// A cause that is an Open fallback (ADR 0015: a split, several clients, colliding matches, a
    /// Ghostty without `tty`) keeps Open on the card, which looks the same whether the click will reach
    /// the exact pane or raise the app. Setup guidance such as "Update Ghostty" stays in settings.
    public static func openAvailability(binding: HerdrSessionBinding, ttySupport: GhosttyTTYSupport?,
                                        soleTerminal: GhosttyTTYJoin? = nil) -> HerdrOpenAvailability {
        switch binding {
        case .notInHerdr: return .notInHerdr
        case .unavailable(let reason):
            return HerdrOpenFallback.reason(for: reason) == nil ? .unavailable(.session(reason)) : .available
        case .bound:
            guard ttySupport == .unsupported else { return .available }
            switch soleTerminal {
            case .matched?, nil, .ttyUnsupported?: return .available
            case let join?: return HerdrOpenFallback.reason(for: join) == nil ? .unavailable(.ghosttyTTY(join)) : .available
            }
        }
    }

    // MARK: - Settings row

    /// The settings row model.
    ///
    /// - Parameters:
    ///   - switches: every host's switch. herdr off reads Off; herdr on with no terminal on needs
    ///     attention, because Steer contacts herdr only through a terminal (ADR 0014).
    ///   - inUse: the ADR 0009 gate is open (herdr's switch allows contact, and a live Claude session
    ///     reported a pane or a live or daemon-loaded Codex terminal session exists beside a known
    ///     Ghostty inventory with herdr's socket trusted).
    ///   - outcome: the latest scan, nil before the first scan after the gate opened.
    ///   - agentsSeen: agents whose live sessions' newest hook event reported running in herdr;
    ///     an integration problem is listed only for Claude Code, and only when it is among these.
    ///   - ttySupport: whether Ghostty declares `tty`; nil while unknown, which lists no problem.
    public static func settingsRow(switches: TerminalHostSwitches, inUse: Bool, outcome: HerdrScanOutcome?,
                                   agentsSeen: Set<HerdrAgentKind>, ttySupport: GhosttyTTYSupport?) -> HerdrSettingsRow {
        guard switches.isOn(.herdr) else {
            return HerdrSettingsRow(badge: .off, detail: "Steer never scans or contacts herdr.", problems: [])
        }
        guard switches.anyTerminalOn else {
            return HerdrSettingsRow(badge: .needsAttention, detail: "Fix each item below.", problems: [.noTerminalOn])
        }
        // A Codex session opens the gate whenever herdr's socket is trusted (ADR 0012); with no
        // server and no Claude session reporting a pane, nothing runs in herdr.
        let nothingInHerdr = outcome == .unavailable(.notRunning) && !agentsSeen.contains(.claude)
        guard inUse, !nothingInHerdr else {
            return HerdrSettingsRow(badge: .notInUse, detail: "No herdr sessions seen.", problems: [])
        }
        guard let outcome else {
            return HerdrSettingsRow(badge: nil, detail: "Checking herdr…", problems: [])
        }
        var problems: [HerdrSettingsProblem] = []
        var herdrUnavailable = false
        switch outcome {
        case .available(let scan):
            if agentsSeen.contains(.claude), scan.integration.reason(for: .claude) != nil {
                problems.append(.integration(.claude))
            }
        case .unavailable(.integrationNotCurrent(.claude)):
            problems.append(.integration(.claude))
        case .unavailable:
            herdrUnavailable = true
        }
        if ttySupport == .unsupported { problems.append(.ghosttyCannotIdentifyTab) }
        if herdrUnavailable { problems.append(.herdrUnavailable) }
        return HerdrSettingsRow(badge: problems.isEmpty ? .ready : .needsAttention,
                                detail: problems.isEmpty ? "herdr is reachable and its integrations are current." : "Fix each item below.",
                                problems: problems)
    }
}
