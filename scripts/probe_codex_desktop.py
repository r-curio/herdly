#!/usr/bin/env python3
"""Inspect installed Codex protocol capabilities without controlling the app.

Run: python3 scripts/probe_codex_desktop.py
Check the parser: python3 scripts/probe_codex_desktop.py --self-test
Only runs the bundled CLI's version/schema commands, with temporary output.
Does not launch an app server, read conversations, install hooks, or change config.
"""

import argparse
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile


def protocol_methods(value):
    methods = set()
    if isinstance(value, dict):
        method = value.get("properties", {}).get("method", {})
        if isinstance(method, dict):
            methods.update(v for v in method.get("enum", []) if isinstance(v, str))
            if isinstance(method.get("const"), str):
                methods.add(method["const"])
        for child in value.values():
            methods.update(protocol_methods(child))
    elif isinstance(value, list):
        for child in value:
            methods.update(protocol_methods(child))
    return methods


def probe(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.openai.codex":
        raise ValueError("The selected bundle does not identify as Codex.")
    binary = app / "Contents/Resources/codex"
    version = subprocess.run(
        [str(binary), "--version"], check=True, capture_output=True, text=True, timeout=10
    ).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="herdly-desktop-schema-") as directory:
        subprocess.run(
            [str(binary), "app-server", "generate-json-schema", "--experimental", "--out", directory],
            check=True, capture_output=True, text=True, timeout=45,
        )
        schemas = {}
        for name in ("ClientRequest", "ServerRequest", "ServerNotification"):
            schemas[name] = protocol_methods(
                json.loads((Path(directory) / f"{name}.json").read_text())
            )
    requests = schemas["ClientRequest"]
    notifications = schemas["ServerNotification"]
    all_methods = set.union(*schemas.values())
    relevant_requests = {
        "thread/read", "thread/loaded/list", "thread/list", "hooks/list",
    }
    relevant_notifications = {
        "turn/started", "turn/completed", "thread/status/changed",
        "hook/started", "hook/completed", "serverRequest/resolved",
    }
    return {
        "app_path": str(app),
        "bundle_id": info["CFBundleIdentifier"],
        "app_version": info.get("CFBundleShortVersionString"),
        "bundled_cli_version": version,
        "registered_url_schemes": sorted({
            scheme for entry in info.get("CFBundleURLTypes", [])
            for scheme in entry.get("CFBundleURLSchemes", [])
        }),
        "protocol_definitions": {
            "read_queries": sorted(requests & relevant_requests),
            "lifecycle_notifications": sorted(notifications & relevant_notifications),
            "approval_requests": sorted(
                method for method in schemas["ServerRequest"]
                if "approval" in method.lower()
            ),
            "focus_or_read_receipt_named_methods": sorted(
                method for method in all_methods
                if any(part in method.lower() for part in (
                    "focus", "unread", "readstate", "read/state", "viewed"
                ))
            ),
        },
        "verification_limits": [
            "Protocol definitions do not prove access to the running desktop's sessions.",
            "A registered URL scheme does not prove thread navigation works.",
            "No method-name match does not rule out private desktop integration.",
            "Focused conversation, jump-back, and approval handoff are not live-tested.",
        ],
    }


def self_test():
    sample = {"oneOf": [
        {"properties": {"method": {"enum": ["thread/read"]}}},
        {"properties": {"method": {"const": "turn/completed"}}},
        {"properties": {"status": {"enum": ["not-a-method"]}}},
        {"definitions": {"nested": {"properties": {
            "method": {"enum": ["thread/read", "hooks/list"]}
        }}}},
    ]}
    assert protocol_methods(sample) == {"thread/read", "turn/completed", "hooks/list"}
    assert protocol_methods(None) == set()
    print("Protocol method parser self-check passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("/Applications/ChatGPT.app"))
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        try:
            print(json.dumps(probe(args.app), indent=2))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            parser.exit(1, f"Desktop probe failed: {error}\n")
