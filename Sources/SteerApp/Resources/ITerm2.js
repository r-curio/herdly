// Steer's iTerm2 adapter (#238). One JSON request per call:
//   osascript -l JavaScript ITerm2.js '{"action": "snapshot" | "select", ...}'
// It reads the inventory and selects one session for Open. It never writes text to a session (ADR 0017:
// iTerm2 gets no typed input), never reads `jobName` (stale for undisplayed tabs; Steer reads `ps -t`),
// and never launches iTerm2. Any error fails the whole request, so a partial inventory never stands for
// a complete one.
function run(argv) {
    const request = JSON.parse(argv[0]);
    const app = Application('com.googlecode.iterm2');
    if (!app.running()) return JSON.stringify({status: 'not_running'});

    function variable(session, name) {
        try { return session.variable({named: name}); } catch (e) { return null; }
    }
    function list(collection) {
        // A window or tab closing mid-walk returns null; that read is incomplete.
        if (collection === null || collection === undefined) throw new Error('incomplete inventory');
        return collection;
    }
    function current() {
        try {
            const w = app.currentWindow();
            if (!w) return null;
            const s = w.currentTab().currentSession();
            return s ? {window: w.id(), session: s.id()} : null;
        } catch (e) { return null; }
    }

    if (request.action === 'snapshot') {
        const windows = list(app.windows()).map(w => ({id: w.id(), tabs: list(w.tabs()).map(t => ({
            sessions: list(t.sessions()).map(s => ({
                id: s.id(), tty: s.tty(),
                window_name: variable(s, 'terminalWindowName'),
                icon_name: variable(s, 'terminalIconName')
            }))
        }))}));
        return JSON.stringify({status: 'ok', windows: windows, current: current()});
    }

    if (request.action === 'select') {
        // ADR 0016's iTerm2 step: select the window, the tab and the session, then activate. Recheck the
        // session first: it must still exist, on the same tty, alone in its tab.
        if (typeof request.session !== 'string' || typeof request.tty !== 'string')
            return JSON.stringify({status: 'changed'});
        let hit = null, count = 0;
        list(app.windows()).forEach(w => list(w.tabs()).forEach(t => {
            const sessions = list(t.sessions());
            sessions.forEach(s => {
                if (s.id() === request.session) { hit = {w: w, t: t, s: s, tabSessions: sessions.length}; count += 1; }
            });
        }));
        if (count === 0) return JSON.stringify({status: 'gone'});
        if (count !== 1 || hit.tabSessions !== 1 || hit.s.tty() !== request.tty)
            return JSON.stringify({status: 'changed'});
        hit.w.select();
        hit.t.select();
        hit.s.select();
        app.activate();
        return JSON.stringify({status: 'ok'});
    }

    return JSON.stringify({status: 'unknown'});
}
