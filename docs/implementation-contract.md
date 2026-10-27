# Architecture and implementation contracts

## Ownership and storage

The resident collector owns input monitoring, local writes, pause/resume and its
helper processes. macOS separates an AppKit agent from a SwiftUI dashboard;
KeyTrailPet and KeyTrailFloat are display-only helpers. Closing a dashboard must
exit that process without stopping collection. Quitting the collector stops its
owned helpers. Windows uses Raw Input plus a local authenticated HTTP viewer.

The Rust core preserves SQLite user_version 1 and supports additive schema
extensions. Persistent statistics are minute aggregates, physical-key histograms,
activity masks and rhythm summaries. Ordered input events and screen coordinates
must never be persisted. Only bounded current animation state exists in memory.

Queries use half-open intervals and the user's local calendar. Historical
selection/deletion is minute-granular. Keyboard/mouse activity uses bounded
post-event windows, unioned and capped by observed time. Paused, locked and sleeping
time is excluded. Cursor movement is in display points, not physical desk distance.

## Native boundaries

`KeyTrailCore` contains compatible Swift models and analysis. `KeyTrailRuntime`
links the Rust static library and owns collection, text, retention and sync.
`KeyTrailIPC` provides owner-only local socket transport and shared preferences.
The UI performs bounded serial background RPC and applies results on the UI thread;
response generations prevent stale queries overwriting current selection. Visible
historical summaries and week/month insights expire after thirty seconds; short
live selections retain two-second refresh. This bounds stale retention/deletion
results without keeping a hidden dashboard process alive.

Normal, preview and validation profiles use separate data directories and scoped
Keychain services. Preview cannot collect real input. Existing bundle IDs, service
names and notification names are protocol compatibility values, not secrets.
Changing them requires a migration design rather than search-and-replace.

The pet polls a bounded current pose; its sorted key set has no event order.
Release-only reconciliation checks already-held candidates against current session
state, removes confirmed releases, preserves true holds and emits no statistical
samples. Permission/tap, pause, secure-input and system suspension gates apply.
`resetPetPose` resets transient state only. Rendering continues in common run-loop
modes so menu tracking does not leave a stale pose. Model/SDK inputs are optional
external resources with their own licenses.

The floating statistics view reads only status and summary, normally every two
seconds. It can display the current local hour or day; missing data is an explicit
error/stale state, not a fabricated zero. Closing the float does not stop capture.

## Text, retention and export

Committed text is separately encrypted with AES-GCM and authenticated metadata;
macOS keys use Keychain, Windows keys use current-user DPAPI. No clipboard reading.
Capture is explicit, excludes secure fields, and skips unsupported/inconsistent
snapshots. Focus and pause changes reset the baseline; coverage is not universal.

Text paging binds cursor and query scope to a data revision. Complete TXT/CSV
exports use bounded pages and final snapshot validation. macOS streams to an
owner-only temporary file before atomic publication. The web viewer emits bounded
parts and a final checksum manifest for multi-part exports. Plaintext exports are
explicit user actions and never uploaded automatically.

Capacity/preferences reads use read-only text metadata without retrieving an
encryption key. Combined deletion/retention maintains statistics and text within
an atomic ATTACH transaction and preserves deletion journals. A metadata lower bound
can prevent reaching a requested cap and must be reported honestly.

## Private replication and web viewer

The service binds loopback by default. Collectors and viewers have separate opaque
bearer credentials; accounts bind one device and have isolated databases.
`/api/sync` applies monotonically revisioned minute snapshots/tombstones
idempotently. Text sync is a separate opt-in and uses ciphertext only. Per-minute
revision receipts prevent old retries from resurrecting deleted data.

Replica identity changes reset the collector cursor and replay retained latest
state. Network failure preserves cursors and backoff. No endpoint is preconfigured;
remote access requires the user's private HTTPS origin. The macOS scheduler uses
monotonic time, checks local pending journals at a two-second cadence, and contacts
an idle remote about every sixty seconds. Force bypasses throttles; failed work
retains exponential backoff and durable cursors. New-work scheduling assumes a
healthy maintenance timer and does not promise network completion within three
seconds under failure or suspension. The viewer cannot collect,
delete or manage accounts. Tokens, keys and plaintext stay in page memory.

Scalar summaries and bounded trend/timeline APIs are distinct. Trend supports at
most 400 ordered non-overlapping ranges; calendar plans must handle DST and future
buckets honestly. CSV snapshot identity/revision must cover every exported page.
Web chart failures preserve the full applied base-summary/export range. Text
Clear/disconnect/new-login/page-exit revokes transient keys, keywords and async
results; stale operations cannot restore them. Service contracts and deployment details are in deploy/README.md; tests are in
Rust crate suites and Tests/*Checks.
