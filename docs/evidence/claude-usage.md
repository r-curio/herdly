# Claude usage evidence boundary

Status: automated proof recorded; live product delivery deferred.

The automated checks in `Tests/HerdlyCoreTests/ClaudeUsageTests.swift` run only against temporary
configuration and support directories. They prove independent five-hour and seven-day decoding,
expiry on a supplied Steer clock, missing-window behavior, spend-limit exclusion, canonical session
identity, root isolation, malformed newest-record invalidation, bounded status-line probing, one-record
retention, oversized input rejection, unrelated over-cap files, forged-file protection, reversible
bridge ownership, and repair/undo after many refreshes. A packaged helper check separately proved
byte-identical large stdin forwarding, output preservation, early command exit handling, exit 7, and
termination of a spawned descendant when the bridge received cancellation.

The earlier compatibility proof at commit `9b4f835` is a disposable prototype against one tested
first-party Max root. It did not read or change the real Claude settings, credentials, or transcripts.
No consenting live root has been run through this product branch's packaged bridge, so these checks do
not claim live Claude delivery or live usage windows. Unproved roots and windows remain unavailable.
