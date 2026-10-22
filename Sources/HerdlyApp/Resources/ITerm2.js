// Herdly's iTerm2 adapter (#238). One JSON request per call, run after AppleEvents.js:
//   {"action": "snapshot" | "select", "pid": <iTerm2's process id>, ...}
// It reads the inventory and selects one session for Open. It never writes text to a session (ADR 0017:
// iTerm2 gets no typed input), never reads `jobName` (stale for undisplayed tabs; Herdly reads `ps -t`),
// and never launches iTerm2: every event goes to the process `pid` (#270), and an iTerm2 that is not
// there, or quits during the request, answers `not_running`. Any other error fails the whole request, so
// a partial inventory never stands for a complete one.
//
// Codes are iTerm2's dictionary (iTerm2.sdef): window 'cwin', tab 'Trmt', session 'Trms', id 'ID  ',
// tty 'Stty', current window 'Crwn', current tab 'Crtb', current session 'Wcsn', `variable` 'Itrmvarb'
// with `named` 'Namd', `select` 'Itrmslct'.
function run(argv) {
    const request = JSON.parse(argv[0]);
    return AppleEvents.run(request.pid, request.deadline, {status: 'not_running'}, app => {
        const E = AppleEvents;
        const get = (spec, name) => app.get(E.property(spec, name));
        const elements = (spec, elementClass) => list(app.get(E.every(spec, elementClass)));

        function variable(session, name) {
            try { return app.command('Itrmvarb', session, {Namd: name}); } catch (e) {
                if (E.isGone(e)) throw e;
                return null;
            }
        }
        function list(collection) {
            // A window or tab closing mid-walk returns null; that read is incomplete.
            if (collection === null || collection === undefined) throw new Error('incomplete inventory');
            return collection;
        }
        function current() {
            try {
                const w = get(null, 'Crwn');
                if (!w) return null;
                const s = get(get(w, 'Crtb'), 'Wcsn');
                return s ? {window: get(w, 'ID  '), session: get(s, 'ID  ')} : null;
            } catch (e) {
                if (E.isGone(e)) throw e;
                return null;
            }
        }

        if (request.action === 'snapshot') {
            const windows = elements(null, 'cwin').map(w => ({id: get(w, 'ID  '), tabs: elements(w, 'Trmt').map(t => ({
                sessions: elements(t, 'Trms').map(s => ({
                    id: get(s, 'ID  '), tty: get(s, 'Stty'),
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
            elements(null, 'cwin').forEach(w => elements(w, 'Trmt').forEach(t => {
                const sessions = elements(t, 'Trms');
                sessions.forEach(s => {
                    if (get(s, 'ID  ') === request.session) { hit = {w: w, t: t, s: s, tabSessions: sessions.length}; count += 1; }
                });
            }));
            if (count === 0) return JSON.stringify({status: 'gone'});
            if (count !== 1 || hit.tabSessions !== 1 || get(hit.s, 'Stty') !== request.tty)
                return JSON.stringify({status: 'changed'});
            app.command('Itrmslct', hit.w);
            app.command('Itrmslct', hit.t);
            app.command('Itrmslct', hit.s);
            app.activate();
            return JSON.stringify({status: 'ok'});
        }

        return JSON.stringify({status: 'unknown'});
    });
}
