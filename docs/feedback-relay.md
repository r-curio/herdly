# Feedback relay

Send Feedback in the menu bar item posts one JSON note to the relay in [`relay/feedback`](../relay/feedback/app.py), which emails it to the maintainer through [Resend](https://resend.com). The app holds no mail credentials. Product behavior is in [product.md](product.md#agreed-feedback); the window is in [DESIGN.md](../DESIGN.md#send-feedback-window).

## Deployment

- Railway project `herdly-feedback` (personal workspace), environment `production`, service `relay`, built from `relay/feedback/Dockerfile`.
- Public URL: `https://relay-production-ea0cde5f.up.railway.app`. The app posts to `/feedback` (`FeedbackRelay.endpoint`); `/health` answers 200.
- Variables: `FEEDBACK_TO` (the inbox), `RESEND_API_KEY` (set by the maintainer, never committed), and optionally `FEEDBACK_FROM`. Without a verified domain in Resend, the default sender `onboarding@resend.dev` only delivers to the Resend account's own address, so `FEEDBACK_TO` must be that address.

Deploy a change from the repository root:

```sh
cd relay/feedback && railway up --service relay --detach
```

## Rules the relay enforces

- `POST /feedback` with `Content-Length` (411 without it), at most 20 MB of screenshots after decoding (413), and a body no larger than that base64-encoded plus 256 KB (413 before reading).
- Five notes per client address per hour (429), keyed on Railway's `X-Real-IP`. `X-Forwarded-For` is ignored because its first entry is caller-supplied.
- Kind, area, description (1–5,000 characters), at most 10 detail lines of 200 characters, and at most five PNG, JPEG, HEIC, GIF, or TIFF attachments; anything else is 400 and nothing is sent.
- The email is plain text. Filenames lose path components and header characters. A Resend failure answers 502, which the app shows as "the feedback service is having trouble".
- Nothing is stored. Logs carry the method, path, and status only.

## Checks

```sh
python3 -m unittest discover -s relay/feedback
swift test --filter FeedbackTests
```
