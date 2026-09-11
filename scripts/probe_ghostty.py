#!/usr/bin/env python3
"""Read installed Ghostty capabilities and this process's context; no UI calls."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET


def capabilities(root):
    return {node.attrib["name"]: {
        "properties": sorted(p.attrib["name"] for p in node.findall("property")),
        "commands": sorted(p.attrib["command"] for p in node.findall("responds-to")),
    } for node in root.findall(".//class")}


def pane_for_tty(tty, terminals):
    """Resolve only an authoritative exact TTY match from a fresh native snapshot."""
    if not isinstance(tty, str) or not re.fullmatch(r'/dev/ttys[0-9]+', tty):
        return {'status': 'unknown', 'terminal_id': None}
    if not isinstance(terminals, list) or any(not isinstance(item, dict) for item in terminals):
        return {'status': 'unknown', 'terminal_id': None}
    matches = [item for item in terminals if item.get('tty') == tty]
    if len(matches) != 1 or not isinstance(matches[0].get('id'), str) or not matches[0]['id']:
        return {'status': 'unavailable' if not matches else 'unknown', 'terminal_id': None}
    return {'status': 'matched', 'terminal_id': matches[0]['id']}


def probe(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.mitchellh.ghostty":
        raise ValueError("Selected bundle is not Ghostty")
    dictionary = app / "Contents/Resources/Ghostty.sdef"
    try:
        tty = os.ttyname(0)
    except OSError:
        tty = None
    classes = capabilities(ET.parse(dictionary).getroot())
    properties = classes.get('terminal', {}).get('properties', [])
    return {"app_path": str(app), "version": info.get("CFBundleShortVersionString"),
        "dictionary": classes,
        "native_tty_mapping_available": 'tty' in properties,
        "native_pid_mapping_available": 'pid' in properties,
        "invocation_context": {"stdin_tty": tty, "environment": {
            key: os.environ.get(key) for key in (
                "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "GHOSTTY_SURFACE_ID", "GHOSTTY_SESSION_ID")}},
        "session_to_pane_mapping": "unverified",
        "focused_pane": "unknown",
        "limit": "Inherited environment and stdin TTY alone do not prove an exact live pane binding."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/Ghostty.app"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        assert capabilities(ET.fromstring("<dictionary/>")) == {}
        assert capabilities(ET.fromstring('<dictionary><class name="terminal">'
            '<property name="id"/><responds-to command="focus"/>'
            '</class></dictionary>')) == {
                "terminal": {"properties": ["id"], "commands": ["focus"]}}
        panes = [{'id':'pane-a','tty':'/dev/ttys001','cwd':'/same'},
                 {'id':'pane-b','tty':'/dev/ttys002','cwd':'/same'}]
        assert pane_for_tty('/dev/ttys001', panes)['terminal_id'] == 'pane-a'
        assert pane_for_tty('/dev/ttys002', panes)['terminal_id'] == 'pane-b'
        assert pane_for_tty('/dev/ttys001', panes[1:])['status'] == 'unavailable'
        assert pane_for_tty('/dev/ttys001', panes + [panes[0]])['status'] == 'unknown'
        assert pane_for_tty(None, panes)['status'] == 'unknown'
        assert pane_for_tty('/dev/ttys001', [None])['status'] == 'unknown'
        assert pane_for_tty('/same', panes)['status'] == 'unknown'
        assert pane_for_tty('/dev/ttys001', [{'id':'pane-a','cwd':'/same'}])['status'] == 'unavailable'
        print("Ghostty dictionary and exact TTY matching checks passed; no live pane queried.")
    else:
        try:
            print(json.dumps(probe(args.app), indent=2))
        except (OSError, ValueError, ET.ParseError, plistlib.InvalidFileException) as error:
            parser.exit(1, f"Ghostty probe failed: {error}\n")
