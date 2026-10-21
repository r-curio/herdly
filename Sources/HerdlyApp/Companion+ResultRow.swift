import Foundation
import HerdlyCore

/// The open queue's result rows (#322, D20): a click, or Return on the selected row, opens the row's
/// session through `openAgent`, the same Open every card uses, which revalidates the exact target
/// and may only raise the session's app when it cannot reach it (ADR 0015). The rules are Core's
/// (`ResultRowReading`, `QueueRowSelection.action`, `RowOpenFold`); these only feed them what the
/// latest scans observed. Opening acknowledges nothing: a verified visit (ADR 0016), the Codex app's
/// read state, a new prompt, or Dismiss still decides when a result clears. `rowOpenFold` is changed
/// only here (and cancelled by `collapse`).
extension Companion {
    /// herdr's Open availability for `session` as the notch presents it, from the shared Ghostty
    /// `tty` support reading the view also observes.
    func presentedHerdrOpen(_ session: AgentSessionIdentity) -> HerdrOpenAvailability {
        herdrOpenAvailability(session, ttySupport: GhosttyTTYSupportMonitor.shared.support).presented
    }

    /// The one reading of a result row's session: whether a click can reach it and the line under
    /// its name. The row's word, line, click, Return and fold all read it.
    func resultRowReading(_ session: AgentSessionIdentity) -> ResultRowReading {
        ResultRowReading.resolve(ResultRowObservation(
            source: session.source, herdr: presentedHerdrOpen(session),
            scanOffersOpen: offersTerminalOpen(session), terminalLine: terminalOpenLine(session),
            codexSessionKnown: session.source != .codex || codexSession(session) != nil,
            codexTerminalHostsOff: session.source == .codex && isCodexTerminalSession(session) && !cliTerminalHostOn,
            claudeOpenable: canOpenClaude(session), claudeBackground: isBackgroundClaudeSession(session),
            claudeLastSeen: session.source == .claude ? claudeLastSeenLine(session) : nil))
    }

    /// A click on a queue row, or Return on the selected one. Returns false when the row does
    /// nothing (an unreachable result row, or a row no longer on screen), so the key goes on.
    @discardableResult
    func activateRow(_ id: AgentAttentionID) -> Bool {
        guard let item = selectableItems.first(where: { $0.id == id }) else { return activateSpotlitResult(id) }
        let target = item.kind.opensSession ? resultRowReading(item.session).target : .reachable
        switch QueueRowSelection.action(for: item, target: target) {
        case let .openCard(id)?:
            openCard(id)
            return true
        case let .openInPlace(id)?:
            return toggleRunningRow(id)
        case let .openSession(session)?:
            openSessionFromRow(session)
            return true
        case nil:
            return false
        }
    }

    /// A click on the popped result card's header line (#323, 8DW "New ones"): the same Open as the
    /// queue's result row, through the same reading, so an unreachable session does nothing. Only the
    /// result card on screen as the spotlight is reached here; queue rows keep `selectableItems`.
    private func activateSpotlitResult(_ id: AgentAttentionID) -> Bool {
        guard case .agentSpotlight(id) = presentationMode,
              let item = orderedAgentAttentionItems.first(where: { $0.id == id }), item.outcome != nil,
              case let .openSession(session)? = QueueRowSelection.action(for: item, target: resultRowReading(item.session).target)
        else { return false }
        openSessionFromRow(session)
        return true
    }

    /// One result's reply, resolved once for either agent (#323): a Codex card's progress is keyed by
    /// its queued completion, a Claude card's by its outcome. Nil for a Codex result no longer queued.
    enum ResultReply {
        case codex(AttentionCompletion, SessionReplyProgress)
        case claude(ReplyProgress<AgentTurnIdentity>)

        var phase: SessionReplyPhase {
            switch self {
            case let .codex(_, progress): progress.phase
            case let .claude(progress): progress.phase
            }
        }

        var note: RowNote? {
            switch self {
            case let .codex(_, progress): RowNote.reply(progress, agent: .codex)
            case let .claude(progress): RowNote.reply(progress, agent: .claude)
            }
        }
    }

    func resultReply(_ turn: AgentTurnIdentity) -> ResultReply? {
        switch turn.session.source {
        case .codex: codexTurn(turn).map { .codex($0, reply(for: $0)) }
        case .claude: .claude(terminalApp.claudeReplies[turn] ?? ReplyProgress(completion: turn))
        }
    }

    /// Whether the result card shows its reply field now (`ResultCardReply.offersField`).
    func resultCardOffersReply(_ outcome: AgentOutcome) -> Bool {
        switch resultReply(outcome.id) {
        case let .codex(completion, progress)?:
            ResultCardReply.offersField(for: completion, target: replyTarget(for: completion), phase: progress.phase)
        case let .claude(progress)?:
            ResultCardReply.offersField(target: claudeReplyTarget(for: outcome), phase: progress.phase)
        case nil:
            false
        }
    }

    /// One Send on the result card, by the agent's own one-reply path. A send that took the reply out
    /// of `.ready` folds the card (#323): the spotlight collapses as Escape's does, nothing is
    /// dismissed, and the result row carries the reply's note from then on. A refused send stays
    /// `.ready` and keeps the card. Returns the phase after the send, so the caller keeps refused text.
    @discardableResult
    func sendResultReply(_ outcome: AgentOutcome, text: String) -> SessionReplyPhase {
        guard let before = resultReply(outcome.id) else { return .ready }
        switch before {
        case let .codex(completion, _): sendReply(to: completion, text: text)
        case .claude: sendClaudeReply(outcome, text: text)
        }
        let after = resultReply(outcome.id)?.phase ?? .ready
        if ResultCardReply.foldsCard(before: before.phase, after: after),
           presentationMode.singleCard == .outcome(outcome.id) {
            collapse()
        }
        return after
    }

    /// Opens a result row's session, then folds the panel back once the Open has finished (8DW),
    /// unless this click left a reason line on the row, which stays in view. A click while another
    /// Open is running is ignored, as the cards' disabled Open is.
    private func openSessionFromRow(_ session: AgentSessionIdentity) {
        guard !openingTask else { return }
        rowOpenFold.begin(session, at: Date().timeIntervalSince1970)
        openAgent(session)
        settleRowOpenFold()
    }

    /// Settles a pending row Open; called on every refresh. Returns true when it collapsed the
    /// panel, which refreshes on its own.
    @discardableResult
    func settleRowOpenFold() -> Bool {
        guard let session = rowOpenFold.pending else { return false }
        let clickLineAt = openLineKey(session).flatMap(openLines.clickedAt)
        switch rowOpenFold.settle(opening: openingTask, reading: resultRowReading(session), clickLineAt: clickLineAt) {
        case .collapse:
            collapse()
            return true
        case .stay, .none:
            return false
        }
    }
}
