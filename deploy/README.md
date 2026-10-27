# KeyTrail 1.2 private aggregate replica and read-only browser

This directory contains a runnable Rust HTTP service, embedded static browser
viewer, and optional private-container deployment. It does not capture keyboard,
mouse, clipboard, text, or coordinates. Sync remains an explicit collector opt-in.
Minute snapshots and durable deletion tombstones reach the service only after aggregate sync is explicitly enabled. Separately opted-in text sync sends AES-GCM ciphertext envelopes and authenticated metadata; the private service never receives its decryption key or plaintext.
Never point a development fixture at a real collector database or upload real data.

## Local private service

From the repository root, with an installed Rust toolchain and system SQLite
headers/library (on Debian: `libsqlite3-dev pkg-config`):

```sh
cargo build --release --locked --manifest-path rust/Cargo.toml -p keytrail-server
./rust/target/release/keytrail-server init /absolute/private/config.json /absolute/private/data personal MY_DEVICE_ID
./rust/target/release/keytrail-server serve /absolute/private/config.json
```

Initialization refuses to replace an existing config, generates two distinct
256-bit OS-random bearer credentials, writes mode `0600`, and never prints them.
The default bind is `127.0.0.1:8787`; open that address locally for the viewer.
Read the file in a local editor to copy `collectorToken` into the collector's
explicit sync configuration and `viewerToken` into the viewer password field.
`MY_DEVICE_ID` must equal the collector's displayed sync device ID. Configuration
is a secret file: keep it out of source control, screenshots, chat, shell command
arguments, URLs, request logs, and browser storage. The viewer keeps its token only
in page memory. Refreshing the page requires login again. The viewer has no
third-party resources, tracking, or remote font requests.

Config keys are `bind`, `dataDir`, optional `demoData` (default `false`), and
`accounts`. Each account has `id`, `deviceId`, `collectorToken`, `viewerToken`.
IDs contain 1–80 ASCII letters, digits, `_`, or `-`; credentials are unique opaque
43–256-character ASCII strings. `init` uses 64-character random hex strings.
Accounts use isolated `dataDir/ACCOUNT/replica.sqlite` files in mode-0700
directories. Creating more accounts requires deliberately editing the protected
configuration; there is no public account creation or token issuance endpoint.
One account binds exactly one collector revision domain. When replacing the
collector's database with unrelated data, create a new account/device binding;
do not reuse an old account's revision sequence.

Use a dedicated separate data directory and `"demoData": true` for demo fixtures.
The viewer then visibly labels the device `[演示数据 / DEMO]`. This is demonstration
validation and cannot establish real input monitoring acceptance.

## Phone / private remote access

Put the service behind your own HTTPS reverse proxy on a private VPN or trusted
LAN. Do not expose port 8787 publicly. The macOS sync client accepts HTTP only
for loopback; use your user-configured HTTPS origin for a phone or another host.
Serve the viewer and `/api/` at the same origin; there is intentionally no CORS
support, URL token, analytics backend, public registration, or third-party relay.
`nginx-private.conf.example` is a location fragment for an existing TLS server;
use your own hostname, certificate, private network restriction, and firewall.
Credentials are bearer secrets and rely on TLS outside loopback. Do not log the
Authorization header or request/response bodies.

On iOS Safari or Android Chrome, open the private HTTPS origin, paste only the
viewer credential, choose a range, and refresh. You may add the page to the home
screen. This is a responsive read-only browser experience; it does not collect
mobile input. The service worker caches the static shell only. API statistics and
credentials are never added to CacheStorage, localStorage, or sessionStorage.
When offline the shell can open, but aggregate queries require reconnection;
there is no fabricated offline last-sync result.

The browser uses its own local calendar/timezone, half-open minute ranges, and
actual elapsed local hours across DST. It offers basic counts and active union,
Top 10 physical keys, BPM with measured-interval evidence, burst occurrence minute,
a Monday-based 7-by-24 active-window heatmap and natural-month calendar, optional entertainment cards, local weekly/monthly
report text, clipboard copy, and minute CSV download. Entertainment formulas mirror
`Sources/KeyTrailCore/FunMetrics.swift`; the fictional per-press distance defaults
to 0.01 m and never changes the reported cursor-display-point distance. Key wear
uses cumulative press count and at least three recorded days among the last 30
finished local days; it does not claim hardware lifetime.

## Optional Docker deployment

`Dockerfile` builds a Linux executable and serves the embedded viewer. The compose
file binds only the host loopback, uses a named state volume, runs as UID 10001,
and has no restart policy or hidden autostart. Run these explicitly:

```sh
docker compose -f deploy/compose.yaml build
docker compose -f deploy/compose.yaml run --rm keytrail init /state/config.json /state/data personal MY_DEVICE_ID
```

Before starting, use a local editor or a volume-management tool to change the
protected config's `bind` to `0.0.0.0:8787` **inside the container only**. Keep
compose's host binding `127.0.0.1:8787:8787`. This is needed because Docker forwards
to the container interface rather than its loopback. Preserve mode `0600`; keep
the file owned by UID 10001. Transfer the credentials through your own secure local
process; never print them in shared tool output. Then run:

```sh
docker compose -f deploy/compose.yaml up -d
docker compose -f deploy/compose.yaml down
```

The named volume survives `down`; do not use `down -v` unless deletion is intended.
The container package is provided for reproducibility. Docker image building and
TLS/VPN deployment must be verified on the actual target; a local Rust/Chromium
fixture is separate evidence.

## Frozen HTTP contract and recovery

Every API requires `Authorization: Bearer TOKEN`. POST requires
`Content-Type: application/json` and a known Content-Length. Tokens never appear
in URLs. Success is `{ "ok": true, "result": ... }`; failure is
`{ "ok": false, "error": "..." }`, with a non-2xx status.

- `POST /api/sync` accepts collector-only `{deviceId,changes}` (at most 1000).
  Core validation applies the whole batch transactionally. Return fields are
  `applied`, `ignored`, `cursor`. The acknowledgement cursor is this request's
  maximum revision, or persisted maximum for an empty request. Keep the collector's
  sent-page cursor after successful acknowledgement; never skip local pages merely
  because a server previously saw a higher global revision.
- `POST /api/query` permits only `summary`, `insights`, `buckets`, `timeline`,
  `summaries`, `trend`, `export`, `exportPage`, and `exportValidate` with their exact field sets. Both scopes may read;
  viewer credentials can never call sync, retention, deletion, ingestion, account
  management, or replica replacement. Scalar summary/insights/legacy export ranges
  permit 100 elapsed years; buckets are limited to 10,000 returned buckets, and
  timeline/summaries retain their core limits. Legacy `export` has an 8 MiB CSV
  budget; complete exports use the separate paginated protocol below.
- `trend` accepts only `{op,ranges}` with at most 400 ordered non-overlapping
  `{start,end}` segments, positive durations of at most 367 days and a total span
  of at most 100×366 days. Starts are minute-aligned. The service rejects unknown
  nested fields, and the core preserves empty buckets. The viewer plans these
  boundaries from its local calendar and clips to the applied range/observation
  time; this does not widen the existing timeline/summaries limits.
- `exportPage` accepts `{op,start,end,cursor?,limit?}` with finite nonnegative
  half-open bounds below epoch `1e12`, including empty or partial-minute ranges.
  Limit is 1–1000 rows (default 500); the actual JSON page stays below 1 MiB.
  It returns `{header,csv,rowCount,totalRows,snapshot,nextCursor,hasMore}`. Append
  the header once per downloaded CSV part and each page's data rows exactly once;
  continue with the opaque `nextCursor`. The cursor binds the exact range and
  persistent database source ID/revision, so a different account, rebuilt database,
  or committed statistics mutation rejects continuation. There is no 8 MiB or
  100-year total-export cutoff. A single unrepresentable row fails explicitly.
  `exportValidate` accepts only `{op,snapshot}` and returns null when unchanged;
  validate before finalizing downloaded parts. The browser emits bounded parts and
  a final manifest; an interrupted or invalidated export remains incomplete.
- `GET /api/status` accepts either scope and returns `deviceId`, `replicaId`,
  `lastSyncedAt` (Unix seconds or null), `cursor`, `readOnly`, and `demoData`.
  Metadata survives process restart. Recreating an account database creates a new
  UUID replica identity even if old metadata remains. The collector must compare
  identity on reconnect, reset its cursor, and replay its retained latest snapshots
  and tombstones when the replica changes.

A failed/lost response is safe to retry. Per-minute revision receipts survive
replica deletion, so an old update cannot revive a later tombstone. Remote deletes
are eventually consistent with the collector's next successful sync. Do not
restore database and metadata from different snapshots: stop the service and back
up each entire account directory consistently. Restore it as a unit or initialize
a new account and replay. Protect backup credentials/data with private permissions.

The intentionally small service processes one request at a time, bounding active
connection concurrency and avoiding unbounded threads. Headers are at most 8 KiB,
bodies at most 2 MiB, result bodies at most 16 MiB. Header/body reads share one
5-second deadline; writes time out after 5 seconds. Duplicate headers, chunked
requests, token-bearing query URLs, oversized bodies, and non-JSON API writes are
rejected. An outer private reverse proxy should bound waiting connections/rate and
terminate TLS. CSP forbids external scripts, framing, objects and cross-origin
connections; API responses use no-store. This is a single private-device replica,
not a public multi-tenant high-availability service.

## Verification

```sh
cargo test --locked --manifest-path rust/Cargo.toml -p keytrail-server
node scripts/test-web-metrics.js
cargo build --locked --manifest-path rust/Cargo.toml -p keytrail-server
NODE_PATH=/path/to/node_modules node scripts/test-private-web.js
```

The browser fixtures use isolated synthetic data and loopback services. Run
`KeyTrailTextChecks` first to create the explicitly synthetic cross-language text
fixture. Prepare Node/Playwright separately; see [testing](../docs/testing.md) for
prerequisites and the distinction between browser emulation, Android OS, Wine,
and actual hardware acceptance. Local diagnostic logs and screenshots are not
part of the public source distribution.

## Optional encrypted text history

Text collection and text sync are separate opt-ins and default off. The server stores only
version-1 AES-256-GCM envelopes (`12-byte nonce + ciphertext + 16-byte tag`) and the
explicit metadata `{id,timestamp,applicationBundleID,characterCount}`. It preserves
base64 AAD bytes exactly and validates their JSON metadata against the outer record.
It never accepts a decryption key or tries to decrypt/tag-verify server-side.
`POST /api/text-sync` uses the collector credential and bound `deviceId`, applies
per-ID revisions/tombstones transactionally, and returns applied/ignored/cursor.
`POST /api/text-query` uses only the viewer credential, accepts `{start,end,offset,limit}`
(limit 1–200), and returns records/offset/nextOffset/hasMore/total/totalCharacters.
Pages also stop at an 8-MiB byte budget. Status provides durable `textReplicaId` and
`textCursor`; text state and tombstones use their own account-local SQLite database.
A recreated text database has a new identity and triggers independent text replay.

The viewer's optional text panel imports an explicitly copied 32-byte Base64 archive
key into WebCrypto in memory, verifies original AAD and GCM authentication, and searches
keywords locally after decryption. Key/keyword/plaintext never enter API requests,
URLs or browser storage. It reports scan coverage and caps displayed matches; use
Continue to finish scanning. The recorded-character total is metadata indexed in the
service; full archive character-speed metrics appear only after the entire range has
been decrypted/authenticated. They union each committed fragment's 30-second window,
clip to the selected range and report characters per archived-active-minute, with a
UTC natural-minute peak. This includes pasted committed fragments and does not claim
to cover all input or measure genuine typing speed. TXT export is an explicit plaintext
export; Clear removes the in-memory key, keyword and displayed results. Disconnect,
new login and page exit revoke outstanding text operations as well.

The cumulative feature viewer also implements per-key Top-10 wear with recent recorded
days, keyboard-only/mouse-only/overlap window classification, seven-day same-clock
comparison with missing-day and DST exclusions, and cumulative keyboard/cursor-point
badges matching the native app. The fun master switch hides those panels, Top-10/BPM,
heatmap and related report fields. Editing a range marks the existing overview stale
until View applies it; reports and CSV retain the displayed applied snapshot range.
Text search separately labels the actual range it scanned.


### 查看时间范围

“今天/本周/本月/本年”在点击刷新时重新计算截至当前分钟的范围；手工编辑后转为固定自定义区间。本地时钟回拨产生的重复分钟需要明确选择第1次或第2次，前跳造成的不存在分钟不能提交。范围终点不包含在结果内。网络失败时页面保留上次成功的报告和CSV范围，并标示新输入尚未应用；文字历史搜索单独使用当前输入，报告文字摘要仍必须与报告范围一致。

验证私有部署时，必须独立检查 HTTPS、目标设备信任链、凭据和同步行为；浏览器视口模拟或拒绝未知 CA 不等于完整手机部署验收。见[已知限制](../docs/known-issues.md)。
