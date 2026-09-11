#!/usr/bin/env python3
"""Inspect one installed CLI's protocol, without starting a server or model turn."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from probe_codex_desktop import protocol_methods


def fields(schema):
    return {"required": sorted(schema.get("required", [])),
            "properties": sorted(schema.get("properties", {}))}


def probe(binary):
    version = subprocess.run([str(binary), "--version"], check=True,
        capture_output=True, text=True, timeout=10).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="steer-contract-") as directory:
        subprocess.run([str(binary), "app-server", "generate-json-schema",
            "--experimental", "--out", directory], check=True,
            capture_output=True, text=True, timeout=45)
        root = Path(directory)
        methods = {name: sorted(protocol_methods(json.loads(
            (root / (name + ".json")).read_text())))
            for name in ("ServerRequest", "ServerNotification")}
        selected = {}
        for path in sorted(root.rglob("*.json")):
            if (path.name.endswith("ApprovalParams.json") or path.name in (
                "ServerRequestResolvedNotification.json",
                "HookStartedNotification.json", "HookCompletedNotification.json")):
                selected[str(path.relative_to(root))] = fields(json.loads(path.read_text()))
    return {"binary": str(binary), "version": version,
        "approval_methods": [m for m in methods["ServerRequest"] if "approval" in m.lower()],
        "event_methods": [m for m in methods["ServerNotification"]
            if m.startswith(("turn/", "hook/", "thread/status/", "serverRequest/"))],
        "parameter_fields": selected,
        "live_existing_session_access": "unverified",
        "native_prompt_handoff": "unverified"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        assert fields({}) == {"required": [], "properties": []}
        assert fields({"required": ["b"], "properties": {"b": {}, "a": {}}}) == {
            "required": ["b"], "properties": ["a", "b"]}
        print("Schema field summary self-check passed.")
    elif not args.binary:
        parser.error("--binary must identify the exact runtime being checked")
    else:
        try:
            print(json.dumps(probe(args.binary), indent=2))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            parser.exit(1, f"Contract probe failed: {error}\n")
