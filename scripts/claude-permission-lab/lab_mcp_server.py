"""Disposable stdio MCP server for the issue #75 lab. Python standard library only.

Tools:
  lab_echo      ordinary tool; returns its `text` argument. No side effect beyond the call log.
  lab_confirm   same behavior, but marked `_meta["anthropic/requiresUserInteraction"] = true`, which Claude Code
                2.1.296 reads to decide that one-tap Approve/Deny must not be offered for the tool.

Every tools/call is appended to <log dir>/mcp-calls.jsonl so a run can prove whether the call reached the server.

Usage: python3 -I lab_mcp_server.py <log dir>
"""
import json, os, sys, time

LOG = os.path.join(sys.argv[1], "mcp-calls.jsonl")
SCHEMA = {"type": "object", "properties": {"text": {"type": "string", "maxLength": 64}}, "required": ["text"],
          "additionalProperties": False}
TOOLS = [
    {"name": "lab_echo", "description": "Lab tool: echoes the given short text. Harmless.", "inputSchema": SCHEMA},
    {"name": "lab_confirm", "description": "Lab tool: echoes the given short text after the user confirms. Harmless.",
     "inputSchema": SCHEMA, "_meta": {"anthropic/requiresUserInteraction": True}},
]


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        request = json.loads(line)
    except ValueError:
        continue
    method, rid = request.get("method"), request.get("id")
    if rid is None:
        continue  # notifications need no reply
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": request.get("params", {}).get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}}, "serverInfo": {"name": "steer-lab", "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        params = request.get("params", {})
        with open(LOG, "a") as f:
            f.write(json.dumps({"t": time.time(), "tool": params.get("name"), "arguments": params.get("arguments")}) + "\n")
        text = str((params.get("arguments") or {}).get("text", ""))[:64]
        send({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "lab: " + text}]}})
    else:
        send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unsupported"}})
