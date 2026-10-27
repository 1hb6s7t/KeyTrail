#!/bin/sh
# A separate, read-only companion leaves the authorized collector bundle intact.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"
PRODUCTS=${KEYTRAIL_BUILD_PRODUCTS:-$ROOT/.build/release}
case "${KEYTRAIL_FLOAT_PROFILE:-validation}" in
  validation) PROFILE='KeyTrail Validation'; SUFFIX=validation; COLLECTOR="$ROOT/artifacts/KeyTrail-Cat-dev.app" ;;
  normal) PROFILE=KeyTrail; SUFFIX=normal; COLLECTOR="$ROOT/artifacts/KeyTrail-v1.2-candidate.app" ;;
  demo) PROFILE='KeyTrail Demo'; SUFFIX=demo; COLLECTOR="$ROOT/artifacts/KeyTrail-preview.app" ;;
  *) echo 'KEYTRAIL_FLOAT_PROFILE must be validation, normal, or demo' >&2; exit 2 ;;
esac
# These are read-only launch links written to this new bundle's metadata.
# They are never passed to the output guard, copied, signed, or modified.
COLLECTOR=${KEYTRAIL_FLOAT_COLLECTOR_APP-$COLLECTOR}
if [ "$SUFFIX" = validation ]; then
  DASHBOARD="$ROOT/artifacts/KeyTrail-Dashboard-dev.app"
else
  DASHBOARD="$COLLECTOR/Contents/Helpers/KeyTrailDashboard.app"
fi
DASHBOARD=${KEYTRAIL_FLOAT_DASHBOARD_APP-$DASHBOARD}
for TARGET in "$COLLECTOR" "$DASHBOARD"; do
  case "$TARGET" in
    /*.app) ;;
    *) echo 'Float collector/dashboard links must be non-empty absolute .app paths' >&2; exit 2 ;;
  esac
done
APP_OUTPUT=${KEYTRAIL_FLOAT_APP_OUTPUT-$ROOT/artifacts/KeyTrail-Float-$SUFFIX-dev.app}
. "$ROOT/scripts/app-output-guard.sh"
APP=$(keytrail_validate_app_output "$APP_OUTPUT")
python3 - "$APP" "$COLLECTOR" "$DASHBOARD" <<'PYLINKS'
from pathlib import Path
import sys
output = Path(sys.argv[1]).resolve()
for raw in sys.argv[2:]:
    target = Path(raw).resolve()
    if output == target or output in target.parents or target in output.parents:
        raise SystemExit('Float output must be separate from the collector and dashboard launch targets')
PYLINKS
case "${KEYTRAIL_SKIP_BUILD:-0}" in
  0) swift build -c release --product KeyTrailFloat ;;
  1) test -x "$PRODUCTS/KeyTrailFloat" ;;
  *) echo 'KEYTRAIL_SKIP_BUILD must be 0 or 1' >&2; exit 2 ;;
esac
APP=$(keytrail_validate_app_output "$APP")
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/KeyTrailFloat" "$APP/Contents/MacOS/KeyTrailFloat"
python3 - "$APP" "$PROFILE" "$SUFFIX" "$COLLECTOR" "$DASHBOARD" <<'PY'
import pathlib,plistlib,sys
app,profile,suffix,collector,dashboard=sys.argv[1:]
value={'CFBundleExecutable':'KeyTrailFloat','CFBundleIdentifier':'com.auriel.keytrail.float.'+suffix,
       'CFBundleName':'KeyTrail Float','CFBundleDisplayName':'键迹数据浮窗',
       'CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.3.1','CFBundleVersion':'24',
       'LSMinimumSystemVersion':'14.0','LSUIElement':True,'NSPrincipalClass':'NSApplication',
       'KeyTrailDataProfile':profile,'KeyTrailCollectorApp':collector,'KeyTrailDashboardApp':dashboard}
with (pathlib.Path(app)/'Contents/Info.plist').open('wb') as f:plistlib.dump(value,f)
PY
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Created data window: %s\n' "$APP"
