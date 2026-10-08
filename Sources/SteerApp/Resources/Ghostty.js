
function run(argv) {
    const request = JSON.parse(argv[0]);
    const app = Application('com.mitchellh.ghostty');
    if (!app.running()) return JSON.stringify({status: 'unavailable'});
    // `tty` is read only when the app's dictionary check found it declared (ADR 0011); Ghostty 1.3.1
    // lacks it, and its inventory stays exactly as before.
    const withTTY = request.tty === true;
    function terminal(p) {
        const value = {id: p.id(), name: p.name()};
        if (withTTY) value.tty = p.tty();
        return value;
    }
    function inventory() {
        return app.windows().map(w => ({id: w.id(), tabs: w.tabs().map(t => ({
            id: t.id(), terminals: t.terminals().map(terminal)
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
    if (request.action === 'select_tty') {
        // herdr Open (ADR 0011): the tab is identified only by its terminal's `tty`, never by title.
        // Recheck that exactly one terminal has the TTY, alone in its tab, in the front window, and
        // that it is still the target; then select it and activate Ghostty. No input is sent.
        const tty = v => (typeof v === 'string' && /^(\/dev\/)?ttys[0-9]{1,12}$/.test(v))
            ? (v.indexOf('/dev/') === 0 ? v : '/dev/' + v) : null;
        const wanted = tty(request.tty), target = request.target;
        if (!wanted || !target) return JSON.stringify({status: 'unknown'});
        const found = [];
        app.windows().forEach(w => w.tabs().forEach(t => {
            const terminals = t.terminals();
            terminals.forEach(p => {
                if (tty(p.tty()) === wanted) found.push({window_id: w.id(), tab_id: t.id(),
                    terminal_id: p.id(), count: terminals.length});
            });
        }));
        if (found.length !== 1 || found[0].count !== 1) return JSON.stringify({status: 'unknown'});
        const f = found[0], front = app.frontWindow();
        if (f.window_id !== target.window_id || f.tab_id !== target.tab_id || f.terminal_id !== target.terminal_id
            || !front || front.id() !== target.window_id) return JSON.stringify({status: 'unknown'});
        const w = app.windows.byId(target.window_id);
        app.activateWindow(w);
        app.selectTab(w.tabs.byId(target.tab_id));
        app.activate();
        return JSON.stringify({status: 'ok'});
    }
    if (request.action === 'select_sole') {
        // herdr Open without `tty` (ADR 0011's sole-terminal rule): Steer has checked Ghostty's child
        // processes hold one surface, on herdr's client TTY. Recheck that `target` is still Ghostty's
        // only scripted terminal, in the front window; then select it and activate Ghostty. No input.
        const target = request.target;
        if (!target) return JSON.stringify({status: 'unknown'});
        const all = [];
        app.windows().forEach(w => w.tabs().forEach(t => t.terminals().forEach(p => {
            all.push({window_id: w.id(), tab_id: t.id(), terminal_id: p.id()});
        })));
        const front = app.frontWindow();
        if (all.length !== 1 || all[0].window_id !== target.window_id || all[0].tab_id !== target.tab_id
            || all[0].terminal_id !== target.terminal_id || !front || front.id() !== target.window_id)
            return JSON.stringify({status: 'unknown'});
        const w = app.windows.byId(target.window_id);
        app.activateWindow(w);
        app.selectTab(w.tabs.byId(target.tab_id));
        app.activate();
        return JSON.stringify({status: 'ok'});
    }
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
    const recipient = t.terminals().find(p => p.id() === target.terminal_id);
    if (!recipient || recipient.name() !== request.title) return JSON.stringify({status: 'unknown'});
    for (const k of keys) app.sendKey(k, {to: recipient});
    return JSON.stringify({status: 'ok', sent: keys});
}
