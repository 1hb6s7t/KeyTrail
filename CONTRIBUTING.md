# Contributing

Keep changes focused and describe the user-visible behavior, relevant validation
and remaining platform limits. Use an issue or pull request in this repository;
never attach real input records, tokens, archive keys or unredacted screenshots.

- Statistics remain minute aggregates and per-minute physical-key histograms.
  Do not persist ordered keystrokes or screen coordinates, or read the clipboard.
- Optional text requires explicit opt-in, authenticated encryption, secure-field
  exclusion and truthful coverage. Sync must remain opt-in and private-endpoint only.
- Preserve SQLite v1 compatibility, half-open ranges and local-calendar queries.
  Only the resident collector writes. Dashboard or pet helpers must not collect.
- Keep demo databases isolated and visibly labeled. Do not enable capture, login
  startup or network synchronization as a side effect of tests.
- Preserve installed applications and user data. Build into new development paths.
  Application IDs and Keychain services require a migration plan if changed.
- Run the checks relevant to a change, including locked Cargo tests, core/runtime
  checks and release build for native integration. Inspect affected UI. Report
  fixture, emulator, Wine, permission and real-input evidence separately.
- Do not vendor SDKs, models or generated app bundles. New dependencies must name
  their license and upstream source; binary distribution has additional notices.

See docs/testing.md for the reproducible test entry points. Before preparing a
source snapshot, run scripts/export-source.py --check. Multi-agent contributors
should assign non-overlapping file ownership and independently review integration.
