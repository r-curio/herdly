"""Run with: python3 -m unittest discover -s relay/feedback"""

import base64
import io
import json
import unittest

import app


def note(**overrides):
    body = {"kind": "bug", "area": "approvals", "description": "The card stayed up.\nSecond line.",
            "details": ["Herdly 0.9.4 (e1da6fb) · macOS 26.1"],
            "attachments": [{"filename": "shot.png", "contentType": "image/png",
                             "content": base64.b64encode(b"png").decode()}]}
    body.update(overrides)
    return json.dumps(body).encode()


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def relay(sent, clock=None):
    return app.Relay("inbox@example.com", "Herdly <relay@example.com>", sent.append,
                     app.RateLimiter(clock=clock or FakeClock()))


def post(target, body, address="1.2.3.4"):
    return target.handle(address, len(body), io.BytesIO(body).read)


class RelayTests(unittest.TestCase):
    def test_a_valid_note_is_emailed_as_plain_text_with_its_screenshot(self):
        sent = []
        status, _ = post(relay(sent), note())
        self.assertEqual(status, 202)
        email = sent[0]
        self.assertEqual(email["to"], ["inbox@example.com"])
        self.assertEqual(email["subject"], "[Herdly] Bug · Approvals: The card stayed up.")
        self.assertIn("The card stayed up.\nSecond line.", email["text"])
        self.assertIn("  Herdly 0.9.4 (e1da6fb) · macOS 26.1", email["text"])
        self.assertNotIn("html", email)
        self.assertEqual(email["attachments"], [{"filename": "shot.png", "content": "cG5n"}])

    def test_details_left_out_say_so(self):
        sent = []
        post(relay(sent), note(details=None, attachments=[]))
        self.assertIn("App details: not included", sent[0]["text"])
        self.assertNotIn("attachments", sent[0])

    def test_malformed_notes_are_refused_and_nothing_is_sent(self):
        sent = []
        target = app.Relay("i@example.com", "s@example.com", sent.append, app.RateLimiter(limit=100))
        for body in [b"not json", b"[]", note(kind="spam"), note(area="x"), note(description="  "),
                     note(description="a" * 5001), note(details=["x" * 201]),
                     note(attachments=[{"filename": "a.exe", "contentType": "application/x-msdownload",
                                        "content": "AA=="}]),
                     note(attachments=[{"filename": "a.png", "contentType": "image/png", "content": "!!"}]),
                     note(attachments=[{"filename": "a.png", "contentType": "image/png", "content": "AA=="}] * 6)]:
            status, _ = post(target, body)
            self.assertEqual(status, 400, body[:80])
        self.assertEqual(sent, [])

    def test_oversized_bodies_are_refused_before_reading(self):
        sent = []
        status, _ = relay(sent).handle("1.2.3.4", app.MAX_BODY_BYTES + 1, lambda n: self.fail("read"))
        self.assertEqual(status, 413)
        status, _ = relay(sent).handle("1.2.3.4", None, lambda n: self.fail("read"))
        self.assertEqual(status, 411)

    def test_five_sends_an_hour_per_address(self):
        sent, clock = [], FakeClock()
        target = relay(sent, clock)
        for _ in range(5):
            self.assertEqual(post(target, note())[0], 202)
        self.assertEqual(post(target, note())[0], 429)
        self.assertEqual(post(target, note(), address="5.6.7.8")[0], 202)
        clock.now = 3600
        self.assertEqual(post(target, note())[0], 202)
        self.assertEqual(len(sent), 7)

    def test_a_mail_failure_answers_502(self):
        def fail(_):
            raise RuntimeError("Resend answered 500")
        target = app.Relay("i@example.com", "s@example.com", fail, app.RateLimiter())
        self.assertEqual(post(target, note())[0], 502)

    def test_filenames_lose_paths_and_header_characters(self):
        self.assertEqual(app.safe_filename("../../etc/pass\"wd.png", "image/png"), "passwd.png")
        self.assertEqual(app.safe_filename("C:\\Users\\me\\x.png", "image/png"), "x.png")
        self.assertEqual(app.safe_filename("...", "image/jpeg"), "screenshot.jpeg")


if __name__ == "__main__":
    unittest.main()
