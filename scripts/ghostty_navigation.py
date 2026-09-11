"""Issue #3 navigation adapter. Importable only; no live test entry point.

The application must supply current live session IDs and run this off its UI thread.
No terminal input or approval commands are supported.
"""
import json
import subprocess
from probe_ghostty import session_title, tab_for_session

# JXA uses Ghostty's installed scripting dictionary. Never run during offline checks.
SCRIPT = r'''
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
    if (request.action === 'snapshot')
        return JSON.stringify({status: 'ok', windows: inventory(), selected: selected()});
    if (request.action !== 'select') return JSON.stringify({status: 'unknown'});
    // Recheck the entire inventory immediately before any selection.
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
    app.activateWindow(w);
    app.selectTab(t);
    return JSON.stringify({status: 'ok'});
}
'''


def native_request(request):
    result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', SCRIPT,
                             json.dumps(request)], capture_output=True, text=True, timeout=5)
    if result.returncode != 0:
        return {'status': 'unknown'}
    return json.loads(result.stdout)


def observe(session, live_sessions, request=native_request):
    """Acknowledge only a fresh, uniquely matched, foreground session."""
    try:
        snapshot = request({'action': 'snapshot'})
        if snapshot.get('status') != 'ok' or 'selected' not in snapshot:
            return {'status': 'unknown', 'target': None}
        selected = snapshot['selected']
        if selected is not None and (not isinstance(selected, dict) or
                set(selected) != {'window_id', 'tab_id', 'terminal_id'} or
                any(not isinstance(value, str) or not value for value in selected.values())):
            return {'status': 'unknown', 'target': None}
        match = tab_for_session(session, live_sessions, snapshot.get('windows'))
        if match['status'] != 'matched':
            return match
        return {'status': 'foreground' if snapshot.get('selected') == match['target']
                else 'background', 'target': match['target']}
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, AttributeError):
        return {'status': 'unknown', 'target': None}


def navigate(session, live_sessions, request=native_request):
    """Fresh match -> native revalidation/selection -> fresh verified match.

    A failure after selection means unknown, not success or acknowledgment.
    Caller must invalidate ended sessions before invoking; no cached locators accepted.
    """
    try:
        before = request({'action': 'snapshot'})
        if before.get('status') != 'ok':
            return {'status': 'unknown', 'target': None}
        match = tab_for_session(session, live_sessions, before.get('windows'))
        if match['status'] != 'matched':
            return match
        target = match['target']
        result = request({'action': 'select', 'target': target, 'title': session_title(session)})
        if result.get('status') != 'ok':
            return {'status': 'unknown', 'target': None}
        after = request({'action': 'snapshot'})
        if (after.get('status') == 'ok' and after.get('selected') == target and
                tab_for_session(session, live_sessions, after.get('windows')) == match):
            return {'status': 'opened', 'target': target}
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, AttributeError):
        pass
    return {'status': 'unknown', 'target': None}
