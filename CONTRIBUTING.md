# Contributing to Herdly

Thanks for your interest. Herdly is maintained by one person, so the process is small.

## Before you start

- Open an issue first for anything beyond a small fix. Product behavior is agreed in [docs/product.md](docs/product.md) and the [architecture decisions](docs/adr); a change that alters agreed behavior needs that agreement before code.
- Pull requests are reviewed as part of the normal issue flow; they are not a separate request queue. Link the issue your PR addresses.
- Read [AGENTS.md](AGENTS.md). It is written for coding agents but is the clearest summary of the project's invariants, repository layout, and conventions.

## Making a change

1. Work on a branch named `feat/<issue>-<slug>`, `fix/<issue>-<slug>`, or `docs/<slug>`.
2. Keep the change to one issue and follow the surrounding style.
3. Run the checks:

   ```sh
   swift test
   git diff --check
   ```

   For app, helper, or packaging changes, also run `sh scripts/build-app.sh` and `output/Herdly.app/Contents/MacOS/Herdly --smoke-test`.
4. Never change your real Codex hook or permission configuration to run tests; the lab scripts in `scripts/` use isolated configuration. Read a lab before running it.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
