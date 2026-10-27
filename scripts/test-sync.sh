#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
"$ROOT/scripts/test-sync-scheduling.sh"
./scripts/build-rust.sh
export KEYTRAIL_TEST_SERVER=${KEYTRAIL_TEST_SERVER:-${CARGO_TARGET_DIR:-$ROOT/rust/target}/release/keytrail-server}
if [ -n "${KEYTRAIL_SWIFT_SCRATCH:-}" ]; then
  swift run --scratch-path "$KEYTRAIL_SWIFT_SCRATCH" -c release KeyTrailSyncChecks
else
  swift package clean
  swift run -c release KeyTrailSyncChecks
fi
