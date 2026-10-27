# Optional text archive evidence and boundaries

The fixture executable covers deterministic check groups using injected temporary
AES-256 keys and unique temporary SQLite paths. It does not call production Keychain key creation, request AX/Input
Monitoring permission, attach to another app, read the clipboard, or start an
input hook. Run with `swift run KeyTrailTextChecks` after the Rust static library
has been built. The fixture creates an **undisplayed** native `NSTextView` to inspect
its own accessibility provider and drive `setMarkedText`/`insertText`; this is not
an external TextEdit or real IME end-to-end acceptance test.

Apple documents `NSAccessibility.Attribute.textInputMarkedRangeAttribute`:
https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/attribute/textinputmarkedrangeattribute
and `AXUIElementCopyAttributeValue`:
https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue
The local native fixture verifies that NSTextView's provider advertises and reads
`AXTextInputMarkedRange`, exposes an active range during synthetic Chinese preedit,
and clears that range after committing the final Chinese value. Availability
across other processes, TextEdit versions, and third-party editors remains
unverified without user-authorized runtime permission/capture checks. Unsupported
or unreadable composition metadata fails closed with an explicit coverage message.

Capture is off by default. Enabling without an explicit permission flag never
requests permission. Preview/demo rejects enable before invoking AX. Only a recent
user input intent arms a delayed read; role, secure-input/protected state, focus,
selected range, marked range, and text-size checks constrain capture. First focus
builds a memory-only baseline. Contiguous insertion/replacement at that baseline's
caret is extracted as UTF-16-safe Unicode, while unrelated off-caret changes,
deletions, and IME preedit are not archived. App switching, disable, and runtime
pause/lock reset the baseline. This conservative inference is not an OS-provided
proof that every value change was caused by a human; editor coverage is explicit.

TextArchive stores metadata plus AES-GCM ciphertext in its own database. The key
is Keychain-held in production and never written to SQLite or a plaintext key
file. Key lookup disallows authentication UI; incorrect/missing key checks fail
without replacing an existing archive. Explicit exportKey returns base64 to the
caller only when the user requests key export.

Cipher envelope version 1: `metadata = {id, timestamp, applicationBundleID,
characterCount}`; timestamp is Unix seconds, normalized to millisecond precision.
`aadBase64` contains the exact UTF-8 sorted-key JSON metadata bytes.
`sealedBoxBase64` decodes as 12-byte nonce + ciphertext + 16-byte GCM tag.
Clients use the supplied AAD bytes verbatim for WebCrypto AES-GCM. Import verifies
AAD metadata equals outer metadata and verifies the tag/Unicode character count.
The server stores these opaque envelopes without receiving a key.

The text change journal coalesces each ID to its latest revision/record or durable
tombstone. Per-ID receipts survive deletion/restart, preventing duplicate or stale
ciphertext from resurrecting deleted text. The source only advances a sync ack
after authenticated server success (runtime-owned). Default sync stays off.

Search decrypts records in the requested half-open range, never a plaintext index.
The current UI uses `searchPage` / `textSearchPage`, with stable `(time_ms,id)` seek
pagination rather than an offset or a fixed first-10,000-record scan. A page examines
at most 256 candidate records or 4 MiB of encrypted envelopes and returns at most
1 MiB of encoded output. `hasMore` refers to remaining candidates: an empty matching
page can still have a next cursor. `scannedRecords` and `matchedCount` are page-local;
`totalRecords` and `totalCharacters` cover the entire range independent of keyword.
The UI retains only its current plaintext page and a history of input cursors.

The cursor carries an integer Unix-millisecond timestamp, ID, snapshot revision,
and query fingerprint. Entry metadata timestamps remain Unix seconds. Fingerprints
bind the normalized range, keyword, locale, and archive session. Every record mutation
advances a separate transactional query revision, including replicated changes with
a lower source-sync revision. Mutating the archive invalidates earlier cursors and
`textValidateSnapshot`; SQL rollback preserves the prior revision. Range totals use
a single-entry cache keyed by range and revision to avoid a full count on every page.
Fixtures traverse 10,001 records sharing one timestamp without skips, continue empty
keyword pages to a late match, check old-page replay and scope rejection, and traverse
large results within each page's encoded-byte budget.

The current TXT export consumes this same cursor path until every candidate has
been scanned, requiring one revision throughout and a final snapshot validation.
The app streams chunks into a mode-0600 temporary file and only publishes a complete
successful result with atomic rename. Cancellation, stale versions, or write/query
failures preserve the previous target. This path has no whole-export 10,000-record
or 8-MiB limit. The runtime fixture suite separately exercises the RPC and file writer.

Legacy `search` / `textSearch` and `exportTXT` / `textExport` remain compatibility
paths, not the current UI search/export path. Legacy search scans at most 10,000
candidates or 64 MiB of envelopes, bounds output to 4 MiB, and reports incomplete
coverage honestly. Legacy TXT and ciphertext exports reject above 8 MiB or incomplete
coverage rather than silently truncating. Encrypted sync pages retain their separate
conservative 1-MiB budget.

Unified statistics/text deletion attaches the on-disk statistics database to the
archive connection. Both must use DELETE journal mode; one IMMEDIATE transaction
updates both durable change journals and removes both sets of records. Foreign
keys cascade statistic histograms/rhythm. Fixtures inject failures on each database,
verify both data sets and revisions roll back, then confirm the Rust C ABI sees
the committed tombstones. The runtime must end transient activity before calling.

The executable also writes synthetic cross-language test material to
`artifacts/text-interop/`. The clearly labelled TEST ONLY key file is mode 0600
and is never a production Keychain key. Do not use this public test key for real data.

`storageInfo()` includes the entire text SQLite allocation, including encrypted
sync journal bodies and tombstones. Combined retention orders statistics minutes
and text timestamps together, deleting oldest containing minutes in atomic batches.
The final 256 or fewer candidates are removed one complete natural minute at a time,
with compaction and a fresh capacity check between minutes, to preserve a newer
suffix that fits. A copied-database capacity oracle proves that 43 of 44 newer
records survive when deleting one old minute is sufficient, with rollback/version
and tombstone checks. It compacts outside transactions, never drops unacknowledged tombstones, and returns
`limitMet=false` if metadata alone prevents reaching the requested cap. Tests cover
oldest-first/newest-preserved behavior, exact combined file sizes, cascade/journal
updates, first-batch SQL failure rollback, and a 20,000-tombstone metadata floor.
Each batch commits independently; a later error does not undo prior completed
retention batches, and is reported to the caller rather than claiming completion.

AX reads execute on a dedicated serial utility queue, never within the CGEventTap
callback or main run loop. The scheduler retains one in-flight and one latest
queued request; a 100,000-intent fixture checks coalescing and cancellation. Results
are discarded after generation reset or foreground-PID mismatch, and committed
text still requires same-focus, recent-intent, secure-state and selection checks.
Asynchronous initial snapshots remain baselines, so first edits in a newly focused
or stale field may be omitted rather than exporting previously present text.
Baseline freshness is separate from a pending keyboard sample: a pointer snapshot
or completed sample remains reusable for two seconds in the same field even after
the pending intent is cleared. A deterministic post-edit snapshot fixture checks
the first key after a pointer and three separately sampled characters, plus expiry,
focus mismatch, clock reversal and reset. This proves the state transition only;
it does not claim a particular real application's AX scheduling order.

`metrics(start:end:)` reads only `time_ms,char_count` metadata. Each in-range saved
fragment contributes its character count and a timestamp-to-timestamp+30s window,
clipped to the query end; windows are unioned. Records outside the half-open range
contribute neither counts nor activity, including their otherwise-overlapping tails.
Average archived characters per active minute is characters*60/unionSeconds (null
when empty). The peak is summed characters in a natural UTC minute; ties retain
the earliest minute. Pasted fragments count too. These are archive character
metrics, not physical keyboard typing speed, efficiency, complete-day activity,
or evidence that every application/control was captured. The fixture deliberately
invalidates ciphertext and verifies metrics still succeed without decryption.
