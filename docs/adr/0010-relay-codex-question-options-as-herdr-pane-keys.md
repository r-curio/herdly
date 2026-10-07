# Relay Codex question options as herdr pane keys

Accepted with the user on 2026-10-07 (issue #106). This is the herdr counterpart of ADR 0006. When a Codex CLI session in a herdr pane asks a `request_user_input` question and the Codex daemon does not hold that call, a click on an option sends exactly one `agent.send_keys` request to the bound pane over herdr's socket (ADR 0009). The request carries only the option's one-based digit. The live proof (`docs/evidence/herdr-ghostty-live.md`) showed that the digit alone selects and submits an option in Codex 0.154.0. Approvals are never keys.

## Rules

- **Target:** the key is addressed to the pane ID from the session's pane binding (ADR 0008), never to an herdr agent name, which is a user-chosen label. A paste, `herdr agent prompt`, or text input is never used. Acceptance must show that `agent.send_keys` accepts a pane ID target. If it does not, the herdr relay is unavailable, with no fallback to names.
- **Payload:** one digit `1` to `8` per clicked option. Enter is never sent, unlike ADR 0006's conditional Enter. If a later Codex release stops committing on the digit, the answer shows as unconfirmed and this decision is revisited. Text, Other, None of the above, Skip and Escape are never sent.
- **Fresh check before sending:** immediately before the key, Steer re-reads the rollout (no output for the call, turn not ended, rollout readable). It also takes a fresh snapshot and re-runs ADR 0008's target checks, and herdr must report the pane's agent as `blocked`. Any other agent status makes the relay unavailable. `blocked` is a veto only: it never proves the question is still pending. This closes the gap between a manual answer in the pane and Codex writing its output to the rollout.
- **Precedence:** the daemon route (ADR 0007) wins whenever the daemon holds the pending request for that exact thread and call ID. Otherwise a herdr-bound session uses herdr keys and a Ghostty-tab-bound session uses Ghostty keys (ADR 0006). A session that appears bound to both is unavailable.
- **One route per call:** once any answer for a call has left Steer by one route, every later question in that call uses the same route. Key progress through a multi-question call never moves to the daemon, whose single response would overwrite the TUI's partial answers, and a daemon answer in progress never moves to keys.
- **Eligibility and progress:** the same as the Ghostty relay. Only questions whose listed options Steer can number exactly (one to eight) have controls. `isSecret` offers nothing. Multi-question calls advance optimistically, one digit per question. One key per call and question index, sent only after a click, never on a timer, retry, restart or error.
- **Failure:** a failed check before sending yields one typed unavailable reason (ADR 0009). Nothing is sent, and the card offers Open in Codex. If the socket write may have happened (timeout, disconnect, malformed or mismatched reply after writing), the key counts as sent and is never resent. A herdr `ok` means only that the bytes were queued. A last answer with no rollout output within 10 seconds becomes unconfirmed and offers Open in Codex. Only resolution evidence or Dismiss clears the question.

## Considered options

- **Address the key by agent name:** names are not unique and are not an identity.
- **Send the digit and Enter:** the live proof showed Enter is unnecessary, and a stray Enter could act on the next screen.
- **Trust the rollout alone before sending:** it misses a manual answer that Codex has not yet written to the rollout.
- **Switch to the daemon partway through a keyed call:** its whole-call response would override the answers already given by key.

Not yet shown live: a pane ID target for `send_keys`, multi-question calls in herdr, the race against a manual answer, and a key sent to an agent that is not blocked. Each must pass before acceptance.
