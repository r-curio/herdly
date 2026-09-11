#!/usr/bin/env python3
"""Identify running Codex bundles; does not inspect or control their UI."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys


def app_processes(output):
    for line in output.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        pid, executable = fields
        bundle, marker, name = executable.rpartition(".app/Contents/MacOS/")
        if marker and name and "/" not in name:
            yield int(pid), Path(bundle + ".app"), name


def main():
    output = subprocess.run(
        ["ps", "-axo", "pid=,comm="], check=True, capture_output=True,
        text=True, timeout=10,
    ).stdout
    candidates = []
    for pid, app, executable in app_processes(output):
        try:
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        except (OSError, plistlib.InvalidFileException):
            continue  # A process can exit while being inspected.
        if (info.get("CFBundleIdentifier") == "com.openai.codex"
                and info.get("CFBundleExecutable") == executable):
            candidates.append({"pid": pid, "app_path": str(app),
                               "version": info.get("CFBundleShortVersionString")})
    print(json.dumps({"running_bundles": candidates,
        "selection": "unique" if len(candidates) == 1 else "unknown",
        "focused_conversation": "unknown",
        "limit": "Process identity does not establish focused conversation or navigation."}, indent=2))


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        assert list(app_processes("")) == []
        assert list(app_processes("12 /Applications/My App.app/Contents/MacOS/My App\n"
            "13 /Applications/My App.app/Contents/Resources/helper\ninvalid")) == [
                (12, Path("/Applications/My App.app"), "My App")]
        assert len(list(app_processes("1 /A.app/Contents/MacOS/A\n2 /B.app/Contents/MacOS/B"))) == 2
        print("Process parser self-check passed.")
    else:
        main()
