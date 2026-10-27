# Preparing a public source snapshot

The public repository contains code, tests, dependency references and sanitized
documentation. Generated applications, SDKs/models, toolchains, data, diagnostic
history and personal screenshots are deliberately outside its scope.

Run the publication check and export into a new destination:

```sh
python3 scripts/export-source.py --check
python3 scripts/export-source.py
```

The default output is `release/KeyTrail-source/`, a sibling ZIP and ZIP checksum.
The source directory contains a file checksum manifest. The exporter refuses
existing outputs; choose a new `--output` directory for another snapshot.

Review the exported file list and scan result before publishing. Copying the
original working directory, hidden .git directory or tool-generated internal refs
can reintroduce removed private files. Initialize Git only inside the reviewed clean
snapshot. Never use `push --mirror` to publish a private development workspace.
No export command initializes Git, commits, configures a remote or uploads anything.

The ignore rules protect normal development, while the exporter applies a separate
allowlist and detects common credential/personal-path patterns. Neither can prove
that arbitrary prose is non-sensitive; review new screenshots, examples and
business documents manually. Fixed public TEST-ONLY cryptography fixtures are not
production secrets and must never be used to protect user data.

Deployment files named `config.json`, `server.json`, `settings.json` or
`credentials.json` under `deploy/` are refused by the exporter and ignored by Git
and Docker. Literal collector/viewer/sync tokens are also checked in JSON, YAML
and source assignments. Generate private deployment configuration outside the
source tree; no scanner is a substitute for keeping live configuration separate.

The repository uses Apache-2.0 for KeyTrail-owned source. Read LICENSE, NOTICE and
THIRD_PARTY_NOTICES.md. The optional desktop-cat SDK/model assets are not included;
a future bundled binary release needs a separate rights and dependency-notice check.

Before upload, verify a clean source copy builds and the relevant tests pass. Keep
local validation logs outside the snapshot. Source publication is separate from
full Windows/mobile/IME/hardware acceptance; current limitations remain documented.
