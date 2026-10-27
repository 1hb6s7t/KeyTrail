#!/bin/sh
# Source this helper before any build or output mutation. Validation creates nothing.
keytrail_validate_app_output() {
    python3 - "$1" "${KEYTRAIL_REPLACE_OUTPUT:-0}" <<'PYGUARD'
import os
from pathlib import Path
import stat
import sys

raw, replace = sys.argv[1:]
def refuse(message):
    print("Refusing application output: " + message, file=sys.stderr)
    raise SystemExit(2)

if replace not in {"0", "1"}:
    refuse("KEYTRAIL_REPLACE_OUTPUT must be 0 or 1")
if not raw or not os.path.isabs(raw) or not raw.endswith(".app"):
    refuse("use a non-empty absolute path ending in .app")
if any(part in {".", ".."} for part in raw.split("/")) or any(ord(c) < 32 for c in raw):
    refuse("path traversal and control characters are not allowed")
output = Path(raw)
if output.name.casefold() in {".app", "keytrail-cat-validation.app", "keytrail-dashboard-fixed.app", "keytrail-float-validation.app"}:
    refuse("this application name is protected; choose a separate development output")
# Check the path itself and every existing ancestor, including dangling links.
for candidate in [output, *output.parents]:
    try:
        mode = candidate.lstat().st_mode
    except FileNotFoundError:
        continue
    except OSError:
        refuse("an output path component is inaccessible or not a directory")
    if stat.S_ISLNK(mode):
        refuse("symbolic links are not allowed in the output path")
    if candidate != output and not stat.S_ISDIR(mode):
        refuse("an output parent is not a directory")
if output.exists():
    if replace != "1":
        refuse("path already exists; use KEYTRAIL_REPLACE_OUTPUT=1 only for a disposable development output")
    if not output.is_dir():
        refuse("an existing output must be an application directory")
print(output)
PYGUARD
}
