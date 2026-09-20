
function run(argv) {
    const request = JSON.parse(argv[0]);
    const app = Application('com.mitchellh.ghostty');
    if (!app.running()) return JSON.stringify({status: 'unavailable'});
    function inventory() {
        return app.windows().map(w => ({id: w.id(), tabs: w.tabs().map(t => ({
            id: t.id(), terminals: t.terminals().map(p => ({id: p.id(), name: p.name()}))
        }))}));
    }
    function selected() {
        if (!app.frontmost()) return null;
        const w = app.frontWindow(), t = w.selectedTab();
        return {window_id: w.id(), tab_id: t.id(), terminal_id: t.focusedTerminal().id()};
    }
    function frontWindowID() {
        const w = app.frontWindow();
        return w ? w.id() : null;
    }
    if (request.action === 'snapshot')
        return JSON.stringify({status: 'ok', windows: inventory(), front_window_id: frontWindowID(), selected: selected()});
    if (request.action !== 'select' && request.action !== 'answer') return JSON.stringify({status: 'unknown'});
    // Recheck the entire inventory immediately before any selection or key.
    const matches = [];
    inventory().forEach(w => w.tabs.forEach(t => t.terminals.forEach(p => {
        if (p.name === request.title) matches.push({window_id: w.id, tab_id: t.id,
            terminal_id: p.id, count: t.terminals.length});
    })));
    if (matches.length !== 1 || matches[0].count !== 1)
        return JSON.stringify({status: 'unknown'});
    const m = matches[0], target = request.target;
    if (m.window_id !== target.window_id || m.tab_id !== target.tab_id ||
        m.terminal_id !== target.terminal_id) return JSON.stringify({status: 'unknown'});
    const w = app.windows.byId(target.window_id), t = w.tabs.byId(target.tab_id);
    if (request.action === 'select') {
        if (request.same_window_only) {
            const front = app.frontWindow();
            if (!front || front.id() !== target.window_id) return JSON.stringify({status: 'unknown'});
        }
        app.activateWindow(w);
        app.selectTab(t);
        return JSON.stringify({status: 'ok'});
    }
    // answer: one user-chosen digit (and Enter only where the live check proved it necessary) as
    // key events to that exact terminal, through Ghostty's own `send key`. No text is ever input.
    const keys = Array.isArray(request.keys) ? request.keys : [];
    if (keys.length < 1 || keys.length > 2 || !keys.every(k => /^([1-9]|enter)$/.test(k)))
        return JSON.stringify({status: 'unknown'});
    const terminal = t.terminals().find(p => p.id() === target.terminal_id);
    if (!terminal || terminal.name() !== request.title) return JSON.stringify({status: 'unknown'});
    for (const k of keys) app.sendKey(k, {to: terminal});
    return JSON.stringify({status: 'ok', sent: keys});
}
