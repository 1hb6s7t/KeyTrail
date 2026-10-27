# Privacy and data handling

KeyTrail collects only after explicit user action and normal OS permission.
Optional text, private synchronization and login startup default off. There is no
clipboard reader, advertising service, public cloud endpoint or analytics SDK.

## Statistics

SQLite stores minute aggregates, per-minute physical-key histograms, activity masks
and rhythm summaries. It does not store ordered physical keystrokes or screen
coordinates. Current pet poses are bounded in-memory sets and short pulses; they
are neither a stored event stream nor a synchronization payload.

Queries use half-open ranges and the viewing device's local calendar. Historical
selection/deletion is minute-granular. Keyboard and mouse active windows are
unioned; pause, lock and sleep terminate or suspend activity. Display-point cursor
distance is not calibrated physical movement. These are activity indicators, not
attention, productivity or health measurements.

## Optional text

Supported non-secure controls may yield committed text fragments after opt-in.
Focus changes establish a baseline; unsupported, unsafe or inconsistent snapshots
are skipped. Coverage varies by editor, input method and accessibility support;
this is not a full reconstruction of every document or edit.

Text is separate AES-GCM ciphertext with authenticated metadata. Metadata includes
time, application identifier and character count. macOS uses a profile-scoped
Keychain service; Windows protects the key with current-user DPAPI. Keyword search
decrypts locally and does not create a plaintext full-text index. Read-only capacity
queries do not load a decryption key. Existing technical IDs are retained for data
and permission compatibility.

## Sync, deletion and export

The user supplies their own private endpoint. HTTP is accepted only for loopback;
remote use requires HTTPS. Statistics synchronization is explicit, and ciphertext
text synchronization has its own switch. The private service never receives the
text decryption key. A phone viewer retains credentials and decrypted text in page
memory, not URLs or persistent browser storage; static shell caching excludes APIs.

Deletion applies locally and produces tombstones. An offline remote replica retains
older records until successful synchronization, so deletion is eventually consistent.
A storage cap removes oldest records with dependent metadata; required tombstones
can prevent reaching the requested byte target, which is reported explicitly.

TXT and CSV exports are deliberately readable files and are not automatically
uploaded. Users decide where they are saved and shared. Tests and public bug reports
must use synthetic data. Never publish real databases, settings with tokens, archive
keys, screenshots of personal activity or local diagnostic histories.
