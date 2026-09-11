#!/usr/bin/env python3
"""Read installed Ghostty capabilities and this process's context; no UI calls."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET


def capabilities(root):
    return {node.attrib["name"]: {
        "properties": sorted(p.attrib["name"] for p in node.findall("property")),
        "commands": sorted(p.attrib["command"] for p in node.findall("responds-to")),
    } for node in root.findall(".//class")}


def probe(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.mitchellh.ghostty":
        raise ValueError("Selected bundle is not Ghostty")
    dictionary = app / "Contents/Resources/Ghostty.sdef"
    try:
        tty = os.ttyname(0)
    except OSError:
        tty = None
    return {"app_path": str(app), "version": info.get("CFBundleShortVersionString"),
        "dictionary": capabilities(ET.parse(dictionary).getroot()),
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
        print("Ghostty dictionary self-check passed.")
    else:
        try:
            print(json.dumps(probe(args.app), indent=2))
        except (OSError, ValueError, ET.ParseError, plistlib.InvalidFileException) as error:
            parser.exit(1, f"Ghostty probe failed: {error}\n")
