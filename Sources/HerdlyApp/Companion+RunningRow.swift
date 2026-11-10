import HerdlyCore

/// The open queue's one running row opened in place (#319, F3). The rules are `OpenRunningRow`'s;
/// these only feed it the rows on screen and publish a change.
extension Companion {
    /// A click on a running row's header line, or Return on it: opens it, moves the open state to it,
    /// or closes it. Returns false when `id` is not a working row on screen, so the key is not handled.
    @discardableResult
    func toggleRunningRow(_ id: AgentAttentionID) -> Bool {
        guard let row = selectableItems.first(where: { $0.id == id }) else { return false }
        var handled = false
        updateOpenRunningRow { handled = $0.toggle(row) }
        return handled
    }

    /// Escape closes an open running row and reports true; with none open it reports false.
    func escapeOpenRunningRow() -> Bool {
        var handled = false
        updateOpenRunningRow { handled = $0.escape() }
        return handled
    }

    /// A switcher well in the opened row (#397): shows the session's lines or one running subagent's.
    /// A choice for a row that is not open, or a subagent that has finished, changes nothing.
    func showInOpenRunningRow(_ choice: OpenRunningRow.Shown, row id: AgentAttentionID) {
        guard let row = selectableItems.first(where: { $0.id == id }) else { return }
        updateOpenRunningRow { $0.select(choice, in: row) }
    }

    func closeOpenRunningRow() {
        updateOpenRunningRow { $0.close() }
    }

    /// Closes the open row once its turn leaves the queue, stops working, or a closed fold hides it,
    /// and hands its details back to the session once a shown subagent finishes.
    func reconcileOpenRunningRow() {
        guard openRunningRow.open != nil else { return }
        let rows = selectableItems
        updateOpenRunningRow { $0.reconcile(visible: rows) }
    }

    /// The terminal app or multiplexer whose inventory last showed this session, for the opened row's
    /// "where" line. Presentation only: Open still revalidates the exact target.
    func lastSeenHost(for session: AgentSessionIdentity) -> TerminalHost? {
        switch session.source {
        case .codex: codexSession(session).flatMap { lastSeenHosts[$0] }
        case .claude: openLineKey(session).flatMap { lastSeenClaudeHosts[$0] }
        }
    }

    /// The open queue's on-screen rows in reading order; empty while it is not shown. Read-only;
    /// shared with Companion+ResultRow.swift, whose click and Return act only on rows on screen.
    var selectableItems: [AgentAttentionItem] {
        presentationMode.showsAll ? visibleSections.selectableItems(workingOpen: workingFoldOpen) : []
    }

    /// Publishes only a real change, so a refresh does not redraw the panel for nothing.
    private func updateOpenRunningRow(_ change: (inout OpenRunningRow) -> Void) {
        var next = openRunningRow
        change(&next)
        if next != openRunningRow { openRunningRow = next }
    }
}
