#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"
PRODUCTS=${KEYTRAIL_BUILD_PRODUCTS:-$ROOT/.build/release}
export MACOSX_DEPLOYMENT_TARGET=14.0

VERSION=${KEYTRAIL_VERSION:-1.2.1}
BUILD=${KEYTRAIL_BUILD:-20}
PREVIEW=${KEYTRAIL_PREVIEW:-0}
VALIDATION=${KEYTRAIL_VALIDATION:-0}
case "$PREVIEW" in
  0|1) ;;
  *) echo "KEYTRAIL_PREVIEW must be 0 or 1" >&2; exit 2 ;;
esac
case "$VALIDATION" in
  0|1) ;;
  *) echo "KEYTRAIL_VALIDATION must be 0 or 1" >&2; exit 2 ;;
esac
if [ "$PREVIEW" = 1 ] && [ "$VALIDATION" = 1 ]; then
  echo "Preview and real-input validation are separate profiles" >&2; exit 2
fi

# Preview builds default to a separate path. An explicit output path must be absolute.
if [ "${KEYTRAIL_APP_OUTPUT+x}" = x ]; then
  if [ -z "$KEYTRAIL_APP_OUTPUT" ]; then
    echo "KEYTRAIL_APP_OUTPUT must be a non-empty full .app path" >&2
    exit 2
  fi
  APP_OUTPUT=$KEYTRAIL_APP_OUTPUT
elif [ "$VALIDATION" = 1 ]; then
  APP_OUTPUT="$ROOT/artifacts/KeyTrail-v1.2-validation.app"
elif [ "$PREVIEW" = 1 ]; then
  APP_OUTPUT="$ROOT/artifacts/KeyTrail-preview.app"
else
  APP_OUTPUT="$ROOT/artifacts/KeyTrail-v1.2-candidate.app"
fi

. "$ROOT/scripts/app-output-guard.sh"
APP=$(keytrail_validate_app_output "$APP_OUTPUT")

if [ "$VALIDATION" = 1 ]; then
  if [ "$APP" = "$ROOT/artifacts/KeyTrail.app" ]; then
    echo "Refusing to replace the normal app with a validation build" >&2
    exit 2
  fi
  OUTER_BUNDLE_ID=com.auriel.keytrail.validation
  DASH_BUNDLE_ID=com.auriel.keytrail.validation.dashboard
  OUTER_DISPLAY_NAME="KeyTrail 键迹（验证）"
  DASH_DISPLAY_NAME="KeyTrail 键迹看板（验证）"
  FLAVOR=" validation"
elif [ "$PREVIEW" = 1 ]; then
  if [ "$APP" = "$ROOT/artifacts/KeyTrail.app" ]; then
    echo "Refusing to replace the normal app with a preview build" >&2
    exit 2
  fi
  OUTER_BUNDLE_ID=com.auriel.keytrail.preview
  DASH_BUNDLE_ID=com.auriel.keytrail.preview.dashboard
  OUTER_DISPLAY_NAME="KeyTrail 键迹（预览）"
  DASH_DISPLAY_NAME="KeyTrail 键迹看板（预览）"
  FLAVOR=" preview"
else
  OUTER_BUNDLE_ID=com.auriel.keytrail
  DASH_BUNDLE_ID=com.auriel.keytrail.dashboard
  OUTER_DISPLAY_NAME="KeyTrail 键迹"
  DASH_DISPLAY_NAME="KeyTrail 键迹看板"
  FLAVOR=""
fi

case "${KEYTRAIL_SKIP_BUILD:-0}" in
  0)
    # SwiftPM does not track the external Rust archive; clean after building it.
    "$ROOT/scripts/build-rust.sh"
    swift package clean
    swift build -c release
    ;;
  1)
    # Explicit local packaging after the caller has just built/tested this tree.
    test -x "$PRODUCTS/KeyTrailAgent"
    test -x "$PRODUCTS/KeyTrailDashboard"
    ;;
  *) echo "KEYTRAIL_SKIP_BUILD must be 0 or 1" >&2; exit 2 ;;
esac

CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
HELPERS="$CONTENTS/Helpers"
DASH="$HELPERS/KeyTrailDashboard.app"
APP=$(keytrail_validate_app_output "$APP")
rm -rf "$APP"
mkdir -p "$MACOS" "$CONTENTS/Resources" "$DASH/Contents/MacOS" "$DASH/Contents/Resources"
cp "$PRODUCTS/KeyTrailAgent" "$MACOS/KeyTrail"
cp "$PRODUCTS/KeyTrailDashboard" "$DASH/Contents/MacOS/KeyTrailDashboard"
cp "$ROOT/Sources/KeyTrailApp/Resources/journal-keycaps.png" "$DASH/Contents/Resources/journal-keycaps.png"
chmod 755 "$MACOS/KeyTrail" "$DASH/Contents/MacOS/KeyTrailDashboard"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>KeyTrail</string>
  <key>CFBundleIdentifier</key><string>$OUTER_BUNDLE_ID</string>
  <key>CFBundleName</key><string>KeyTrail</string>
  <key>CFBundleDisplayName</key><string>$OUTER_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

cat > "$DASH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>KeyTrailDashboard</string>
  <key>CFBundleIdentifier</key><string>$DASH_BUNDLE_ID</string>
  <key>CFBundleName</key><string>KeyTrailDashboard</string>
  <key>CFBundleDisplayName</key><string>$DASH_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign the nested application before its containing application.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$DASH"
  codesign --force --sign - "$APP"
fi
printf 'Created %s (version %s build %s%s)\n' "$APP" "$VERSION" "$BUILD" "$FLAVOR"
