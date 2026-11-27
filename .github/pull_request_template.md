## Issue

Closes #<!-- issue number -->

## What changed

<!-- A short summary of the behavior or docs that changed. -->

## Checks

- [ ] `swift test`
- [ ] `git diff --check`
- [ ] App, helper, or packaging change: `sh scripts/build-app.sh` and `output/Herdly.app/Contents/MacOS/Herdly --smoke-test`
- [ ] Relay change: `python3 -m unittest discover -s relay/feedback`

<!-- Say what each check reported, and anything you could not verify. -->

## Screenshots

<!-- Required for UI changes. Crop out conversation content. -->

## Safety

- [ ] No real agent configuration (`~/.codex`, `~/.claude`) was changed to run tests or scripts.
- [ ] No transcripts, secrets, or personal paths are included.
