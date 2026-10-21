import HerdlyCore

/// The open queue's result rows (#322, D20): a click, or Return on the selected row, opens the row's
/// session through `openAgent`, the same Open every card uses, which revalidates the exact target
/// and may only raise the session's app when it cannot reach it (ADR 0015). The rules are Core's
/// (`ResultRowTarget`, `QueueRowSelection.returnAction`, `RowOpenFold`); these only feed them what
/// the latest scans observed. Opening acknowledges nothing: a verified visit (ADR 0016), the Codex
/// app's read state, a new prompt, or Dismiss still decides when a result clears.
extension Companion {
    /// Whether a click on a row for `session` can take the user there, from the same observations
    /// the cards read to offer Open: herdr's binding, the terminal scan's line, and for Claude the
    /// live inventories. With Ghostty controls off a herdr session keeps the Ghostty rules, as the
    /// cards present it.
    func resultRowTarget(_ session: AgentSessionIdentity) -> ResultRowTarget {
        var herdr = herdrOpenAvailability(session, ttySupport: GhosttyTTYSupportMonitor.shared.support)
        if case .unavailable(.session(.ghosttyControlsOff)) = herdr { herdr = .notInHerdr }
        return ResultRowTarget.resolve(source: session.source, herdr: herdr,
                                       scanOffersOpen: offersTerminalOpen(session),
                                       codexSessionKnown: codexSession(session) != nil,
                                       claudeOpenable: canOpenClaude(session))
    }

    /// A click on a queue row, or Return on the selected one. Returns false when the row does
    /// nothing (an unreachable result row, or a row no longer on screen), so the key goes on.
    @discardableResult
    func activateRow(_ id: AgentAttentionID) -> Bool {
        guard let item = selectableItems.first(where: { $0.id == id }) else { return false }
        switch QueueRowSelection.returnAction(for: item, target: resultRowTarget(item.session)) {
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

    /// Opens a result row's session, then folds the panel back once the Open has finished (8DW),
    /// unless the click's recheck left a reason line on the row, which stays in view. A click while
    /// another Open is running is ignored, as the cards' disabled Open is.
    private func openSessionFromRow(_ session: AgentSessionIdentity) {
        guard !openingTask else { return }
        openAgent(session)
        rowOpenFold.begin(session)
        settleRowOpenFold()
    }

    /// Settles a pending row Open; called on every refresh. Returns true when it collapsed the
    /// panel, which refreshes on its own.
    @discardableResult
    func settleRowOpenFold() -> Bool {
        guard let session = rowOpenFold.pending else { return false }
        let showsLine = resultRowTarget(session) == .unreachable || terminalOpenLine(session) != nil
        switch rowOpenFold.settle(opening: openingTask, showsLine: showsLine) {
        case .collapse:
            collapse()
            return true
        case .stay, .none:
            return false
        }
    }
}
