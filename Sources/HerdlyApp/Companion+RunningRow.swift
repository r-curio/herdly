import HerdlyCore

/// The open queue's one running row opened in place (#319, F3). The rules are `OpenRunningRow`'s;
/// these only feed it the rows on screen and publish a change.
extension Companion {
    /// A click on a running row's header line, or Return on it: opens it, moves the open state to it,
    /// or closes it. Returns false when `id` is not a working row on screen, so the key is not handled.
    @discardableResult
    func toggleRunningRow(_ id: AgentAttentionID) -> Bool {
        guard let row = selectableItems.first(where: { $0.id == id }), row.kind == .running else { return false }
        updateOpenRunningRow { $0.toggle(row) }
        return true
    }

    /// Escape closes an open running row and reports true; with none open it reports false.
    func escapeOpenRunningRow() -> Bool {
        var handled = false
        updateOpenRunningRow { handled = $0.escape() }
        return handled
    }

    func closeOpenRunningRow() {
        updateOpenRunningRow { $0.close() }
    }

    /// Closes the open row once its turn leaves the queue, stops working, or a closed fold hides it.
    func reconcileOpenRunningRow() {
        guard openRunningRow.open != nil else { return }
        let rows = selectableItems
        updateOpenRunningRow { $0.reconcile(visible: rows) }
    }

    /// The open queue's on-screen rows in reading order; empty while it is not shown.
    private var selectableItems: [AgentAttentionItem] {
        presentationMode.showsAll ? visibleSections.selectableItems(workingOpen: workingFoldOpen) : []
    }

    /// Publishes only a real change, so a refresh does not redraw the panel for nothing.
    private func updateOpenRunningRow(_ change: (inout OpenRunningRow) -> Void) {
        var next = openRunningRow
        change(&next)
        if next != openRunningRow { openRunningRow = next }
    }
}
