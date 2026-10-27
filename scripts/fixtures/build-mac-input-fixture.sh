#!/bin/sh
# Compile only. Never launches the app or requests permissions.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
FIXTURE_OUTPUT="$ROOT/artifacts/mac-input-fixture"
APP="$FIXTURE_OUTPUT/SyntheticInputFixture.app"
mkdir -p "$APP/Contents/MacOS"
case "$(uname -m)" in
  arm64) FIXTURE_TARGET=arm64-apple-macosx14.0 ;;
  x86_64) FIXTURE_TARGET=x86_64-apple-macosx14.0 ;;
  *) echo "Unsupported macOS architecture" >&2; exit 2 ;;
esac
xcrun swiftc -parse-as-library -swift-version 6 -O -target "$FIXTURE_TARGET" \
  -framework AppKit "$ROOT/scripts/fixtures/MacInputFixture.swift" \
  -o "$APP/Contents/MacOS/SyntheticInputFixture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.auriel.synthetic-input-fixture</string>
<key>CFBundleExecutable</key><string>SyntheticInputFixture</string>
<key>CFBundleName</key><string>Synthetic Input Fixture</string>
<key>CFBundleDisplayName</key><string>Synthetic Input Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSQuitAlwaysKeepsWindows</key><false/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"
printf '%s\n' "Compiled and ad-hoc verified fixture only: $APP" \
  'Not launched. Standard NSSecureTextField; actual system secure-input state remains unverified.'
