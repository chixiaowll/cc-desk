#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product CCDesk
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/CCDesk"
APP="build/CCDesk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CCDesk"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
SWIFTTERM_BUNDLE="$BIN_DIR/SwiftTerm_SwiftTerm.bundle"
if [ -e "$SWIFTTERM_BUNDLE" ]; then
    cp -R "$SWIFTTERM_BUNDLE" "$APP/Contents/Resources/"
fi
codesign --force --sign - "$APP"
echo "$APP"
