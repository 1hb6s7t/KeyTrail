# KeyTrail Rust aggregate core

`keytrail-core` exports a system-SQLite static library through the C ABI frozen in
`../docs/implementation-contract.md`. The Swift collector serializes access to each
handle. Every returned string has its own allocation and must be released exactly
once with `keytrail_string_free`; handles are released with `keytrail_close`.
Null handles/arguments are reported as JSON errors. Non-null foreign pointers must
remain valid for their calls; the API cannot validate arbitrary pointer lifetimes.
Panics are caught at the exported C boundaries (release keeps unwind enabled).

The existing SQLite v1 schema is retained. Rows contain only natural-minute
counters, physical-key histograms, and masks for fully elapsed activity seconds.
No raw sample table exists. Unknown key labels become `Other` before SQLite sees
them. Pending 30-second activity windows are memory-only and vanish on restart.
Deleting intersecting minutes also cuts pending windows over those minutes.

A batch is validated and coalesced into per-minute deltas before its transaction.
Statements are reused; 10,000 identical keys in a minute require one minute upsert
and one histogram upsert. A failed transaction does not update pending windows or
the observation clock, so the caller must retain and retry its failed input batch.
An idle advance with no pending window performs no write transaction. Queries do
not advance the collection clock. All time ranges are half-open Unix timestamps;
the Swift client supplies local-calendar boundaries, including DST-length days.

`buckets` can aggregate streamed minute rows into a larger `stepSeconds` and skip
histograms using `includeKeyCounts: false`. Default output retains minute precision
and histograms. `summary` independently calculates exact totals and the maximum
natural-minute keyboard count.

Build and check using `scripts/build-rust.sh` or an installed Cargo toolchain:

```sh
cargo test --locked --manifest-path rust/Cargo.toml
cargo build --release --locked --manifest-path rust/Cargo.toml
```

The tests port all 13 existing Swift store scenarios and add schema compatibility,
transaction rollback/retry, actual SQLite write-count coalescing, coarse buckets,
C allocation/error ownership, JSON contract behavior, and UTC date formatting.
These automated storage tests do not establish macOS input permission, real-event
capture, dashboard appearance, or the resident app's process-memory budget.

The `timeline` RPC accepts `ranges: [{ start, end }, ...]` and returns one bucket
per requested range, including empty buckets. It accepts at most 200 ordered,
non-overlapping ranges, with finite nonnegative timestamps, minute-aligned starts,
positive durations no longer than 7,200 seconds, and a total span no longer than
eight days. Ends may be fractional observation times. Empty input returns `[]`.
The client supplies calendar-derived instants, so 23-hour and 25-hour local days
require no fixed-day assumption in Rust. One ordered minute query and a forward
range cursor distribute counters and precisely clipped activity masks. Histograms
are never queried, and every output `keyCounts` is `{}`. Existing SQLite v1 data
is read without migration or modification.

The release benchmark creates a unique temporary SQLite database with 525,600
minute rows and 525,600 physical-key histogram rows. It verifies all summary fields
for the full year, the final week, the final 31-day month, each of 168 hourly
timeline cells, and all 31 daily summaries before
measuring nine repeated queries. JSON goes to stdout; the temporary database is
removed on exit. No Application Support path or real user database is used:

```sh
cargo run --release --locked \
  --manifest-path rust/Cargo.toml --example timeline_benchmark
```

Reported timings include the Rust C ABI request/response JSON serialization and
parse, with system SQLite and warm caches after correctness verification. They
exclude Swift, IPC, UI, and real-input monitoring; they are not whole-app latency
or memory-budget acceptance results.


The `summaries` RPC uses the same `ranges` shape, ordered minute cursor, zero-bucket
output, complete-second masks, and natural-minute counter precision as `timeline`.
Its separate limits allow at most 32 ranges, each up to 32 elapsed days, and a total
span up to 400 elapsed days. This supports local-calendar daily/monthly queries
and separated comparison windows. Starts remain finite, nonnegative and aligned
to a UTC minute; ends may be fractional, and ranges must remain positive, ordered,
and non-overlapping. It never reads histograms or writes SQLite. The original
`timeline` limits of 200 ranges, two hours per range, and eight days overall are
unchanged. Both methods share aggregation and validation logic with explicit
per-operation limits.
