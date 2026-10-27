#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
./scripts/build-rust.sh
if [ -n "${KEYTRAIL_SWIFT_SCRATCH:-}" ]; then
  swift run --scratch-path "$KEYTRAIL_SWIFT_SCRATCH" -c release KeyTrailRuntimeChecks
else
  swift package clean
  swift run -c release KeyTrailRuntimeChecks
fi
