# KeyTrail Windows 1.2

This is a native Windows 10/11 resident with passive Raw Input, an explicit
Start/Pause control, tray menu, a shared read-only browser dashboard, an optional
current-hour floating window with civil-hour boundaries across half-hour DST changes, explicit current-user login toggle, combined storage
cap, and independent private aggregate/encrypted-text sync. **Startup begins paused.**
Closing the control window hides it to the tray; Quit stops the resident's HTTP,
sync and UI Automation workers. There is no service installation, automatic admin
elevation, startup registration, or collection enabled by merely opening the package.

Quit first pauses capture and commits pending statistics plus the activity-end
boundary. If that final write fails, Quit is blocked: the resident stays paused,
retains pending input and its first cutoff, and reports an error. Fix storage and
retry Quit. A successful retry does not count the paused interval or duplicate input.

Run `keytrail-windows.exe` manually. Open dashboard launches a loopback browser;
Copy viewer credential explicitly copies an ephemeral read-only credential to paste
into its password field. This token is never put in a URL, config file or browser
storage, and expires when the resident exits. The read-only server shares the
resident's Engine and cannot ingest, delete, replicate or modify settings. Closing
the browser does not stop the resident; quitting the resident closes its listener.

Statistics CSV export uses the same read-only `exportPage`/`exportValidate` protocol
as the private viewer. Each page is bounded to 1 MiB of JSON, with source/revision
and exact-range validation; the browser downloads bounded CSV parts plus a final
completion manifest. Large ranges are not silently truncated at 8 MiB. Collection,
deletion or retention during the export invalidates its snapshot and requires a
restart. The local viewer retains no mutation route for this feature.

Raw Input uses INPUTSINK without hooks, suppression or NOLEGACY. Physical scan-code
make/break state ignores auto-repeat makes. Only counts, per-minute histograms and
activity masks persist. Coordinates are a transient cursor baseline; the engine
receives scalar movement in the process's default 96-DPI logical display coordinate
space. Raw HID counts never masquerade as display points or physical desk distance.
Pause/lock/session disconnect/suspend clear transient activity. If an end transaction
fails, a sticky first cutoff blocks new collection and retries that original instant;
waking cannot fill locked/sleeping time into the activity union.

Settings are under `%LOCALAPPDATA%\KeyTrail`. A share-denied owner file prevents two
residents across Windows console/RDP sessions from owning the same profile. This lock
is acquired before any settings write. Settings inherit the current-user profile ACL;
keep this directory private. Bearer credentials and the text archive key are protected
with current-user Windows DPAPI; no plaintext key or credential is stored in JSON.
Endpoint/credential/enable changes are saved as a complete candidate before becoming
live. Each POST rechecks the latest endpoint, credential and scope enable state.

Private sync defaults off. Set your own private HTTPS origin and collector credential,
then deliberately enable aggregate sync and/or independent encrypted text sync.
WinHTTP uses OS TLS certificate validation, disallows redirects, and permits HTTP
only for loopback. It retries durable journal snapshots/tombstones with backoff,
commits only acknowledged sent-page cursors, and independently resets the appropriate
cursor when an aggregate/text replica identity changes. Nothing connects to a bundled
public service. Login startup changes only the current-user Run key, only through
its explicit toggle, and still launches paused. If the system change succeeds but
saving preferences fails, status reports that failure instead of replacing it with a
success message; the displayed setting follows the actual Windows Run-key state.

The worker checks enabled local journals at most once per second and uploads pending
changes promptly, rather than waiting 30 seconds after a successful round. The native
one-second flush plus the one-second scheduling budget targets delivery within three
seconds on a healthy private connection; OS scheduling, server load and network latency
still require runtime measurement. With no pending changes, network identity probes
run only every 30 seconds to detect a rebuilt remote database. Disabled sync performs
no journal preflight or network requests. Failures retain both journals/cursors and
back off for 60, 120, 240, then 480 seconds from request completion; ordinary input
does not bypass this backoff. Sync now or an actual endpoint/credential/device/scope
change can retry promptly. Connection/retry status has a dedicated line, separate
from collection messages. The same monotonic scheduler used by the Windows worker
has host fixtures using real temporary Engine/TextArchive/private Service instances;
these are scheduling and protocol evidence, not an OS or HTTPS latency measurement.

The storage cap defaults to unlimited. Enabling a cap of at least 1 MiB flushes the
activity boundary and atomically removes the oldest natural minute across both
statistics and text databases through an ATTACH transaction. Both deletion journals
commit together; failure rolls back both sides. Vacuum follows outside the transaction.
Metadata/tombstones may prevent the requested size; status reports that honestly.
The final small batch is compacted and checked after each complete natural minute,
so a small excess does not discard every remaining record merely to fill a batch.
Maintenance repeats every minute while a cap remains enabled. Status shows combined
bytes, text bytes, text record count and the configured cap.

## Optional committed-text capture

Text capture and encrypted text sync are separate switches, both off by default.
To use supported controls, enable local text recording, save settings, then explicitly
Start collection. UI Automation reads only in a short window after Raw Input keyboard
or pointer intent. It excludes the KeyTrail process, background processes, IsPassword
fields, disabled/nonfocusable controls, and providers without reliable composition or
selection evidence. Only Edit/Document controls exposing TextEditPattern with successful
GetActiveComposition/GetConversionTarget and no active range can produce a committed
snapshot. The real UIA adapter uses a bounded coordinator that brackets two identical
text/UTF-16-selection reads with three clear composition checks and matching focused
control/process/security context. A changing body, caret, composition state or context
is rejected and clears the extraction baseline; active composition never reads preedit
payload. This sampling reduces cross-call races. It is not an atomic Windows snapshot
and does not guarantee rejection of an entire begin/commit/restore cycle between calls.
Legacy controls, unsupported IMEs, protected/elevated controls, secure desktops
and unknown composition states **fail closed**, with a visible explanation. No clipboard
read APIs are used. There is no claim that all Windows applications are covered.

Windows application identifiers use a sanitized executable basename prefixed with `windows.`; they are not macOS bundle IDs. A focused-control baseline is not archived. Subsequent insertions/replacements must
match the old UTF-16 selection, unchanged prefix/suffix and new collapsed caret;
surrogate boundaries are protected, and combining-mark insertion follows the same
contract as macOS. Composition/preedit is held in memory, never saved as committed text.
Focus changes, pause, lock, cleanup, delete and text-mode changes invalidate prior work.
Before persisting, the worker rechecks generation, intent deadline, current foreground
PID/focus/password status and the enabled state. Provider timeouts and bounded shutdown
prevent a stalled provider from leaving a hidden resident process after Quit.

Committed fragments encrypt locally with a random AES-256 key protected by DPAPI.
The wire format and original sorted-key metadata AAD match macOS CryptoKit and the
phone WebCrypto viewer. SQLite stores ciphertext and metadata; there is no plaintext
search index. Copy text decryption key is an explicit local clipboard write. Paste it
in the local or private browser's optional text panel to decrypt/search/inspect coverage
and explicitly export TXT. The key and keyword stay in page memory. Native Manage/delete local data opens a resident-owned management window. It has four
separate actions: delete one encrypted text UUID, delete only text in a chosen range,
atomically delete statistics plus text in a chosen range, or clear all recorded data.
Copy record ID in the local dashboard supplies a UUID to paste into the native field;
there is no HTTP delete or writable selection bridge. A native confirmation displays
the exact ID/metadata or range and affected counts. Time fields accept YYYY-MM-DD HH:MM
in local or explicit UTC mode. Local gaps/repeated DST minutes are rejected with an
instruction to use UTC. Every operation first pauses/ends activity and invalidates old
UIA work; a pending failed cutoff blocks deletion. Confirmation and deletion run in
resident-owned workers so the control window remains responsive. Start and automatic
retention are blocked while a data-management job is pending. Cancelling or completing
an operation leaves collection paused, including clear-all; resume requires explicit
Start. Range/clear journal changes and both stores use one ATTACH transaction. Clear
preserves settings, AES keys, revision domains and durable tombstones. Remote and phone
viewers remain read-only.

The `--demo` switch uses the separate `%LOCALAPPDATA%\KeyTrail-Demo-v1.2` profile,
visibly marks synthetic data, disables real input/text capture and remote sync, and
refuses login registration. Demo evidence is separate from real monitoring acceptance.

## Build, tests and remaining runtime verification

On a Windows desktop with Rust and Visual Studio Build Tools:

```powershell
cargo test --locked --manifest-path rust/Cargo.toml -p keytrail-windows
./scripts/package-windows.ps1
.\rust\target\release\keytrail-windows.exe --demo
```

On a Docker host, `scripts/package-windows.sh` uses a Linux MinGW toolchain
container to produce a Windows x86-64 PE release and compile test executables
with `--no-run`. It does not launch collection. The output ZIP is
`artifacts/KeyTrail-Windows-v1.2.zip`; SQLite is bundled. The Windows workflow runs
locked tests and packaging when triggered; a local workflow file is not evidence
that remote CI has passed.

For Wine checks, prepare the images and current test executables described in
[testing](../../docs/testing.md). `scripts/test-windows-wine.py` lists and executes
every selected PE group in this run and records actual counts and exit codes.
Synthetic GUI/capture fixtures use disposable profiles and XTEST input. They do
not establish physical keyboard reception or Windows-kernel behavior.

The suite covers normalization, display-point scaling, endpoint validation,
UTF-16 differences, authenticated text encryption, public Swift interoperability
fixtures, deletion/retention transactions, revision receipts, provider composition
state and failure/retry paths. Deterministic provider checks cannot establish
UI Automation or real IME coverage in arbitrary editors.

Runtime acceptance still requires supported Windows desktops: physical Raw Input,
UIA/IME, secure fields, DPI transitions, lock/sleep/RDP, tray/UI, login startup,
private HTTPS and separate background/dashboard resource measurements. Current
limitations are listed in [known issues](../../docs/known-issues.md). Historical
personal test logs and screenshots are excluded from the public repository.

Official API references:
- [Microsoft Raw Input](https://learn.microsoft.com/en-us/windows/win32/inputdev/using-raw-input)
- [Session notifications](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/nf-wtsapi32-wtsregistersessionnotification)
- [Suspend event](https://learn.microsoft.com/en-us/windows/win32/power/pbt-apmsuspend)
- [Cursor coordinates](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getcursorpos)
- [TextEdit active composition](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationtexteditpattern-getactivecomposition)
- [Rust Windows platform support](https://doc.rust-lang.org/rustc/platform-support/windows-msvc.html)
