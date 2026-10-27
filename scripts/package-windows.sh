#!/bin/sh
# Cross-build only. This does not launch the collector or establish Windows runtime acceptance.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TASK_ROOT"
if ! docker image inspect keytrail-windows-builder:1.2 >/dev/null 2>&1; then
  docker build -t keytrail-windows-builder:1.2 - < scripts/package-windows.Dockerfile
fi
docker run --rm -v "$TASK_ROOT:/src" -e CARGO_HOME=/src/.toolchains/windows-cargo -e CARGO_TARGET_DIR=/src/rust/target-windows keytrail-windows-builder:1.2 cargo build --locked --release --manifest-path rust/Cargo.toml -p keytrail-windows --target x86_64-pc-windows-gnu
docker run --rm -v "$TASK_ROOT:/src" -e CARGO_HOME=/src/.toolchains/windows-cargo -e CARGO_TARGET_DIR=/src/rust/target-windows keytrail-windows-builder:1.2 cargo test --locked --no-run --manifest-path rust/Cargo.toml -p keytrail-core -p keytrail-server -p keytrail-windows --target x86_64-pc-windows-gnu
python3 - <<'PY'
from pathlib import Path
import shutil,zipfile,hashlib
root=Path.cwd();dest=root/'artifacts/KeyTrail-Windows-v1.2';dest.mkdir(parents=True,exist_ok=True)
for source,name in [(root/'rust/target-windows/x86_64-pc-windows-gnu/release/keytrail-windows.exe','keytrail-windows.exe'),(root/'rust/keytrail-windows/README.md','README.md')]:shutil.copyfile(source,dest/name)
checksum=hashlib.sha256((dest/'keytrail-windows.exe').read_bytes()).hexdigest();(dest/'SHA256.txt').write_text(checksum+'  keytrail-windows.exe\n')
with zipfile.ZipFile(root/'artifacts/KeyTrail-Windows-v1.2.zip','w',zipfile.ZIP_DEFLATED)as archive:
 for file in dest.iterdir():archive.write(file,arcname='KeyTrail-Windows-v1.2/'+file.name)
print('Windows PE release and test executables compiled; package saved. No Windows runtime was launched.')
PY
