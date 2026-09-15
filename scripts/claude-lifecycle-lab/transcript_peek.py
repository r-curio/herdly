#!/usr/bin/env python3
"""Bounded, read-only look at a session transcript for records tied to given tool_use_ids.

Usage: transcript_peek.py <run-dir> [tool_use_id ...]

Reads the transcript_path recorded in the run's events (never modifies it), and prints
only the shape of records mentioning those ids: record type, tool_use_id, is_error, and a
short truncated content preview. With no ids, lists every tool_use/tool_result pair found.
This is the "smallest sufficient cleanup evidence" comparison for manual denial and
interrupted-tool cases; it is not a proposal to depend on transcripts in production.
"""
import glob, json, os, sys

run = sys.argv[1]
wanted = set(sys.argv[2:])
paths = set()
for f in glob.glob(os.path.join(run, "events", "*.jsonl")):
    for line in open(f):
        try:
            tp = json.loads(line).get("payload", {}).get("transcript_path")
        except Exception:
            continue
        if tp:
            paths.add(os.path.expanduser(tp))
for tp in sorted(paths):
    print(f"== {tp} exists={os.path.exists(tp)} size={os.path.getsize(tp) if os.path.exists(tp) else 0}")
    if not os.path.exists(tp):
        continue
    with open(tp) as fh:
        for n, line in enumerate(fh):
            if len(line) > 2_000_000:
                print(f"  line {n}: skipped (too large)"); continue
            try:
                rec = json.loads(line)
            except Exception:
                print(f"  line {n}: unparseable"); continue
            msg = rec.get("message") or {}
            content = msg.get("content") if isinstance(msg, dict) else None
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                bt = block.get("type")
                tid = block.get("id") if bt == "tool_use" else block.get("tool_use_id") if bt == "tool_result" else None
                if not tid or (wanted and tid not in wanted):
                    continue
                preview = block.get("content") if bt == "tool_result" else block.get("input")
                preview = json.dumps(preview)[:160] if preview is not None else None
                print(f"  line {n}: record_type={rec.get('type')} block={bt} tool_use_id={tid} is_error={block.get('is_error')} uuid={rec.get('uuid')} preview={preview}")
