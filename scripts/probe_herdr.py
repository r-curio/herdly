#!/usr/bin/env python3
"""Read-only herdr-in-Ghostty probe for the live proof (#102).

Reads one herdr server's snapshot, counts the TUI clients attached to that
server from lsof peers, walks each client's process ancestry to its outer
terminal, and optionally reads Ghostty's window/tab/terminal names. It sends no
herdr request that changes state, no Ghostty command and no key.

Output is sanitized JSON: agent session values and herdr IDs are printed (they
come from a disposable session), cwd values are reduced to their last path
component, and Ghostty names that do not contain the marker are only counted.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

TIMEOUT = 5
HERDR_DIR = Path.home() / '.config' / 'herdr'

GHOSTTY_INVENTORY_JS = r'''
const app = Application("com.mitchellh.ghostty");
const out = [];
app.windows().forEach((w) => {
  w.tabs().forEach((t) => {
    const terms = t.terminals();
    out.push({window: w.id(), tab: t.id(), selected: t.selected(),
              terminals: terms.map((x) => ({id: x.id(), name: x.name()}))});
  });
});
JSON.stringify(out);
'''


def run(argv):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=TIMEOUT)
    if result.returncode != 0:
        raise RuntimeError(f'{argv[0]} exited {result.returncode}: {result.stderr.strip()[:200]}')
    return result.stdout


def client_socket(session):
    if session == 'default':
        return HERDR_DIR / 'herdr-client.sock'
    return HERDR_DIR / 'sessions' / session / 'herdr-client.sock'


def parse_lsof(text):
    """Parse `lsof -F pfdn` output into (pid, fd, device, name) records."""
    records, pid, fd, device = [], None, None, None
    for line in text.splitlines():
        tag, value = line[:1], line[1:]
        if tag == 'p':
            pid, fd, device = int(value), None, None
        elif tag == 'f':
            fd, device = value, None
        elif tag == 'd':
            device = value
        elif tag == 'n' and pid is not None:
            records.append((pid, fd, device, value))
    return records


def attached_clients(records, socket_path):
    """Return the server PIDs and the PIDs whose unix peer is a server-side
    connection on `socket_path`. The listener and its accepted connections all
    carry the path as their name; a connection is a device a peer points at."""
    path = str(socket_path)
    owned = {(pid, device) for pid, _, device, name in records if name == path}
    servers = sorted({pid for pid, _ in owned})
    devices = {device for _, device in owned}
    peers = sorted({pid for pid, _, _, name in records
                    if name.startswith('->') and name[2:] in devices and pid not in servers})
    return {'server_pids': servers, 'client_pids': peers}


def ancestry(pid, limit=8):
    chain = []
    while pid > 1 and len(chain) < limit:
        fields = run(['ps', '-o', 'ppid=,tty=,comm=', '-p', str(pid)]).split(None, 2)
        if len(fields) < 3:
            break
        ppid, tty, comm = int(fields[0]), fields[1], fields[2].strip()
        chain.append({'pid': pid, 'tty': tty, 'command': os.path.basename(comm)})
        pid = ppid
    return chain


def summarize_snapshot(snapshot):
    tabs = {tab['tab_id']: tab for tab in snapshot.get('tabs', [])}
    agents = []
    for agent in snapshot.get('agents', []):
        tab = tabs.get(agent.get('tab_id'), {})
        agents.append({
            'pane_id': agent.get('pane_id'),
            'tab_id': agent.get('tab_id'),
            'tab_pane_count': tab.get('pane_count'),
            'agent': agent.get('agent'),
            'agent_status': agent.get('agent_status'),
            'agent_session': agent.get('agent_session'),
            'focused': agent.get('focused'),
            'terminal_title': agent.get('terminal_title_stripped'),
            'cwd_name': os.path.basename(agent.get('cwd') or '') or None,
        })
    return {
        'version': snapshot.get('version'),
        'protocol': snapshot.get('protocol'),
        'focused': {key: snapshot.get(f'focused_{key}_id') for key in ('workspace', 'tab', 'pane')},
        'workspaces': [{'id': w.get('workspace_id'), 'label': w.get('label')}
                       for w in snapshot.get('workspaces', [])],
        'tabs': [{'id': t['tab_id'], 'label': t.get('label'), 'pane_count': t.get('pane_count'),
                  'focused': t.get('focused')} for t in tabs.values()],
        'agents': agents,
    }


def ghostty_matches(inventory, marker):
    """Return the tabs with a terminal whose name contains `marker`, and the
    total terminal count. Names without the marker are not returned."""
    matches, total = [], 0
    for tab in inventory:
        for term in tab.get('terminals', []):
            total += 1
            if marker and marker in (term.get('name') or ''):
                matches.append({'window': tab['window'], 'tab': tab['tab'], 'selected': tab['selected'],
                                'terminal': term['id'], 'tab_terminal_count': len(tab['terminals']),
                                'name': term['name']})
    return {'terminal_count': total, 'matches': matches}


def probe(session, marker, read_ghostty):
    base = ['herdr'] if session == 'default' else ['herdr', '--session', session]
    report = {'session': session}
    report['status'] = json.loads(run(base + ['status', '--json']))['server']
    report['snapshot'] = summarize_snapshot(json.loads(run(base + ['api', 'snapshot']))['result']['snapshot'])
    sock = client_socket(session)
    clients = attached_clients(parse_lsof(run(['lsof', '-nP', '-U', '-F', 'pfdn'])), sock)
    clients['client_socket'] = str(sock).replace(str(Path.home()), '~')
    clients['ancestry'] = {str(pid): ancestry(pid) for pid in clients['client_pids']}
    report['clients'] = clients
    if read_ghostty:
        inventory = json.loads(run(['osascript', '-l', 'JavaScript', '-e', GHOSTTY_INVENTORY_JS]))
        report['ghostty'] = ghostty_matches(inventory, marker)
    return report


def self_test():
    path = '/x/herdr-client.sock'
    text = '\n'.join(['p10', 'f3', 'd0xL', f'n{path}', 'f4', 'd0xA', f'n{path}', 'f5', 'd0xB', f'n{path}',
                      'p20', 'f4', 'd0xC', 'n->0xA', 'f5', 'd0xC', 'n->0xA',
                      'p30', 'f4', 'd0xD', 'n->0xB',
                      'p40', 'f4', 'd0xE', 'n->0xZ'])
    clients = attached_clients(parse_lsof(text), path)
    assert clients == {'server_pids': [10], 'client_pids': [20, 30]}, clients
    assert attached_clients(parse_lsof(text), '/other.sock') == {'server_pids': [], 'client_pids': []}
    inventory = [{'window': 'w', 'tab': 't1', 'selected': True,
                  'terminals': [{'id': 'a', 'name': 'host: steer-probe'}]},
                 {'window': 'w', 'tab': 't2', 'selected': False,
                  'terminals': [{'id': 'b', 'name': 'private title'}, {'id': 'c', 'name': None}]}]
    found = ghostty_matches(inventory, 'steer-probe')
    assert found['terminal_count'] == 3 and [m['terminal'] for m in found['matches']] == ['a'], found
    assert 'private title' not in json.dumps(found)
    assert ghostty_matches(inventory, '')['matches'] == []
    snap = summarize_snapshot({'tabs': [{'tab_id': 'w1:t1', 'pane_count': 1}],
                               'agents': [{'tab_id': 'w1:t1', 'pane_id': 'w1:p1', 'cwd': '/a/b/lab'}]})
    assert snap['agents'][0]['tab_pane_count'] == 1 and snap['agents'][0]['cwd_name'] == 'lab', snap
    print('probe_herdr self-test passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--session', default='steer-probe', help='herdr session name (default: steer-probe)')
    parser.add_argument('--ghostty', action='store_true', help="also read Ghostty's window/tab/terminal names")
    parser.add_argument('--marker', default='', help='substring identifying the herdr client in a Ghostty title')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    print(json.dumps(probe(args.session, args.marker, args.ghostty), indent=2))


if __name__ == '__main__':
    main()
