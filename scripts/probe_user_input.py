#!/usr/bin/env python3
"""Read-only probe of Codex's recorded user-input questions, for ongoing format checks.

Scans session rollouts for `request_user_input` calls and applies Steer's rule: a call is pending
while the same file has no `function_call_output` for its call id and no `task_complete` or
`turn_aborted` for its turn. Prints pending and recently answered calls so a human can compare with
the running notch. Nothing is written. Exit status 1 means a call had a shape Steer would not read.

  python3 scripts/probe_user_input.py [--sessions ~/.codex/sessions] [--file ROLLOUT] [--days 2] [--watch]
  python3 scripts/probe_user_input.py --self-test
"""
import argparse
import datetime as dt
import glob
import json
import os
import sys
import time
import uuid

TOOL = "request_user_input"
MAX_CALL_ID = 256
MAX_ARGUMENTS = 64 * 1024


def parse_time(text):
    try:
        return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def evidence(lines, session=None):
    """Mirror of ReminderReader.evidence: (pending, answered, unexpected) for one rollout."""
    calls, outputs, ended, unexpected = {}, set(), set(), []
    for index, line in enumerate(lines):
        try:
            event = json.loads(line)
            payload = event["payload"]
        except (ValueError, KeyError, TypeError):
            return [], [], [f"line {index + 1}: not a JSON record with a payload"]
        if index == 0:
            if event.get("type") != "session_meta":
                return [], [], ["first line is not session_meta"]
            if session and payload.get("id") != session:
                return [], [], ["session_meta id does not match"]
            continue
        kind = payload.get("type")
        if event.get("type") == "event_msg" and kind in ("task_complete", "turn_aborted"):
            ended.add(payload.get("turn_id"))
        elif event.get("type") == "response_item" and kind == "function_call_output":
            if isinstance(payload.get("call_id"), str):
                outputs.add(payload["call_id"])
        elif event.get("type") == "response_item" and kind == "function_call" and payload.get("name") == TOOL:
            call_id = payload.get("call_id")
            turn = (payload.get("internal_chat_message_metadata_passthrough") or {}).get("turn_id")
            at = parse_time(event.get("timestamp"))
            problems = []
            if not isinstance(call_id, str) or not 0 < len(call_id.encode()) <= MAX_CALL_ID:
                problems.append("call_id missing or out of bounds")
            try:
                uuid.UUID(turn)
            except (TypeError, ValueError):
                problems.append("passthrough turn_id missing or not a UUID")
            if at is None:
                problems.append("timestamp unreadable")
            questions = None
            arguments = payload.get("arguments")
            if isinstance(arguments, str) and len(arguments.encode()) <= MAX_ARGUMENTS:
                try:
                    questions = json.loads(arguments).get("questions")
                except (ValueError, AttributeError):
                    questions = None
            if not isinstance(questions, list):
                problems.append("arguments unreadable (Steer shows the question without text)")
                questions = []
            identity_problems = [p for p in problems if not p.startswith("arguments")]
            if problems:
                unexpected.append(f"line {index + 1} call {call_id!r}: " + "; ".join(problems))
            if identity_problems:
                continue
            if call_id not in calls:
                calls[call_id] = {"call_id": call_id, "turn": turn, "asked_at": at, "questions": questions}
    pending = [c for c in calls.values() if c["call_id"] not in outputs and c["turn"] not in ended]
    answered = [c for c in calls.values() if c["call_id"] in outputs or c["turn"] in ended]
    pending.sort(key=lambda c: (c["asked_at"], c["call_id"]))
    return pending, answered, unexpected


def describe(call, verdict):
    when = dt.datetime.fromtimestamp(call["asked_at"]).isoformat(timespec="seconds")
    age = time.time() - call["asked_at"]
    print(f"  {verdict} call {call['call_id']} turn {call['turn'][:8]} asked {when} ({age / 60:.1f} min ago), "
          f"{len(call['questions'])} question(s)")
    for question in call["questions"]:
        if not isinstance(question, dict):
            continue
        labels = [o.get("label") for o in question.get("options", []) if isinstance(o, dict)]
        print(f"      [{question.get('header', '')}] {question.get('question', '')}")
        for number, label in enumerate(labels, 1):
            print(f"        {number}. {label}")


def report(paths):
    status = 0
    seen = 0
    for path in paths:
        try:
            with open(path, "rb") as f:
                text = f.read().decode("utf-8", errors="replace")
        except OSError as error:
            print(f"UNREADABLE {path}: {error}")
            continue
        if TOOL not in text:
            continue
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        pending, answered, unexpected = evidence(lines)
        if not (pending or answered or unexpected):
            continue
        seen += 1
        print(os.path.basename(path))
        for call in pending:
            describe(call, "PENDING")
        for call in answered:
            describe(call, "answered")
        for problem in unexpected:
            print(f"  UNEXPECTED {problem}")
            status = 1
    if seen == 0:
        print("no rollouts with user-input calls in range")
    return status


def recent_rollouts(root, days):
    cutoff = time.time() - days * 86400
    found = []
    for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        try:
            if os.path.getmtime(path) >= cutoff:
                found.append(path)
        except OSError:
            continue
    return sorted(found)


def self_test():
    session = "01a09d9b-7642-7b51-bcce-9b66cfe5361f"
    turn = "01a09db7-0c51-7f33-9ebc-4e44f91df22c"
    meta = json.dumps({"type": "session_meta", "payload": {"id": session, "source": "vscode"}})
    arguments = json.dumps({"questions": [{"id": "q", "header": "Nested choices", "question": "Which shape?",
                                          "options": [{"label": "Flexible paths (Recommended)", "description": "x"},
                                                      {"label": "Same levels throughout", "description": "y"}]}]})

    def call(call_id, at="2026-09-14T02:20:36.895Z", args=arguments, passthrough=True):
        payload = {"type": "function_call", "name": TOOL, "call_id": call_id, "arguments": args}
        if passthrough:
            payload["internal_chat_message_metadata_passthrough"] = {"turn_id": turn}
        return json.dumps({"timestamp": at, "type": "response_item", "payload": payload})

    def output(call_id, at="2026-09-14T02:21:41.908Z"):
        return json.dumps({"timestamp": at, "type": "response_item",
                           "payload": {"type": "function_call_output", "call_id": call_id, "output": "{\"answers\":{}}"}})

    def ended(kind):
        return json.dumps({"timestamp": "2026-09-14T02:23:00.135Z", "type": "event_msg", "payload": {"type": kind, "turn_id": turn}})

    checks = []
    pending, answered, unexpected = evidence([meta, call("c1")], session)
    checks.append(([c["call_id"] for c in pending], [], unexpected) == (["c1"], [], []))
    pending, answered, unexpected = evidence([meta, call("c1"), output("c1")], session)
    checks.append(([], [c["call_id"] for c in answered], unexpected) == ([], ["c1"], []))
    pending, answered, unexpected = evidence([meta, call("c1"), ended("turn_aborted")], session)
    checks.append(([], [c["call_id"] for c in answered]) == ([], ["c1"]))
    pending, answered, unexpected = evidence([meta, call("c1", args="not json")], session)
    checks.append(len(pending) == 1 and pending[0]["questions"] == [] and len(unexpected) == 1)
    pending, answered, unexpected = evidence([meta, call("c1", passthrough=False)], session)
    checks.append(pending == [] and len(unexpected) == 1)
    pending, answered, unexpected = evidence([meta, call("c1")[:-5]], session)
    checks.append(pending == [] and len(unexpected) == 1)
    pending, answered, unexpected = evidence([meta, call("c1")], "other")
    checks.append(pending == [] and len(unexpected) == 1)
    for number, ok in enumerate(checks, 1):
        print(f"check {number}: {'ok' if ok else 'FAILED'}")
    return 0 if all(checks) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sessions", default=os.path.expanduser("~/.codex/sessions"))
    parser.add_argument("--file", help="one rollout instead of scanning the sessions tree")
    parser.add_argument("--days", type=float, default=2, help="only rollouts modified within this many days")
    parser.add_argument("--watch", action="store_true", help="repeat every 2 seconds until interrupted")
    parser.add_argument("--self-test", action="store_true", help="run the rule against embedded fixture lines")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    paths = [args.file] if args.file else recent_rollouts(args.sessions, args.days)
    status = report(paths)
    while args.watch:
        time.sleep(2)
        print("---")
        paths = [args.file] if args.file else recent_rollouts(args.sessions, args.days)
        status = report(paths)
    return status


if __name__ == "__main__":
    sys.exit(main())
