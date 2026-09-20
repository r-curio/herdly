# Claude usage evidence boundary

Status: automated proof recorded; live product delivery deferred.

The automated checks in `Tests/SteerCoreTests/ClaudeUsageTests.swift` run only against temporary
configuration and support directories. They prove independent five-hour and seven-day decoding,
expiry on a supplied Steer clock, missing-window behavior, spend-limit exclusion, root isolation,
newest-record invalidation, bounded status-line probing, reversible bridge ownership, and repair/undo
conflicts.

The earlier compatibility proof at commit `9b4f835` is a disposable prototype against one tested
first-party Max root. It did not read or change the real Claude settings, credentials, or transcripts.
No consenting live root has been run through this product branch's packaged bridge, so this record
does not claim that live acceptance passed. Unproved roots and windows remain unavailable.
