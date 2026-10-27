# Building and testing

All commands run from the repository root. Generated outputs belong in ignored
`artifacts/`, `.build/` or Rust target directories. Tests use isolated synthetic
databases; never substitute a personal database or enable real sync in a fixture.

## Required local tools

- macOS native code: macOS 14+, Swift 6, Rust stable, Python 3.9+, system SQLite.
- Rust server on Linux: Rust stable, a C toolchain, pkg-config and SQLite headers
  (for example, libsqlite3-dev). Windows builds use the configured bundled SQLite.
- Web checks: Node 20+ and Playwright with the required browser engines. Install
  these explicitly in your own development environment; no dependency tree is
  committed. NODE_PATH may point to an external node_modules directory.
- Docker/Wine and Android checks have additional requirements listed below.

## Core and native checks

```sh
cargo test --locked --manifest-path rust/Cargo.toml
./scripts/test-core.sh
./scripts/test-runtime.sh
swift build -c release
```

`build-rust.sh` uses a provisioned local `.toolchains` directory when present,
otherwise the system Cargo. It does not install tools. Swift links the release Rust
static library, so build Rust before a standalone Swift build. `test-runtime.sh`
builds the Rust library first. Only Command Line Tools may lack XCTest: the Core
script executes the standalone harness, which must not be reported as `swift test`.

Additional current checks after Rust is built:

```sh
swift run -c release KeyTrailPetChecks
swift run -c release KeyTrailFloatingChecks
swift run -c release KeyTrailTextChecks
./scripts/test-sync.sh
./scripts/test-sync-scheduling.sh
node scripts/test-web-metrics.js
```

SyncChecks also waits for an actual idle heartbeat after rebuilding a temporary
replica (about a minute), with no forced request or new local input. The separate
scheduling harness uses a deterministic clock and needs no network or user data.

TextChecks creates a public, explicitly synthetic `artifacts/text-interop` fixture
for Swift/CryptoKit → Rust/WebCrypto interoperation. It must run before private
web/Docker/HTTPS checks that consume that fixture. The fixed key under the Windows
TEST-ONLY fixtures is deliberately public and must never protect user data.

For an isolated build, set CARGO_TARGET_DIR, KEYTRAIL_RUST_LIBRARY_DIR and
KEYTRAIL_SWIFT_SCRATCH consistently. Swift package commands also accept
`--scratch-path`; the library-directory override must point at the Rust release
output. Temporary build caches can be removed after verification.

The default performance entry now exercises the current Rust core, with exact
synthetic results checked before timing repeated warm queries over 525,600 minute
rows and 525,600 histogram rows:

```sh
./scripts/benchmark-core.sh
# When all locked dependencies are already cached:
./scripts/benchmark-core.sh --offline
```

It reports annual, monthly and weekly summaries, weekly hourly cells and monthly
daily cells. The JSON includes the measured source hashes. This replaces the old
Swift-store benchmark; it excludes Swift/UI/socket overhead, cold filesystem cache
behavior and real monitoring, so it cannot establish whole-app memory or latency.

## Browser and private service checks

Build the current Rust server, then run the relevant scripts with Playwright
available. Scripts accepting a server argument should receive the just-built
binary, avoiding stale embedded Web assets:

```sh
node scripts/test-private-web.js rust/target/release/keytrail-server
node scripts/test-mobile-web.js rust/target/release/keytrail-server
node scripts/test-web-login-race.js rust/target/release/keytrail-server
node scripts/test-web-base-activity.js rust/target/release/keytrail-server
node scripts/test-web-dst-range.js
node scripts/test-web-range-trend.js
KEYTRAIL_SERVER=rust/target/release/keytrail-server node scripts/test-web-range-trend-service.js
```

Inspect each script's header/options before running specialized fixtures.
Browser phone profiles are viewport/touch/engine tests, not Android or iOS OS tests.
Docker/HTTPS fixtures use temporary state, random credentials and loopback bindings;
read deploy/README.md before running them. Do not log credential values.

After building the shipped Dockerfile, check that exact image rather than a stale
development tag:

```sh
docker build -f deploy/Dockerfile -t keytrail-private:1.2 .
KEYTRAIL_DOCKER_IMAGE=keytrail-private:1.2 python3 scripts/test-private-docker.py
KEYTRAIL_HTTPS_SERVICE_IMAGE=keytrail-private:1.2 python3 scripts/test-private-https.py
```

The Docker check defaults to `keytrail-private:1.2`. It verifies all eight embedded
Web resources, roles, replica identity across restart, tombstones and export
invalidation. Its result is successful only after owned containers and volumes
are confirmed removed. `KEYTRAIL_DOCKER_OUTPUT` selects the result JSON location.

## Windows compatibility checks

On Windows, use Cargo tests plus `scripts/package-windows.ps1`. On a Docker host,
`scripts/package-windows.sh` builds a release and test PE executables. Build the
Wine image explicitly:

```sh
docker build --platform linux/amd64 -t keytrail-wine:1.2 - < scripts/windows-wine.Dockerfile
python3 scripts/test-windows-wine.py
```

The runner lists and executes each selected current PE test group; it does not
reuse counts from historical reports. Multiple PE variants require explicit
`--test-executable CRATE=FILENAME` selection. `--demo-only` does not establish PE
suite success. GUI/capture checks also need `keytrail-wine-ui:1.2` and
`keytrail-windows-builder:1.2`; their scripts share helper definitions, so keep
those sources together. Wine is not Windows-kernel, hardware, UIA/IME or DPAPI
acceptance; validate supported Windows versions separately.

## Android and native permissions

The Android OS script requires ANDROID_SDK_ROOT (or ANDROID_HOME), JAVA_HOME,
SDK tools, and an already-installed Android 36 Google APIs arm64-v8a image.
KEYTRAIL_AVDMANAGER may override `cmdline-tools/latest/bin/avdmanager`.
It creates a disposable isolated AVD and refuses to take over another device.
It does not download SDKs/images or accept licenses. Read the script options and
prepare Playwright's Android support explicitly.

`test-android-os-web.js --large` checks the current embedded assets, native login
tap, paged text results and actual Android Downloads files in a disposable guest.
Set `KEYTRAIL_SERVER` to the current native server. The HTTPS variant uses a
temporary CA and normal Android Settings installation; it must fail if the trust
flow cannot be completed, without ignoring certificate errors or modifying system
trust files. `KEYTRAIL_HTTPS_SERVICE_IMAGE` selects the freshly built service image
for the HTTPS fixtures. Record its digest and embedded asset hashes.

macOS Input Monitoring and optional Accessibility permission require normal system
approval. Automated fixture checks do not prove physical-key monitoring. Keep
permission, real input, secure-input, lock/sleep and performance evidence separate.
Measure collector-only, pet/float and dashboard-open process costs separately;
short idle samples cannot establish sustained CPU, power or memory behavior.

For a current release Agent/Dashboard pair, the isolated runtime profiler is:

```sh
python3 scripts/measure-runtime-profile.py \
  --agent .build/release/KeyTrailAgent --output artifacts/runtime-profile
python3 scripts/test-auto-sync-latency.py \
  --agent .build/release/KeyTrailAgent --server rust/target/release/keytrail-server
```

The first command requires closing only the newly opened fixture window when
requested; it samples menu-agent, dashboard-open and dashboard-closed states.
A visible main window belonging to the fixture must be observed before the open
state and again after reopening; a live process or menu-bar window is insufficient.
Use `--shutdown-mode ui` to verify the normal agent menu exit as well; the default
IPC shutdown is recorded separately and is not evidence of a menu click.
For UI evidence, pair the user's current action confirmation with observations of
both the agent and its currently running dashboard. A final absent PID alone is
insufficient: a dashboard already closed before the menu action cannot prove that
quitting the agent closes its helper. Keep earlier failed runs separate.
`--lifecycle-only --shutdown-mode ui` skips resource sampling for a focused UI check.
All fixture programs use `--demo --test-directory=/absolute/temporary/path`. The
single-argument directory form avoids suppressing the default SwiftUI window in
the observed AppKit launch behavior. Malformed, non-demo and duplicated directory
arguments are rejected before storage initialization. The
second command measures already committed synthetic journal data becoming visible
through loopback HTTP without a manual sync. It excludes physical input, collector
flush delay, Internet/TLS latency and offline retry delays; it is not a complete
three-second end-to-end guarantee.

## Source publication checks

```sh
python3 -m unittest discover -s Tests/PublicationChecks -v
python3 scripts/export-source.py --check
```

The exporter uses a source allowlist, rejects suspicious content and excludes
local state. It is a release hygiene check, not proof of all PRD requirements or
arbitrary sensitive-prose detection. See docs/open-source.md.
