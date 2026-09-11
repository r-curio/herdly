"""Offline transport checks. Never imports or invokes a live UI request."""
from ghostty_navigation import navigate, observe
from probe_ghostty import session_title

A = '01a09046-5590-7882-adad-6b7f4ec91925'
B = '01a09046-56da-7d83-9a38-02e59d7441ec'
TARGET = {'window_id': 'w', 'tab_id': 'a', 'terminal_id': 'p-a'}
WINDOWS = [{'id': 'w', 'tabs': [
    {'id': name, 'terminals': [{'id': 'p-'+name, 'name': session_title(session)}]}
    for name, session in [('a', A), ('b', B)]]}]


def check(responses, expected, actions):
    calls = []
    def request(value):
        calls.append(value)
        result = responses.pop(0)
        if isinstance(result, Exception):
            raise result
        return result
    assert navigate(A, [A, B], request)['status'] == expected
    assert [c['action'] for c in calls] == actions
    if len(calls) > 1:
        assert calls[1]['target'] == TARGET
        assert calls[1]['title'] == session_title(A)


snapshot = {'status': 'ok', 'windows': WINDOWS, 'selected': None}
check([snapshot, {'status': 'ok'}, dict(snapshot, selected=TARGET)],
      'opened', ['snapshot', 'select', 'snapshot'])
check([snapshot, {'status': 'ok'}, snapshot], 'unknown', ['snapshot', 'select', 'snapshot'])
check([snapshot, {'status': 'unknown'}], 'unknown', ['snapshot', 'select'])
check([dict(snapshot, windows=[])], 'unavailable', ['snapshot'])
check([dict(snapshot, windows=WINDOWS+WINDOWS)], 'unknown', ['snapshot'])
check([snapshot, {'status': 'ok'}, dict(snapshot, windows=[], selected=TARGET)],
      'unknown', ['snapshot', 'select', 'snapshot'])
check([OSError('permission denied')], 'unknown', ['snapshot'])
check([None], 'unknown', ['snapshot'])
print('Offline Ghostty navigation transport checks passed; no UI queried or selected.')

# Execute the actual JXA function against a fake dictionary-shaped application.
# Node has no Apple Events bridge; this cannot contact Ghostty.
import json
import subprocess
from ghostty_navigation import SCRIPT
mock = r'''
const assert = require('node:assert/strict');
let commands = [], duplicate = false, split = false;
const p = {id: () => 'p-a', name: () => TITLE};
const t = {id: () => 'a', terminals: () => split ? [p,p] : [p], focusedTerminal: () => p};
const tabs = () => [t]; tabs.byId = id => { assert.equal(id, 'a'); return t; };
const w = {id: () => 'w', tabs, selectedTab: () => t};
const windows = () => duplicate ? [w,w] : [w];
windows.byId = id => { assert.equal(id, 'w'); return w; };
function Application(id) {
    assert.equal(id, 'com.mitchellh.ghostty');
    return {running: () => true, windows, frontmost: () => true, frontWindow: () => w,
        activateWindow: value => {assert.equal(value,w); commands.push('window');},
        selectTab: value => {assert.equal(value,t); commands.push('tab');}};
}
const request = {action: 'select', title: TITLE, target: TARGET};
assert.equal(JSON.parse(run([JSON.stringify(request)])).status, 'ok');
assert.deepEqual(commands, ['window','tab']);
assert.deepEqual(JSON.parse(run(['{"action":"snapshot"}'])).selected, TARGET);
commands = []; duplicate = true;
assert.equal(JSON.parse(run([JSON.stringify(request)])).status, 'unknown');
assert.deepEqual(commands, []);
duplicate = false; split = true;
assert.equal(JSON.parse(run([JSON.stringify(request)])).status, 'unknown');
split = false; request.target = {...TARGET, tab_id: 'stale'};
assert.equal(JSON.parse(run([JSON.stringify(request)])).status, 'unknown');
assert.deepEqual(commands, []);
'''
subprocess.run(['node'], input='const TITLE='+json.dumps(session_title(A))+';\nconst TARGET='+json.dumps(TARGET)+';\n'+SCRIPT+mock, text=True, check=True)
print('Native script fake-application checks passed; no Apple Events bridge used.')

# A different tab must not acknowledge the originating session.
assert observe(A, [A, B], lambda _: dict(snapshot, selected=TARGET))['status'] == 'foreground'
assert observe(B, [A, B], lambda _: dict(snapshot, selected=TARGET))['status'] == 'background'
assert observe(A, [A, B], lambda _: snapshot)['status'] == 'background'
assert observe(A, [A, B], lambda _: {'status': 'unknown'})['status'] == 'unknown'
assert observe(A, [B], lambda _: dict(snapshot, selected=TARGET))['status'] == 'unknown'
print('Foreground-session observation checks passed.')

assert observe(A, [A, B], lambda _: {'status':'ok', 'windows':WINDOWS})['status'] == 'unknown'
assert observe(A, [A, B], lambda _: dict(snapshot, selected={}))['status'] == 'unknown'
