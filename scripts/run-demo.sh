#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/artifacts/KeyTrail-preview.app"

if [ ! -x "$APP/Contents/MacOS/KeyTrail" ] || [ ! -x "$APP/Contents/Helpers/KeyTrailDashboard.app/Contents/MacOS/KeyTrailDashboard" ]; then
  KEYTRAIL_PREVIEW=1 KEYTRAIL_APP_OUTPUT="$APP" "$ROOT/scripts/package-app.sh"
fi

open -n "$APP" --args --demo
