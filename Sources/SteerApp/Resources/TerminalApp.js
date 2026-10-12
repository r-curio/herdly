// Terminal.app adapter (#239). One JSON request per call:
//   osascript -l JavaScript TerminalApp.js '{"action": "...", ...}'
// Terminal tabs have no id: every ⌘T tab is its own scripting window, and a tab is addressed by its
// window id and its read-only `tty`, resolved fresh on every call (docs/evidence/terminal-app-live.md).
// Nothing here launches Terminal, creates a window or tab, or types anywhere but the one tab named.
function run(argv) {
    const request = JSON.parse(argv[0]);
    const app = Application('com.apple.Terminal');
    if (!app.running()) return JSON.stringify({status: 'not_running'});

    const ttyPattern = /^\/dev\/ttys[0-9]{1,12}$/;
    function title(tab) {
        try {
            const value = tab.customTitle();
            return typeof value === 'string' ? value : null;
        } catch (e) { return null; }
    }
    // Front window first: Terminal lists windows in front-to-back order.
    function inventory() {
        return app.windows().map(w => ({id: w.id(), tabs: w.tabs().map(t => ({tty: t.tty(), title: title(t)}))}));
    }
    // The tab with `tty` in window `windowID`. `gone` when no tab anywhere has the tty (the session's
    // tab closed); `moved` when it has, but not exactly once or not in that window (a layout change).
    function locate(windowID, tty) {
        if (typeof windowID !== 'number' || typeof tty !== 'string' || !ttyPattern.test(tty)) return {status: 'gone'};
        let found = null, count = 0;
        app.windows().forEach(w => {
            const id = w.id();
            w.tabs().forEach(t => {
                if (t.tty() !== tty) return;
                count += 1;
                if (id === windowID) found = {window: w, tab: t, tabs: w.tabs().length};
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
        const hit = found.hit;
        hit.window.frontmost = true;
        app.activate();
        return JSON.stringify({status: 'ok'});
    }
    if (request.action === 'type') {
        // ADR 0017: `do script` into that tab only; Terminal appends a newline. It never raises Terminal.
        if (typeof request.text !== 'string') return JSON.stringify({status: 'gone'});
        const found = locate(request.window, request.tty);
        if (found.status !== 'ok') return JSON.stringify({status: found.status});
        app.doScript(request.text, {in: found.hit.tab});
        return JSON.stringify({status: 'ok'});
    }
    return JSON.stringify({status: 'unknown'});
}
