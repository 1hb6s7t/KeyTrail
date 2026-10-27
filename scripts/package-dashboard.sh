#!/bin/sh
# Dashboard-only package; collection remains owned by the existing agent.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"
PRODUCTS=${KEYTRAIL_BUILD_PRODUCTS:-$ROOT/.build/release}
VERSION=${KEYTRAIL_VERSION:-1.3.3}
BUILD=${KEYTRAIL_BUILD:-27}
case "${KEYTRAIL_DASHBOARD_PROFILE:-validation}" in
  validation) BUNDLE_ID=com.auriel.keytrail.validation.dashboard.repaired ;;
  normal) BUNDLE_ID=com.auriel.keytrail.dashboard ;;
  journal) BUNDLE_ID=com.auriel.keytrail.journal.dashboard ;;
  demo|preview) BUNDLE_ID=com.auriel.keytrail.preview.dashboard ;;
  *) echo 'KEYTRAIL_DASHBOARD_PROFILE must be validation, normal, journal, or demo' >&2; exit 2 ;;
esac
APP_OUTPUT=${KEYTRAIL_DASHBOARD_APP_OUTPUT-$ROOT/artifacts/KeyTrail-Dashboard-dev.app}
. "$ROOT/scripts/app-output-guard.sh"
APP=$(keytrail_validate_app_output "$APP_OUTPUT")
case "${KEYTRAIL_SKIP_BUILD:-0}" in
  0) swift build -c release --product KeyTrailDashboard ;;
  1) test -x "$PRODUCTS/KeyTrailDashboard" ;;
  *) echo 'KEYTRAIL_SKIP_BUILD must be 0 or 1' >&2; exit 2 ;;
esac
APP=$(keytrail_validate_app_output "$APP")
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/KeyTrailDashboard" "$APP/Contents/MacOS/KeyTrailDashboard"
cp "$ROOT/Sources/KeyTrailApp/Resources/journal-keycaps.png" "$APP/Contents/Resources/journal-keycaps.png"
python3 - "$APP" "$BUNDLE_ID" "$VERSION" "$BUILD" <<'PYPLIST'
import pathlib,plistlib,sys
app,identifier,version,build=sys.argv[1:]
value={'CFBundleExecutable':'KeyTrailDashboard','CFBundleIdentifier':identifier,
'CFBundleName':'KeyTrail Dashboard','CFBundleDisplayName':'键迹看板', 'CFBundlePackageType':'APPL',
'CFBundleShortVersionString':version,'CFBundleVersion':build,'LSMinimumSystemVersion':'14.0','NSPrincipalClass':'NSApplication'}
with (pathlib.Path(app)/'Contents/Info.plist').open('wb') as f:plistlib.dump(value,f)
PYPLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Created dashboard: %s\n' "$APP"
