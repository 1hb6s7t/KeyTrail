# Aggregate extensions and Rust API

`Engine::open(path: &str) -> Result<Engine, String>` and
`Engine::request(&mut self, input: &str) -> Result<serde_json::Value, String>`
provide a single-caller safe wrapper over the same store as the unchanged C ABI.
The wrapper catches Rust unwinds and returns errors. The C ABI still returns its
owned JSON envelope, while `Engine::request` returns the unwrapped result value.
Authorization belongs to the caller: a server must allowlist viewer queries and
must never expose `replicaApply` or `ingest` to its read-only viewer. The macOS
local dashboard IPC must also exclude both operations.

## Interval and burst measurements

`insights {start,end}` returns `intervalCount`, `intervalSumMs`, nullable `bpm`,
`burstPeak`, nullable `burstPeakAt`, and integer `measuredMinutes`. Intervals from
30 through 2000 milliseconds contribute to mean-interval BPM (`60000 * count /
sumMs`). A sub-30ms interval is not a BPM sample but can still extend a burst.
Consecutive increasing key timestamps no more than 750ms apart form a fast burst;
a first key counts as one. Equal or decreasing timestamps break continuity.
Floating-point threshold comparisons tolerate 0.001ms at Unix epoch magnitudes.

Only aggregate interval counts/sums and per-minute burst peaks are persisted.
**`burstPeakAt` is the UTC minute start, never the raw key timestamp.** This is the
root-approved privacy decision: UI must say "occurrence minute". A burst advances
into its latest minute; historical minutes may retain their earlier partial peak.
Queries select burst records whose occurrence minute is inside `[start,end)`.
Interval totals retain natural-minute selection precision, like existing counters.
A newly captured keyboard minute has `measuredMinutes=1` even if it has too few
valid intervals for BPM. Legacy minutes have no fabricated timing evidence.
Pause/end/restart, deletion, retention, and replica replacement break transient
rhythm continuity. Failed transactions retain the pre-attempt transient state.

## Durable replication

SQLite `user_version=1` and the original `minutes`/`key_histograms` tables stay
compatible. Four additive tables store minute rhythm, a global revision counter,
the latest per-minute sync snapshot/tombstone, and per-minute replica revision
receipts. No ordered keystrokes, coordinates, clipboard data, or free text enter
these tables. Existing rows are bootstrapped exactly once when tracking is first
initialized, in the same transaction as the additive schema.

`syncChanges {after,limit}` accepts a nonnegative cursor and limit 1–1000. Its
result is `{changes,cursor,hasMore}`. Every local changed minute receives a fresh
durable revision. The journal retains only the latest snapshot per minute: it
does not keep successive partial histograms that could reveal input order.
Coalescing never loses a change after an acknowledged cursor, because updating a
minute also advances its revision. Callers persist an acknowledgement only after
successful authenticated application at the private server.

`replicaApply {changes}` returns `{applied,ignored}`. All records are validated
before a single transaction applies them. Per-minute revision receipts survive
deletions and restart, so duplicate or older updates cannot resurrect tombstones.
An update newer than a tombstone represents new collection and is allowed.
Replica application is a server-side sink; it does not echo remote records into
the local collector's outbound journal. This protocol assumes the frozen
single-collector-per-account model; do not merge unrelated revision domains.

Revisions and counts are nonnegative exact JSON-safe integers (revisions start at
1). Minutes are nonnegative, aligned UTC minute starts below 1e12 seconds. Masks
must be decimal **strings** with at most 60 significant bits. Histogram labels
must be canonical physical labels, and their sum must equal `keys`. Rhythm is
optional for legacy records. When present its interval sum must fit the defined
sample window, its measured-minute count is 0 or 1, and a positive burst's endpoint
must equal the record's minute. Unknown record fields are rejected.

## User-controlled retention

`storageInfo {}` returns `databaseBytes`, `minuteCount`, nullable `oldestMinute`
and `newestMinute`. Bytes are SQLite allocated pages times page size.
`retention {maxBytes}` requires at least 1 MiB. It first compacts free pages, then
removes the oldest remaining minute rows in bounded batches, writes durable sync
tombstones in each deletion transaction, and compacts again. Pending activity is
cut over deleted minutes before any later advance; rhythm continuity is reset.
The last 256 or fewer minutes are deleted one minute at a time with a fresh
compacted-byte check, preventing a small excess from erasing the entire final batch.
A temporary database oracle verifies that 43 of 44 rows remain when one deletion
suffices, including failed-transaction rollback and durable tombstones.
It returns `{deletedMinutes,databaseBytes,limitMet}`. Tombstones/metadata can keep
the database above the chosen limit, in which case `limitMet` is honestly false.
A compaction error after committed deletion is reported as an error; already
committed deletions and their tombstones remain durable. Default behavior is
unlimited: only the authorized runtime preference should invoke retention.

All core fixtures use memory or unique temporary SQLite files. These automated
checks establish aggregate, storage, and replication behavior, not OS input
permissions, real input capture, private deployment, or mobile/Windows acceptance.

Legacy `export` checks an 8 MiB byte budget during construction and rejects oversized
results with a smaller-range error, rather than allocating an unbounded response
and checking only after IPC/HTTP serialization. A 240,000-minute histogram fixture
verifies this rejection and that no database contents are changed.

`syncChanges` is bounded by both requested row count and actual serialized change
bytes: the complete page stays below 1 MiB, reserving envelope overhead. Byte-bound
pages return the last included revision and `hasMore=true`, preserving the next
revision for the next request. A 600-minute dense valid histogram fixture verifies
500-row requests split into smaller pages without loss and replicate exact totals.


## Complete paginated CSV export

`exportPage {start,end,cursor?,limit?}` returns
`{header,csv,rowCount,totalRows,snapshot,nextCursor,hasMore}`. `header` is identical
on every page and contains the original two metadata comments and CSV column line
with CRLF endings. `csv` contains only the current page's data rows. Write the
header once, then append each page's CSV. The format, natural-minute count semantics,
half-open range selection, complete-second activity clipping, and lexical histogram
ordering are identical to legacy `export`. Bounds are finite, nonnegative Unix
seconds below 1e12; `end >= start`. Non-minute-aligned bounds retain legacy clipping.
There is no total range, row-count, or 8-MiB whole-export cap on this path.

The default `limit` is 500, valid from 1 through 1000. Every complete serialized JSON
page is at most 1 MiB, accounting for escaping and envelope fields. Pages may end
before `limit` when the byte budget is reached. A single minute that cannot fit
fails explicitly; it is never skipped or partly emitted. No valid collector histogram
requires such a giant row. Two ordered SQLite cursors stream minutes/histograms;
there is no per-minute histogram query and no accumulated full export in core memory.

`snapshot` is `{id,revision}`: `id` is a persistent random 128-bit lowercase hexadecimal
string (32 characters), and `revision` is a safe integer from 0 through 2^53-1.
`nextCursor` is null at completion, otherwise
`{snapshot,start,end,afterMinute}` with an integer UTC-minute position. Pass it back
unchanged. The cursor binds source identity, revision, and exact range. Database
recreation changes the identity even if contents/revision happen to match. Reopening
an unchanged database preserves it. Each page uses one SQLite read transaction for
snapshot, totals, and data. Range totals use a single-entry cache keyed by both range
and full snapshot, avoiding a repeated COUNT during a stable full export.

`exportValidate {snapshot}` returns JSON null on an exact match and otherwise fails
with `export snapshot changed; restart the export`. A client must require the same
snapshot on all pages, append only successful pages, verify summed rowCount equals
totalRows when hasMore becomes false, and perform this final validation before
publishing a complete export. Failed exports must not replace an existing target.

The additive `export_snapshot` table does not change `user_version=1` or existing
aggregate rows. INSERT/UPDATE/DELETE triggers on `minutes`, `key_histograms`, and
`rhythm_minutes` advance the revision in the data transaction; rollback preserves
the previous revision. This covers local collection, delete/clear/retention,
replicaApply (including lower source revisions on other minutes), and writes through
another connection's ATTACH transaction. It deliberately does not rely on sync_state.
No-op UPDATEs conservatively invalidate snapshots. Ignored replica replays do not.
The revision is a change detector, not retained change history or input ordering.

Fixtures cover legacy byte-for-byte CSV equality and partial masks, gaps/empty ranges,
reopen versus rebuilt/other source databases, range/cursor validation, all data tables,
rollback, external ATTACH deletion/cascade, lower-source-revision replicas, existing v1
storage, collection/advance/delete/clear/retention, and complete >8-MiB dense history
with per-page JSON bounds. These are temporary synthetic database checks only.

For a bounded synthetic write-cost check, run
`cargo run --release --locked -p keytrail-core --example export_snapshot_write_benchmark`
from the Rust workspace. It runs one paired comparison on distinct temporary databases:
the same current binary with only the nine export triggers disabled, then enabled.
Each side processes 1,000 real ingest transactions of 32 generated keys, validates
all 32,000 key counts, and reports elapsed/per-batch latency, database bytes, and
snapshot ticks as JSON. Input construction is excluded; JSON parsing, aggregate
and sync writes, and DELETE/FULL commits are included. This is neither a historical
binary comparison nor real input capture evidence, and one sequential pair is not
a general performance distribution across machines or storage configurations.

## Bounded overview trends

The read-only `trend {ranges:[{start,end},...]}` operation returns one
`MinuteBucket` per supplied calendar interval, including zero buckets, with an
empty key histogram and the complete summary fields. It accepts at most 400
ordered, non-overlapping half-open ranges, each at most 367 elapsed days; the
whole first-start to final-end span is at most 100 * 366 days. Starts must be
nonnegative UTC-minute-aligned values and ends may be fractional seconds. Existing
`timeline` and `summaries` limits are unchanged. One ordered minute-table cursor
serves all intervals; counts and complete-second masks sum and peak remains the
natural-minute maximum. No histogram query or database mutation is performed.

The native overview supplies actual local-calendar hour/day/month/year boundaries
from the shared `OverviewTrendPlan`, clipped to the selected interval and current
observation time. It does not ask for decades of hourly buckets just to sum them
again in the chart. Summary queries remain independent if the trend cannot load.
A synthetic 300,000-hour fixture checks a 35-cell response below 20 KiB with exact
counts/activity/peak; the unbounded compatibility `buckets` operation is no longer
used by the current native overview UI.
