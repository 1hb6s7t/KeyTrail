#!/bin/sh
# Local desktop-cat integration build. SDK acquisition is an explicit user action;
# this script only reads an already downloaded SDK and never fetches it.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PRODUCTS=${KEYTRAIL_BUILD_PRODUCTS:-$ROOT/.build/release}
VERSION=${KEYTRAIL_VERSION:-1.3.3}
BUILD=${KEYTRAIL_BUILD:-27}
ASSETS="$ROOT/artifacts/bongo-assets"
case "${KEYTRAIL_CAT_PREVIEW:-0}" in
  0) APP="$ROOT/artifacts/KeyTrail-Cat-dev.app"; VALIDATION=1; PREVIEW=0; PET_ID=com.auriel.keytrail.validation.pet ;;
  1) APP="$ROOT/artifacts/KeyTrail-Cat-preview.app"; VALIDATION=0; PREVIEW=1; PET_ID=com.auriel.keytrail.preview.pet ;;
  *) echo 'KEYTRAIL_CAT_PREVIEW must be 0 or 1' >&2; exit 2 ;;
esac
if [ "${KEYTRAIL_CAT_APP_OUTPUT+x}" = x ]; then APP="$KEYTRAIL_CAT_APP_OUTPUT"; fi
. "$ROOT/scripts/app-output-guard.sh"
APP=$(keytrail_validate_app_output "$APP")
SDK=${KEYTRAIL_CUBISM_SDK:?Set KEYTRAIL_CUBISM_SDK to the extracted official SDK root}
CORE="$SDK/Core/dll/macos/libLive2DCubismCore.dylib"
test -f "$CORE"
test -f "$ASSETS/standard/cat.model3.json"
test -f "$ASSETS/standard/demomodel.moc3"
# Do not replace any of the already-authorized real-use or validation bundles.
KEYTRAIL_VERSION=$VERSION KEYTRAIL_BUILD=$BUILD KEYTRAIL_VALIDATION=$VALIDATION KEYTRAIL_PREVIEW=$PREVIEW KEYTRAIL_APP_OUTPUT="$APP" \
    "$ROOT/scripts/package-app.sh"
PET="$APP/Contents/Helpers/KeyTrailPet.app"
mkdir -p "$PET/Contents/MacOS" "$PET/Contents/Resources/Licenses"
cp "$PRODUCTS/KeyTrailPet" "$PET/Contents/MacOS/KeyTrailPet"
cp "$CORE" "$PET/Contents/Resources/libLive2DCubismCore.dylib"
cp -R "$ASSETS/standard" "$PET/Contents/Resources/standard"
cp "$ROOT/docs/bongo-cat-assets.md" "$PET/Contents/Resources/Licenses/bongo-cat-assets.md"
find "$SDK/Core" -maxdepth 1 -type f \( -iname '*license*' -o -iname '*notice*' -o -name RedistributableFiles.txt \) -exec cp {} "$PET/Contents/Resources/Licenses/" \;
for notice in "$SDK/LICENSE.md" "$SDK/NOTICE.md"; do
    if [ -f "$notice" ]; then cp "$notice" "$PET/Contents/Resources/Licenses/SDK-$(basename "$notice")"; fi
done
cp "$ASSETS/LICENSE.upstream" "$PET/Contents/Resources/Licenses/BongoCat-APACHE-LICENSE"
cp "$ASSETS/manifest.json" "$PET/Contents/Resources/Licenses/bongo-assets-manifest.json"
cat > "$PET/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KeyTrailPet</string>
<key>CFBundleIdentifier</key><string>$PET_ID</string>
<key>CFBundleName</key><string>KeyTrailPet</string>
<key>CFBundleDisplayName</key><string>键迹桌面小猫</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$PET"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Local integration package: %s\n' "$APP"
