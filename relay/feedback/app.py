"""Herdly feedback relay.

Receives one Send Feedback note from the Herdly app and emails it to the maintainer through
Resend. The app holds no mail credentials; this service does, in its environment:

  RESEND_API_KEY  Resend API key (required to send)
  FEEDBACK_TO     inbox that receives the notes (required)
  FEEDBACK_FROM   sender, default "Herdly Feedback <onboarding@resend.dev>"
  PORT            listen port, default 8080

Notes are anonymous. The relay keeps nothing on disk; the only state is an in-memory count of
recent sends per client address for the rate limit.
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable

KINDS = {"bug": "Bug", "idea": "Idea", "other": "Something else"}
AREAS = {
    "notSure": "Not sure", "notch": "Notch", "approvals": "Approvals", "questions": "Questions",
    "completions": "Completions", "settings": "Settings", "terminals": "Terminals",
    "phoneAlerts": "Phone alerts",
}
CONTENT_TYPES = {"image/png", "image/jpeg", "image/heic", "image/gif", "image/tiff"}

MAX_DESCRIPTION = 5_000
MAX_ATTACHMENTS = 5
MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
# Base64 grows the screenshots by a third; the JSON around them is small.
MAX_BODY_BYTES = MAX_ATTACHMENT_BYTES * 4 // 3 + 256 * 1024
MAX_DETAIL_LINES = 10
MAX_DETAIL_LENGTH = 200

RATE_LIMIT = 5
RATE_WINDOW_SECONDS = 3600

RESEND_URL = "https://api.resend.com/emails"
RESEND_TIMEOUT_SECONDS = 30


class Rejected(Exception):
    def __init__(self, status: int, reason: str):
        super().__init__(reason)
        self.status = status
        self.reason = reason


class RateLimiter:
    """At most `limit` sends per address in any `window` seconds."""

    def __init__(self, limit: int = RATE_LIMIT, window: float = RATE_WINDOW_SECONDS,
                 clock: Callable[[], float] = time.monotonic):
        self.limit = limit
        self.window = window
        self.clock = clock
        self.sends: dict[str, deque[float]] = defaultdict(deque)
        self.lock = threading.Lock()

    def allow(self, address: str) -> bool:
        now = self.clock()
        with self.lock:
            recent = self.sends[address]
            while recent and now - recent[0] >= self.window:
                recent.popleft()
            if len(recent) >= self.limit:
                return False
            recent.append(now)
            # Forget idle addresses so the table stays bounded by recent traffic.
            for key in [key for key, times in self.sends.items() if not times]:
                del self.sends[key]
            return True


def parse_note(body: bytes) -> dict:
    """Validates one note. Raises Rejected(400 or 413) for anything malformed or too large."""
    try:
        note = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        raise Rejected(400, "body is not JSON")
    if not isinstance(note, dict):
        raise Rejected(400, "body is not an object")

    kind, area, description = note.get("kind"), note.get("area"), note.get("description")
    if kind not in KINDS:
        raise Rejected(400, "unknown kind")
    if area not in AREAS:
        raise Rejected(400, "unknown area")
    if not isinstance(description, str) or not description.strip() or len(description) > MAX_DESCRIPTION:
        raise Rejected(400, "description missing or too long")

    details = note.get("details")
    if details is not None:
        if (not isinstance(details, list) or len(details) > MAX_DETAIL_LINES
                or not all(isinstance(line, str) and len(line) <= MAX_DETAIL_LENGTH for line in details)):
            raise Rejected(400, "details malformed")

    attachments = note.get("attachments", [])
    if not isinstance(attachments, list) or len(attachments) > MAX_ATTACHMENTS:
        raise Rejected(400, "too many attachments")
    decoded_total = 0
    clean = []
    for attachment in attachments:
        if not isinstance(attachment, dict):
            raise Rejected(400, "attachment malformed")
        content_type = attachment.get("contentType")
        content = attachment.get("content")
        filename = attachment.get("filename")
        if content_type not in CONTENT_TYPES or not isinstance(content, str) or not isinstance(filename, str):
            raise Rejected(400, "attachment malformed")
        try:
            data = base64.b64decode(content, validate=True)
        except (binascii.Error, ValueError):
            raise Rejected(400, "attachment is not base64")
        decoded_total += len(data)
        if decoded_total > MAX_ATTACHMENT_BYTES:
            raise Rejected(413, "attachments too large")
        clean.append({"filename": safe_filename(filename, content_type), "content": content})

    return {"kind": kind, "area": area, "description": description.strip(),
            "details": details, "attachments": clean}


def safe_filename(name: str, content_type: str) -> str:
    base = name.replace("\\", "/").rsplit("/", 1)[-1]
    base = "".join(ch for ch in base if ch.isprintable() and ch not in '"<>:|?*')[:100].strip(". ")
    return base or "screenshot." + content_type.split("/")[1]


def compose_email(note: dict, sender: str, recipient: str) -> dict:
    """The Resend request body. Plain text only, so nothing in the note renders as markup."""
    first_line = note["description"].splitlines()[0]
    summary = first_line[:60] + ("…" if len(first_line) > 60 else "")
    subject = f"[Herdly] {KINDS[note['kind']]} · {AREAS[note['area']]}: {summary}"
    parts = [f"Kind: {KINDS[note['kind']]}", f"Part of Herdly: {AREAS[note['area']]}", "",
             note["description"], ""]
    if note["details"]:
        parts += ["App details:", *("  " + line for line in note["details"]), ""]
    else:
        parts += ["App details: not included", ""]
    if note["attachments"]:
        parts.append(f"Screenshots: {len(note['attachments'])} attached")
    email = {"from": sender, "to": [recipient], "subject": subject, "text": "\n".join(parts)}
    if note["attachments"]:
        email["attachments"] = note["attachments"]
    return email


def resend_send(email: dict, api_key: str) -> None:
    request = urllib.request.Request(
        RESEND_URL, data=json.dumps(email).encode(), method="POST",
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
                 "User-Agent": "herdly-feedback-relay/1"})
    try:
        with urllib.request.urlopen(request, timeout=RESEND_TIMEOUT_SECONDS) as response:
            if not 200 <= response.status < 300:
                raise RuntimeError(f"Resend answered {response.status}")
    except urllib.error.HTTPError as error:
        # Resend's JSON reason (for example an unverified recipient) is the useful part; it never
        # contains the note.
        reason = error.read(1000).decode("utf-8", "replace")
        raise RuntimeError(f"Resend answered {error.code}: {reason}") from None


class Relay:
    def __init__(self, recipient: str, sender: str, send: Callable[[dict], None],
                 limiter: RateLimiter | None = None):
        self.recipient = recipient
        self.sender = sender
        self.send = send
        self.limiter = limiter or RateLimiter()

    def handle(self, address: str, content_length: int | None, read: Callable[[int], bytes]) -> tuple[int, dict]:
        if content_length is None:
            return 411, {"error": "length required"}
        if content_length > MAX_BODY_BYTES:
            return 413, {"error": "too large"}
        if not self.limiter.allow(address):
            return 429, {"error": "too many notes, try again in an hour"}
        try:
            note = parse_note(read(content_length))
        except Rejected as rejected:
            return rejected.status, {"error": rejected.reason}
        try:
            self.send(compose_email(note, self.sender, self.recipient))
        except (urllib.error.URLError, RuntimeError, TimeoutError, OSError) as error:
            print(f"send failed: {error}", file=sys.stderr, flush=True)
            return 502, {"error": "could not send"}
        return 202, {"ok": True}


def client_address(handler: BaseHTTPRequestHandler) -> str:
    # Railway's edge sets X-Real-IP to the caller's address. X-Forwarded-For is not used: its first
    # entry is whatever the caller sent, so it would let anyone dodge the rate limit.
    return handler.headers.get("X-Real-IP", "").strip() or handler.client_address[0]


def make_handler(relay: Relay):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            if self.path == "/health":
                self.reply(200, {"ok": True})
            else:
                self.reply(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/feedback":
                self.reply(404, {"error": "not found"})
                return
            length = self.headers.get("Content-Length")
            try:
                content_length = int(length) if length is not None else None
            except ValueError:
                content_length = None
            status, body = relay.handle(client_address(self), content_length, self.rfile.read)
            self.reply(status, body)

        def reply(self, status: int, body: dict):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            if status >= 400:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, format, *args):
            # Status lines only; never note contents.
            print(f"{self.command} {self.path} {args[1] if len(args) > 1 else ''}", file=sys.stderr, flush=True)

    return Handler


def main() -> None:
    api_key = os.environ.get("RESEND_API_KEY", "")
    recipient = os.environ.get("FEEDBACK_TO", "")
    if not api_key or not recipient:
        sys.exit("RESEND_API_KEY and FEEDBACK_TO must be set")
    sender = os.environ.get("FEEDBACK_FROM", "Herdly Feedback <onboarding@resend.dev>")
    relay = Relay(recipient, sender, lambda email: resend_send(email, api_key))
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(relay))
    print(f"listening on {port}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
