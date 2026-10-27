# Known limits and follow-ups

Feature implementation, automated checks and platform acceptance are separate.
Current source includes optional text/private sync, desktop statistics, mobile
viewing and native desktop-cat integration; this does not promise universal editor,
device or OS behavior.

## Recently resolved in source

- Capacity maintenance preserves active-time windows when no history is deleted.
  A below-limit check does not compact databases or reset input/text state; when
  reclaiming free pages is enough, activity also continues. Live activity is ended
  only immediately before the first necessary deletion, retaining atomic deletion
  journals and protection against deleted minutes reappearing.
- Windows keypad digits, operators and Enter now retain distinct `Num …` labels;
  NumLock, ScrollLock, Insert and PrintScreen use bounded physical labels. Previously
  merged history cannot be reconstructed; the change does not rewrite old rows.
- macOS sync inspects pending local work at a two-second cadence and uses a
  sixty-second idle remote heartbeat. Pending changes, forced sync and failure
  backoff remain independent. A quiet rebuilt replica may take the next heartbeat
  plus network time to recover; this is not a hard real-time SLA.
- Visible historical dashboard statistics and week/month insights refresh at a
  thirty-second cadence, so retention or another client's deletion cannot leave
  the selection cached indefinitely. Short live ranges retain two-second refresh.
- Web Clear, disconnect, new login and page exit clear text-search keywords and
  revoke stale key imports/search results. Plaintext intentionally exported by the
  user remains the user's file and is not deleted by clearing the page.
- Web trends cover the entire applied selection using bounded local-calendar
  hour/day/month/year cells. Future time is excluded and missing records are
  labeled. An auxiliary chart failure does not replace the base summary or CSV
  range with a smaller interval.

## Remaining acceptance boundaries

- Committed-text coverage and IME preedit exclusion require editor-specific real
  input checks. Secure-field, lock/sleep, login startup, multi-monitor/DPI and
  sustained resource behavior require platform-specific checks.
- Wine checks are compatibility-layer evidence. Chromium/WebKit phone profiles are
  browser emulation. The current assets passed an Android 16 OS emulator flow with
  native login touch, 201 text records across two pages, and verified downloads of
  2,010 CSV rows plus manifest/report files. This does not establish iOS, physical
  devices, mobile background recovery or PWA installation behavior.
- The current private service passed verified local HTTPS through the shipped
  nginx fragment, including unknown-CA/wrong-host rejection and role/deletion
  checks. Android 16 OS emulator HTTPS now passes the normal CA installation
  flow: untrusted rejection before installation, verified TLS 1.3 afterward,
  viewer login, fixed-range refresh, CSV/report downloads and disconnect clearing.
  The shipped Dockerfile also builds the current service, with cached dependency
  layers, and its new image passes restart and HTTPS checks. External private
  deployment, real collector HTTPS and binary notices remain release checks.
- The public source excludes Live2D SDKs and third-party model assets. A standalone
  cat binary needs those assets and the corresponding distribution-rights review.
- The isolated macOS profiler now requires a visible main window before sampling
  or reporting a reopened dashboard. A reproduced split CLI-argument issue had
  suppressed the fixture's SwiftUI window; the single-argument directory form
  fixes that while preserving strict demo-only storage isolation. Earlier
  process-only measurements do not establish a visible dashboard.
- With the corrected fixture, two 60-second idle samples measured background
  agent RSS median 42.9 MiB / peak 85.8 MiB, and agent plus visible dashboard RSS
  median 159.7 MiB / peak 182.0 MiB. These samples exclude real input, text capture,
  sync, cat and float. They do not establish a sustained 50 MB limit; the observed
  background peak exceeds it. Normal-close and menu-exit evidence is tracked
  separately from startup, process existence and measurements.
- A follow-up, same-binary headless comparison isolated startup seeding: cold
  synthetic seeding peaked at 72.5 MiB, while an empty SQLite fixture and a restart
  of the seeded fixture each peaked at 32.1 MiB over their 60-second samples.
  This implicates synthetic seed allocation in the earlier peak; it does not
  establish memory use during real input, with a menu, optional text or sync.
- The default core benchmark now targets Rust. A verified synthetic year with
  525,600 minute rows and the same number of histogram rows produced warm-query
  medians of about 127 ms for an annual summary, 9 ms for a month and 2 ms for a
  week. This is one local release run, including Rust FFI/JSON but excluding
  Swift, sockets, UI and cold filesystem caches; it is not a latency guarantee.
- A subsequent user-operated isolated demo check passed normal dashboard close,
  continued operation of the same background agent, a visible reopened dashboard,
  and normal agent-menu exit with the currently running owned dashboard. Manual
  confirmation and a separate paired-process observation support this result;
  an already closed old dashboard PID is not evidence of exit propagation.
  Earlier timed-out checks remain failures. This lifecycle-only run did not
  measure post-close memory, real input, or pet/float shutdown under load.

The modifier-release fix has synthetic missed-release/true-hold checks and limited
user-observed physical-key evidence. It does not establish every keyboard, IME or
long-duration scenario. No real input samples or personal test logs are included.
See [requirement coverage](prd-coverage.md) for implementation versus acceptance.
