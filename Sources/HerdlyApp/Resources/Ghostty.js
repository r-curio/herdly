// Herdly's Ghostty adapter. One JSON request per call, run after AppleEvents.js:
//   {"action": "...", "pid": <Ghostty's process id>, ...}
// Every event goes to the process `pid` (#270), so Herdly never launches Ghostty; a Ghostty that is not
// there, or quits during the request, answers `unavailable`.
//
// Codes are Ghostty's dictionary (Ghostty.sdef): window 'Gwnd', tab 'Gtab', terminal 'Gtrm', id 'ID  ',
// name 'pnam', tty 'Gtty', frontmost 'pisf', front window 'GFWn', selected tab 'GWsT', focused terminal
// 'GTfT', `activate window` 'GhstAcWn', `select tab` 'GhstSlTb', `send key` 'GhstSKey' with `to` 'GKeT'.
function run(argv) {
    const request = JSON.parse(argv[0]);
    return AppleEvents.run(request.pid, request.deadline, {status: 'unavailable'}, app => {
        const E = AppleEvents;
        const get = (spec, name) => app.get(E.property(spec, name));
        const windows = () => app.get(E.every(null, 'Gwnd'));
        const tabs = w => app.get(E.every(w, 'Gtab'));
        const terminals = t => app.get(E.every(t, 'Gtrm'));
        // `tty` is read only when the app's dictionary check found it declared (ADR 0011); Ghostty 1.3.1
        // lacks it, and its inventory stays exactly as before.
        const withTTY = request.tty === true;
        function terminal(p) {
            const value = {id: get(p, 'ID  '), name: get(p, 'pnam')};
            if (withTTY) value.tty = get(p, 'Gtty');
            return value;
        }
        function inventory() {
            return windows().map(w => ({id: get(w, 'ID  '), tabs: tabs(w).map(t => ({
                id: get(t, 'ID  '), terminals: terminals(t).map(terminal)
            }))}));
        }
        function selected() {
            if (!get(null, 'pisf')) return null;
            const w = get(null, 'GFWn'), t = get(w, 'GWsT');
            return {window_id: get(w, 'ID  '), tab_id: get(t, 'ID  '), terminal_id: get(get(t, 'GTfT'), 'ID  ')};
        }
        function frontWindow() {
            return get(null, 'GFWn');
        }
        function frontWindowID() {
            const w = frontWindow();
            return w ? get(w, 'ID  ') : null;
        }
        const windowByID = id => E.byID(null, 'Gwnd', id);
        const tabByID = (w, id) => E.byID(w, 'Gtab', id);
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
            windows().forEach(w => tabs(w).forEach(t => {
                const all = terminals(t);
                all.forEach(p => {
                    if (tty(get(p, 'Gtty')) === wanted) found.push({window_id: get(w, 'ID  '), tab_id: get(t, 'ID  '),
                        terminal_id: get(p, 'ID  '), count: all.length});
                });
            }));
            if (found.length !== 1 || found[0].count !== 1) return JSON.stringify({status: 'unknown'});
            const f = found[0], front = frontWindow();
            if (f.window_id !== target.window_id || f.tab_id !== target.tab_id || f.terminal_id !== target.terminal_id
                || !front || get(front, 'ID  ') !== target.window_id) return JSON.stringify({status: 'unknown'});
            const w = windowByID(target.window_id);
            app.command('GhstAcWn', w);
            app.command('GhstSlTb', tabByID(w, target.tab_id));
            app.activate();
            return JSON.stringify({status: 'ok'});
        }
        if (request.action === 'select_sole') {
            // herdr Open without `tty` (ADR 0011's sole-terminal rule): Herdly has checked Ghostty's child
            // processes hold one surface, on herdr's client TTY. Recheck that `target` is still Ghostty's
            // only scripted terminal, in the front window; then select it and activate Ghostty. No input.
            const target = request.target;
            if (!target) return JSON.stringify({status: 'unknown'});
            const all = [];
            windows().forEach(w => tabs(w).forEach(t => terminals(t).forEach(p => {
                all.push({window_id: get(w, 'ID  '), tab_id: get(t, 'ID  '), terminal_id: get(p, 'ID  ')});
            })));
            const front = frontWindow();
            if (all.length !== 1 || all[0].window_id !== target.window_id || all[0].tab_id !== target.tab_id
                || all[0].terminal_id !== target.terminal_id || !front || get(front, 'ID  ') !== target.window_id)
                return JSON.stringify({status: 'unknown'});
            const w = windowByID(target.window_id);
            app.command('GhstAcWn', w);
            app.command('GhstSlTb', tabByID(w, target.tab_id));
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
        const w = windowByID(target.window_id), t = tabByID(w, target.tab_id);
        if (request.action === 'select') {
            if (request.same_window_only) {
                const front = frontWindow();
                if (!front || get(front, 'ID  ') !== target.window_id) return JSON.stringify({status: 'unknown'});
            }
            app.command('GhstAcWn', w);
            app.command('GhstSlTb', t);
            return JSON.stringify({status: 'ok'});
        }
        // answer: one user-chosen digit (and Enter only where the live check proved it necessary) as
        // key events to that exact terminal, through Ghostty's own `send key`. No text is ever input.
        const keys = Array.isArray(request.keys) ? request.keys : [];
        if (keys.length < 1 || keys.length > 2 || !keys.every(k => /^([1-9]|enter)$/.test(k)))
            return JSON.stringify({status: 'unknown'});
        const recipient = terminals(t).find(p => get(p, 'ID  ') === target.terminal_id);
        if (!recipient || get(recipient, 'pnam') !== request.title) return JSON.stringify({status: 'unknown'});
        for (const k of keys) app.command('GhstSKey', k, {GKeT: recipient});
        return JSON.stringify({status: 'ok', sent: keys});
    });
}
