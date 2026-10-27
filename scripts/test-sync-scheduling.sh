#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEMPORARY=$(mktemp -d "${TMPDIR:-/tmp}/keytrail-sync-schedule.XXXXXX")
trap 'rm -rf "$TEMPORARY"' EXIT HUP INT TERM
swiftc -module-cache-path "$TEMPORARY/module-cache" \
    "$ROOT/Sources/KeyTrailRuntime/PrivateSyncSchedule.swift" \
    "$ROOT/Tests/SyncSchedulingChecks/SyncSchedulingChecks.swift" \
    -o "$TEMPORARY/schedule-checks"
"$TEMPORARY/schedule-checks"
