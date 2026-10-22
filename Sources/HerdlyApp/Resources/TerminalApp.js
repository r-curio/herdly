// Terminal.app adapter (#239). One JSON request per call, run after AppleEvents.js:
//   {"action": "...", "pid": <Terminal's process id>, ...}
// Terminal tabs have no id: every ⌘T tab is its own scripting window, and a tab is addressed by its
// window id and its read-only `tty`, resolved fresh on every call (docs/evidence/terminal-app-live.md).
// Nothing here launches Terminal, creates a window or tab, or types anywhere but the one tab named:
// every event goes to the process `pid` (#270), and a Terminal that is not there, or quits during the
// request, answers `not_running`.
//
// Codes are Terminal's dictionary (Terminal.sdef): window 'cwin', tab 'ttab', id 'ID  ', tty 'ttty',
// custom title 'titl', frontmost 'pisf', `do script` 'coredosc' with `in` 'kfil'.
function run(argv) {
    const request = JSON.parse(argv[0]);
    return AppleEvents.run(request.pid, request.deadline, {status: 'not_running'}, app => {
        const E = AppleEvents;
        const get = (spec, name) => app.get(E.property(spec, name));
        const windows = () => app.get(E.every(null, 'cwin'));
        const tabs = w => app.get(E.every(w, 'ttab'));

        const ttyPattern = /^\/dev\/ttys[0-9]{1,12}$/;
        function title(tab) {
            try {
                const value = get(tab, 'titl');
                return typeof value === 'string' ? value : null;
            } catch (e) {
                if (E.isGone(e)) throw e;
                return null;
            }
        }
        // Front window first: Terminal lists windows in front-to-back order.
        function inventory() {
            return windows().map(w => ({id: get(w, 'ID  '), tabs: tabs(w).map(t => ({tty: get(t, 'ttty'), title: title(t)}))}));
        }
        // The tab with `tty` in window `windowID`. `gone` when no tab anywhere has the tty (the session's
        // tab closed); `moved` when it has, but not exactly once or not in that window (a layout change).
        function locate(windowID, tty) {
            if (typeof windowID !== 'number' || typeof tty !== 'string' || !ttyPattern.test(tty)) return {status: 'gone'};
            let found = null, count = 0;
            windows().forEach(w => {
                const id = get(w, 'ID  ');
                const all = tabs(w);
                all.forEach(t => {
                    if (get(t, 'ttty') !== tty) return;
                    count += 1;
                    if (id === windowID) found = {window: w, tab: t, tabs: all.length};
                });
            });
            if (count === 0) return {status: 'gone'};
            if (count !== 1 || !found) return {status: 'moved'};
            return {status: 'ok', hit: found};
        }

        if (request.action === 'snapshot') return JSON.stringify({status: 'ok', windows: inventory()});
        if (request.action === 'raise') {
            // ADR 0016: set the tab-window's `frontmost`, then activate. Only a window holding the one tab.
            const found = locate(request.window, request.tty);
            if (found.status !== 'ok') return JSON.stringify({status: found.status});
            if (found.hit.tabs !== 1) return JSON.stringify({status: 'moved'});
            app.set(E.property(found.hit.window, 'pisf'), true);
            app.activate();
            return JSON.stringify({status: 'ok'});
        }
        if (request.action === 'type') {
            // ADR 0017: `do script` into that tab only; Terminal appends a newline. It never raises Terminal.
            if (typeof request.text !== 'string') return JSON.stringify({status: 'gone'});
            const found = locate(request.window, request.tty);
            if (found.status !== 'ok') return JSON.stringify({status: found.status});
            try {
                app.command('coredosc', request.text, {kfil: found.hit.tab});
            } catch (e) {
                // Terminal quitting while it handled the script may have typed it: not `not_running`.
                if (e.errorNumber === -609) throw E.fail(-1, 'Terminal quit while typing');
                throw e;
            }
            return JSON.stringify({status: 'ok'});
        }
        return JSON.stringify({status: 'unknown'});
    });
}
